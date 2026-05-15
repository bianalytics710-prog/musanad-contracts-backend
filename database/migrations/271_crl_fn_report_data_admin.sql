-- Migration: 271_crl_fn_report_data_admin.sql
-- Module: M20 — CR-L Reports & Briefings
-- Date: 2026-05-15
-- Description: 3 admin data fn_'s (system_health, audit_chain_verification, source_health_snapshot).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_report_data_admin_system_health(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := fn_demo_now();
  v_sources JSONB;
  v_rule_count INTEGER;
  v_trace JSONB;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'sourceId', source_id, 'displayName', display_name, 'kind', kind, 'enabled', enabled
  )), '[]'::jsonb) INTO v_sources
  FROM osint_source WHERE is_active = TRUE;

  SELECT COUNT(*) INTO v_rule_count FROM correlation_rule WHERE enabled = TRUE AND is_active = TRUE;

  v_trace := jsonb_build_array(
    jsonb_build_object('tableName','osint_source','count', (SELECT COUNT(*) FROM osint_source WHERE is_active = TRUE)),
    jsonb_build_object('tableName','correlation_rule','count', v_rule_count)
  );

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('osintSources', v_sources, 'activeRuleCount', v_rule_count),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_admin_system_health: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_admin_system_health(BIGINT, JSONB) IS 'System health: OSINT sources + active correlation rules.';
REVOKE EXECUTE ON FUNCTION fn_report_data_admin_system_health(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_admin_system_health(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_admin_audit_chain_verification(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := fn_demo_now();
  v_total INTEGER;
  v_recent JSONB;
  v_trace JSONB;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT COUNT(*) INTO v_total FROM audit_log;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'tableName', table_name, 'action', action, 'changedAt', changed_at,
    'hashPresent', this_hash IS NOT NULL
  ) ORDER BY changed_at DESC), '[]'::jsonb) INTO v_recent
  FROM (SELECT id, table_name, action, changed_at, this_hash FROM audit_log ORDER BY changed_at DESC LIMIT 20) s;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','audit_log','count', v_total));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('totalEntries', v_total, 'recentEntries', v_recent),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_admin_audit_chain_verification: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_admin_audit_chain_verification(BIGINT, JSONB) IS 'Audit-log chain integrity sample (recent 20 entries + total count).';
REVOKE EXECUTE ON FUNCTION fn_report_data_admin_audit_chain_verification(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_admin_audit_chain_verification(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_admin_source_health_snapshot(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := fn_demo_now();
  v_data JSONB;
  v_trace JSONB;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'sourceId', os.source_id, 'displayName', os.display_name, 'kind', os.kind, 'enabled', os.enabled,
    'signalsLast24h', (SELECT COUNT(*) FROM osint_signal s WHERE s.osint_source_id = os.id AND s.fetched_at >= v_now - INTERVAL '24 hours'),
    'signalsLast7d',  (SELECT COUNT(*) FROM osint_signal s WHERE s.osint_source_id = os.id AND s.fetched_at >= v_now - INTERVAL '7 days')
  )), '[]'::jsonb) INTO v_data
  FROM osint_source os
  WHERE os.is_active = TRUE;

  v_trace := jsonb_build_array(
    jsonb_build_object('tableName','osint_source','count', (SELECT COUNT(*) FROM osint_source WHERE is_active = TRUE)),
    jsonb_build_object('tableName','osint_signal','count', (SELECT COUNT(*) FROM osint_signal WHERE fetched_at >= v_now - INTERVAL '7 days'))
  );

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('sources', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_admin_source_health_snapshot: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_admin_source_health_snapshot(BIGINT, JSONB) IS 'Per-source signal counts (24h, 7d) and current enabled state.';
REVOKE EXECUTE ON FUNCTION fn_report_data_admin_source_health_snapshot(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_admin_source_health_snapshot(BIGINT, JSONB) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (271, '271_crl_fn_report_data_admin', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_report_data_admin_system_health(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_admin_audit_chain_verification(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_admin_source_health_snapshot(BIGINT, JSONB);
-- DELETE FROM schema_migrations WHERE version = 271;
-- ============================================================
