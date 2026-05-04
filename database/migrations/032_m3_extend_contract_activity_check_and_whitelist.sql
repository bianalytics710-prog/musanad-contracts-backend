-- ============================================================================
-- 032_m3_extend_contract_activity_check_and_whitelist.sql
-- ============================================================================
-- Module:    M3 (Signatures + Signer Q&A AI)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   027_m2_extend_fn_contract_activity_create_whitelist.sql (14-value
--            CHECK constraint), 031_m2_fix_actor_check_and_cron_actor.sql
--            (canonical fn_contract_activity_create body w/ v_actor=0 -> NULL
--            coercion).
-- ----------------------------------------------------------------------------
-- ATOMIC EXTENSION (per M1b 010/013 + M2 027 split-cycle precedent):
--   (a) DROP + ADD contract_activity.activity_type CHECK to extend the
--       14-value enum to 20 (+6 new M3 lifecycle activity types).
--   (b) CREATE OR REPLACE fn_contract_activity_create with body byte-for-byte
--       identical to canonical M2 031 EXCEPT the IF NOT IN whitelist literal
--       (extended by the same 6 names).
--
-- The two changes ship in a SINGLE migration so a fn_signature_send_for_signature
-- call that reaches fn_contract_activity_create never inserts a value the table
-- CHECK can't accept.
--
-- M3 6 new activity types:
--   sent_for_signature       — emitted by fn_signature_send_for_signature
--   signer_viewed            — RESERVED: signature_event captures view; activity
--                              feed currently does NOT emit signer_viewed (kept
--                              in whitelist for future use).
--   signer_signed            — emitted by fn_signature_sign on every sign event
--   signer_declined          — emitted by fn_signature_decline (and on cancel
--                              rollback path)
--   fully_executed           — emitted by fn_signature_sign on final-step path
--   signature_invalidated    — emitted by fn_signature_invitation_cancel
--                              rollback + fn_signature_invitation_expire_due
--                              halt path
--
-- S2-19 fidelity: fn_contract_activity_create body compared byte-for-byte to
-- 031_m2_fix_actor_check_and_cron_actor.sql lines 292-347. Only the
-- IF p_activity_type NOT IN (...) tuple changes. v_actor IN (NULL, 0) -> NULL
-- coercion preserved (S2-20). REVOKE/GRANT statements preserved.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- 1. Extend contract_activity.activity_type CHECK constraint
--    14 -> 20 values. Stable name (DROP + ADD pattern).
-- ============================================================
ALTER TABLE contract_activity
  DROP CONSTRAINT IF EXISTS contract_activity_activity_type_check;

ALTER TABLE contract_activity
  ADD CONSTRAINT contract_activity_activity_type_check CHECK (
    activity_type IN (
      'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
      'payment_schedule_replaced','exported',
      'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated',
      'sent_for_signature','signer_viewed','signer_signed','signer_declined','fully_executed','signature_invalidated'
    )
  );

-- ============================================================
-- 2. fn_contract_activity_create — extend whitelist
--    Body byte-for-byte identical to canonical M2 031 except the
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
  -- M3 (032): whitelist extended +6 to 20 values for signature lifecycle.
  IF p_activity_type NOT IN (
    'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
    'payment_schedule_replaced','exported',
    'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated',
    'sent_for_signature','signer_viewed','signer_signed','signer_declined','fully_executed','signature_invalidated'
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

  -- M2 (031) v_actor=0 SYSTEM_ACTOR_ID coercion preserved verbatim.
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
  'INTERNAL helper. SECURITY DEFINER. M3 (032): whitelist extended to 20 values incl. sent_for_signature, signer_viewed, signer_signed, signer_declined, fully_executed, signature_invalidated. v_actor=0 SYSTEM_ACTOR_ID coercion (M2 031) preserved.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (32, 'm3_extend_contract_activity_check_and_whitelist', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;

-- Restore M2 14-value CHECK.
ALTER TABLE contract_activity
  DROP CONSTRAINT IF EXISTS contract_activity_activity_type_check;

ALTER TABLE contract_activity
  ADD CONSTRAINT contract_activity_activity_type_check CHECK (
    activity_type IN (
      'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
      'payment_schedule_replaced','exported',
      'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated'
    )
  );

-- Restore canonical M2 031 fn_contract_activity_create body verbatim.
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
    'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated'
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

DELETE FROM schema_migrations WHERE version = 32;
COMMIT;
-- ROLLBACK END
