-- Migration: 236_fn_demo_reset.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: fn_demo_reset DEFINER VOLATILE — SET LOCAL statement_timeout='120s',
--              cascade purge via fn_demo_data_purge, REFRESH MV, reload seed packs.
--              Returns elapsed + slaWarn flag (HITL CR-J-Q3 — warn not fail).
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_demo_reset(
  p_actor_id      BIGINT,
  p_confirm_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_started_at  TIMESTAMPTZ;
  v_elapsed_ms  INTEGER;
  v_purge_stats JSONB;
  v_reload_stats JSONB;
  v_sla_warn    BOOLEAN;
  v_tenant_id   UUID;
BEGIN
  -- Extended timeout for 163K demo signal purge
  SET LOCAL statement_timeout = '120s';

  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  -- Permission check
  IF NOT fn_current_user_has_permission('demo.reset') THEN
    RAISE EXCEPTION 'fn_demo_reset: permission_denied — demo.reset required'
      USING ERRCODE = '42501';
  END IF;

  -- Confirm token validation (rolling token issued by BE controller on same request)
  IF p_confirm_token IS NULL OR p_confirm_token = '' THEN
    RAISE EXCEPTION 'fn_demo_reset: Reset confirm token missing or invalid'
      USING ERRCODE = '22023';
  END IF;

  IF p_confirm_token != COALESCE(current_setting('app.demo.reset_token', true), '') THEN
    RAISE EXCEPTION 'fn_demo_reset: Reset confirm token missing or invalid'
      USING ERRCODE = '22023';
  END IF;

  v_started_at := clock_timestamp();

  -- Cascade purge (53-table topology, extended in migration 230; also refreshes latest_risk_score MV)
  v_purge_stats := fn_demo_data_purge(FALSE);

  -- Reload seed packs
  v_reload_stats := jsonb_build_object(
    'sources',   fn_demo_seed_load_sources(),
    'rules',     fn_demo_seed_load_rules(),
    'templates', fn_demo_seed_load_templates(),
    'signals',   fn_demo_seed_load_signals()
  );

  v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;

  -- SLA warn (not fail) per HITL CR-J-Q3
  v_sla_warn := v_elapsed_ms > 60000;
  IF v_sla_warn THEN
    PERFORM pg_notify(
      'demo.reset.sla_warn',
      jsonb_build_object('elapsedMs', v_elapsed_ms, 'tenantId', v_tenant_id)::text
    );
  END IF;

  -- Strategy A audit
  PERFORM fn_audit_log_record_v2(
    'demo_data',
    NULL,
    'DELETE',
    NULL,
    jsonb_build_object(
      'actionCode',    'DEMO_RESET',
      'elapsedMs',     v_elapsed_ms,
      'slaWarn',       v_sla_warn,
      'purgeStats',    v_purge_stats,
      'reloadStats',   v_reload_stats
    ),
    NULLIF(p_actor_id, 0)
  );

  RETURN jsonb_build_object(
    'elapsedMs',   v_elapsed_ms,
    'purgeStats',  v_purge_stats,
    'reloadStats', v_reload_stats,
    'slaWarn',     v_sla_warn
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_reset: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_reset(BIGINT, TEXT) IS 'DEFINER: cascade-purge all demo data (53-table topology) + reload seed packs. Returns elapsed + slaWarn flag. SLA > 60s triggers pg_notify warning but does not fail. Requires demo.reset permission.';
REVOKE EXECUTE ON FUNCTION fn_demo_reset(BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_reset(BIGINT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (236, '236_fn_demo_reset', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 236;
-- DROP FUNCTION IF EXISTS fn_demo_reset(BIGINT, TEXT);
-- ============================================================
