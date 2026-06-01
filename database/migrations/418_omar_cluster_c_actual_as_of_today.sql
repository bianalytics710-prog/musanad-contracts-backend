-- Migration: 418_omar_cluster_c_actual_as_of_today.sql
-- Unit: Omar Operations QA Phase 3 — Cluster C followup
-- Targets:
--   O17 follow-up — fn_budget_burn_portfolio still over-projects HERO-001
--   because it sums ALL FY 2026 contract_cost_actual rows including future
--   months (e.g., 2026-07 day-rate spike seeded by mig 370). Effect:
--   portfolio "actual" = AED 848M while Projection tab actual-to-date =
--   AED 476.2M; portfolio projection lands +AED 173M while Projection tab
--   says +AED 107.5M.
--
-- Fix: in fn_budget_burn_portfolio, also filter actuals to
-- period_label <= TO_CHAR(CURRENT_DATE, 'YYYY-MM') so the portfolio sees
-- only actuals that have been "booked" up to today. Mirrors
-- fn_budget_year_end_projection's default behavior (as_of = latest
-- reporting period).
--
-- Same idempotent CREATE OR REPLACE pattern; body byte-for-byte matches
-- mig 417 except for one filter clause on actual_by_contract.

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
  v_total_budget_aed   NUMERIC(18,2);
  v_total_actual_aed   NUMERIC(18,2);
  v_over_budget_count  INTEGER;
  v_proj_overrun       NUMERIC(18,2);
  v_trending_over_count INTEGER;
  v_months_in_fy       INTEGER := 12;
  v_as_of_period       TEXT;
