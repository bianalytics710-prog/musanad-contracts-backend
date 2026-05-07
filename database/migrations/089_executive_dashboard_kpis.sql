-- ================================================================
-- Migration 089 — R-EX0: extend fn_dashboard_executive with the 4
-- missing KPIs (activeContractsCount, avgCycleTimeDays,
-- renewalsCount90d, renewalValueAed90d) and a kpiPrev block for
-- delta indicators. M6's S7 baseline returned 4 KPIs; Lovable shows 5
-- with deltas. This migration brings the BE shape up to the Lovable
-- executive parity.
-- ================================================================
-- Up: BEGIN
-- Body otherwise byte-for-byte identical to migration 056. Same
-- 1-arg signature; same role gate; same value distribution + status
-- summary + counterparties projection. Only additions:
--   - 4 new KPIs computed in v_kpis: activeContractsCount,
--     avgCycleTimeDays, renewalsCount90d, renewalValueAed90d.
--   - kpiPrev block computed against the prior window (last
--     v_window..2*v_window days ago) for delta arithmetic on
--     totalActiveValueAed, activeContractsCount, avgCycleTimeDays,
--     renewalsCount90d, renewalValueAed90d.
--
-- Adversarial:
--   - "Renewals" is defined as contracts with status IN
--     ('active','expiring_soon','fully_signed') AND end_date BETWEEN
--     CURRENT_DATE and CURRENT_DATE + INTERVAL '90 days'. The 90d
--     window is fixed (matches Lovable's "Renewals (90d)" label).
--   - "avgCycleTimeDays" sums the 4 stage averages: drafting
--     (created_at -> first activity status_changed to in_review),
--     legal_review (in_review -> in_approval), approval_chain
--     (approval_step.created_at -> approval_decision.decided_at),
--     counterparty_signature (signature_invitation.invitation_sent_at
--     -> signature_event 'signed'). Falls back to 0 per stage if no
--     data.
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
  v_kpi_prev    JSONB;
  -- Cycle-time computation accumulators
  v_drafting    NUMERIC;
  v_legal       NUMERIC;
  v_approval    NUMERIC;
  v_signing     NUMERIC;
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

  -- AI cost panel — only if caller has ai.observability.read; capped at 90 days
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
      WHEN OTHERS THEN
        v_ai_cost := NULL;
    END;
  ELSE
    v_ai_cost := NULL;
  END IF;

  -- Cycle-time stage averages (current window).
  -- Drafting: contract.created_at -> first contract_activity row with
  --   activity_type = 'status_changed' moving FROM 'draft' TO 'in_review'.
  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (sa.first_review - c.created_at)) / 86400.0), 0)
  INTO v_drafting
  FROM contract c
  JOIN LATERAL (
    SELECT MIN(ca.created_at) AS first_review
    FROM contract_activity ca
    WHERE ca.contract_id = c.id
      AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus', '') = 'in_review'
  ) sa ON sa.first_review IS NOT NULL
  WHERE c.is_active = TRUE
    AND c.created_at >= CURRENT_DATE - v_window;

  -- Legal review: in_review -> in_approval transition.
  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (b.first_in_approval - a.first_in_review)) / 86400.0), 0)
  INTO v_legal
  FROM contract c
  JOIN LATERAL (
    SELECT MIN(ca.created_at) AS first_in_review
    FROM contract_activity ca
    WHERE ca.contract_id = c.id
      AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus', '') = 'in_review'
  ) a ON a.first_in_review IS NOT NULL
  JOIN LATERAL (
    SELECT MIN(ca.created_at) AS first_in_approval
    FROM contract_activity ca
    WHERE ca.contract_id = c.id
      AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus', '') = 'in_approval'
  ) b ON b.first_in_approval IS NOT NULL
  WHERE c.is_active = TRUE
    AND c.created_at >= CURRENT_DATE - v_window;

  -- Approval chain: approval_step.created_at -> approval_decision.decided_at.
  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (ad.decided_at - s.created_at)) / 86400.0), 0)
  INTO v_approval
  FROM approval_step s
  JOIN approval_decision ad ON ad.approval_step_id = s.id AND ad.is_active = TRUE
  WHERE s.is_active = TRUE
    AND ad.decided_at >= CURRENT_DATE - v_window;

  -- Counterparty signature: invitation_sent_at -> first 'signed' event.
  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (se.signed_at - si.invitation_sent_at)) / 86400.0), 0)
  INTO v_signing
  FROM signature_invitation si
  JOIN LATERAL (
    SELECT MIN(created_at) AS signed_at
    FROM signature_event sev
    WHERE sev.signature_invitation_id = si.id
      AND sev.event_type = 'signed'
      AND sev.is_active = TRUE
  ) se ON se.signed_at IS NOT NULL
  WHERE si.is_active = TRUE
    AND si.invitation_sent_at >= CURRENT_DATE - v_window;

  SELECT jsonb_build_object(
    'totalActiveValueAed',
      (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE
          AND status NOT IN ('cancelled','expired','rejected')),
    'activeContractsCount',
      (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE
          AND status IN ('active','fully_signed','expiring_soon')),
    'avgCycleTimeDays', ROUND((COALESCE(v_drafting,0) + COALESCE(v_legal,0)
                              + COALESCE(v_approval,0) + COALESCE(v_signing,0))::NUMERIC, 2),
    'renewalsCount90d',
      (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE
          AND status IN ('active','fully_signed','expiring_soon')
          AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'),
    'renewalValueAed90d',
      (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE
          AND status IN ('active','fully_signed','expiring_soon')
          AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'),
    'cycleTimeFunnel', jsonb_build_object(
      'draftingDays',                ROUND(COALESCE(v_drafting, 0)::NUMERIC, 2),
      'legalReviewDays',             ROUND(COALESCE(v_legal,    0)::NUMERIC, 2),
      'approvalChainDays',           ROUND(COALESCE(v_approval, 0)::NUMERIC, 2),
      'counterpartySignatureDays',   ROUND(COALESCE(v_signing,  0)::NUMERIC, 2)
    ),
    'contractsByStatus',
      COALESCE((
        SELECT jsonb_object_agg(status, contract_count)
        FROM vw_contract_status_summary
      ), '{}'::jsonb),
    'expiryCliffs',
      jsonb_build_object(
        'next30d', (SELECT COUNT(*) FROM contract
                     WHERE is_active = TRUE
                       AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days'),
        'next60d', (SELECT COUNT(*) FROM contract
                     WHERE is_active = TRUE
                       AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '60 days'),
        'next90d', (SELECT COUNT(*) FROM contract
                     WHERE is_active = TRUE
                       AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days')
      ),
    'topCounterpartiesByValue5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'counterpartyId', x.counterparty_id,
          'totalValueAed', x.total_value_aed,
          'contractCount', x.contract_count
        ) ORDER BY x.total_value_aed DESC)
        FROM (
          SELECT counterparty_id,
                 COALESCE(SUM(value_aed), 0) AS total_value_aed,
                 COUNT(*) AS contract_count
          FROM contract
          WHERE is_active = TRUE AND counterparty_id IS NOT NULL
          GROUP BY counterparty_id
          ORDER BY total_value_aed DESC
          LIMIT 5
        ) x
      ), '[]'::jsonb),
    'valueDistribution',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('bucket', bucket, 'count', cnt) ORDER BY ord)
        FROM (
          SELECT '<100k'::TEXT AS bucket, 1 AS ord,
                 (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND COALESCE(value_aed, 0) < 100000) AS cnt
          UNION ALL
          SELECT '100k-1M', 2,
                 (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND value_aed >= 100000 AND value_aed < 1000000)
          UNION ALL
          SELECT '1M-10M', 3,
                 (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND value_aed >= 1000000 AND value_aed < 10000000)
          UNION ALL
          SELECT '10M+', 4,
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

  -- Previous-window KPIs for delta arithmetic. Same definitions as
  -- above but offset by v_window (i.e. v_window..2*v_window ago).
  SELECT jsonb_build_object(
    'totalActiveValueAed',
      (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE
          AND status NOT IN ('cancelled','expired','rejected')
          AND created_at < CURRENT_DATE - v_window),
    'activeContractsCount',
      (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE
          AND status IN ('active','fully_signed','expiring_soon')
          AND created_at < CURRENT_DATE - v_window),
    'renewalsCount90d',
      (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE
          AND status IN ('active','fully_signed','expiring_soon')
          AND end_date BETWEEN CURRENT_DATE - v_window AND CURRENT_DATE - v_window + INTERVAL '90 days'),
    'renewalValueAed90d',
      (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE
          AND status IN ('active','fully_signed','expiring_soon')
          AND end_date BETWEEN CURRENT_DATE - v_window AND CURRENT_DATE - v_window + INTERVAL '90 days')
  ) INTO v_kpi_prev;

  SELECT jsonb_build_object(
    'valueOverTimeByMonth',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'month', to_char(month_start, 'YYYY-MM'),
          'totalValueAed', COALESCE(c.total_value_aed, 0)
        ) ORDER BY month_start)
        FROM generate_series(
          date_trunc('month', CURRENT_DATE - v_window),
          date_trunc('month', CURRENT_DATE),
          INTERVAL '1 month'
        ) AS gs(month_start)
        LEFT JOIN (
          SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS total_value_aed
          FROM contract
          WHERE is_active = TRUE
            AND created_at >= CURRENT_DATE - v_window
          GROUP BY 1
        ) c ON c.m = month_start
      ), '[]'::jsonb),
    'contractsCreatedByMonth',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'month', to_char(month_start, 'YYYY-MM'),
          'count', COALESCE(c.cnt, 0)
        ) ORDER BY month_start)
        FROM generate_series(
          date_trunc('month', CURRENT_DATE - v_window),
          date_trunc('month', CURRENT_DATE),
          INTERVAL '1 month'
        ) AS gs(month_start)
        LEFT JOIN (
          SELECT date_trunc('month', created_at) AS m, COUNT(*) AS cnt
          FROM contract
          WHERE is_active = TRUE
            AND created_at >= CURRENT_DATE - v_window
          GROUP BY 1
        ) c ON c.m = month_start
      ), '[]'::jsonb)
  ) INTO v_trends;

  RETURN jsonb_build_object(
    'kpis', v_kpis,
    'kpiPrev', v_kpi_prev,
    'trends', v_trends
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
  'M6 S7 + R-EX0: extended with 4 new KPIs (activeContractsCount, avgCycleTimeDays, renewalsCount90d, renewalValueAed90d) + cycleTimeFunnel object (4 stages) + kpiPrev block for delta indicators. INVOKER (CRIT-3 lock preserved). Permission gate: executive | platform_admin | Super Admin | insights.executive.';

-- ================================================================
-- Up: END
-- Down: BEGIN
-- (Replay 056 to revert to the M6 baseline shape.)
-- ================================================================
-- Down: END
