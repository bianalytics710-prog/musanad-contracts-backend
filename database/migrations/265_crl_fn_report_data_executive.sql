-- Migration: 265_crl_fn_report_data_executive.sql
-- Module: M20 — CR-L Reports & Briefings
-- CR: CR-L
-- Date: 2026-05-15
-- Description: 4 executive data fn_'s. STABLE INVOKER + S2-21 trio per fn.
--              Uses fn_demo_now() for date windows; explicit tenant filter on MV.
-- Common contract: returns { payload, meta: { tenantId, generatedAt, sourceTraceability, parameters } }

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- fn_report_data_executive_weekly_brief
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_data_executive_weekly_brief(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant   UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now      TIMESTAMPTZ := fn_demo_now();
  v_window_start TIMESTAMPTZ;
  v_avg_health  NUMERIC;
  v_top_corrs   JSONB;
  v_case_counts JSONB;
  v_pending_drafts INTEGER;
  v_trace JSONB := '[]'::jsonb;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;
  v_window_start := v_now - INTERVAL '7 days';

  SELECT AVG(health_score) INTO v_avg_health
    FROM latest_risk_score WHERE tenant_id = v_tenant;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', c.id, 'ruleId', c.rule_id, 'confidence', c.confidence, 'matchReason', c.match_reason
  ) ORDER BY c.confidence DESC), '[]'::jsonb) INTO v_top_corrs
  FROM correlation c
  WHERE c.tenant_id = v_tenant
    AND c.status = 'active'
    AND c.created_at >= v_window_start
  LIMIT 10;

  SELECT jsonb_object_agg(status, cnt) INTO v_case_counts FROM (
    SELECT status, COUNT(*) AS cnt FROM risk_case
     WHERE tenant_id = v_tenant AND is_active = TRUE
       AND created_at >= v_window_start
     GROUP BY status
  ) s;

  SELECT COUNT(*) INTO v_pending_drafts FROM advisory_draft
   WHERE tenant_id = v_tenant AND approval_status = 'pending_approval' AND is_active = TRUE;

  v_trace := jsonb_build_array(
    jsonb_build_object('tableName','latest_risk_score','count', COALESCE((SELECT COUNT(*) FROM latest_risk_score WHERE tenant_id = v_tenant), 0)),
    jsonb_build_object('tableName','correlation','count', COALESCE(jsonb_array_length(v_top_corrs), 0)),
    jsonb_build_object('tableName','risk_case','count', COALESCE((SELECT COUNT(*) FROM risk_case WHERE tenant_id = v_tenant AND created_at >= v_window_start), 0)),
    jsonb_build_object('tableName','advisory_draft','count', v_pending_drafts)
  );

  RETURN jsonb_build_object(
    'payload', jsonb_build_object(
      'avgHealthScore', v_avg_health,
      'topCorrelations', v_top_corrs,
      'riskCaseCounts', COALESCE(v_case_counts, '{}'::jsonb),
      'pendingAdvisoryDrafts', v_pending_drafts,
      'windowStart', v_window_start,
      'windowEnd', v_now
    ),
    'meta', jsonb_build_object(
      'tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', v_trace, 'parameters', p_parameters
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_data_executive_weekly_brief: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_data_executive_weekly_brief(BIGINT, JSONB) IS 'Executive weekly brief data: avg health, top correlations, risk-case counts, pending advisory drafts (last 7d).';
REVOKE EXECUTE ON FUNCTION fn_report_data_executive_weekly_brief(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_executive_weekly_brief(BIGINT, JSONB) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- fn_report_data_executive_monthly_board
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_data_executive_monthly_board(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant   UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now      TIMESTAMPTZ := fn_demo_now();
  v_month_start TIMESTAMPTZ;
  v_avg_health  NUMERIC;
  v_mar_total   NUMERIC;
  v_closed_cases INTEGER;
  v_dispatched_drafts INTEGER;
  v_reports_count INTEGER;
  v_trace JSONB := '[]'::jsonb;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;
  v_month_start := v_now - INTERVAL '1 month';

  SELECT AVG(health_score), SUM(mar_value) INTO v_avg_health, v_mar_total
    FROM latest_risk_score WHERE tenant_id = v_tenant;

  SELECT COUNT(*) INTO v_closed_cases FROM risk_case
   WHERE tenant_id = v_tenant AND status = 'closed' AND closed_at >= v_month_start;

  SELECT COUNT(*) INTO v_dispatched_drafts FROM advisory_draft
   WHERE tenant_id = v_tenant AND approval_status = 'dispatched' AND dispatched_at >= v_month_start;

  SELECT COUNT(*) INTO v_reports_count FROM report_run
   WHERE tenant_id = v_tenant AND status = 'complete' AND completed_at >= v_month_start;

  v_trace := jsonb_build_array(
    jsonb_build_object('tableName','latest_risk_score','count', (SELECT COUNT(*) FROM latest_risk_score WHERE tenant_id = v_tenant)),
    jsonb_build_object('tableName','risk_case','count', v_closed_cases),
    jsonb_build_object('tableName','advisory_draft','count', v_dispatched_drafts),
    jsonb_build_object('tableName','report_run','count', v_reports_count)
  );

  RETURN jsonb_build_object(
    'payload', jsonb_build_object(
      'avgHealthScore', v_avg_health,
      'totalMarValue', v_mar_total,
      'closedCasesLast30d', v_closed_cases,
      'dispatchedAdvisoriesLast30d', v_dispatched_drafts,
      'reportsGeneratedLast30d', v_reports_count,
      'windowStart', v_month_start,
      'windowEnd', v_now
    ),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
                               'sourceTraceability', v_trace, 'parameters', p_parameters)
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_data_executive_monthly_board: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_data_executive_monthly_board(BIGINT, JSONB) IS 'Executive monthly board data: monthly rolling counts.';
REVOKE EXECUTE ON FUNCTION fn_report_data_executive_monthly_board(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_executive_monthly_board(BIGINT, JSONB) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- fn_report_data_executive_avar_trend
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_data_executive_avar_trend(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant   UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now      TIMESTAMPTZ := fn_demo_now();
  v_series   JSONB;
  v_trace    JSONB;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'month', month_bucket, 'totalMar', total_mar, 'avgHealth', avg_health
  ) ORDER BY month_bucket ASC), '[]'::jsonb) INTO v_series
  FROM (
    SELECT date_trunc('month', calculated_at) AS month_bucket,
           SUM(mar_value) AS total_mar,
           AVG(health_score) AS avg_health
      FROM risk_score
     WHERE tenant_id = v_tenant
       AND calculated_at >= v_now - INTERVAL '12 months'
     GROUP BY 1
  ) m;

  v_trace := jsonb_build_array(
    jsonb_build_object('tableName','risk_score','count', (SELECT COUNT(*) FROM risk_score WHERE tenant_id = v_tenant AND calculated_at >= v_now - INTERVAL '12 months'))
  );

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('series', v_series, 'windowMonths', 12),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
                               'sourceTraceability', v_trace, 'parameters', p_parameters)
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_data_executive_avar_trend: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_data_executive_avar_trend(BIGINT, JSONB) IS 'Executive AVaR 12-month trend: monthly MAR + avg health from risk_score series.';
REVOKE EXECUTE ON FUNCTION fn_report_data_executive_avar_trend(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_executive_avar_trend(BIGINT, JSONB) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- fn_report_data_executive_top10_exposures
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_data_executive_top10_exposures(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now    TIMESTAMPTZ := fn_demo_now();
  v_data   JSONB;
  v_trace  JSONB;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractId', lrs.contract_id,
    'contractTitle', COALESCE(c.title_en, c.title_ar),
    'healthScore', lrs.health_score,
    'marValue', lrs.mar_value,
    'marCurrency', lrs.mar_currency,
    'calculatedAt', lrs.calculated_at
  ) ORDER BY lrs.health_score ASC), '[]'::jsonb) INTO v_data
  FROM (
    SELECT contract_id, health_score, mar_value, mar_currency, calculated_at
      FROM latest_risk_score
     WHERE tenant_id = v_tenant
     ORDER BY health_score ASC
     LIMIT 10
  ) lrs
  LEFT JOIN contract c ON c.id = lrs.contract_id;

  v_trace := jsonb_build_array(
    jsonb_build_object('tableName','latest_risk_score','count', LEAST((SELECT COUNT(*) FROM latest_risk_score WHERE tenant_id = v_tenant), 10))
  );

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('exposures', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
                               'sourceTraceability', v_trace, 'parameters', p_parameters)
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_data_executive_top10_exposures: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_data_executive_top10_exposures(BIGINT, JSONB) IS 'Top 10 most-exposed contracts by health score ASC.';
REVOKE EXECUTE ON FUNCTION fn_report_data_executive_top10_exposures(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_executive_top10_exposures(BIGINT, JSONB) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (265, '265_crl_fn_report_data_executive', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_report_data_executive_weekly_brief(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_executive_monthly_board(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_executive_avar_trend(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_executive_top10_exposures(BIGINT, JSONB);
-- DELETE FROM schema_migrations WHERE version = 265;
-- ============================================================