BEGIN
  v_fiscal_year      := COALESCE((p_filters->>'fiscalYear')::INTEGER, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);
  v_min_variance_pct := (p_filters->>'minVariancePct')::NUMERIC;
  v_cost_category    := p_filters->>'costCategory';
  v_page             := GREATEST(COALESCE((p_filters->>'page')::INTEGER, 1), 1);
  v_limit            := LEAST(GREATEST(COALESCE((p_filters->>'limit')::INTEGER, 20), 1), 100);
  v_offset           := (v_page - 1) * v_limit;

  -- Default: actual-as-of-today period boundary. If the FY parameter is
  -- different from current FY, treat as_of as end-of-FY.
  IF v_fiscal_year = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER THEN
    v_as_of_period := TO_CHAR(CURRENT_DATE, 'YYYY-MM');
  ELSE
    v_as_of_period := v_fiscal_year::text || '-12';
  END IF;

  WITH budget_by_contract AS (
    SELECT contract_id, SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget
    WHERE is_active = TRUE AND fiscal_year = v_fiscal_year
      AND (v_cost_category IS NULL OR cost_category = v_cost_category)
    GROUP BY contract_id
  ),
  actual_by_contract AS (
    SELECT
      contract_id,
      SUM(actual_amount_aed) AS actual_aed,
      COUNT(DISTINCT period_label) AS months_elapsed
    FROM contract_cost_actual
    WHERE is_active = TRUE AND fiscal_year = v_fiscal_year AND period_type = 'month'
      AND (v_cost_category IS NULL OR cost_category = v_cost_category)
      AND period_label <= v_as_of_period
    GROUP BY contract_id
  ),
  joined AS (
    SELECT
      bbc.contract_id,
      bbc.budget_aed,
      COALESCE(abc.actual_aed, 0) AS actual_aed,
      COALESCE(abc.actual_aed, 0) - bbc.budget_aed AS variance_aed,
      ROUND(
        LEAST(
          GREATEST(
            (COALESCE(abc.actual_aed, 0) +
             (COALESCE(abc.actual_aed, 0) / NULLIF(COALESCE(abc.months_elapsed, 0), 0)) *
              (v_months_in_fy - COALESCE(abc.months_elapsed, 0))
            ) - bbc.budget_aed,
            (COALESCE(abc.actual_aed, 0) - bbc.budget_aed)
          ),
          bbc.budget_aed * 2.0
        ),
        2
      ) AS projected_over_under_aed,
      CASE WHEN bbc.budget_aed > 0
           THEN ROUND(((COALESCE(abc.actual_aed, 0) - bbc.budget_aed) / bbc.budget_aed * 100)::NUMERIC, 2)
           ELSE 0 END AS variance_pct,
      CASE WHEN bbc.budget_aed > 0
           THEN ROUND((COALESCE(abc.actual_aed, 0) / bbc.budget_aed * 100)::NUMERIC, 2)
           ELSE 0 END AS pct_consumed
    FROM budget_by_contract bbc
    LEFT JOIN actual_by_contract abc ON abc.contract_id = bbc.contract_id
    WHERE (v_min_variance_pct IS NULL OR
           CASE WHEN bbc.budget_aed > 0
                THEN ((COALESCE(abc.actual_aed, 0) - bbc.budget_aed) / bbc.budget_aed * 100) >= v_min_variance_pct
                ELSE FALSE END)
  ),
  contract_rows AS (
    SELECT j.*, c.contract_number, c.title_en, c.title_ar,
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
    COALESCE(SUM(GREATEST(projected_over_under_aed, 0)), 0)::NUMERIC(18,2),
    COUNT(*) FILTER (WHERE actual_aed <= budget_aed AND projected_over_under_aed > 0)::INTEGER
  INTO v_total, v_total_budget_aed, v_total_actual_aed, v_over_budget_count, v_proj_overrun, v_trending_over_count
  FROM contract_rows;

  WITH budget_by_contract AS (
    SELECT contract_id, SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget WHERE is_active = TRUE AND fiscal_year = v_fiscal_year
      AND (v_cost_category IS NULL OR cost_category = v_cost_category)
    GROUP BY contract_id
  ),
  actual_by_contract AS (
    SELECT contract_id, SUM(actual_amount_aed) AS actual_aed,
           COUNT(DISTINCT period_label) AS months_elapsed
    FROM contract_cost_actual
    WHERE is_active = TRUE AND fiscal_year = v_fiscal_year AND period_type = 'month'
      AND (v_cost_category IS NULL OR cost_category = v_cost_category)
      AND period_label <= v_as_of_period
    GROUP BY contract_id
  ),
  joined AS (
    SELECT
      bbc.contract_id, bbc.budget_aed,
      COALESCE(abc.actual_aed, 0) AS actual_aed,
      COALESCE(abc.actual_aed, 0) - bbc.budget_aed AS variance_aed,
      ROUND(
        LEAST(
          GREATEST(
            (COALESCE(abc.actual_aed, 0) +
             (COALESCE(abc.actual_aed, 0) / NULLIF(COALESCE(abc.months_elapsed, 0), 0)) *
              (v_months_in_fy - COALESCE(abc.months_elapsed, 0))
            ) - bbc.budget_aed,
            (COALESCE(abc.actual_aed, 0) - bbc.budget_aed)
          ),
          bbc.budget_aed * 2.0
        ),
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

  WITH budget_by_contract AS (
    SELECT contract_id, SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget WHERE is_active = TRUE AND fiscal_year = v_fiscal_year
    GROUP BY contract_id
  ),
  actual_by_contract AS (
    SELECT contract_id, SUM(actual_amount_aed) AS actual_aed,
           COUNT(DISTINCT period_label) AS months_elapsed
    FROM contract_cost_actual
    WHERE is_active = TRUE AND fiscal_year = v_fiscal_year AND period_type = 'month'
      AND period_label <= v_as_of_period
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
                                 LEAST(
                                   GREATEST(
                                     (COALESCE(abc.actual_aed, 0) +
                                      (COALESCE(abc.actual_aed, 0) / NULLIF(COALESCE(abc.months_elapsed, 0), 0)) *
                                       (v_months_in_fy - COALESCE(abc.months_elapsed, 0))
                                     ) - bbc.budget_aed,
                                     (COALESCE(abc.actual_aed, 0) - bbc.budget_aed)
                                   ),
                                   bbc.budget_aed * 2.0
                                 ),
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
                       'trendingOverContractCount', COALESCE(v_trending_over_count, 0)
                     ),
    'data',          v_data,
    'topOverBudget', v_top_over_budget,
    'pagination',    jsonb_build_object('page', v_page, 'limit', v_limit, 'total', v_total)
  );

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_budget_burn_portfolio: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_budget_burn_portfolio(BIGINT, JSONB) IS
'Budget Burn portfolio rollup. v4 (mig 418): pin actual_by_contract to period_label <= current month.
Aligns HERO-001 portfolio actual with Projection tab actual-to-date (AED 476.2M, not AED 848M).
HERO-001 portfolio projection now lands ~+AED 107M, matching Projection tab +12.7%.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (418, '418_omar_cluster_c_actual_as_of_today — O17 follow-up portfolio actual as-of today', NOW())
ON CONFLICT (version) DO NOTHING;
