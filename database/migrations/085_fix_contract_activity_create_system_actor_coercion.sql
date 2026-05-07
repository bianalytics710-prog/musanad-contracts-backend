-- ================================================================
-- Migration 085 — restore the v_actor=0 → NULL SYSTEM_ACTOR_ID
-- coercion in fn_contract_activity_create (lost in 074 / 079).
-- ================================================================
-- Up: BEGIN
-- Migration 031 (M2) introduced the SYSTEM_ACTOR_ID=0 sentinel: the
-- cron driver runs with `SET app.current_user_id = '0'` so audit
-- triggers can attribute system events without a synthetic system
-- user row. fn_contract_activity_create coerces v_actor=0 to NULL
-- before INSERTing into contract_activity (which has a FK on
-- actor_id → "user".id; no user with id=0 exists, so an un-coerced
-- 0 raises 23503).
--
-- Migrations 032 / 040 / 047 explicitly preserved the coercion when
-- they extended the activity-type whitelist. Migrations 074 (R-LC4)
-- and 079 (R-LC7) recreated fn_contract_activity_create to extend
-- the whitelist further but dropped the
--
--   IF v_actor = 0 THEN v_actor := NULL; END IF;
--
-- guard. Net effect: M2-escalation, M3 cron-and-system-actor, and
-- any future fn that runs with SYSTEM_ACTOR_ID raise SQLSTATE 23503
-- on the contract_activity INSERT.
--
-- This migration restores the coercion. Whitelist is preserved
-- byte-for-byte from 079 (M0..M4 base + M5 regulatory + R-LC4
-- review_request_info + R-LC7 impact_signal_notify / amendment_initiated).
-- ================================================================

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
    'review_request_info',
    'impact_signal_notify','amendment_initiated'
  ) THEN
    RAISE EXCEPTION 'fn_contract_activity_create: activityType:invalid type %', p_activity_type USING ERRCODE = '22023';
  END IF;

  v_actor := COALESCE(
    p_actor_id,
    NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
  );

  -- S2-20: coerce v_actor = 0 (SYSTEM_ACTOR_ID sentinel) to NULL so cron
  -- drivers' `SET app.current_user_id = '0'` produces a system-event row
  -- (actor_id IS NULL) instead of a 23503 FK violation against "user".
  IF v_actor = 0 THEN
    v_actor := NULL;
  END IF;

  INSERT INTO contract_activity (
    contract_id, activity_type, actor_id, description_en, description_ar, metadata
  ) VALUES (
    p_contract_id, p_activity_type, v_actor, p_description_en, p_description_ar, p_metadata
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'activityType', p_activity_type, 'contractId', p_contract_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) TO neondb_owner;

COMMENT ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) IS
  'INTERNAL helper. SECURITY DEFINER. Whitelist preserved from R-LC7 (079). v_actor=0 SYSTEM_ACTOR_ID coercion restored after 074/079 dropped it (S2-20).';

-- ================================================================
-- Up: END
-- Down: BEGIN
-- (Replay 079 to revert.)
-- ================================================================
-- Down: END
