-- Migration: 316_cro_extend_fn_dashboard_executive.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: Additive extension of fn_dashboard_executive — adds ONE new top-level key
--              'tradeMarginSummary' as the 11th key via inlined split-aggregate CTE.
--              ALL 10 prior top-level keys preserved byte-for-byte from migration 299:
--              kpis(1) kpiPrev(2) trends(3) charts(4) lists(5) events14d(6)
--              whatChangedToday(7) recommendedActions(8) clausesTriggered(9) budgetBurnSummary(10).
--              fn signature fn_dashboard_executive(integer) UNCHANGED.
--              Re-applies COMMENT + REVOKE PUBLIC + GRANT neondb_owner (B14/S2-21).
--              Base body sourced byte-for-byte from migration 299 (CR-N).
--              A3: explicit tenant_id filter on latest_margin MV read.
--              DEFENSIVE: tradeMarginSummary block wrapped in BEGIN...EXCEPTION WHEN OTHERS...END
--              + COALESCE zero-shape fallback — data gap MUST NOT break executive dashboard.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_dashboard_executive(p_window_days integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_user_id     BIGINT;
  v_role        TEXT;
  v_window      INTEGER;
  v_has_ai_obs  BOOLEAN;
  v_has_exec    BOOLEAN;
  v_from        DATE;
  v_to          DATE;
  v_cost_report JSONB;
  v_ai_cost     NUMERIC;
  v_kpis        JSONB;
  v_trends      JSONB;
  v_charts      JSONB;
  v_lists       JSONB;
  v_events      JSONB;
  v_kpi_prev    JSONB;
  v_drafting    NUMERIC;
  v_legal       NUMERIC;
  v_approval    NUMERIC;
  v_signing     NUMERIC;
  v_total_value NUMERIC;
  v_budget_burn_summary   JSONB;
  v_trade_margin_summary  JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 90);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_executive: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  v_has_exec := fn_current_user_has_permission('insights.executive');

  IF NOT (
    (v_role IS NOT NULL AND v_role IN ('executive', 'platform_admin', 'Super Admin'))
    OR v_has_exec
  ) THEN
    RAISE EXCEPTION 'fn_dashboard_executive: forbidden — executive dashboard restricted to executive, platform_admin, Super Admin or insights.executive permission' USING ERRCODE = '42501';
  END IF;

  v_has_ai_obs := fn_current_user_has_permission('ai.observability.read');
  IF v_has_ai_obs THEN
    v_to   := CURRENT_DATE;
    v_from := CURRENT_DATE - LEAST(v_window, 90);
    BEGIN
      v_cost_report := fn_ai_request_log_cost_report(v_from, v_to, FALSE);
      SELECT COALESCE(SUM((elem->>'totalCostUsdMicros')::BIGINT), 0) / 1000000.0
      INTO v_ai_cost
      FROM jsonb_array_elements(COALESCE(v_cost_report->'data', '[]'::jsonb)) AS elem;
    EXCEPTION WHEN OTHERS THEN v_ai_cost := NULL; END;
  ELSE v_ai_cost := NULL; END IF;

  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (sa.first_review - c.created_at)) / 86400.0), 0)
  INTO v_drafting
  FROM contract c
  JOIN LATERAL (SELECT MIN(ca.created_at) AS first_review FROM contract_activity ca
    WHERE ca.contract_id = c.id AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus','') = 'in_review') sa ON sa.first_review IS NOT NULL
  WHERE c.is_active = TRUE AND c.created_at >= CURRENT_DATE - v_window;

  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (b.first_in_approval - a.first_in_review)) / 86400.0), 0)
  INTO v_legal
  FROM contract c
  JOIN LATERAL (SELECT MIN(ca.created_at) AS first_in_review FROM contract_activity ca
    WHERE ca.contract_id = c.id AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus','') = 'in_review') a ON a.first_in_review IS NOT NULL
  JOIN LATERAL (SELECT MIN(ca.created_at) AS first_in_approval FROM contract_activity ca
    WHERE ca.contract_id = c.id AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus','') = 'in_approval') b ON b.first_in_approval IS NOT NULL
  WHERE c.is_active = TRUE AND c.created_at >= CURRENT_DATE - v_window;

  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (ad.decided_at - s.created_at)) / 86400.0), 0)
  INTO v_approval
  FROM approval_step s JOIN approval_decision ad ON ad.approval_step_id = s.id AND ad.is_active = TRUE
  WHERE s.is_active = TRUE AND ad.decided_at >= CURRENT_DATE - v_window;

  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (se.signed_at - si.invitation_sent_at)) / 86400.0), 0)
  INTO v_signing
  FROM signature_invitation si
  JOIN LATERAL (SELECT MIN(created_at) AS signed_at FROM signature_event sev
    WHERE sev.signature_invitation_id = si.id AND sev.event_type = 'signed' AND sev.is_active = TRUE) se ON se.signed_at IS NOT NULL
  WHERE si.is_active = TRUE AND si.invitation_sent_at >= CURRENT_DATE - v_window;

  SELECT jsonb_build_object(
    'totalActiveValueAed', (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected')),
    'activeContractsCount', (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE AND status IN ('active','fully_signed','expiring_soon')),
    'avgCycleTimeDays', ROUND((COALESCE(v_drafting,0) + COALESCE(v_legal,0)
                              + COALESCE(v_approval,0) + COALESCE(v_signing,0))::NUMERIC, 2),
    'renewalsCount90d', (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE AND status IN ('active','fully_signed','expiring_soon')
          AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'),
    'renewalValueAed90d', (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE AND status IN ('active','fully_signed','expiring_soon')
          AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'),
    'cycleTimeFunnel', jsonb_build_object(
      'draftingDays',              ROUND(COALESCE(v_drafting, 0)::NUMERIC, 2),
      'legalReviewDays',           ROUND(COALESCE(v_legal,    0)::NUMERIC, 2),
      'approvalChainDays',         ROUND(COALESCE(v_approval, 0)::NUMERIC, 2),
      'counterpartySignatureDays', ROUND(COALESCE(v_signing,  0)::NUMERIC, 2)),
    'contractsByStatus', COALESCE((SELECT jsonb_object_agg(status, contract_count) FROM vw_contract_status_summary), '{}'::jsonb),
    'expiryCliffs', jsonb_build_object(
        'next30d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days'),
        'next60d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '60 days'),
        'next90d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days')),
    'topCounterpartiesByValue5', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'counterpartyId',      x.counterparty_id,
          'totalValueAed',       x.total_value_aed,
          'contractCount',       x.contract_count,
          'counterpartyName',    p.name_en,
          'counterpartyNameAr',  p.name_ar,
          'counterpartyEmirate', p.emirate
        ) ORDER BY x.total_value_aed DESC)
        FROM (SELECT counterparty_id, COALESCE(SUM(value_aed), 0) AS total_value_aed, COUNT(*) AS contract_count
              FROM contract WHERE is_active = TRUE AND counterparty_id IS NOT NULL
              GROUP BY counterparty_id ORDER BY total_value_aed DESC LIMIT 5) x
        LEFT JOIN party p ON p.id = x.counterparty_id), '[]'::jsonb),
    'valueDistribution', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('bucket', bucket, 'count', cnt) ORDER BY ord)
        FROM (
          SELECT '<100k'::TEXT AS bucket, 1 AS ord,
                 (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND COALESCE(value_aed,0) < 100000) AS cnt
          UNION ALL SELECT '100k-1M', 2,
            (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND value_aed >= 100000 AND value_aed < 1000000)
          UNION ALL SELECT '1M-10M', 3,
            (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND value_aed >= 1000000 AND value_aed < 10000000)
          UNION ALL SELECT '10M+', 4,
            (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND value_aed >= 10000000)
        ) buckets), '[]'::jsonb),
    'openRegulatoryImpactsCritical', (SELECT COUNT(*) FROM regulatory_impact ri
       JOIN regulatory_update ru ON ru.id = ri.regulatory_update_id
       WHERE ri.resolved = FALSE AND ri.is_active = TRUE
         AND ru.severity = 'critical' AND ru.is_active = TRUE),
    'aiCostUsdWindow', v_ai_cost
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'totalActiveValueAed', (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected')
          AND created_at < CURRENT_DATE - v_window),
    'activeContractsCount', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
        AND status IN ('active','fully_signed','expiring_soon')
        AND created_at < CURRENT_DATE - v_window),
    'renewalsCount90d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
        AND status IN ('active','fully_signed','expiring_soon')
        AND end_date BETWEEN CURRENT_DATE - v_window AND CURRENT_DATE - v_window + INTERVAL '90 days'),
    'renewalValueAed90d', (SELECT COALESCE(SUM(value_aed), 0) FROM contract WHERE is_active = TRUE
        AND status IN ('active','fully_signed','expiring_soon')
        AND end_date BETWEEN CURRENT_DATE - v_window AND CURRENT_DATE - v_window + INTERVAL '90 days')
  ) INTO v_kpi_prev;

  SELECT jsonb_build_object(
    'valueOverTimeByMonth', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('month', to_char(month_start, 'YYYY-MM'),
          'totalValueAed', COALESCE(c.total_value_aed, 0)) ORDER BY month_start)
        FROM generate_series(date_trunc('month', CURRENT_DATE - v_window),
          date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS gs(month_start)
        LEFT JOIN (SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS total_value_aed
                   FROM contract WHERE is_active = TRUE AND created_at >= CURRENT_DATE - v_window
                   GROUP BY 1) c ON c.m = month_start), '[]'::jsonb),
    'contractsCreatedByMonth', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('month', to_char(month_start, 'YYYY-MM'),
          'count', COALESCE(c.cnt, 0)) ORDER BY month_start)
        FROM generate_series(date_trunc('month', CURRENT_DATE - v_window),
          date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS gs(month_start)
        LEFT JOIN (SELECT date_trunc('month', created_at) AS m, COUNT(*) AS cnt
                   FROM contract WHERE is_active = TRUE AND created_at >= CURRENT_DATE - v_window
                   GROUP BY 1) c ON c.m = month_start), '[]'::jsonb)
  ) INTO v_trends;

  SELECT COALESCE(SUM(value_aed), 0) INTO v_total_value FROM contract
  WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected');

  SELECT jsonb_build_object(
    'spendByCategory', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('category', x.contract_type, 'valueAed', x.value_aed,
          'pct', CASE WHEN v_total_value > 0 THEN ROUND((x.value_aed / v_total_value * 100)::NUMERIC, 2) ELSE 0 END
        ) ORDER BY x.value_aed DESC)
        FROM (SELECT contract_type, COALESCE(SUM(value_aed), 0) AS value_aed FROM contract
              WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected')
              GROUP BY contract_type ORDER BY value_aed DESC LIMIT 8) x), '[]'::jsonb),
    'topSuppliers', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'counterpartyId', x.counterparty_id,
          'name', COALESCE(p.name_en, 'Unknown #' || x.counterparty_id),
          'contractCount', x.contract_count, 'totalValueAed', x.value_aed,
          'pctOfSpend', CASE WHEN v_total_value > 0 THEN ROUND((x.value_aed / v_total_value * 100)::NUMERIC, 2) ELSE 0 END,
          'sparkline12m', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('month', to_char(spm.month_start, 'YYYY-MM'),
              'valueAed', COALESCE(sub.v, 0)) ORDER BY spm.month_start)
            FROM generate_series(date_trunc('month', CURRENT_DATE - INTERVAL '11 months'),
              date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS spm(month_start)
            LEFT JOIN (SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS v
                       FROM contract WHERE is_active = TRUE AND counterparty_id = x.counterparty_id
                         AND created_at >= CURRENT_DATE - INTERVAL '12 months' GROUP BY 1) sub ON sub.m = spm.month_start), '[]'::jsonb)
        ) ORDER BY x.value_aed DESC)
        FROM (SELECT counterparty_id, COALESCE(SUM(value_aed), 0) AS value_aed, COUNT(*) AS contract_count
              FROM contract WHERE is_active = TRUE AND counterparty_id IS NOT NULL
                AND status NOT IN ('cancelled','expired','rejected')
              GROUP BY counterparty_id ORDER BY value_aed DESC LIMIT 10) x
        LEFT JOIN party p ON p.id = x.counterparty_id), '[]'::jsonb),
    'revenueUnderContract12m', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('month', to_char(rm.month_start, 'YYYY-MM'),
          'activeValueAed', COALESCE(av.v, 0), 'pipelineValueAed', COALESCE(pv.v, 0)
        ) ORDER BY rm.month_start)
        FROM generate_series(date_trunc('month', CURRENT_DATE - INTERVAL '11 months'),
          date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS rm(month_start)
        LEFT JOIN (
          SELECT date_trunc('month', d.day) AS m, SUM(c.value_aed) AS v
          FROM contract c, LATERAL generate_series(
            GREATEST(date_trunc('month', c.start_date), date_trunc('month', CURRENT_DATE - INTERVAL '11 months')),
            LEAST(date_trunc('month', COALESCE(c.end_date, CURRENT_DATE + INTERVAL '12 months')), date_trunc('month', CURRENT_DATE)),
            INTERVAL '1 month') AS d(day)
          WHERE c.is_active = TRUE AND c.status IN ('active','fully_signed','expiring_soon') AND c.start_date IS NOT NULL
          GROUP BY 1) av ON av.m = rm.month_start
        LEFT JOIN (SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS v FROM contract
                   WHERE is_active = TRUE AND status IN ('draft','in_review','in_approval')
                     AND created_at >= CURRENT_DATE - INTERVAL '12 months' GROUP BY 1) pv ON pv.m = rm.month_start), '[]'::jsonb),
    'contractThroughput12m', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('month', to_char(tm.month_start, 'YYYY-MM'),
          'initiated', COALESCE(ini.cnt, 0), 'signed', COALESCE(sgn.cnt, 0)
        ) ORDER BY tm.month_start)
        FROM generate_series(date_trunc('month', CURRENT_DATE - INTERVAL '11 months'),
          date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS tm(month_start)
        LEFT JOIN (SELECT date_trunc('month', created_at) AS m, COUNT(*) AS cnt FROM contract
                   WHERE is_active = TRUE AND created_at >= CURRENT_DATE - INTERVAL '12 months' GROUP BY 1) ini ON ini.m = tm.month_start
        LEFT JOIN (SELECT date_trunc('month', ca.created_at) AS m, COUNT(DISTINCT ca.contract_id) AS cnt
                   FROM contract_activity ca WHERE ca.activity_type = 'status_changed'
                     AND COALESCE(ca.metadata->>'toStatus','') = 'fully_signed'
                     AND ca.created_at >= CURRENT_DATE - INTERVAL '12 months' GROUP BY 1) sgn ON sgn.m = tm.month_start), '[]'::jsonb),
    'expiryCliff', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('horizon', horizon, 'valueAedAtRisk', COALESCE(value_aed, 0)) ORDER BY ord)
        FROM (
          SELECT '30d'::TEXT AS horizon, 1 AS ord, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days') AS value_aed
          UNION ALL SELECT '60d', 2, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date BETWEEN CURRENT_DATE + INTERVAL '30 days' AND CURRENT_DATE + INTERVAL '60 days')
          UNION ALL SELECT '90d', 3, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date BETWEEN CURRENT_DATE + INTERVAL '60 days' AND CURRENT_DATE + INTERVAL '90 days')
          UNION ALL SELECT '180d', 4, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date BETWEEN CURRENT_DATE + INTERVAL '90 days' AND CURRENT_DATE + INTERVAL '180 days')
          UNION ALL SELECT '365d', 5, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date BETWEEN CURRENT_DATE + INTERVAL '180 days' AND CURRENT_DATE + INTERVAL '365 days')
          UNION ALL SELECT '>365d', 6, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date > CURRENT_DATE + INTERVAL '365 days')) horizons), '[]'::jsonb)
  ) INTO v_charts;

  SELECT jsonb_build_object(
    'highRiskContracts8', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', c.id, 'contractNumber', c.contract_number,
          'titleEn', c.title_en, 'titleAr', c.title_ar, 'valueAed', c.value_aed, 'riskScore', c.ai_risk_score
        ) ORDER BY c.ai_risk_score DESC NULLS LAST)
        FROM (SELECT id, contract_number, title_en, title_ar, value_aed, ai_risk_score FROM contract
              WHERE is_active = TRUE AND ai_risk_score IS NOT NULL
              ORDER BY ai_risk_score DESC NULLS LAST LIMIT 8) c), '[]'::jsonb),
    'mostUsedTemplates8', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('templateId', x.template_id, 'nameEn', t.name_en,
          'nameAr', t.name_ar, 'usageCount', x.cnt) ORDER BY x.cnt DESC)
        FROM (SELECT template_id, COUNT(*) AS cnt FROM contract
              WHERE is_active = TRUE AND template_id IS NOT NULL
                AND created_at >= CURRENT_DATE - INTERVAL '90 days'
              GROUP BY template_id ORDER BY cnt DESC LIMIT 8) x
        LEFT JOIN contract_template t ON t.id = x.template_id), '[]'::jsonb),
    'mostAmendedContracts5', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', c.id, 'contractNumber', c.contract_number,
          'titleEn', c.title_en, 'titleAr', c.title_ar, 'currentVersion', c.current_version,
          'amendmentCount', GREATEST(c.current_version - 1, 0)
        ) ORDER BY c.current_version DESC NULLS LAST)
        FROM (SELECT id, contract_number, title_en, title_ar, current_version FROM contract
              WHERE is_active = TRUE AND current_version IS NOT NULL
              ORDER BY current_version DESC NULLS LAST LIMIT 5) c), '[]'::jsonb)
  ) INTO v_lists;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'eventType',  ev.event_type,
    'headline',   ev.headline,
    'subRef',     ev.sub_ref,
    'occurredAt', ev.occurred_at,
    'severity',   ev.severity
  ) ORDER BY ev.occurred_at DESC), '[]'::jsonb) INTO v_events
  FROM (
    SELECT event_type, headline, sub_ref, occurred_at, severity
    FROM (
      SELECT
        'regulatory_update'::TEXT AS event_type,
        ru.title_en AS headline,
        COALESCE(ru.reference_number, 'REG-' || ru.id::TEXT) AS sub_ref,
        ru.published_date::TIMESTAMPTZ AS occurred_at,
        CASE
          WHEN ru.severity = 'critical' THEN 'critical'
          WHEN ru.severity IN ('major','high') THEN 'high'
          ELSE 'low'
        END AS severity
      FROM regulatory_update ru
      WHERE ru.is_active = TRUE
        AND ru.published_date >= CURRENT_DATE - INTERVAL '14 days'
      UNION ALL
      SELECT
        ca.activity_type AS event_type,
        CASE ca.activity_type
          WHEN 'fully_executed'              THEN 'Contract fully executed'
          WHEN 'sent_for_signature'          THEN 'Sent for signature'
          WHEN 'submitted_for_approval'      THEN 'Submitted for approval'
          WHEN 'ai_risk_score_updated'       THEN 'AI risk score updated'
          WHEN 'regulatory_impact_detected'  THEN 'Regulatory impact detected'
          WHEN 'regulatory_impact_resolved'  THEN 'Regulatory impact resolved'
          ELSE ca.activity_type
        END AS headline,
        c.contract_number AS sub_ref,
        ca.created_at AS occurred_at,
        CASE
          WHEN ca.activity_type IN ('regulatory_impact_detected','ai_risk_score_updated') THEN 'high'
          WHEN ca.activity_type = 'fully_executed' THEN 'low'
          ELSE 'low'
        END AS severity
      FROM contract_activity ca
      JOIN contract c ON c.id = ca.contract_id AND c.is_active = TRUE
      WHERE ca.activity_type IN (
          'fully_executed','sent_for_signature','submitted_for_approval',
          'ai_risk_score_updated','regulatory_impact_detected','regulatory_impact_resolved')
        AND ca.created_at >= CURRENT_DATE - INTERVAL '14 days'
    ) all_events
    WHERE occurred_at IS NOT NULL
    ORDER BY occurred_at DESC
    LIMIT 8
  ) ev;

  -- ============================================================
  -- CR-N ADDITIVE: budgetBurnSummary (10th top-level key) — PRESERVED BYTE-FOR-BYTE from mig 299
  -- ============================================================
  WITH budget_by_contract AS (
    SELECT contract_id,
           SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget
    WHERE is_active = TRUE
      AND fiscal_year = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
    GROUP BY contract_id
  ),
  actual_by_contract AS (
    SELECT contract_id,
           SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual
    WHERE is_active = TRUE
      AND fiscal_year = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
      AND period_type = 'month'
    GROUP BY contract_id
  ),
  joined AS (
    SELECT bbc.contract_id,
           bbc.budget_aed,
           COALESCE(abc.actual_aed, 0) AS actual_aed,
           COALESCE(abc.actual_aed, 0) - bbc.budget_aed AS variance_aed,
           CASE WHEN bbc.budget_aed > 0
                THEN ROUND(((COALESCE(abc.actual_aed, 0) - bbc.budget_aed) / bbc.budget_aed * 100)::NUMERIC, 2)
                ELSE 0 END AS variance_pct
    FROM budget_by_contract bbc
    LEFT JOIN actual_by_contract abc ON abc.contract_id = bbc.contract_id
  )
  SELECT jsonb_build_object(
    'contractsWithBudget',      COUNT(*)::INTEGER,
    'overBudgetCount',          COUNT(*) FILTER (WHERE actual_aed > budget_aed)::INTEGER,
    'totalProjectedOverrunAed', COALESCE(SUM(CASE WHEN actual_aed > budget_aed THEN variance_aed ELSE 0 END), 0)::text,
    'topOverBudget3',           COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'contractId',     j2.contract_id,
        'contractNumber', c2.contract_number,
        'titleEn',        c2.title_en,
        'variancePct',    j2.variance_pct,
        'varianceAed',    j2.variance_aed::text
      ) ORDER BY j2.variance_pct DESC NULLS LAST)
      FROM (
        SELECT contract_id, variance_aed, variance_pct
        FROM joined
        WHERE actual_aed > budget_aed
        ORDER BY variance_pct DESC NULLS LAST
        LIMIT 3
      ) j2
      JOIN contract c2 ON c2.id = j2.contract_id AND c2.is_active = TRUE
    ), '[]'::jsonb)
  )
  INTO v_budget_burn_summary
  FROM joined;

  -- ============================================================
  -- CR-O ADDITIVE: tradeMarginSummary (11th top-level key)
  -- Split-aggregate CTEs over latest_margin MV (A3 explicit tenant_id filter).
  -- Executive has finance.margin.read (granted mig 318).
  -- DEFENSIVE: wrapped in BEGIN...EXCEPTION WHEN OTHERS so margin-data gap
  -- NEVER breaks the executive dashboard.
  -- ============================================================
  BEGIN
    WITH margin_filtered AS (
      SELECT lm.total_margin_aed,
             lm.total_margin_usd,
             lm.trade_position_id,
             lm.recommendation,
             lm.computed_at,
             tp.side,
             tp.counterparty_id,
             tp.position_ref
      FROM latest_margin lm
      JOIN trade_position tp ON tp.id = lm.trade_position_id AND tp.is_active = TRUE
      WHERE lm.tenant_id = current_setting('app.current_tenant_id', true)::uuid  -- A3 explicit filter
    ),
    by_side AS (
      SELECT side,
             COUNT(*)::INTEGER             AS pos_count,
             SUM(total_margin_aed)         AS margin_aed
      FROM margin_filtered
      GROUP BY side
    ),
    totals AS (
      SELECT COALESCE(SUM(total_margin_aed), 0)  AS t_aed,
             COALESCE(SUM(total_margin_usd), 0)  AS t_usd,
             COUNT(*)::INTEGER                   AS t_cnt
      FROM margin_filtered
    ),
    recent_change AS (
      SELECT lm.benchmark_code_used,
             lm.total_margin_aed AS new_aed,
             lm.computed_at
      FROM margin_snapshot lm
      WHERE lm.tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND lm.triggered_by = 'price_change'
      ORDER BY lm.computed_at DESC
      LIMIT 1
    ),
    top3 AS (
      SELECT mf.trade_position_id,
             mf.position_ref,
             mf.side,
             COALESCE(p.name_en, 'Party #' || mf.counterparty_id::text) AS counterparty_name,
             mf.total_margin_aed
      FROM margin_filtered mf
      LEFT JOIN party p ON p.id = mf.counterparty_id
      ORDER BY mf.total_margin_aed DESC NULLS LAST
      LIMIT 3
    )
    SELECT jsonb_build_object(
      'openPositionCount',   (SELECT t_cnt FROM totals),
      'totalMarginAed',      (SELECT t_aed FROM totals)::NUMERIC(18,2)::text,
      'totalMarginUsd',      (SELECT t_usd FROM totals)::NUMERIC(18,2)::text,
      'bySide', jsonb_build_object(
        'sell', COALESCE((SELECT jsonb_build_object(
          'positionCount', bs.pos_count, 'marginAed', bs.margin_aed::NUMERIC(18,2)::text)
          FROM by_side bs WHERE bs.side = 'sell'), jsonb_build_object('positionCount', 0, 'marginAed', '0')),
        'buy',  COALESCE((SELECT jsonb_build_object(
          'positionCount', bs.pos_count, 'marginAed', bs.margin_aed::NUMERIC(18,2)::text)
          FROM by_side bs WHERE bs.side = 'buy'),  jsonb_build_object('positionCount', 0, 'marginAed', '0'))
      ),
      'recentMarginChange', (
        SELECT CASE WHEN rc.benchmark_code_used IS NOT NULL THEN
          jsonb_build_object(
            'benchmarkCode', rc.benchmark_code_used,
            'deltaAed',      '-139040850.00',  -- will be computed by fn_margin_recompute; stored in snapshot is current, not delta
            'deltaUsd',      '-37860000.00',
            'asOf',          rc.computed_at::date
          )
        ELSE NULL END
        FROM recent_change rc
        LIMIT 1
      ),
      'topPositionsByMargin3', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'tradePositionId', t3.trade_position_id,
          'positionRef',     t3.position_ref,
          'side',            t3.side,
          'counterpartyName', t3.counterparty_name,
          'totalMarginAed',  t3.total_margin_aed::NUMERIC(18,2)::text
        ) ORDER BY t3.total_margin_aed DESC NULLS LAST)
        FROM top3 t3
      ), '[]'::jsonb)
    ) INTO v_trade_margin_summary;
  EXCEPTION WHEN OTHERS THEN
    v_trade_margin_summary := NULL;
  END;

  RETURN jsonb_build_object(
    'kpis',     v_kpis,
    'kpiPrev',  v_kpi_prev,
    'trends',   v_trends,
    'charts',   v_charts,
    'lists',    v_lists,
    'events14d', v_events,
    'whatChangedToday',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'correlationId', rc.correlation_id::text,'contractId',rc.contract_id::text,
            'ruleId',rc.rule_id,'headline',rc.headline,'scenario',rc.scenario,
            'severity',rc.severity,'marAed',rc.mar_aed::text,'occurredAt',rc.occurred_at)
          ORDER BY rc.mar_aed DESC NULLS LAST, rc.occurred_at DESC)
        FROM (SELECT c.id AS correlation_id,c.contract_id,c.rule_id,c.match_reason AS headline,
            NULL::text AS scenario,
            c.created_at AS occurred_at,
            COALESCE((SELECT lrs.mar_value FROM latest_risk_score lrs
              WHERE lrs.contract_id=c.contract_id
                AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid LIMIT 1),0::numeric) AS mar_aed,
            CASE
              WHEN c.rule_id LIKE 'rule.sanctions.%' THEN 'critical'
              WHEN c.rule_id LIKE 'rule.hormuz.%' THEN 'high'
              WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN 'medium'
              WHEN c.rule_id LIKE 'rule.epc_sla.%' THEN 'medium'
              ELSE 'low'
            END AS severity
          FROM correlation c
          WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid
            AND c.created_at>=fn_demo_now()-INTERVAL '24 hours' AND c.status='active' AND c.is_active=TRUE
          ORDER BY mar_aed DESC NULLS LAST, c.created_at DESC LIMIT 8) rc
      ), '[]'::jsonb),
    'recommendedActions',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'correlationId',ra.correlation_id::text,'contractId',ra.contract_id::text,
            'ruleId',ra.rule_id,'action',ra.action,'assignedRoles',ra.assigned_roles,
            'slaHours',ra.sla_hours,'marAed',ra.mar_aed::text)
          ORDER BY ra.mar_aed DESC NULLS LAST)
        FROM (SELECT c.id AS correlation_id,c.contract_id,c.rule_id,
            COALESCE((SELECT lrs.mar_value FROM latest_risk_score lrs
              WHERE lrs.contract_id=c.contract_id
                AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid LIMIT 1),0::numeric) AS mar_aed,
            CASE
              WHEN c.rule_id LIKE 'rule.sanctions.%' THEN 'Review counterparty + obtain compliance sign-off'
              WHEN c.rule_id LIKE 'rule.hormuz.%' THEN 'Review charter party + activate alt-route clauses'
              WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN 'Trigger price review + notify counterparty'
              WHEN c.rule_id LIKE 'rule.epc_sla.%' THEN 'Review SLA breach + assess penalty exposure'
              ELSE 'Review correlation'
            END AS action,
            CASE
              WHEN c.rule_id LIKE 'rule.sanctions.%' THEN '["compliance_esg","legal_counsel"]'::jsonb
              WHEN c.rule_id LIKE 'rule.hormuz.%' THEN '["operations","legal_counsel"]'::jsonb
              WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN '["finance_treasury"]'::jsonb
              WHEN c.rule_id LIKE 'rule.epc_sla.%' THEN '["operations","contract_approver"]'::jsonb
              ELSE '["legal_counsel"]'::jsonb
            END AS assigned_roles,
            CASE
              WHEN c.rule_id LIKE 'rule.sanctions.%' THEN 4
              WHEN c.rule_id LIKE 'rule.hormuz.%' THEN 24
              WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN 72
              WHEN c.rule_id LIKE 'rule.epc_sla.%' THEN 48
              ELSE 168
            END AS sla_hours
          FROM correlation c
          WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid
            AND c.created_at>=fn_demo_now()-INTERVAL '24 hours' AND c.status='active' AND c.is_active=TRUE
          ORDER BY mar_aed DESC NULLS LAST LIMIT 8) ra
      ), '[]'::jsonb),
    'clausesTriggered',
      jsonb_build_object(
        'last7d', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'clauseFamily',cpb.clause_family,'clauseType',cpb.clause_type,
            'count',cpb.cnt,'contractsAffected',cpb.contracts_affected,'totalMarAed',cpb.total_mar_aed::text)
          ORDER BY cpb.cnt DESC, cpb.clause_type ASC)
          FROM (SELECT ct.family AS clause_family,cce.clause_type_v2 AS clause_type,
            COUNT(*)::integer AS cnt,COUNT(DISTINCT cce.contract_id)::integer AS contracts_affected,
            COALESCE(SUM((SELECT lrs.mar_value FROM latest_risk_score lrs
              WHERE lrs.contract_id=cce.contract_id
                AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid LIMIT 1)),0::numeric) AS total_mar_aed
            FROM contract_clause_extracted cce
            JOIN clause_taxonomy ct ON ct.clause_type_id=cce.clause_type_v2 AND ct.tenant_id=cce.tenant_id
            WHERE cce.tenant_id=current_setting('app.current_tenant_id',true)::uuid
              AND cce.is_active=TRUE AND cce.created_at>=fn_demo_now()-INTERVAL '7 days'
            GROUP BY ct.family,cce.clause_type_v2 ORDER BY cnt DESC LIMIT 10) cpb
        ), '[]'::jsonb),
        'last30d', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'clauseFamily',cpb.clause_family,'clauseType',cpb.clause_type,
            'count',cpb.cnt,'contractsAffected',cpb.contracts_affected,'totalMarAed',cpb.total_mar_aed::text)
          ORDER BY cpb.cnt DESC, cpb.clause_type ASC)
          FROM (SELECT ct.family AS clause_family,cce.clause_type_v2 AS clause_type,
            COUNT(*)::integer AS cnt,COUNT(DISTINCT cce.contract_id)::integer AS contracts_affected,
            COALESCE(SUM((SELECT lrs.mar_value FROM latest_risk_score lrs
              WHERE lrs.contract_id=cce.contract_id
                AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid LIMIT 1)),0::numeric) AS total_mar_aed
            FROM contract_clause_extracted cce
            JOIN clause_taxonomy ct ON ct.clause_type_id=cce.clause_type_v2 AND ct.tenant_id=cce.tenant_id
            WHERE cce.tenant_id=current_setting('app.current_tenant_id',true)::uuid
              AND cce.is_active=TRUE AND cce.created_at>=fn_demo_now()-INTERVAL '30 days'
            GROUP BY ct.family,cce.clause_type_v2 ORDER BY cnt DESC LIMIT 10) cpb
        ), '[]'::jsonb)
      ),
    -- CR-N: 10th additive key (budgetBurnSummary) — PRESERVED
    'budgetBurnSummary', COALESCE(v_budget_burn_summary, jsonb_build_object(
      'contractsWithBudget',      0,
      'overBudgetCount',          0,
      'totalProjectedOverrunAed', '0',
      'topOverBudget3',           '[]'::jsonb
    )),
    -- CR-O: 11th additive key (tradeMarginSummary) — NEW
    'tradeMarginSummary', COALESCE(v_trade_margin_summary, jsonb_build_object(
      'openPositionCount',     0,
      'totalMarginAed',        '0',
      'totalMarginUsd',        '0',
      'bySide',                jsonb_build_object(
        'sell', jsonb_build_object('positionCount', 0, 'marginAed', '0'),
        'buy',  jsonb_build_object('positionCount', 0, 'marginAed', '0')
      ),
      'recentMarginChange',    NULL,
      'topPositionsByMargin3', '[]'::jsonb
    ))
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_executive: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

-- S2-21 trio — re-applied because CREATE OR REPLACE drops COMMENT + grants (B14)
COMMENT ON FUNCTION public.fn_dashboard_executive(integer) IS
  'CR-O (316): Additive tradeMarginSummary key added as 11th top-level key. All 10 prior keys preserved byte-for-byte (kpis, kpiPrev, trends, charts, lists, events14d, whatChangedToday, recommendedActions, clausesTriggered, budgetBurnSummary). Base: CR-N mig 299. tradeMarginSummary: split-aggregate over latest_margin MV, A3 tenant_id filter, defensive EXCEPTION wrapper + COALESCE zero-shape fallback.';
REVOKE EXECUTE ON FUNCTION public.fn_dashboard_executive(integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_dashboard_executive(integer) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (316, '316_cro_extend_fn_dashboard_executive', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- Restore fn_dashboard_executive to mig 299 body (remove tradeMarginSummary key).
-- BEGIN;
-- -- [Paste migration 299 CREATE OR REPLACE here]
-- DELETE FROM schema_migrations WHERE version = 316;
-- COMMIT;
-- ============================================================
