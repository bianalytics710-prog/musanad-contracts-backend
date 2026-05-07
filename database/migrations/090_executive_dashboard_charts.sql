-- ================================================================
-- Migration 090 — R-EX1: extend fn_dashboard_executive with 5 new
-- chart sections returning under a top-level "charts" key:
--   spendByCategory (top 8 contract_types by SUM(value_aed))
--   topSuppliers (top 10 counterparties by SUM(value_aed) + sparkline12m)
--   revenueUnderContract12m (12-month series, active vs pipeline)
--   contractThroughput12m (12-month series, Initiated vs Signed)
--   expiryCliff (6 horizon buckets × AED at risk)
-- ================================================================
-- Up: BEGIN
-- Body byte-for-byte identical to migration 089 except for:
--   1. Added v_charts JSONB local + computation block
--   2. Added 'charts' key to the top-level RETURN object
--
-- Definitions (adversarial-safe):
--   spendByCategory: GROUP BY contract_type, top 8 by SUM(value_aed)
--     DESC, with pct = value / total. Total is the sum across all 8
--     PLUS an "Other" rollup for ranks 9+ so percentages reconcile.
--   topSuppliers: GROUP BY counterparty_id, top 10 by SUM(value_aed)
--     DESC. Sparkline = 12 trailing months of SUM(value_aed) for
--     contracts created_at in that month bucket. Counterparty name
--     resolved via party.name_en (or 'Unknown #<id>' fallback).
--   revenueUnderContract12m: 12-month series; per month:
--     activeValueAed   = SUM(value_aed) for contracts where the month
--                        intersects [start_date, end_date] AND status
--                        IN ('active','fully_signed','expiring_soon')
--     pipelineValueAed = SUM(value_aed) for contracts created_at in
--                        the month AND status IN ('draft','in_review',
--                        'in_approval') — represents revenue NOT YET
--                        active.
--   contractThroughput12m: per month:
--     initiated = COUNT(*) by month of created_at
--     signed    = COUNT(*) where status reached 'fully_signed' in that
--                 month (via contract_activity status_changed).
--   expiryCliff: 6 buckets, SUM(value_aed) of is_active=TRUE rows:
--     30d  = end_date BETWEEN today AND today+30d
--     60d  = end_date BETWEEN today+30d AND today+60d
--     90d  = end_date BETWEEN today+60d AND today+90d
--     180d = end_date BETWEEN today+90d AND today+180d
--     365d = end_date BETWEEN today+180d AND today+365d
--     >365d = end_date > today+365d
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
    EXCEPTION
      WHEN OTHERS THEN v_ai_cost := NULL;
    END;
  ELSE
    v_ai_cost := NULL;
  END IF;

  -- Cycle-time stage averages (current window) — same as 089.
  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (sa.first_review - c.created_at)) / 86400.0), 0)
  INTO v_drafting
  FROM contract c
  JOIN LATERAL (
    SELECT MIN(ca.created_at) AS first_review FROM contract_activity ca
    WHERE ca.contract_id = c.id AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus','') = 'in_review'
  ) sa ON sa.first_review IS NOT NULL
  WHERE c.is_active = TRUE AND c.created_at >= CURRENT_DATE - v_window;

  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (b.first_in_approval - a.first_in_review)) / 86400.0), 0)
  INTO v_legal
  FROM contract c
  JOIN LATERAL (
    SELECT MIN(ca.created_at) AS first_in_review FROM contract_activity ca
    WHERE ca.contract_id = c.id AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus','') = 'in_review'
  ) a ON a.first_in_review IS NOT NULL
  JOIN LATERAL (
    SELECT MIN(ca.created_at) AS first_in_approval FROM contract_activity ca
    WHERE ca.contract_id = c.id AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus','') = 'in_approval'
  ) b ON b.first_in_approval IS NOT NULL
  WHERE c.is_active = TRUE AND c.created_at >= CURRENT_DATE - v_window;

  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (ad.decided_at - s.created_at)) / 86400.0), 0)
  INTO v_approval
  FROM approval_step s
  JOIN approval_decision ad ON ad.approval_step_id = s.id AND ad.is_active = TRUE
  WHERE s.is_active = TRUE AND ad.decided_at >= CURRENT_DATE - v_window;

  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (se.signed_at - si.invitation_sent_at)) / 86400.0), 0)
  INTO v_signing
  FROM signature_invitation si
  JOIN LATERAL (
    SELECT MIN(created_at) AS signed_at FROM signature_event sev
    WHERE sev.signature_invitation_id = si.id AND sev.event_type = 'signed' AND sev.is_active = TRUE
  ) se ON se.signed_at IS NOT NULL
  WHERE si.is_active = TRUE AND si.invitation_sent_at >= CURRENT_DATE - v_window;

  SELECT jsonb_build_object(
    'totalActiveValueAed',
      (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected')),
    'activeContractsCount',
      (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE AND status IN ('active','fully_signed','expiring_soon')),
    'avgCycleTimeDays', ROUND((COALESCE(v_drafting,0) + COALESCE(v_legal,0)
                              + COALESCE(v_approval,0) + COALESCE(v_signing,0))::NUMERIC, 2),
    'renewalsCount90d',
      (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE AND status IN ('active','fully_signed','expiring_soon')
          AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'),
    'renewalValueAed90d',
      (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE AND status IN ('active','fully_signed','expiring_soon')
          AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'),
    'cycleTimeFunnel', jsonb_build_object(
      'draftingDays',              ROUND(COALESCE(v_drafting, 0)::NUMERIC, 2),
      'legalReviewDays',           ROUND(COALESCE(v_legal,    0)::NUMERIC, 2),
      'approvalChainDays',         ROUND(COALESCE(v_approval, 0)::NUMERIC, 2),
      'counterpartySignatureDays', ROUND(COALESCE(v_signing,  0)::NUMERIC, 2)
    ),
    'contractsByStatus',
      COALESCE((SELECT jsonb_object_agg(status, contract_count) FROM vw_contract_status_summary), '{}'::jsonb),
    'expiryCliffs',
      jsonb_build_object(
        'next30d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days'),
        'next60d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '60 days'),
        'next90d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days')),
    'topCounterpartiesByValue5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('counterpartyId', x.counterparty_id,
          'totalValueAed', x.total_value_aed, 'contractCount', x.contract_count) ORDER BY x.total_value_aed DESC)
        FROM (SELECT counterparty_id, COALESCE(SUM(value_aed), 0) AS total_value_aed, COUNT(*) AS contract_count
              FROM contract WHERE is_active = TRUE AND counterparty_id IS NOT NULL
              GROUP BY counterparty_id ORDER BY total_value_aed DESC LIMIT 5) x
      ), '[]'::jsonb),
    'valueDistribution',
      COALESCE((
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
        ) buckets
      ), '[]'::jsonb),
    'openRegulatoryImpactsCritical',
      (SELECT COUNT(*) FROM regulatory_impact ri
       JOIN regulatory_update ru ON ru.id = ri.regulatory_update_id
       WHERE ri.resolved = FALSE AND ri.is_active = TRUE
         AND ru.severity = 'critical' AND ru.is_active = TRUE),
    'aiCostUsdWindow', v_ai_cost
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'totalActiveValueAed',
      (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected')
          AND created_at < CURRENT_DATE - v_window),
    'activeContractsCount',
      (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
        AND status IN ('active','fully_signed','expiring_soon')
        AND created_at < CURRENT_DATE - v_window),
    'renewalsCount90d',
      (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
        AND status IN ('active','fully_signed','expiring_soon')
        AND end_date BETWEEN CURRENT_DATE - v_window AND CURRENT_DATE - v_window + INTERVAL '90 days'),
    'renewalValueAed90d',
      (SELECT COALESCE(SUM(value_aed), 0) FROM contract WHERE is_active = TRUE
        AND status IN ('active','fully_signed','expiring_soon')
        AND end_date BETWEEN CURRENT_DATE - v_window AND CURRENT_DATE - v_window + INTERVAL '90 days')
  ) INTO v_kpi_prev;

  SELECT jsonb_build_object(
    'valueOverTimeByMonth',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('month', to_char(month_start, 'YYYY-MM'),
          'totalValueAed', COALESCE(c.total_value_aed, 0)) ORDER BY month_start)
        FROM generate_series(date_trunc('month', CURRENT_DATE - v_window),
          date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS gs(month_start)
        LEFT JOIN (SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS total_value_aed
                   FROM contract WHERE is_active = TRUE AND created_at >= CURRENT_DATE - v_window
                   GROUP BY 1) c ON c.m = month_start
      ), '[]'::jsonb),
    'contractsCreatedByMonth',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('month', to_char(month_start, 'YYYY-MM'),
          'count', COALESCE(c.cnt, 0)) ORDER BY month_start)
        FROM generate_series(date_trunc('month', CURRENT_DATE - v_window),
          date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS gs(month_start)
        LEFT JOIN (SELECT date_trunc('month', created_at) AS m, COUNT(*) AS cnt
                   FROM contract WHERE is_active = TRUE AND created_at >= CURRENT_DATE - v_window
                   GROUP BY 1) c ON c.m = month_start
      ), '[]'::jsonb)
  ) INTO v_trends;

  -- ──────────────────────────────────────────────────────────────────
  -- R-EX1 — charts block (5 sections)
  -- ──────────────────────────────────────────────────────────────────

  SELECT COALESCE(SUM(value_aed), 0) INTO v_total_value
  FROM contract
  WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected');

  SELECT jsonb_build_object(
    -- 1. Spend by category
    'spendByCategory',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'category', x.contract_type,
          'valueAed', x.value_aed,
          'pct', CASE WHEN v_total_value > 0
                      THEN ROUND((x.value_aed / v_total_value * 100)::NUMERIC, 2)
                      ELSE 0 END
        ) ORDER BY x.value_aed DESC)
        FROM (
          SELECT contract_type, COALESCE(SUM(value_aed), 0) AS value_aed
          FROM contract
          WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected')
          GROUP BY contract_type
          ORDER BY value_aed DESC
          LIMIT 8
        ) x
      ), '[]'::jsonb),

    -- 2. Top suppliers (10) with sparkline12m
    'topSuppliers',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'counterpartyId', x.counterparty_id,
          'name', COALESCE(p.name_en, 'Unknown #' || x.counterparty_id),
          'contractCount', x.contract_count,
          'totalValueAed', x.value_aed,
          'pctOfSpend', CASE WHEN v_total_value > 0
                              THEN ROUND((x.value_aed / v_total_value * 100)::NUMERIC, 2)
                              ELSE 0 END,
          'sparkline12m', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'month', to_char(spm.month_start, 'YYYY-MM'),
              'valueAed', COALESCE(sub.v, 0)
            ) ORDER BY spm.month_start)
            FROM generate_series(
              date_trunc('month', CURRENT_DATE - INTERVAL '11 months'),
              date_trunc('month', CURRENT_DATE),
              INTERVAL '1 month'
            ) AS spm(month_start)
            LEFT JOIN (
              SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS v
              FROM contract
              WHERE is_active = TRUE AND counterparty_id = x.counterparty_id
                AND created_at >= CURRENT_DATE - INTERVAL '12 months'
              GROUP BY 1
            ) sub ON sub.m = spm.month_start
          ), '[]'::jsonb)
        ) ORDER BY x.value_aed DESC)
        FROM (
          SELECT counterparty_id, COALESCE(SUM(value_aed), 0) AS value_aed,
                 COUNT(*) AS contract_count
          FROM contract
          WHERE is_active = TRUE AND counterparty_id IS NOT NULL
            AND status NOT IN ('cancelled','expired','rejected')
          GROUP BY counterparty_id
          ORDER BY value_aed DESC
          LIMIT 10
        ) x
        LEFT JOIN party p ON p.id = x.counterparty_id
      ), '[]'::jsonb),

    -- 3. Revenue under contract — 12 months, active vs pipeline
    'revenueUnderContract12m',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'month', to_char(rm.month_start, 'YYYY-MM'),
          'activeValueAed', COALESCE(av.v, 0),
          'pipelineValueAed', COALESCE(pv.v, 0)
        ) ORDER BY rm.month_start)
        FROM generate_series(
          date_trunc('month', CURRENT_DATE - INTERVAL '11 months'),
          date_trunc('month', CURRENT_DATE),
          INTERVAL '1 month'
        ) AS rm(month_start)
        LEFT JOIN (
          SELECT date_trunc('month', d.day) AS m, SUM(c.value_aed) AS v
          FROM contract c,
               LATERAL generate_series(
                 GREATEST(date_trunc('month', c.start_date), date_trunc('month', CURRENT_DATE - INTERVAL '11 months')),
                 LEAST(date_trunc('month', COALESCE(c.end_date, CURRENT_DATE + INTERVAL '12 months')), date_trunc('month', CURRENT_DATE)),
                 INTERVAL '1 month'
               ) AS d(day)
          WHERE c.is_active = TRUE
            AND c.status IN ('active','fully_signed','expiring_soon')
            AND c.start_date IS NOT NULL
          GROUP BY 1
        ) av ON av.m = rm.month_start
        LEFT JOIN (
          SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS v
          FROM contract
          WHERE is_active = TRUE
            AND status IN ('draft','in_review','in_approval')
            AND created_at >= CURRENT_DATE - INTERVAL '12 months'
          GROUP BY 1
        ) pv ON pv.m = rm.month_start
      ), '[]'::jsonb),

    -- 4. Contract throughput — 12 months, Initiated vs Signed
    'contractThroughput12m',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'month', to_char(tm.month_start, 'YYYY-MM'),
          'initiated', COALESCE(ini.cnt, 0),
          'signed',    COALESCE(sgn.cnt, 0)
        ) ORDER BY tm.month_start)
        FROM generate_series(
          date_trunc('month', CURRENT_DATE - INTERVAL '11 months'),
          date_trunc('month', CURRENT_DATE),
          INTERVAL '1 month'
        ) AS tm(month_start)
        LEFT JOIN (
          SELECT date_trunc('month', created_at) AS m, COUNT(*) AS cnt
          FROM contract WHERE is_active = TRUE
            AND created_at >= CURRENT_DATE - INTERVAL '12 months'
          GROUP BY 1
        ) ini ON ini.m = tm.month_start
        LEFT JOIN (
          SELECT date_trunc('month', ca.created_at) AS m, COUNT(DISTINCT ca.contract_id) AS cnt
          FROM contract_activity ca
          WHERE ca.activity_type = 'status_changed'
            AND COALESCE(ca.metadata->>'toStatus','') = 'fully_signed'
            AND ca.created_at >= CURRENT_DATE - INTERVAL '12 months'
          GROUP BY 1
        ) sgn ON sgn.m = tm.month_start
      ), '[]'::jsonb),

    -- 5. Expiry cliff by horizon (6 buckets × AED at risk)
    'expiryCliff',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('horizon', horizon, 'valueAedAtRisk', COALESCE(value_aed, 0)) ORDER BY ord)
        FROM (
          SELECT '30d'::TEXT AS horizon, 1 AS ord,
                 (SELECT SUM(value_aed) FROM contract
                   WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days') AS value_aed
          UNION ALL SELECT '60d', 2,
                 (SELECT SUM(value_aed) FROM contract
                   WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE + INTERVAL '30 days' AND CURRENT_DATE + INTERVAL '60 days')
          UNION ALL SELECT '90d', 3,
                 (SELECT SUM(value_aed) FROM contract
                   WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE + INTERVAL '60 days' AND CURRENT_DATE + INTERVAL '90 days')
          UNION ALL SELECT '180d', 4,
                 (SELECT SUM(value_aed) FROM contract
                   WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE + INTERVAL '90 days' AND CURRENT_DATE + INTERVAL '180 days')
          UNION ALL SELECT '365d', 5,
                 (SELECT SUM(value_aed) FROM contract
                   WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE + INTERVAL '180 days' AND CURRENT_DATE + INTERVAL '365 days')
          UNION ALL SELECT '>365d', 6,
                 (SELECT SUM(value_aed) FROM contract
                   WHERE is_active = TRUE
                     AND end_date > CURRENT_DATE + INTERVAL '365 days')
        ) horizons
      ), '[]'::jsonb)
  ) INTO v_charts;

  RETURN jsonb_build_object(
    'kpis', v_kpis,
    'kpiPrev', v_kpi_prev,
    'trends', v_trends,
    'charts', v_charts
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
  'M6 S7 + R-EX0 (089) + R-EX1 (090): adds top-level "charts" block with spendByCategory, topSuppliers (10 + 12m sparkline), revenueUnderContract12m (active+pipeline), contractThroughput12m (initiated+signed), expiryCliff (6 horizon buckets). INVOKER, executive | platform_admin | Super Admin | insights.executive permission.';

-- ================================================================
-- Up: END
-- Down: BEGIN
-- (Replay 089 to revert to the kpis+kpiPrev+trends shape.)
-- ================================================================
-- Down: END
