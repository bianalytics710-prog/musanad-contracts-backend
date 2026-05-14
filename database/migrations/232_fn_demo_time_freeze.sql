-- Migration: 232_fn_demo_time_freeze.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: fn_demo_time_freeze_set + fn_demo_time_unfreeze — minute-granularity, audit-logged.
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- fn_demo_time_freeze_set
CREATE OR REPLACE FUNCTION fn_demo_time_freeze_set(
  p_actor_id        BIGINT,
  p_target_timestamp TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_frozen_at  TIMESTAMPTZ;
  v_tenant_id  UUID;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;

  -- Permission check
  IF NOT fn_current_user_has_permission('demo.time_freeze.manage') THEN
    RAISE EXCEPTION 'fn_demo_time_freeze_set: permission_denied — demo.time_freeze.manage required'
      USING ERRCODE = '42501';
  END IF;

  IF p_target_timestamp IS NULL THEN
    RAISE EXCEPTION 'fn_demo_time_freeze_set: targetTimestamp required'
      USING ERRCODE = '22023';
  END IF;

  -- Truncate to minute granularity per HITL CR-J-Q1
  v_frozen_at := date_trunc('minute', p_target_timestamp);

  -- Set session-scoped GUC (is_local=FALSE = session scope, survives statement boundaries)
  PERFORM set_config('app.demo.time_now', v_frozen_at::text, FALSE);

  -- Audit log
  PERFORM fn_audit_log_record_v2(
    'system_setting', NULL, 'UPDATE', NULL,
    jsonb_build_object('frozenAt', v_frozen_at, 'actionCode', 'DEMO_TIME_FREEZE_SET'),
    NULLIF(p_actor_id, 0)
  );

  RETURN jsonb_build_object('frozenAt', v_frozen_at, 'actualNow', now());

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_time_freeze_set: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_time_freeze_set(BIGINT, TIMESTAMPTZ) IS 'DEFINER: freeze app.demo.time_now GUC to minute-truncated timestamp. Requires demo.time_freeze.manage permission.';
REVOKE EXECUTE ON FUNCTION fn_demo_time_freeze_set(BIGINT, TIMESTAMPTZ) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_time_freeze_set(BIGINT, TIMESTAMPTZ) TO neondb_owner;

-- fn_demo_time_unfreeze
CREATE OR REPLACE FUNCTION fn_demo_time_unfreeze(
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id UUID;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;

  -- Permission check
  IF NOT fn_current_user_has_permission('demo.time_freeze.manage') THEN
    RAISE EXCEPTION 'fn_demo_time_unfreeze: permission_denied — demo.time_freeze.manage required'
      USING ERRCODE = '42501';
  END IF;

  -- Clear GUC
  PERFORM set_config('app.demo.time_now', '', FALSE);

  -- Audit log
  PERFORM fn_audit_log_record_v2(
    'system_setting', NULL, 'UPDATE', NULL,
    jsonb_build_object('actionCode', 'DEMO_TIME_UNFREEZE', 'unfrozenAt', now()),
    NULLIF(p_actor_id, 0)
  );

  RETURN jsonb_build_object('unfrozenAt', now());

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_time_unfreeze: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_time_unfreeze(BIGINT) IS 'DEFINER: clear app.demo.time_now GUC so fn_demo_now() returns real now(). Requires demo.time_freeze.manage permission.';
REVOKE EXECUTE ON FUNCTION fn_demo_time_unfreeze(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_time_unfreeze(BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (232, '232_fn_demo_time_freeze', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 232;
-- DROP FUNCTION IF EXISTS fn_demo_time_unfreeze(BIGINT);
-- DROP FUNCTION IF EXISTS fn_demo_time_freeze_set(BIGINT, TIMESTAMPTZ);
-- ============================================================
