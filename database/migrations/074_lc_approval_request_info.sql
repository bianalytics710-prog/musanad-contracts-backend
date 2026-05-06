-- Migration 074: R-LC4 LC-F7 — add Request-info action to approvals.
--
-- Per LC decision 2(c), legal counsel + approvers get TWO non-approve
-- non-reject actions:
--   * Request resubmission — hard reject, contract bounces to drafter,
--     status → resubmission_requested.
--   * Request info        — soft, posts a comment, contract STAYS in
--     in_approval, step STAYS pending. No status change. The drafter
--     replies via the comments thread; the approver eventually
--     approve/reject the contract on the merits.
--
-- Schema changes:
--   1. Extend approval_decision.decision CHECK constraint to allow
--      'request_info'. Existing CHECK is anonymous in 024 — drop+recreate
--      with a stable name ourselves so future modules can ALTER it.
--   2. Extend contract_activity.activity_type CHECK to allow
--      'review_request_info' so we can audit the action.
--   3. Extend fn_contract_activity_create whitelist (M5 047 has 25; we
--      add 1 for total 26).
--   4. Add fn_approval_request_info — gates on approval.act, posts
--      contract comment + emits activity, no state mutation on step.

-- 1. approval_decision constraint -------------------------------------------

ALTER TABLE approval_decision DROP CONSTRAINT IF EXISTS approval_decision_decision_check;

DO $$
DECLARE
  v_constraint_name TEXT;
BEGIN
  SELECT conname INTO v_constraint_name
  FROM pg_constraint
  WHERE conrelid = 'approval_decision'::regclass
    AND contype = 'c'
    AND conname LIKE '%decision%check%'
    AND pg_get_constraintdef(oid) ILIKE '%approve%';
  IF v_constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE approval_decision DROP CONSTRAINT %I', v_constraint_name);
  END IF;
END$$;

ALTER TABLE approval_decision
  ADD CONSTRAINT approval_decision_decision_check CHECK (
    decision IN ('approve','reject','request_resubmission','request_info','delegate','reassign','escalate')
  );

-- 2 + 3. contract_activity whitelist + fn_contract_activity_create ----------

ALTER TABLE contract_activity DROP CONSTRAINT contract_activity_activity_type_check;
ALTER TABLE contract_activity
  ADD CONSTRAINT contract_activity_activity_type_check CHECK (
    activity_type IN (
      'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
      'payment_schedule_replaced','exported',
      'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated',
      'sent_for_signature','signer_viewed','signer_signed','signer_declined','fully_executed','signature_invalidated',
      'ai_summary_generated','ai_risk_score_updated','ai_diff_summary_generated',
      'regulatory_impact_detected','regulatory_impact_resolved',
      'review_request_info'
    )
  );

CREATE OR REPLACE FUNCTION fn_contract_activity_create(
  p_contract_id    BIGINT,
  p_activity_type  TEXT,
  p_actor_id       BIGINT       DEFAULT NULL,
  p_description_en TEXT         DEFAULT NULL,
  p_description_ar TEXT         DEFAULT NULL,
  p_metadata       JSONB        DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id    BIGINT;
  v_actor BIGINT;
BEGIN
  IF p_activity_type NOT IN (
    'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
    'payment_schedule_replaced','exported',
    'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated',
    'sent_for_signature','signer_viewed','signer_signed','signer_declined','fully_executed','signature_invalidated',
    'ai_summary_generated','ai_risk_score_updated','ai_diff_summary_generated',
    'regulatory_impact_detected','regulatory_impact_resolved',
    'review_request_info'
  ) THEN
    RAISE EXCEPTION 'fn_contract_activity_create: activityType:invalid type %', p_activity_type USING ERRCODE = '22023';
  END IF;

  v_actor := COALESCE(
    p_actor_id,
    NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
  );

  INSERT INTO contract_activity (
    contract_id, activity_type, actor_id, description_en, description_ar, metadata
  ) VALUES (
    p_contract_id, p_activity_type, v_actor, p_description_en, p_description_ar, p_metadata
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'activityType', p_activity_type, 'contractId', p_contract_id);
END;
$$;

-- 4. fn_approval_request_info ----------------------------------------------

CREATE OR REPLACE FUNCTION fn_approval_request_info(
  p_actor_id      BIGINT,
  p_step_id       BIGINT,
  p_message       TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_chain_id    BIGINT;
  v_contract_id BIGINT;
  v_decision_id BIGINT;
  v_comment_id  BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('approval.act') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_message IS NULL OR length(trim(p_message)) < 1 THEN
    RAISE EXCEPTION 'fn_approval_request_info: message:request-info message is required' USING ERRCODE = '22023';
  END IF;

  SELECT s.approval_chain_id, ch.contract_id
    INTO v_chain_id, v_contract_id
  FROM approval_step s
  JOIN approval_chain ch ON ch.id = s.approval_chain_id
  WHERE s.id = p_step_id
    AND s.is_active = TRUE
    AND s.status = 'pending';

  IF v_chain_id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_request_info: stepId:step not found or not pending' USING ERRCODE = 'P0002';
  END IF;

  -- Append a request_info decision row but DO NOT change step status.
  INSERT INTO approval_decision (
    approval_step_id, decision, decided_by, decision_note, created_by
  ) VALUES (
    p_step_id, 'request_info', p_actor_id, p_message, p_actor_id
  ) RETURNING id INTO v_decision_id;

  -- Post the message as a contract comment so the drafter sees it in the
  -- comments thread alongside other discussion (R4 contract_comment table).
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'contract_comment') THEN
    INSERT INTO contract_comment (
      contract_id, body, created_by, updated_by
    ) VALUES (
      v_contract_id, p_message, p_actor_id, p_actor_id
    ) RETURNING id INTO v_comment_id;
  END IF;

  -- Activity log entry.
  PERFORM fn_contract_activity_create(
    v_contract_id,
    'review_request_info',
    p_actor_id,
    'Approver requested information from drafter',
    NULL,
    jsonb_build_object(
      'stepId',     p_step_id,
      'decisionId', v_decision_id,
      'commentId',  v_comment_id
    )
  );

  RETURN jsonb_build_object(
    'decisionId', v_decision_id,
    'commentId',  v_comment_id,
    'stepId',     p_step_id,
    'contractId', v_contract_id
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_approval_request_info(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_approval_request_info(BIGINT, BIGINT, TEXT) TO neondb_owner;

-- ROLLBACK BEGIN
-- ALTER TABLE approval_decision DROP CONSTRAINT IF EXISTS approval_decision_decision_check;
-- ALTER TABLE approval_decision ADD CONSTRAINT approval_decision_decision_check CHECK (
--   decision IN ('approve','reject','request_resubmission','delegate','reassign','escalate')
-- );
-- DROP FUNCTION IF EXISTS fn_approval_request_info(BIGINT, BIGINT, TEXT);
-- ROLLBACK END
