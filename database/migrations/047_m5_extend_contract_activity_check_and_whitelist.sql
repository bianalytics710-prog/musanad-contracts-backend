-- ============================================================================
-- 047_m5_extend_contract_activity_check_and_whitelist.sql
-- ============================================================================
-- Module:    M5 (Regulatory Radar)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   027_m2_extend_fn_contract_activity_create_whitelist.sql,
--            031_m2_fix_actor_check_and_cron_actor.sql,
--            032_m3_extend_contract_activity_check_and_whitelist.sql,
--            040_m4_extend_contract_activity_check_and_whitelist.sql (canonical
--            23-value whitelist body — preserved byte-for-byte except the
--            IF NOT IN tuple).
-- ----------------------------------------------------------------------------
-- ATOMIC EXTENSION (M2 027 / M3 032 / M4 040 split-cycle precedent):
--   (a) DROP + ADD contract_activity.activity_type CHECK to extend the
--       23-value enum to 25 (+2 new M5 regulatory lifecycle activity types).
--   (b) CREATE OR REPLACE fn_contract_activity_create with body byte-for-byte
--       identical to canonical M4 040 EXCEPT the IF NOT IN whitelist literal.
--
-- The two changes ship in a SINGLE migration so a fn_regulatory_impact_create_bulk
-- or fn_regulatory_impact_resolve call that reaches fn_contract_activity_create
-- never inserts a value the table CHECK can't accept.
--
-- M5 2 new activity types (per Gate 2 Q9 EMIT):
--   regulatory_impact_detected — emitted by fn_regulatory_impact_create_bulk
--                                when a per-contract impact INSERT succeeds.
--   regulatory_impact_resolved — emitted by fn_regulatory_impact_resolve when
--                                resolution_action != 'pending' (resolved=TRUE).
--
-- S2-19 fidelity: fn_contract_activity_create body compared byte-for-byte to
-- 040_m4_extend_contract_activity_check_and_whitelist.sql. ONLY the
-- IF p_activity_type NOT IN (...) tuple changes. v_actor IN (NULL, 0) -> NULL
-- coercion preserved (S2-20). REVOKE/GRANT statements preserved.
-- 6-arg signature preserved. SET search_path = public, pg_temp preserved.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- 1. Extend contract_activity.activity_type CHECK constraint
--    23 -> 25 values. Stable name (DROP + ADD pattern).
-- ============================================================
ALTER TABLE contract_activity
  DROP CONSTRAINT IF EXISTS contract_activity_activity_type_check;

ALTER TABLE contract_activity
  ADD CONSTRAINT contract_activity_activity_type_check CHECK (
    activity_type IN (
      'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
      'payment_schedule_replaced','exported',
      'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated',
      'sent_for_signature','signer_viewed','signer_signed','signer_declined','fully_executed','signature_invalidated',
      'ai_summary_generated','ai_risk_score_updated','ai_diff_summary_generated',
      'regulatory_impact_detected','regulatory_impact_resolved'
    )
  );

-- ============================================================
-- 2. fn_contract_activity_create — extend whitelist
--    Body byte-for-byte identical to canonical M4 040 except the
--    IF p_activity_type NOT IN (...) tuple.
-- ============================================================
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
  v_id      BIGINT;
  v_actor   BIGINT;
BEGIN
  -- M5 (047): whitelist extended +2 to 25 values for regulatory lifecycle activities.
  IF p_activity_type NOT IN (
    'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
    'payment_schedule_replaced','exported',
    'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated',
    'sent_for_signature','signer_viewed','signer_signed','signer_declined','fully_executed','signature_invalidated',
    'ai_summary_generated','ai_risk_score_updated','ai_diff_summary_generated',
    'regulatory_impact_detected','regulatory_impact_resolved'
  ) THEN
    RAISE EXCEPTION 'fn_contract_activity_create: %', 'activityType:Invalid activity type'
      USING ERRCODE = '23514';
  END IF;

  IF p_actor_id IS NOT NULL THEN
    v_actor := p_actor_id;
  ELSE
    BEGIN
      v_actor := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    EXCEPTION WHEN OTHERS THEN v_actor := NULL;
    END;
  END IF;

  -- M2 (031) v_actor=0 SYSTEM_ACTOR_ID coercion preserved verbatim (S2-20).
  IF v_actor IS NULL OR v_actor = 0 THEN
    v_actor := NULL;
  END IF;

  INSERT INTO contract_activity (
    contract_id, activity_type, actor_id, description_en, description_ar, metadata
  ) VALUES (
    p_contract_id, p_activity_type, v_actor, p_description_en, p_description_ar, p_metadata
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) TO neondb_owner;

COMMENT ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) IS
  'INTERNAL helper. SECURITY DEFINER. M5 (047): whitelist extended to 25 values (+regulatory_impact_detected, +regulatory_impact_resolved). v_actor=0 SYSTEM_ACTOR_ID coercion (M2 031) preserved.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (47, 'm5_extend_contract_activity_check_and_whitelist', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;

-- Restore M4 23-value CHECK.
ALTER TABLE contract_activity
  DROP CONSTRAINT IF EXISTS contract_activity_activity_type_check;

ALTER TABLE contract_activity
  ADD CONSTRAINT contract_activity_activity_type_check CHECK (
    activity_type IN (
      'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
      'payment_schedule_replaced','exported',
      'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated',
      'sent_for_signature','signer_viewed','signer_signed','signer_declined','fully_executed','signature_invalidated',
      'ai_summary_generated','ai_risk_score_updated','ai_diff_summary_generated'
    )
  );

-- Restore canonical M4 040 fn_contract_activity_create body verbatim.
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
  v_id      BIGINT;
  v_actor   BIGINT;
BEGIN
  IF p_activity_type NOT IN (
    'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
    'payment_schedule_replaced','exported',
    'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated',
    'sent_for_signature','signer_viewed','signer_signed','signer_declined','fully_executed','signature_invalidated',
    'ai_summary_generated','ai_risk_score_updated','ai_diff_summary_generated'
  ) THEN
    RAISE EXCEPTION 'fn_contract_activity_create: %', 'activityType:Invalid activity type'
      USING ERRCODE = '23514';
  END IF;

  IF p_actor_id IS NOT NULL THEN
    v_actor := p_actor_id;
  ELSE
    BEGIN
      v_actor := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    EXCEPTION WHEN OTHERS THEN v_actor := NULL;
    END;
  END IF;

  IF v_actor IS NULL OR v_actor = 0 THEN
    v_actor := NULL;
  END IF;

  INSERT INTO contract_activity (
    contract_id, activity_type, actor_id, description_en, description_ar, metadata
  ) VALUES (
    p_contract_id, p_activity_type, v_actor, p_description_en, p_description_ar, p_metadata
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) TO neondb_owner;

DELETE FROM schema_migrations WHERE version = 47;
COMMIT;
-- ROLLBACK END
