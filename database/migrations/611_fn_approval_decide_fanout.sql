-- Migration: 611_fn_approval_decide_fanout.sql
-- Module: Approval decision fan-out — notify drafter + mirror feedback to Comments
-- Date: 2026-06-09
--
-- Hala flagged the gap after Layla's "Request resubmission" on OQOOD-2026-003:
--   • no notification arrived in Hala's bell
--   • Layla's note was invisible from the Contract → Comments tab
--   • walk confirmed: fn_approval_decide only inserts approval_decision +
--     contract_activity. No fn_notification_dispatch call. No
--     contract_comment insert. The 'approval.requested_changes' rule
--     (id=23, in_app, enabled) exists, just nothing fires it.
--
-- This migration rewrites fn_approval_decide so that after the existing
-- state changes, two additional fan-out steps run:
--
--   1) Mirror p_decision_note → contract_comment when decision is
--      'reject' or 'request_resubmission' AND a note was provided.
--      Body is the literal note; mentioned_user_ids includes the
--      drafter so it surfaces in the @-mention feed too. Inserted as
--      the actor (decided_by). The Contract → Comments tab reads from
--      this table, so the feedback is visible immediately.
--
--   2) Fire fn_notification_dispatch with one of the existing seeded
--      event_types — the 'approval.requested_changes' rule (in_app,
--      enabled) routes to the drafter:
--        request_resubmission → approval.requested_changes
--        reject               → approval.rejected
--        approve (final step) → approval.approved
--      Each call is wrapped in a per-recipient BEGIN/EXCEPTION block
--      so a dispatch failure can't void the decision (matches the
--      proven pattern from mig 586 obligation.flag).
--
-- Behaviour for callers is unchanged — returned JSONB shape is the
-- same as today. State machine is untouched. Audit row from
-- fn_contract_activity_create still fires.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_approval_decide(
  p_step_id BIGINT,
  p_actor_id BIGINT,
  p_decision TEXT,
  p_decision_note TEXT DEFAULT NULL::text
)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_step                  RECORD;
  v_chain                 RECORD;
  v_contract_id           BIGINT;
  v_remaining_required    INTEGER;
  v_any_optional_peer     BOOLEAN;
  v_advance               BOOLEAN := FALSE;
  v_next_step_order       INTEGER;
  v_new_step_status       TEXT;
  v_new_chain_status      TEXT;
  v_new_contract_status   TEXT;
  v_advanced_to_step_order INTEGER;
  v_decision_id           BIGINT;
  v_actor_role            TEXT;
  -- 611 additions — used by the fan-out at the bottom.
  v_drafted_by            BIGINT;
  v_contract_number       TEXT;
  v_contract_title        TEXT;
  v_actor_first           TEXT;
  v_actor_last            TEXT;
  v_comment_id            BIGINT;
  v_event_type            TEXT;
  v_subject               TEXT;
  v_body                  TEXT;
