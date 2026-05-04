-- ============================================================================
-- 027_m2_extend_fn_contract_activity_create_whitelist.sql — AE-1 9 -> 14
-- ============================================================================
-- Module:    M2 (Approval Workflows)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   013_m1b_extend_activity_create_whitelist.sql (canonical 9-value body),
--            010_m1b_extend_m1a.sql (stable name for table CHECK).
-- ----------------------------------------------------------------------------
-- AE-1 — extend the contract_activity_activity_type_check table CHECK and the
-- fn_contract_activity_create whitelist from 9 -> 14 values:
--   ADD: submitted_for_approval, approval_decided, approval_reassigned,
--        approval_escalated, approval_delegated.
--
-- S2-17: Body diffed against M1b 013 canonical. Preserved verbatim:
--   - SECURITY DEFINER
--   - SET search_path = public, pg_temp
--   - REVOKE ALL FROM PUBLIC + GRANT EXECUTE TO neondb_owner
--   - current_setting('app.current_user_id', true)::BIGINT actor fallback
--   - INSERT INTO contract_activity body
-- Only the IN-list inside the whitelist guard is modified.
--
-- M1b 010 set the CHECK constraint stable name (contract_activity_activity_type_check).
-- We use ALTER TABLE DROP/ADD CONSTRAINT by that stable name.
-- ----------------------------------------------------------------------------

BEGIN;

-- Step A — extend the table CHECK constraint
ALTER TABLE contract_activity DROP CONSTRAINT contract_activity_activity_type_check;
ALTER TABLE contract_activity
  ADD CONSTRAINT contract_activity_activity_type_check
  CHECK (activity_type IN (
    'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
    'payment_schedule_replaced','exported',
    'submitted_for_approval','approval_decided','approval_reassigned','approval_escalated','approval_delegated'
  ));

COMMENT ON CONSTRAINT contract_activity_activity_type_check ON contract_activity IS
  'M2 027: 14 values (M1a 7 + M1b 2 + M2 5). Future modules extend by DROP + ADD CONSTRAINT contract_activity_activity_type_check.';

-- Step B — CREATE OR REPLACE fn_contract_activity_create body
-- Diff against migration 013 canonical: only the IN-list is changed.
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
  -- Whitelist extended in M2 (027) to include 5 approval-namespace activity types.
  -- (CMW M2 027 also extended the table CHECK constraint above.)
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
  'INTERNAL helper. SECURITY DEFINER. Invoked by triggers + fn_contract_status_update_user/_internal + fn_approval_* directly when richer metadata than the trigger has access to is needed. EXECUTE granted only to neondb_owner — bypasses contract_activity RLS deny-direct-INSERT. M2 (027): whitelist extended to 14 values incl. submitted_for_approval, approval_decided, approval_reassigned, approval_escalated, approval_delegated.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (27, 'm2_extend_fn_contract_activity_create_whitelist', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
ALTER TABLE contract_activity DROP CONSTRAINT contract_activity_activity_type_check;
ALTER TABLE contract_activity
  ADD CONSTRAINT contract_activity_activity_type_check
  CHECK (activity_type IN (
    'created','updated','status_changed','version_created','tagged','soft_deleted','restored',
    'payment_schedule_replaced','exported'
  ));

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
    'payment_schedule_replaced','exported'
  ) THEN
    RAISE EXCEPTION 'fn_contract_activity_create: %', 'activityType:Invalid activity type';
  END IF;

  IF p_actor_id IS NOT NULL THEN
    v_actor := p_actor_id;
  ELSE
    BEGIN
      v_actor := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    EXCEPTION WHEN OTHERS THEN v_actor := NULL;
    END;
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
DELETE FROM schema_migrations WHERE version = 27;
COMMIT;
-- ROLLBACK END
