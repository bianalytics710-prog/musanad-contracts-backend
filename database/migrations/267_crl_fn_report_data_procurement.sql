-- Migration: 267_crl_fn_report_data_procurement.sql
-- Module: M20 — CR-L Reports & Briefings
-- Date: 2026-05-15
-- Description: 4 procurement data fn_'s (supplier_scorecard, supplier_scorecard_detail,
--              icv_compliance, sla_breach).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_report_data_procurement_supplier_scorecard(
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
    'counterpartyId', counterparty_id, 'contractCount', contract_count,
    'avgHealthScore', avg_health, 'openRiskCases', open_cases
  ) ORDER BY avg_health ASC NULLS LAST), '[]'::jsonb) INTO v_data
  FROM (
    SELECT c.counterparty_id,
           COUNT(DISTINCT c.id) AS contract_count,
           AVG(lrs.health_score) AS avg_health,
           (SELECT COUNT(*) FROM risk_case rc WHERE rc.tenant_id = v_tenant
             AND rc.contract_id IN (SELECT id FROM contract WHERE counterparty_id = c.counterparty_id)
             AND rc.status NOT IN ('closed','approved','rejected','accept_risk')
             AND rc.is_active = TRUE) AS open_cases
      FROM contract c
      LEFT JOIN latest_risk_score lrs ON lrs.contract_id = c.id AND lrs.tenant_id = v_tenant
     WHERE c.counterparty_id IS NOT NULL
       AND c.is_active = TRUE
     GROUP BY c.counterparty_id
  ) s;

  v_trace := jsonb_build_array(
    jsonb_build_object('tableName','contract','count', (SELECT COUNT(DISTINCT counterparty_id) FROM contract WHERE counterparty_id IS NOT NULL AND is_active = TRUE)),
    jsonb_build_object('tableName','latest_risk_score','count', (SELECT COUNT(*) FROM latest_risk_score WHERE tenant_id = v_tenant))
  );

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('suppliers', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_procurement_supplier_scorecard: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_procurement_supplier_scorecard(BIGINT, JSONB) IS 'Supplier-level aggregate: contract count, avg health score, open risk cases.';
REVOKE EXECUTE ON FUNCTION fn_report_data_procurement_supplier_scorecard(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_procurement_supplier_scorecard(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_procurement_supplier_scorecard_detail(
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
  v_counterparty_id BIGINT := (p_parameters->>'counterpartyId')::BIGINT;
  v_data JSONB;
  v_trace JSONB;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractId', c.id, 'contractTitle', COALESCE(c.title_en, c.title_ar),
    'status', c.status, 'healthScore', lrs.health_score, 'marValue', lrs.mar_value
  )), '[]'::jsonb) INTO v_data
  FROM contract c
  LEFT JOIN latest_risk_score lrs ON lrs.contract_id = c.id AND lrs.tenant_id = v_tenant
  WHERE c.counterparty_id = v_counterparty_id AND c.is_active = TRUE;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','contract','count', (SELECT COUNT(*) FROM contract WHERE counterparty_id = v_counterparty_id AND is_active = TRUE)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('counterpartyId', v_counterparty_id, 'contracts', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_procurement_supplier_scorecard_detail: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_procurement_supplier_scorecard_detail(BIGINT, JSONB) IS 'Per-supplier contract-level drill-down. parameters.counterpartyId required.';
REVOKE EXECUTE ON FUNCTION fn_report_data_procurement_supplier_scorecard_detail(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_procurement_supplier_scorecard_detail(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_procurement_icv_compliance(
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
    'signalId', s.id, 'title', s.title, 'severity', s.severity_v2,
    'fetchedAt', s.fetched_at, 'metadata', s.metadata
  )), '[]'::jsonb) INTO v_data
  FROM osint_signal s
  WHERE s.tenant_id = v_tenant
    AND s.source LIKE 'internal:icv%'
    AND s.is_active = TRUE
  LIMIT 100;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','osint_signal','count', COALESCE(jsonb_array_length(v_data), 0)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('icvSignals', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_procurement_icv_compliance: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_procurement_icv_compliance(BIGINT, JSONB) IS 'ICV compliance signals from internal:icv source.';
REVOKE EXECUTE ON FUNCTION fn_report_data_procurement_icv_compliance(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_procurement_icv_compliance(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_procurement_sla_breach(
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
  v_open_count INTEGER;
  v_resolved_count INTEGER;
  v_avg_ttr_seconds NUMERIC;
  v_trace JSONB;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT COUNT(*) FILTER (WHERE status NOT IN ('closed','approved','rejected','accept_risk')),
         COUNT(*) FILTER (WHERE status = 'closed'),
         AVG(EXTRACT(EPOCH FROM (closed_at - created_at))) FILTER (WHERE status = 'closed')
    INTO v_open_count, v_resolved_count, v_avg_ttr_seconds
    FROM risk_case
   WHERE tenant_id = v_tenant AND case_type = 'sla_breach' AND is_active = TRUE;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','risk_case','count', (SELECT COUNT(*) FROM risk_case WHERE tenant_id = v_tenant AND case_type = 'sla_breach' AND is_active = TRUE)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('openCount', v_open_count, 'resolvedCount', v_resolved_count, 'avgTimeToResolutionSeconds', v_avg_ttr_seconds),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_procurement_sla_breach: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_procurement_sla_breach(BIGINT, JSONB) IS 'SLA-breach risk cases: open, resolved, avg TTR.';
REVOKE EXECUTE ON FUNCTION fn_report_data_procurement_sla_breach(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_procurement_sla_breach(BIGINT, JSONB) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (267, '267_crl_fn_report_data_procurement', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_report_data_procurement_supplier_scorecard(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_procurement_supplier_scorecard_detail(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_procurement_icv_compliance(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_procurement_sla_breach(BIGINT, JSONB);
-- DELETE FROM schema_migrations WHERE version = 267;
-- ============================================================
