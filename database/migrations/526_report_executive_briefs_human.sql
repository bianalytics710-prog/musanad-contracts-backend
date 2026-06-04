-- MIGRATION: 526_report_executive_briefs_human.sql
-- Date: 2026-06-03
-- Description:
--   Rewrite the two Executive briefs (weekly + monthly) to produce
--   human-readable rows. The previous versions surfaced raw ruleIds,
--   correlation IDs, and obscure status keys. The new shape returns:
--     • a `narrative` paragraph (rendered as a highlighted block)
--     • headline KPIs (rendered as KPI tiles in the PDF)
--     • clean joined tables (date · event · contract · counterparty · etc)

BEGIN;

-- ============================================================
-- Executive Weekly Brief
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_executive_weekly_brief(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant       UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now          TIMESTAMPTZ := NOW();
  v_window_start TIMESTAMPTZ := v_now - INTERVAL '7 days';
  v_active       INTEGER;
  v_total_value  NUMERIC;
  v_expiring_30  INTEGER;
  v_pending_drafts INTEGER;
  v_critical_events INTEGER;
  v_top_events   JSONB;
  v_top_risks    JSONB;
  v_expiring     JSONB;
  v_narrative    TEXT;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT COUNT(*), COALESCE(SUM(value_aed), 0) INTO v_active, v_total_value
    FROM contract WHERE is_active = TRUE AND status = 'active';

  SELECT COUNT(*) INTO v_expiring_30
    FROM contract WHERE is_active = TRUE AND status = 'active'
     AND end_date BETWEEN v_now::date AND (v_now + INTERVAL '30 days')::date;

  SELECT COUNT(*) INTO v_pending_drafts
    FROM advisory_draft
   WHERE tenant_id = v_tenant AND is_active = TRUE
     AND approval_status IN ('unapproved', 'pending_approval');

  SELECT COUNT(*) INTO v_critical_events
    FROM correlation co
   WHERE co.tenant_id = v_tenant AND co.is_active = TRUE AND co.status = 'active'
     AND co.created_at >= v_window_start
     AND COALESCE(co.match_evidence->>'severity', 'medium') IN ('high','critical');

  -- Top events this week (table)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'firedAt', fired_at,
    'event', event_name,
    'contractNumber', contract_number,
    'counterpartyName', counterparty_name,
    'severity', severity,
    'exposureAed', exposure_aed
  ) ORDER BY severity_rank, fired_at DESC), '[]'::jsonb) INTO v_top_events FROM (
    SELECT co.created_at AS fired_at,
           cr.name AS event_name,
           c.contract_number,
           COALESCE(p.name_en, '—') AS counterparty_name,
           COALESCE(co.match_evidence->>'severity', 'medium') AS severity,
           CASE COALESCE(co.match_evidence->>'severity', 'medium')
             WHEN 'critical' THEN 1 WHEN 'high' THEN 2
             WHEN 'medium' THEN 3 ELSE 4 END AS severity_rank,
           NULLIF(REGEXP_REPLACE(co.match_reason, '.*AED\s+([0-9.,]+).*', '\1'), co.match_reason)::numeric AS exposure_aed
      FROM correlation co
      JOIN correlation_rule cr ON cr.rule_id = co.rule_id AND cr.tenant_id = co.tenant_id
      LEFT JOIN contract c ON c.id = co.contract_id
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE co.tenant_id = v_tenant AND co.is_active = TRUE AND co.status = 'active'
       AND co.created_at >= v_window_start
     LIMIT 200
  ) s LIMIT 10;

  -- Top exposed contracts
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractNumber', contract_number, 'titleEn', title_en,
    'counterpartyName', counterparty_name,
    'riskScore', risk_score, 'valueAed', value_aed, 'endDate', end_date
  ) ORDER BY risk_score DESC NULLS LAST), '[]'::jsonb) INTO v_top_risks FROM (
    SELECT c.contract_number, c.title_en,
           COALESCE(p.name_en, '—') AS counterparty_name,
           c.ai_risk_score AS risk_score, c.value_aed, c.end_date
      FROM contract c
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE c.is_active = TRUE AND c.status = 'active'
     ORDER BY c.ai_risk_score DESC NULLS LAST LIMIT 5
  ) s;

  -- Expiring next 30d
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractNumber', contract_number, 'titleEn', title_en,
    'counterpartyName', counterparty_name,
    'endDate', end_date, 'daysToExpiry', days_to_expiry,
    'valueAed', value_aed
  ) ORDER BY end_date ASC), '[]'::jsonb) INTO v_expiring FROM (
    SELECT c.contract_number, c.title_en,
           COALESCE(p.name_en, '—') AS counterparty_name,
           c.end_date,
           (c.end_date - v_now::date) AS days_to_expiry,
           c.value_aed
      FROM contract c
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE c.is_active = TRUE AND c.status = 'active'
       AND c.end_date BETWEEN v_now::date AND (v_now + INTERVAL '30 days')::date
     ORDER BY c.end_date ASC LIMIT 10
  ) s;

  v_narrative := format(
    'Portfolio at a glance: %s active contracts totalling AED %s in committed value. %s critical or high-severity events fired in the past 7 days; %s contracts expire within 30 days; %s advisory drafts await Legal approval. The tables below list top events, top exposures, and the renewal cliff.',
    v_active,
    to_char(v_total_value, 'FM999,999,999,999'),
    v_critical_events, v_expiring_30, v_pending_drafts
  );

  RETURN jsonb_build_object(
    'payload', jsonb_build_object(
      'narrative', v_narrative,
      'headline', jsonb_build_object(
        'activeContracts', v_active,
        'portfolioValueAed', v_total_value,
        'expiringNext30Days', v_expiring_30,
        'pendingAdvisoryDrafts', v_pending_drafts,
        'criticalEvents7d', v_critical_events
      ),
      'topEvents', v_top_events,
      'topExposures', v_top_risks,
      'expiringNext30d', v_expiring
    ),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', '[]'::jsonb, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_report_data_executive_weekly_brief: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_executive_weekly_brief(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_executive_weekly_brief(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- Executive Monthly Board Pack
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_executive_monthly_board(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant       UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now          TIMESTAMPTZ := NOW();
  v_month_start  TIMESTAMPTZ := v_now - INTERVAL '30 days';
  v_active       INTEGER; v_total_value NUMERIC;
  v_signed_30    INTEGER; v_value_signed_30 NUMERIC;
  v_expiring_60  INTEGER;
  v_dispatched   INTEGER;
  v_closed_cases INTEGER;
  v_top10        JSONB;
  v_by_type      JSONB;
  v_movers       JSONB;
  v_narrative    TEXT;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT COUNT(*), COALESCE(SUM(value_aed), 0) INTO v_active, v_total_value
    FROM contract WHERE is_active = TRUE AND status = 'active';

  SELECT COUNT(*), COALESCE(SUM(value_aed), 0) INTO v_signed_30, v_value_signed_30
    FROM contract WHERE is_active = TRUE AND signed_at >= v_month_start;

  SELECT COUNT(*) INTO v_expiring_60
    FROM contract WHERE is_active = TRUE AND status = 'active'
     AND end_date BETWEEN v_now::date AND (v_now + INTERVAL '60 days')::date;

  SELECT COUNT(*) INTO v_dispatched
    FROM advisory_draft
   WHERE tenant_id = v_tenant AND is_active = TRUE
     AND dispatched_at >= v_month_start;

  SELECT COUNT(*) INTO v_closed_cases FROM risk_case
   WHERE tenant_id = v_tenant AND status = 'closed' AND updated_at >= v_month_start;

  -- Top 10 exposures
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractNumber', contract_number, 'titleEn', title_en,
    'counterpartyName', counterparty_name, 'riskScore', risk_score,
    'valueAed', value_aed, 'contractType', contract_type
  ) ORDER BY risk_score DESC NULLS LAST), '[]'::jsonb) INTO v_top10 FROM (
    SELECT c.contract_number, c.title_en, c.contract_type,
           COALESCE(p.name_en, '—') AS counterparty_name,
           c.ai_risk_score AS risk_score, c.value_aed
      FROM contract c
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE c.is_active = TRUE AND c.status = 'active'
     ORDER BY c.ai_risk_score DESC NULLS LAST LIMIT 10
  ) s;

  -- Portfolio mix by contract type
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractType', contract_type, 'count', count_n,
    'totalValueAed', total_value_aed, 'sharePct', share_pct
  ) ORDER BY total_value_aed DESC NULLS LAST), '[]'::jsonb) INTO v_by_type FROM (
    SELECT COALESCE(contract_type, '(unknown)') AS contract_type,
           COUNT(*) AS count_n,
           ROUND(SUM(COALESCE(value_aed, 0))::numeric, 0) AS total_value_aed,
           ROUND((SUM(COALESCE(value_aed, 0)) / NULLIF(v_total_value, 0) * 100)::numeric, 1) AS share_pct
      FROM contract
     WHERE is_active = TRUE AND status = 'active'
     GROUP BY contract_type
  ) s;

  -- Recent material events (last 30d) grouped by rule
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'event', event_name, 'count', count_n, 'maxSeverity', max_severity,
    'lastFiredAt', last_fired_at
  ) ORDER BY count_n DESC), '[]'::jsonb) INTO v_movers FROM (
    SELECT cr.name AS event_name, COUNT(*) AS count_n,
           MAX(co.created_at) AS last_fired_at,
           MAX(COALESCE(co.match_evidence->>'severity', 'medium')) AS max_severity
      FROM correlation co
      JOIN correlation_rule cr ON cr.rule_id = co.rule_id AND cr.tenant_id = co.tenant_id
     WHERE co.tenant_id = v_tenant AND co.is_active = TRUE AND co.status = 'active'
       AND co.created_at >= v_month_start
     GROUP BY cr.name
  ) s;

  v_narrative := format(
    'Month at a glance: %s active contracts totalling AED %s. %s contracts signed in the last 30 days (AED %s), %s expiring within 60 days. Legal Counsel dispatched %s advisory drafts and closed %s risk cases. Tables below detail top exposures, portfolio mix, and the month''s event activity.',
    v_active, to_char(v_total_value, 'FM999,999,999,999'),
    v_signed_30, to_char(v_value_signed_30, 'FM999,999,999,999'),
    v_expiring_60, v_dispatched, v_closed_cases
  );

  RETURN jsonb_build_object(
    'payload', jsonb_build_object(
      'narrative', v_narrative,
      'headline', jsonb_build_object(
        'activeContracts', v_active,
        'portfolioValueAed', v_total_value,
        'signedLast30d', v_signed_30,
        'valueSignedLast30dAed', v_value_signed_30,
        'expiringNext60Days', v_expiring_60,
        'dispatchedAdvisories30d', v_dispatched,
        'closedRiskCases30d', v_closed_cases
      ),
      'topExposures', v_top10,
      'portfolioMixByType', v_by_type,
      'monthsEventActivity', v_movers
    ),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', '[]'::jsonb, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_report_data_executive_monthly_board: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_executive_monthly_board(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_executive_monthly_board(BIGINT, JSONB) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (526, 'report_executive_briefs_human', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
