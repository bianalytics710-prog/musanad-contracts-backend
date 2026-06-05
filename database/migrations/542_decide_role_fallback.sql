-- MIGRATION: 542_decide_role_fallback.sql
-- Date: 2026-06-04
-- Description:
--   fn_approval_decide rejected any actor whose id wasn't explicitly recorded
--   as approver_user_id / delegated_to / reassigned_to on the step. But the
--   route-init fn inserts steps with approver_user_id = NULL when the matrix
--   only specifies a role (e.g. "any legal_counsel can decide"). Those steps
--   show up in fn_approval_my_pending via role fallback but the user can never
--   act on them — they hit "actor:Not the assigned approver" (42501).
--
--   Fix: add a role-based fallback to the auth check. If approver_user_id is
--   NULL and the actor's role matches the step's approver_role, accept the
--   decision and bind approver_user_id to the actor on the step row (atomic
--   claim) so the audit trail records WHO actually decided.
--
--   Implementation: this is a SURGICAL patch — full original fn body is
--   preserved verbatim, with ONLY the auth-check block and a new claim block
--   added. All chain progression / peer-step short-circuit / decision id /
--   audit-after-render logic from the original is unchanged.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_approval_decide(p_step_id bigint, p_actor_id bigint, p_decision text, p_decision_note text DEFAULT NULL::text)
 RETURNS jsonb
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
  -- 542 addition — actor's role for role-based fallback when the step's
  -- approver_user_id is NULL (matrix specified role only, no specific user).
  v_actor_role            TEXT;
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

  -- 542 — resolve actor's role for the role-based auth fallback below.
  SELECT r.name INTO v_actor_role
    FROM "user" u
    JOIN role r ON r.id = u.role_id
   WHERE u.id = p_actor_id AND u.is_active = TRUE
   LIMIT 1;

  -- BUG 1 FIX (031): NULL-safe actor check via IS NOT DISTINCT FROM.
  -- 542 addition: role fallback when approver_user_id / delegated_to /
  -- reassigned_to are ALL NULL (role-only step from a matrix entry that
  -- didn't pin a specific user). Without this fallback, my-pending shows the
  -- step but the user can never act on it.
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

  -- 542 — atomic claim. When the actor matched via the role fallback above,
  -- bind their id to approver_user_id so the audit trail and downstream
  -- queries see WHO actually decided (not "(any legal_counsel)").
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

  -- Compute new step status
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

  -- Reject (required) or request_resubmission -> chain halts
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
    -- Parallel-group resolution
    SELECT EXISTS (
      SELECT 1 FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND is_active = TRUE
          AND is_required = FALSE
    ) INTO v_any_optional_peer;

    IF v_any_optional_peer AND v_step.is_required THEN
      -- ANY-OF rule (mixed required + optional peers): approving the required short-circuits the rest
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
      -- ALL-OF rule: advance only when no required peer remains pending
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
VALUES (542, 'decide_role_fallback', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
