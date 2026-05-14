-- Migration: 243_crij_fix_time_freeze_table_backed.sql
-- Module: M17+M18 — DEFECT-CRIJ-FREEZE-1 fix
-- Description:
--   The original time-freeze implementation used a session-scoped GUC
--   (`app.demo.time_now` via `SET LOCAL`). That works inside a single
--   transaction but does NOT survive Neon connection-pool rotation, so
--   subsequent HTTP requests get a clean connection and see no freeze.
--   Replace with table-backed persistence:
--     - new demo_time_freeze_state table (1 row per tenant)
--     - fn_demo_now() reads frozen_at from table (fallback to now())
--     - fn_demo_time_freeze_set / _unfreeze UPSERT / DELETE the row
-- Date: 2026-05-14

BEGIN;

-- ============================================================
-- demo_time_freeze_state — 1 active row per tenant
-- ============================================================
CREATE TABLE IF NOT EXISTS demo_time_freeze_state (
  tenant_id    UUID        PRIMARY KEY REFERENCES tenant(id) ON DELETE CASCADE,
  frozen_at    TIMESTAMPTZ NOT NULL,
  set_by       BIGINT      REFERENCES "user"(id),
  set_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  data_classification TEXT NOT NULL DEFAULT 'demo'
                       CHECK (data_classification IN ('demo','pilot','production'))
);

COMMENT ON TABLE demo_time_freeze_state IS 'Per-tenant table-backed time-freeze state. Replaces session GUC which did not survive connection pooling. fn_demo_now() reads frozen_at from this table.';
COMMENT ON COLUMN demo_time_freeze_state.frozen_at IS 'Timestamp returned by fn_demo_now() while a row exists for the tenant. Cleared on unfreeze.';

ALTER TABLE demo_time_freeze_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE demo_time_freeze_state FORCE ROW LEVEL SECURITY;
CREATE POLICY demo_time_freeze_isolation ON demo_time_freeze_state FOR ALL
  USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);

-- ============================================================
-- fn_demo_now — reads from table, fallback to now()
-- ============================================================
CREATE OR REPLACE FUNCTION fn_demo_now()
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
STABLE
SECURITY DEFINER  -- DEFINER so it can read across RLS (tenant scoped via GUC inside)
AS $$
DECLARE
  v_tenant_id UUID;
  v_frozen    TIMESTAMPTZ;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  IF v_tenant_id IS NULL THEN
    RETURN now();
  END IF;
  SELECT frozen_at INTO v_frozen
    FROM demo_time_freeze_state
   WHERE tenant_id = v_tenant_id;
  RETURN COALESCE(v_frozen, now());
END;
$$;
COMMENT ON FUNCTION fn_demo_now() IS 'Returns demo-frozen time if a demo_time_freeze_state row exists for the current tenant; else now(). Connection-pool safe (table-backed, not GUC-backed).';
REVOKE EXECUTE ON FUNCTION fn_demo_now() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_now() TO neondb_owner;

-- ============================================================
-- fn_demo_time_freeze_set — UPSERT the table row (minute-truncated per HITL Q1)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_demo_time_freeze_set(
  p_actor_id          BIGINT,
  p_target_timestamp  TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id  UUID;
  v_truncated  TIMESTAMPTZ;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_demo_time_freeze_set: tenant_context_missing' USING ERRCODE = '22023';
  END IF;
  IF p_target_timestamp IS NULL THEN
    RAISE EXCEPTION 'fn_demo_time_freeze_set: target_timestamp_required' USING ERRCODE = '22023';
  END IF;

  -- Minute granularity per HITL CR-J-Q1
  v_truncated := date_trunc('minute', p_target_timestamp);

  INSERT INTO demo_time_freeze_state (tenant_id, frozen_at, set_by, set_at)
  VALUES (v_tenant_id, v_truncated, NULLIF(p_actor_id, 0), now())
  ON CONFLICT (tenant_id) DO UPDATE
    SET frozen_at = EXCLUDED.frozen_at,
        set_by    = EXCLUDED.set_by,
        set_at    = now();

  RETURN jsonb_build_object(
    'frozenAt', to_char(v_truncated AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'setBy',    p_actor_id,
    'setAt',    to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_time_freeze_set: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_demo_time_freeze_set(BIGINT, TIMESTAMPTZ) IS 'UPSERTs the per-tenant time-freeze row. Minute-truncated per HITL CR-J-Q1. Connection-pool safe (table-backed).';
REVOKE EXECUTE ON FUNCTION fn_demo_time_freeze_set(BIGINT, TIMESTAMPTZ) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_time_freeze_set(BIGINT, TIMESTAMPTZ) TO neondb_owner;

-- ============================================================
-- fn_demo_time_unfreeze — DELETE the table row
-- ============================================================
CREATE OR REPLACE FUNCTION fn_demo_time_unfreeze(p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id UUID;
  v_deleted   INTEGER;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_demo_time_unfreeze: tenant_context_missing' USING ERRCODE = '22023';
  END IF;
  DELETE FROM demo_time_freeze_state WHERE tenant_id = v_tenant_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN jsonb_build_object('unfrozen', v_deleted > 0, 'unfrozenBy', p_actor_id);
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_time_unfreeze: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_demo_time_unfreeze(BIGINT) IS 'Clears the per-tenant time-freeze row.';
REVOKE EXECUTE ON FUNCTION fn_demo_time_unfreeze(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_time_unfreeze(BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (243, 'CR-I+J DEFECT-CRIJ-FREEZE-1 — table-backed time-freeze (replaces session GUC)', now())
ON CONFLICT (version) DO NOTHING;

COMMIT;
