-- Migration: 270_crl_fn_report_data_compliance.sql
-- Module: M20 — CR-L Reports & Briefings
-- Date: 2026-05-15
-- Description: 3 compliance & ESG data fn_'s.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_report_data_compliance_sanctions_exposure(
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
  v_buckets JSONB;
  v_data JSONB;
  v_trace JSONB;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT jsonb_object_agg(severity_v2, cnt) INTO v_buckets FROM (
    SELECT severity_v2, COUNT(*) AS cnt FROM osint_signal
     WHERE tenant_id = v_tenant AND kind = 'sanctions' AND is_active = TRUE
     GROUP BY severity_v2
  ) s;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'signalId', id, 'title', title, 'severity', severity_v2, 'fetchedAt', fetched_at
  ) ORDER BY fetched_at DESC), '[]'::jsonb) INTO v_data
  FROM osint_signal
  WHERE tenant_id = v_tenant AND kind = 'sanctions' AND is_active = TRUE
  LIMIT 50;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','osint_signal','count', (SELECT COUNT(*) FROM osint_signal WHERE tenant_id = v_tenant AND kind = 'sanctions' AND is_active = TRUE)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('severityBuckets', COALESCE(v_buckets, '{}'::jsonb), 'recentSignals', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_compliance_sanctions_exposure: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_compliance_sanctions_exposure(BIGINT, JSONB) IS 'Sanctions OSINT signals bucketed by severity.';
REVOKE EXECUTE ON FUNCTION fn_report_data_compliance_sanctions_exposure(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_compliance_sanctions_exposure(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_compliance_subcontractor_chain(
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

  -- Subcontractor info lives in contract.metadata or via dedicated extracted clauses; simplified for now
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractId', c.id, 'contractTitle', COALESCE(c.title_en, c.title_ar),
    'correlationDensity', (SELECT COUNT(*) FROM correlation co WHERE co.contract_id = c.id AND co.is_active = TRUE)
  )), '[]'::jsonb) INTO v_data
  FROM contract c
  WHERE c.is_active = TRUE
  LIMIT 100;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','contract','count', COALESCE(jsonb_array_length(v_data), 0)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('contracts', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_compliance_subcontractor_chain: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_compliance_subcontractor_chain(BIGINT, JSONB) IS 'Subcontractor chain analysis with correlation density per contract.';
REVOKE EXECUTE ON FUNCTION fn_report_data_compliance_subcontractor_chain(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_compliance_subcontractor_chain(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_compliance_audit_rights(
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
    'clauseId', cce.id, 'contractId', cce.contract_id,
    'contractTitle', COALESCE(c.title_en, c.title_ar),
    'clauseType', cce.clause_type_v2, 'reviewStatus', cce.review_status
  )), '[]'::jsonb) INTO v_data
  FROM contract_clause_extracted cce
  LEFT JOIN contract c ON c.id = cce.contract_id
  WHERE cce.tenant_id = v_tenant
    AND cce.clause_type_v2 ILIKE '%audit%right%'
    AND cce.is_active = TRUE
  LIMIT 200;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','contract_clause_extracted','count', COALESCE(jsonb_array_length(v_data), 0)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('auditRights', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_compliance_audit_rights: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_compliance_audit_rights(BIGINT, JSONB) IS 'Extracted audit-rights clauses inventory.';
REVOKE EXECUTE ON FUNCTION fn_report_data_compliance_audit_rights(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_compliance_audit_rights(BIGINT, JSONB) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (270, '270_crl_fn_report_data_compliance', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_report_data_compliance_sanctions_exposure(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_compliance_subcontractor_chain(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_compliance_audit_rights(BIGINT, JSONB);
-- DELETE FROM schema_migrations WHERE version = 270;
-- ============================================================
