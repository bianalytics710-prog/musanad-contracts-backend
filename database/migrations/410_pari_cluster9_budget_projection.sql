-- Migration: 410_pari_cluster9_budget_projection.sql
-- Unit: Pari Procurement QA Phase 3.7 (2026-06-01) — Cluster 9 / P41 (+ unblocks P40 'Trending over' badge)
-- Closes:
--   P41 — fn_budget_burn_portfolio.projectedOverUnderAed was returning (actual - budget),
--         a snapshot variance, not a forward projection. The "Projected over/under" column
--         on Budget Burn therefore showed the same value as "Variance to date", and the
--         FE 3-state badge logic (which checks projectedAed > 0 for "Trending over") could
--         never fire for rows currently under budget — collapsing back to 2-state (On track /
--         Over budget) and hiding the demo's "trending toward breach" narrative (P40).
--
-- Strategy:
--   Replace the snapshot expression with a true year-end run-rate projection:
--     days_elapsed_in_fy = (today - Jan 1)
--     days_in_fy         = (Dec 31 - Jan 1) + 1
--     burn_rate_per_day  = actual / NULLIF(days_elapsed_in_fy, 0)
--     year_end_actual    = burn_rate_per_day * days_in_fy
--     projected_over_under = year_end_actual - budget
--
--   - varianceAed remains the snapshot value (drives "% consumed" + current-state badge)
--   - projectedOverUnderAed becomes the year-end projection (drives "Trending over" badge)
--   - Already-over-today rows naturally project even further over; both badges agree.
--   - Under-today rows with high burn rate project positive → "Trending over" badge fires.
--
-- Idempotent: CREATE OR REPLACE FUNCTION.

BEGIN;

