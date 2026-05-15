-- Migration: 268_crl_fn_report_data_operations.sql
-- Module: M20 — CR-L Reports & Briefings
-- Date: 2026-05-15
-- Description: 3 operations data fn_'s (risk_board_snapshot, delivery_delay, penalty_exposure).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_report_data_operations_risk_board_snapshot(
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
  v_cases JSONB;
  v_top_corrs JSONB;
  v_trace JSONB;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'priority', priority, 'status', status, 'title', title, 'dueAt', due_at
  )), '[]'::jsonb) INTO v_cases
  FROM risk_case
  WHERE tenant_id = v_tenant
    AND assigned_role = 'operations'
    AND status NOT IN ('closed','approved','rejected','accept_risk')
    AND is_active = TRUE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'ruleId', rule_id, 'confidence', confidence
  ) ORDER BY confidence DESC), '[]'::jsonb) INTO v_top_corrs
  FROM correlation
  WHERE tenant_id = v_tenant AND status = 'active'
  LIMIT 10;

  v_trace := jsonb_build_array(
    jsonb_build_object('tableName','risk_case','count', COALESCE(jsonb_array_length(v_cases), 0)),
    jsonb_build_object('tableName','correlation','count', COALESCE(jsonb_array_length(v_top_corrs), 0))
  );

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('asOf', v_now, 'operationsCases', v_cases, 'topCorrelations', v_top_corrs),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_operations_risk_board_snapshot: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_operations_risk_board_snapshot(BIGINT, JSONB) IS 'Operations risk-board snapshot: open cases + top correlations as-of now.';
REVOKE EXECUTE ON FUNCTION fn_report_data_operations_risk_board_snapshot(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_operations_risk_board_snapshot(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_operations_delivery_delay(
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
    'correlationId', c.id, 'contractId', c.contract_id,
    'contractTitle', COALESCE(co.title_en, co.title_ar),
    'confidence', c.confidence, 'matchReason', c.match_reason, 'status', c.status, 'createdAt', c.created_at
  )), '[]'::jsonb) INTO v_data
  FROM correlation c
  LEFT JOIN contract co ON co.id = c.contract_id
  WHERE c.tenant_id = v_tenant
    AND c.rule_id ILIKE '%delivery%delay%'
    AND c.is_active = TRUE;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','correlation','count', COALESCE(jsonb_array_length(v_data), 0)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('delays', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_operations_delivery_delay: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_operations_delivery_delay(BIGINT, JSONB) IS 'Delivery-delay correlations with linked contracts.';
REVOKE EXECUTE ON FUNCTION fn_report_data_operations_delivery_delay(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_operations_delivery_delay(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_operations_penalty_exposure(
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
    'contractId', lrs.contract_id,
    'contractTitle', COALESCE(c.title_en, c.title_ar),
    'dimOperational', lrs.dim_operational,
    'marValue', lrs.mar_value, 'marCurrency', lrs.mar_currency
  ) ORDER BY lrs.dim_operational ASC), '[]'::jsonb) INTO v_data
  FROM latest_risk_score lrs
  LEFT JOIN contract c ON c.id = lrs.contract_id
  WHERE lrs.tenant_id = v_tenant
    AND lrs.dim_operational < 70;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','latest_risk_score','count', COALESCE(jsonb_array_length(v_data), 0)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('exposures', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_operations_penalty_exposure: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_operations_penalty_exposure(BIGINT, JSONB) IS 'Operational penalty exposure from risk_score.dim_operational < 70.';
REVOKE EXECUTE ON FUNCTION fn_report_data_operations_penalty_exposure(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_operations_penalty_exposure(BIGINT, JSONB) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (268, '268_crl_fn_report_data_operations', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_report_data_operations_risk_board_snapshot(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_operations_delivery_delay(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_operations_penalty_exposure(BIGINT, JSONB);
-- DELETE FROM schema_migrations WHERE version = 268;
-- ============================================================