BEGIN
  IF p_decision NOT IN ('approve','reject','request_resubmission') THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'decision:Invalid decision'
      USING ERRCODE = '22023';
  END IF;

  SELECT s.*
    INTO v_step
    FROM approval_step s
    WHERE s.id = p_step_id AND s.is_active = TRUE
    FOR UPDATE;
  IF v_step.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'id:Step not found'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT r.name INTO v_actor_role
    FROM "user" u
    JOIN role r ON r.id = u.role_id
   WHERE u.id = p_actor_id AND u.is_active = TRUE
   LIMIT 1;

  IF NOT (
    v_step.approver_user_id IS NOT DISTINCT FROM p_actor_id
    OR v_step.delegated_to  IS NOT DISTINCT FROM p_actor_id
    OR v_step.reassigned_to IS NOT DISTINCT FROM p_actor_id
    OR (v_step.approver_user_id IS NULL
        AND v_step.delegated_to IS NULL
        AND v_step.reassigned_to IS NULL
        AND v_actor_role IS NOT NULL
        AND v_actor_role = v_step.approver_role)
  ) THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'actor:Not the assigned approver'
      USING ERRCODE = '42501';
  END IF;

  IF v_step.approver_user_id IS NULL
     AND v_step.delegated_to IS NULL
     AND v_step.reassigned_to IS NULL THEN
    UPDATE approval_step
       SET approver_user_id = p_actor_id,
           updated_at = CURRENT_TIMESTAMP,
           updated_by = p_actor_id
     WHERE id = p_step_id;
    v_step.approver_user_id := p_actor_id;
  END IF;

  IF v_step.status <> 'pending' THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'status:Step already decided'
      USING ERRCODE = 'P0001';
  END IF;

  IF p_decision IN ('reject','request_resubmission')
     AND (p_decision_note IS NULL OR length(trim(p_decision_note)) = 0) THEN
    RAISE EXCEPTION 'fn_approval_decide: %',
      format('decisionNote:decisionNote is required for %s', p_decision)
      USING ERRCODE = '22023';
  END IF;

  SELECT ch.*
    INTO v_chain
    FROM approval_chain ch
    WHERE ch.id = v_step.approval_chain_id
    FOR UPDATE;
  IF v_chain.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'id:Chain not found'
      USING ERRCODE = 'P0002';
  END IF;

  v_contract_id := v_chain.contract_id;
  PERFORM 1 FROM contract WHERE id = v_contract_id FOR UPDATE;

  v_new_step_status := CASE p_decision
    WHEN 'approve' THEN 'approved'
    WHEN 'reject' THEN 'rejected'
    WHEN 'request_resubmission' THEN 'resubmission_requested'
  END;

  UPDATE approval_step
    SET status     = v_new_step_status,
        decided_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_step_id;

  INSERT INTO approval_decision (
    approval_step_id, decision, decided_by, decision_note,
    decided_at, created_by, is_active
  ) VALUES (
    p_step_id, p_decision, p_actor_id, p_decision_note,
    CURRENT_TIMESTAMP, p_actor_id, TRUE
  ) RETURNING id INTO v_decision_id;

  IF p_decision = 'reject' AND v_step.is_required THEN
    UPDATE approval_chain
      SET status = 'rejected',
          completed_at = CURRENT_TIMESTAMP,
          updated_by = p_actor_id,
          updated_at = CURRENT_TIMESTAMP
      WHERE id = v_chain.id;
    v_new_chain_status := 'rejected';
    PERFORM fn_contract_status_update_internal(v_contract_id, 'rejected', p_actor_id, p_decision_note);
    v_new_contract_status := 'rejected';
  ELSIF p_decision = 'request_resubmission' THEN
    UPDATE approval_chain
      SET status = 'resubmission_requested',
          completed_at = CURRENT_TIMESTAMP,
          updated_by = p_actor_id,
          updated_at = CURRENT_TIMESTAMP
      WHERE id = v_chain.id;
    v_new_chain_status := 'resubmission_requested';
    PERFORM fn_contract_status_update_internal(v_contract_id, 'draft', p_actor_id, p_decision_note);
    v_new_contract_status := 'draft';
  ELSIF p_decision = 'approve' THEN
    SELECT EXISTS (
      SELECT 1 FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND is_active = TRUE
          AND is_required = FALSE
    ) INTO v_any_optional_peer;

    IF v_any_optional_peer AND v_step.is_required THEN
      UPDATE approval_step
        SET status     = 'skipped',
            decided_at = CURRENT_TIMESTAMP,
            updated_by = p_actor_id,
            updated_at = CURRENT_TIMESTAMP
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND status = 'pending'
          AND is_active = TRUE;
      v_advance := TRUE;
    ELSE
      SELECT COUNT(*)
        INTO v_remaining_required
        FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND is_required = TRUE
          AND status = 'pending'
          AND is_active = TRUE;
      v_advance := (v_remaining_required = 0);
    END IF;

    IF v_advance THEN
      SELECT MIN(step_order) INTO v_next_step_order
        FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND status = 'pending'
          AND step_order > v_step.step_order
          AND is_active = TRUE;
      IF v_next_step_order IS NULL THEN
        UPDATE approval_chain
          SET status = 'approved',
              current_step_order = v_step.step_order,
              completed_at = CURRENT_TIMESTAMP,
              updated_by = p_actor_id,
              updated_at = CURRENT_TIMESTAMP
          WHERE id = v_chain.id;
        v_new_chain_status := 'approved';
        PERFORM fn_contract_status_update_internal(v_contract_id, 'approved', p_actor_id, p_decision_note);
        v_new_contract_status := 'approved';
      ELSE
        UPDATE approval_chain
          SET current_step_order = v_next_step_order,
              updated_by = p_actor_id,
              updated_at = CURRENT_TIMESTAMP
          WHERE id = v_chain.id;
        v_new_chain_status := 'in_progress';
        v_new_contract_status := 'in_approval';
        v_advanced_to_step_order := v_next_step_order;
      END IF;
    ELSE
      v_new_chain_status := 'in_progress';
      v_new_contract_status := 'in_approval';
    END IF;
  END IF;

  -- AUDIT-AFTER-RENDER (BE-M1b-004)
  PERFORM fn_contract_activity_create(
    v_contract_id, 'approval_decided', p_actor_id, NULL, NULL,
    jsonb_build_object(
      'chainId',         v_chain.id,
      'stepId',          p_step_id,
      'decision',        p_decision,
      'newStepStatus',   v_new_step_status,
      'newChainStatus',  v_new_chain_status,
      'newContractStatus', v_new_contract_status
    )
  );

  -- ─────────────────────────────────────────────────────────────────
  -- 611 FAN-OUT
  -- After the state changes + audit row, mirror the feedback into the
  -- Comments tab and fire the appropriate notification event. Both are
  -- wrapped so a downstream failure cannot void the decision.
  -- ─────────────────────────────────────────────────────────────────

  -- Pull contract + actor identity once for both branches.
  SELECT drafted_by, contract_number, title_en
    INTO v_drafted_by, v_contract_number, v_contract_title
    FROM contract WHERE id = v_contract_id;
  SELECT first_name, last_name INTO v_actor_first, v_actor_last
    FROM "user" WHERE id = p_actor_id;

  -- (1) Mirror non-trivial decision notes to contract_comment.
  IF p_decision IN ('reject','request_resubmission')
     AND p_decision_note IS NOT NULL
     AND length(trim(p_decision_note)) > 0 THEN
    BEGIN
      INSERT INTO contract_comment (
        contract_id, parent_id, body, mentioned_user_ids,
        created_at, updated_at, created_by, is_active
      ) VALUES (
        v_contract_id, NULL,
        -- Lead the comment with a small approver-context line so the
        -- Comments thread reads naturally rather than just dumping the
        -- note. Drafter sees "<Approver name> — request_resubmission:
        -- <note>".
        CASE
          WHEN v_actor_first IS NULL THEN p_decision || E'\n\n' || p_decision_note
          ELSE concat_ws(' ', v_actor_first, v_actor_last) || ' — ' || p_decision || E':\n\n' || p_decision_note
        END,
        COALESCE(ARRAY[v_drafted_by]::BIGINT[], '{}'::BIGINT[]),
        CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, p_actor_id, TRUE
      ) RETURNING id INTO v_comment_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_approval_decide(611): contract_comment insert failed: %', SQLERRM;
    END;
  END IF;

  -- (2) Dispatch notification per decision branch. Recipient is the
  --     drafter (the audience of every outcome in our current flow).
  v_event_type := CASE p_decision
    WHEN 'request_resubmission' THEN 'approval.requested_changes'
    WHEN 'reject'               THEN 'approval.rejected'
    WHEN 'approve' THEN
      -- Only fire approval.approved on the final step (chain reaches
      -- 'approved' state). Interim approvals don't need to wake the
      -- drafter; they keep the contract in_approval.
      CASE WHEN v_new_chain_status = 'approved' THEN 'approval.approved' ELSE NULL END
  END;

  IF v_event_type IS NOT NULL AND v_drafted_by IS NOT NULL THEN
    v_subject := format('Contract %s — %s',
                        COALESCE(v_contract_number, '#'||v_contract_id::TEXT),
                        CASE p_decision
                          WHEN 'request_resubmission' THEN 'changes requested'
                          WHEN 'reject'               THEN 'rejected'
                          ELSE 'approved'
                        END);
    v_body := CASE
      WHEN p_decision_note IS NOT NULL THEN
        format('%s by %s. Note: %s',
               CASE p_decision
                 WHEN 'request_resubmission' THEN 'Changes requested'
                 WHEN 'reject'               THEN 'Rejected'
                 ELSE 'Approved'
               END,
               COALESCE(concat_ws(' ', v_actor_first, v_actor_last), 'approver'),
               p_decision_note)
      ELSE
        format('%s by %s.',
               CASE p_decision
                 WHEN 'request_resubmission' THEN 'Changes requested'
                 WHEN 'reject'               THEN 'Rejected'
                 ELSE 'Approved'
               END,
               COALESCE(concat_ws(' ', v_actor_first, v_actor_last), 'approver'))
    END;
    BEGIN
      PERFORM fn_notification_dispatch(
        p_actor_id,
        v_event_type,
        jsonb_build_object(
          'subject',        v_subject,
          'bodyRendered',   v_body,
          'contractId',     v_contract_id,
          'contractNumber', v_contract_number,
          'contractTitle',  v_contract_title,
          'decisionId',     v_decision_id,
          'decision',       p_decision,
          'decisionNote',   p_decision_note,
          'commentId',      v_comment_id,
          'actorUserId',    p_actor_id,
          'actorName',      concat_ws(' ', v_actor_first, v_actor_last),
          'source',         'approval.decide'
        ),
        'approval_request',          -- notification_kind (enum: alert / advisory / approval_request / signature_request / system / risk_case / report)
        CASE p_decision
          WHEN 'request_resubmission' THEN 'high'
          WHEN 'reject'               THEN 'high'
          ELSE 'normal'
        END,
        v_drafted_by,                -- caller_user_id = drafter (default rule resolves to them)
        NULL::TEXT
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_approval_decide(611): dispatch % failed: %', v_event_type, SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'stepId',                p_step_id,
    'chainId',               v_chain.id,
    'contractId',            v_contract_id,
    'decisionId',            v_decision_id,
    'newStepStatus',         v_new_step_status,
    'newChainStatus',        v_new_chain_status,
    'newContractStatus',     v_new_contract_status,
    'advancedToStepOrder',   v_advanced_to_step_order,
    'allChainStepsResolved', (v_new_chain_status <> 'in_progress')
  );
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (611, '611_fn_approval_decide_fanout', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