CREATE OR REPLACE FUNCTION fn_budget_burn_portfolio(
  p_actor_id BIGINT,
  p_filters  JSONB DEFAULT '{}'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_fiscal_year        INTEGER;
  v_min_variance_pct   NUMERIC;
  v_cost_category      TEXT;
  v_page               INTEGER;
  v_limit              INTEGER;
  v_offset             INTEGER;
  v_total              INTEGER;
  v_data               JSONB;
  v_top_over_budget    JSONB;
  v_summary            JSONB;
  v_total_budget_aed   NUMERIC(18,2);
  v_total_actual_aed   NUMERIC(18,2);
  v_over_budget_count  INTEGER;
  v_proj_overrun       NUMERIC(18,2);
  v_trending_over_count INTEGER;
  -- Year-end projection helpers
  v_fy_start_date      DATE;
  v_fy_end_date        DATE;
  v_days_in_fy         INTEGER;
  v_days_elapsed       INTEGER;
BEGIN
  v_fiscal_year      := COALESCE((p_filters->>'fiscalYear')::INTEGER, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);
  v_min_variance_pct := (p_filters->>'minVariancePct')::NUMERIC;
  v_cost_category    := p_filters->>'costCategory';
  v_page             := GREATEST(COALESCE((p_filters->>'page')::INTEGER, 1), 1);
  v_limit            := LEAST(GREATEST(COALESCE((p_filters->>'limit')::INTEGER, 20), 1), 100);
  v_offset           := (v_page - 1) * v_limit;

  -- Projection window setup (P41)
  v_fy_start_date := make_date(v_fiscal_year, 1, 1);
  v_fy_end_date   := make_date(v_fiscal_year, 12, 31);
  v_days_in_fy    := (v_fy_end_date - v_fy_start_date) + 1;
  v_days_elapsed  := GREATEST((CURRENT_DATE - v_fy_start_date) + 1, 1);
  -- Guard: if today is before FY start, treat as full year ahead → no extrapolation
  IF v_days_elapsed > v_days_in_fy THEN v_days_elapsed := v_days_in_fy; END IF;

  WITH budget_by_contract AS (
    SELECT contract_id, SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget
    WHERE is_active = TRUE AND fiscal_year = v_fiscal_year
      AND (v_cost_category IS NULL OR cost_category = v_cost_category)
    GROUP BY contract_id
  ),
  actual_by_contract AS (
    SELECT contract_id, SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual
    WHERE is_active = TRUE AND fiscal_year = v_fiscal_year AND period_type = 'month'
      AND (v_cost_category IS NULL OR cost_category = v_cost_category)
    GROUP BY contract_id
  ),
  joined AS (
    SELECT bbc.contract_id, bbc.budget_aed,
           COALESCE(abc.actual_aed, 0) AS actual_aed,
           COALESCE(abc.actual_aed, 0) - bbc.budget_aed AS variance_aed,
           -- P41: year-end run-rate projection
           ROUND(
             (COALESCE(abc.actual_aed, 0) / v_days_elapsed::NUMERIC * v_days_in_fy) - bbc.budget_aed,
             2
           ) AS projected_over_under_aed,
           CASE WHEN bbc.budget_aed > 0
                THEN ROUND(((COALESCE(abc.actual_aed, 0) - bbc.budget_aed) / bbc.budget_aed * 100)::NUMERIC, 2)
                ELSE 0 END AS variance_pct,
           CASE WHEN bbc.budget_aed > 0
                THEN ROUND((COALESCE(abc.actual_aed, 0) / bbc.budget_aed * 100)::NUMERIC, 2)
                ELSE 0 END AS pct_consumed
    FROM budget_by_contract bbc LEFT JOIN actual_by_contract abc ON abc.contract_id = bbc.contract_id
    WHERE (v_min_variance_pct IS NULL OR
           CASE WHEN bbc.budget_aed > 0
                THEN ((COALESCE(abc.actual_aed, 0) - bbc.budget_aed) / bbc.budget_aed * 100) >= v_min_variance_pct
                ELSE FALSE END)
  ),
  contract_rows AS (
    SELECT j.*,
           c.contract_number, c.title_en, c.title_ar, c.counterparty_id,
           cp.name_en AS counterparty_name, cp.name_ar AS counterparty_name_ar
    FROM joined j
    JOIN contract c ON c.id = j.contract_id AND c.is_active = TRUE
    LEFT JOIN party cp ON cp.id = c.counterparty_id
  )
  SELECT
    COUNT(*)::INTEGER,
    COALESCE(SUM(budget_aed), 0)::NUMERIC(18,2),
    COALESCE(SUM(actual_aed), 0)::NUMERIC(18,2),
    COUNT(*) FILTER (WHERE actual_aed > budget_aed)::INTEGER,
    -- P41: summary "projected overrun" now sums year-end projected positive deltas
    COALESCE(SUM(GREATEST(projected_over_under_aed, 0)), 0)::NUMERIC(18,2),
    -- P40: number of rows trending over (currently under, projected over)
    COUNT(*) FILTER (WHERE actual_aed <= budget_aed AND projected_over_under_aed > 0)::INTEGER
  INTO v_total, v_total_budget_aed, v_total_actual_aed, v_over_budget_count, v_proj_overrun, v_trending_over_count
  FROM contract_rows;

  -- Paginated rows (use projected_over_under_aed in payload now)
  WITH budget_by_contract AS (
    SELECT contract_id, SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget
    WHERE is_active = TRUE AND fiscal_year = v_fiscal_year
      AND (v_cost_category IS NULL OR cost_category = v_cost_category)
    GROUP BY contract_id
  ),
  actual_by_contract AS (
    SELECT contract_id, SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual
    WHERE is_active = TRUE AND fiscal_year = v_fiscal_year AND period_type = 'month'
      AND (v_cost_category IS NULL OR cost_category = v_cost_category)
    GROUP BY contract_id
  ),
  joined AS (
    SELECT bbc.contract_id, bbc.budget_aed,
           COALESCE(abc.actual_aed, 0) AS actual_aed,
           COALESCE(abc.actual_aed, 0) - bbc.budget_aed AS variance_aed,
           ROUND(
             (COALESCE(abc.actual_aed, 0) / v_days_elapsed::NUMERIC * v_days_in_fy) - bbc.budget_aed,
             2
           ) AS projected_over_under_aed,
           CASE WHEN bbc.budget_aed > 0
                THEN ROUND(((COALESCE(abc.actual_aed, 0) - bbc.budget_aed) / bbc.budget_aed * 100)::NUMERIC, 2)
                ELSE 0 END AS variance_pct,
           CASE WHEN bbc.budget_aed > 0
                THEN ROUND((COALESCE(abc.actual_aed, 0) / bbc.budget_aed * 100)::NUMERIC, 2)
                ELSE 0 END AS pct_consumed
    FROM budget_by_contract bbc LEFT JOIN actual_by_contract abc ON abc.contract_id = bbc.contract_id
    WHERE (v_min_variance_pct IS NULL OR
           CASE WHEN bbc.budget_aed > 0
                THEN ((COALESCE(abc.actual_aed, 0) - bbc.budget_aed) / bbc.budget_aed * 100) >= v_min_variance_pct
                ELSE FALSE END)
  )
  SELECT COALESCE(jsonb_agg(row_data ORDER BY (row_data->>'variancePct')::NUMERIC DESC NULLS LAST), '[]'::jsonb)
  INTO v_data
  FROM (
    SELECT jsonb_build_object(
      'contractId',            j.contract_id,
      'contractNumber',        c.contract_number,
      'titleEn',               c.title_en,
      'titleAr',               c.title_ar,
      'counterpartyName',      cp.name_en,
      'counterpartyNameAr',    cp.name_ar,
      'budgetAed',             j.budget_aed::text,
      'actualAed',             j.actual_aed::text,
      'varianceAed',           j.variance_aed::text,
      'variancePct',           j.variance_pct,
      'pctConsumed',           j.pct_consumed,
      'projectedOverUnderAed', j.projected_over_under_aed::text,
      'varianceFlag',          (j.actual_aed > j.budget_aed)
    ) AS row_data
    FROM joined j
    JOIN contract c ON c.id = j.contract_id AND c.is_active = TRUE
    LEFT JOIN party cp ON cp.id = c.counterparty_id
    ORDER BY j.variance_pct DESC NULLS LAST
    LIMIT v_limit OFFSET v_offset
  ) sub;

  -- Top over-budget (also uses projection)
  WITH budget_by_contract AS (
    SELECT contract_id, SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget WHERE is_active = TRUE AND fiscal_year = v_fiscal_year
    GROUP BY contract_id
  ),
  actual_by_contract AS (
    SELECT contract_id, SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual WHERE is_active = TRUE AND fiscal_year = v_fiscal_year AND period_type = 'month'
    GROUP BY contract_id
  )
  SELECT COALESCE(jsonb_agg(row_data ORDER BY (row_data->>'variancePct')::NUMERIC DESC NULLS LAST), '[]'::jsonb)
  INTO v_top_over_budget
  FROM (
    SELECT jsonb_build_object(
      'contractId',            bbc.contract_id,
      'contractNumber',        c.contract_number,
      'titleEn',               c.title_en,
      'titleAr',               c.title_ar,
      'counterpartyName',      cp.name_en,
      'counterpartyNameAr',    cp.name_ar,
      'budgetAed',             bbc.budget_aed::text,
      'actualAed',             COALESCE(abc.actual_aed, 0)::text,
      'varianceAed',           (COALESCE(abc.actual_aed, 0) - bbc.budget_aed)::text,
      'variancePct',           CASE WHEN bbc.budget_aed > 0
                                    THEN ROUND(((COALESCE(abc.actual_aed, 0) - bbc.budget_aed) / bbc.budget_aed * 100)::NUMERIC, 2)
                                    ELSE 0 END,
      'pctConsumed',           CASE WHEN bbc.budget_aed > 0
                                    THEN ROUND((COALESCE(abc.actual_aed, 0) / bbc.budget_aed * 100)::NUMERIC, 2)
                                    ELSE 0 END,
      'projectedOverUnderAed', ROUND(
                                 (COALESCE(abc.actual_aed, 0) / v_days_elapsed::NUMERIC * v_days_in_fy) - bbc.budget_aed,
                                 2
                               )::text,
      'varianceFlag',          TRUE
    ) AS row_data
    FROM budget_by_contract bbc
    JOIN actual_by_contract abc ON abc.contract_id = bbc.contract_id
    JOIN contract c ON c.id = bbc.contract_id AND c.is_active = TRUE
    LEFT JOIN party cp ON cp.id = c.counterparty_id
    WHERE COALESCE(abc.actual_aed, 0) > bbc.budget_aed
    ORDER BY (COALESCE(abc.actual_aed, 0) - bbc.budget_aed) DESC
    LIMIT 10
  ) sub;

  RETURN jsonb_build_object(
    'summary',       jsonb_build_object(
                       'contractsWithBudget',       COALESCE(v_total, 0),
                       'totalBudgetAed',            COALESCE(v_total_budget_aed, 0)::text,
                       'totalActualAed',            COALESCE(v_total_actual_aed, 0)::text,
                       'totalVarianceAed',          (COALESCE(v_total_actual_aed, 0) - COALESCE(v_total_budget_aed, 0))::text,
                       'overBudgetContractCount',   COALESCE(v_over_budget_count, 0),
                       'totalProjectedOverrunAed',  COALESCE(v_proj_overrun, 0)::text,
                       -- P40: new summary field — count of "trending over by year-end" rows
                       'trendingOverContractCount', COALESCE(v_trending_over_count, 0)
                     ),
    'data',          v_data,
    'topOverBudget', v_top_over_budget,
    'pagination',    jsonb_build_object('page', v_page, 'limit', v_limit, 'total', v_total)
  );

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_budget_burn_portfolio: %', SQLERRM
    USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_budget_burn_portfolio(BIGINT, JSONB) IS
'Budget Burn portfolio rollup. v2 (mig 410): projectedOverUnderAed is now a true year-end run-rate
projection (= actual * (days_in_fy / days_elapsed) - budget). Adds summary.trendingOverContractCount
(rows currently under budget but projecting positive year-end overrun). Snapshot variance lives in
varianceAed; projection lives in projectedOverUnderAed. Unblocks the 3-state "Trending over" badge.';
REVOKE EXECUTE ON FUNCTION fn_budget_burn_portfolio(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_burn_portfolio(BIGINT, JSONB) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (410, '410_pari_cluster9_budget_projection', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK: restore fn body from mig 298 lines 997-1209; delete schema_migrations row 410.
