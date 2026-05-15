-- Migration: 269_crl_fn_report_data_finance.sql
-- Module: M20 — CR-L Reports & Briefings
-- Date: 2026-05-15
-- Description: 3 finance data fn_'s (fx_exposure, price_review_queue, payment_delay).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_report_data_finance_fx_exposure(
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
    'currency', currency, 'totalMar', total_mar, 'contractCount', contract_count
  ) ORDER BY total_mar DESC), '[]'::jsonb) INTO v_data
  FROM (
    SELECT lrs.mar_currency AS currency,
           SUM(lrs.mar_value) AS total_mar,
           COUNT(DISTINCT lrs.contract_id) AS contract_count
      FROM latest_risk_score lrs
     WHERE lrs.tenant_id = v_tenant
     GROUP BY lrs.mar_currency
  ) s;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','latest_risk_score','count', (SELECT COUNT(*) FROM latest_risk_score WHERE tenant_id = v_tenant)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('byCurrency', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_finance_fx_exposure: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_finance_fx_exposure(BIGINT, JSONB) IS 'FX exposure aggregated by contract currency.';
REVOKE EXECUTE ON FUNCTION fn_report_data_finance_fx_exposure(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_finance_fx_exposure(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_finance_price_review_queue(
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
    'matchReason', c.match_reason, 'createdAt', c.created_at
  )), '[]'::jsonb) INTO v_data
  FROM correlation c
  LEFT JOIN contract co ON co.id = c.contract_id
  WHERE c.tenant_id = v_tenant
    AND c.rule_id ILIKE '%price%review%'
    AND c.is_active = TRUE
    AND c.status = 'active';

  v_trace := jsonb_build_array(jsonb_build_object('tableName','correlation','count', COALESCE(jsonb_array_length(v_data), 0)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('priceReviews', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_finance_price_review_queue: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_finance_price_review_queue(BIGINT, JSONB) IS 'Price-review correlations with linked contracts.';
REVOKE EXECUTE ON FUNCTION fn_report_data_finance_price_review_queue(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_finance_price_review_queue(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_finance_payment_delay(
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
    'matchReason', c.match_reason, 'createdAt', c.created_at,
    'linkedRiskCases', (SELECT COUNT(*) FROM risk_case rc WHERE rc.correlation_id = c.id AND rc.is_active = TRUE)
  )), '[]'::jsonb) INTO v_data
  FROM correlation c
  LEFT JOIN contract co ON co.id = c.contract_id
  WHERE c.tenant_id = v_tenant
    AND c.rule_id ILIKE '%payment%delay%'
    AND c.is_active = TRUE;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','correlation','count', COALESCE(jsonb_array_length(v_data), 0)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('paymentDelays', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_finance_payment_delay: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_finance_payment_delay(BIGINT, JSONB) IS 'Payment-delay correlations with linked risk-case counts.';
REVOKE EXECUTE ON FUNCTION fn_report_data_finance_payment_delay(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_finance_payment_delay(BIGINT, JSONB) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (269, '269_crl_fn_report_data_finance', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_report_data_finance_fx_exposure(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_finance_price_review_queue(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_finance_payment_delay(BIGINT, JSONB);
-- DELETE FROM schema_migrations WHERE version = 269;
-- ============================================================
