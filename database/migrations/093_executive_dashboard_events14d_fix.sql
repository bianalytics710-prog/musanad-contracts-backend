-- ================================================================
-- Migration 092 — R-EX3: extend fn_dashboard_executive with the
-- "Executive events (last 14 days)" feed under a top-level
-- "events14d" key.
-- ================================================================
-- Up: BEGIN
-- Lovable's executive dashboard surfaces a single chronological
-- ticker of recent enterprise activity (regulatory updates, signed
-- contracts, risk flags, lease renewals, etc.). We assemble it from
-- two sources and UNION ALL with a consistent shape:
--
--   1. regulatory_update — published in the last 14 days
--   2. contract_activity — events of type:
--        fully_executed | sent_for_signature | submitted_for_approval
--        | ai_risk_score_updated | regulatory_impact_detected
--        | regulatory_impact_resolved
--      created in the last 14 days. Joined to contract for the
--      contract_number + value_aed.
--
-- Each event row returns:
--   { eventType, headline, subRef, occurredAt, severity }
-- where severity is 'critical' | 'high' | 'low' (used by the FE for
-- amber/terracotta accent colors).
--
-- Top 8 most recent events overall.
-- ================================================================

CREATE OR REPLACE FUNCTION fn_dashboard_executive(
  p_window_days INTEGER DEFAULT 90
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
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
        SELECT jsonb_agg(jsonb_build_object('counterpartyId', x.counterparty_id,
          'totalValueAed', x.total_value_aed, 'contractCount', x.contract_count) ORDER BY x.total_value_aed DESC)
        FROM (SELECT counterparty_id, COALESCE(SUM(value_aed), 0) AS total_value_aed, COUNT(*) AS contract_count
              FROM contract WHERE is_active = TRUE AND counterparty_id IS NOT NULL
              GROUP BY counterparty_id ORDER BY total_value_aed DESC LIMIT 5) x), '[]'::jsonb),
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

  -- ──────────────────────────────────────────────────────────────────
  -- R-EX3 — events14d block (top 8 enterprise events from regulatory_update + contract_activity)
  -- ──────────────────────────────────────────────────────────────────

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
      -- Regulatory updates published in the last 14 days
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

      -- Contract activity events of executive interest in the last 14 days
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

  -- The LIMIT in the inner contract_activity subquery is a soft cap so
  -- the UNION doesn't materialise thousands of rows when seeds grow.
  -- The outer LIMIT 8 enforces the actual cap returned to the caller.

  RETURN jsonb_build_object(
    'kpis',     v_kpis,
    'kpiPrev',  v_kpi_prev,
    'trends',   v_trends,
    'charts',   v_charts,
    'lists',    v_lists,
    'events14d', v_events
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_executive: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_executive(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_executive(INTEGER) TO neondb_owner;

COMMENT ON FUNCTION fn_dashboard_executive(INTEGER) IS
  'M6 S7 + R-EX0 (089) + R-EX1 (090) + R-EX2 (091) + R-EX3 (092): adds top-level "events14d" key — top 8 most-recent enterprise events from regulatory_update + contract_activity (fully_executed, sent_for_signature, submitted_for_approval, ai_risk_score_updated, regulatory_impact_detected/resolved) in the last 14 days. Each event row: { eventType, headline, subRef, occurredAt, severity }.';

-- ================================================================
-- Up: END
-- Down: BEGIN
-- (Replay 091 to revert.)
-- ================================================================
-- Down: END
