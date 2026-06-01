-- Migration: 417_omar_cluster_c_projection_consistency.sql
-- Unit: Omar Operations QA Phase 3 — Cluster C (HERO-001 projection alignment)
-- Targets:
--   O17  HERO-001 shows 4 different year-end projections across 4 surfaces:
--          Contract detail blurb (anchor): +AED 42M / +13% / AED 845M FY budget
--          Budget Burn portfolio:           +AED 1.2B / 100.4% / AED 845M
--          BB drill Overview tab:           +AED 9M variance / +0.8% / AED 1.1B totals
--          BB drill Projection tab:         +AED 107.5M / +12.7% / AED 845M FY budget
--        Goal: pin portfolio + drill-Overview to FY 2026 + month-grain projection
--        so all 4 read +12.7% (≈ +13% Story 1 anchor).
--   O20  Runaway portfolio projection (+AED 2.8B on AED 3.8B budget). Caused by
--        calendar-day extrapolation amplifying early-FY actuals. Switch portfolio
--        projection to MONTH grain (same as fn_budget_year_end_projection) and
--        cap each row's projection at 200% of budget (sanity guard).
--   O21  HERO-001 Variance alert says "125.8% in 2026-07" but page KPI says
--        +0.8%. Indirect fix via O17 — Overview totals now match the Projection
--        tab so the headline KPI lands on +12.7%, agreeing with the banner's
--        FY narrative.
--   O40  Multi-source-of-truth pattern — sidereffect of O17 fixes.
--
-- Strategy:
--   1. Rewrite fn_budget_burn_portfolio to use month-grain projection
--      (matches fn_budget_year_end_projection) instead of day-grain.
--   2. Cap projected_over_under at 200% of budget per row.
--   3. Extend fn_budget_burn_compute with optional p_fiscal_year so
--      totalBudgetAed / totalActualAed / variance are FY-scoped. Defaults
--      to current calendar year if not specified — matches CR-N convention.

BEGIN;

----------------------------------------------------------------------------
-- 1. Rewrite fn_budget_burn_portfolio — month-grain projection, sanity-capped
----------------------------------------------------------------------------
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
BEGIN
  v_fiscal_year      := COALESCE((p_filters->>'fiscalYear')::INTEGER, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);
  v_min_variance_pct := (p_filters->>'minVariancePct')::NUMERIC;
  v_cost_category    := p_filters->>'costCategory';
  v_page             := GREATEST(COALESCE((p_filters->>'page')::INTEGER, 1), 1);
  v_limit            := LEAST(GREATEST(COALESCE((p_filters->>'limit')::INTEGER, 20), 1), 100);
  v_offset           := (v_page - 1) * v_limit;

  -- O17/O20: month-grain projection per contract matches fn_budget_year_end_projection
  -- formula: projected_ye = actual_to_date + (actual_to_date / months_elapsed) * months_remaining
  -- Sanity cap at 2.0 × budget so single-contract runaway extrapolations don't blow up the portfolio total.
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
    GROUP BY contract_id
  ),
  joined AS (
    SELECT
      bbc.contract_id,
      bbc.budget_aed,
      COALESCE(abc.actual_aed, 0) AS actual_aed,
      COALESCE(abc.actual_aed, 0) - bbc.budget_aed AS variance_aed,
      -- O17/O20: month-grain projection (matches Projection tab fn)
      ROUND(
        LEAST(
          -- raw projection
          GREATEST(
            (COALESCE(abc.actual_aed, 0) +
             (COALESCE(abc.actual_aed, 0) / NULLIF(COALESCE(abc.months_elapsed, 0), 0)) *
              (v_months_in_fy - COALESCE(abc.months_elapsed, 0))
            ) - bbc.budget_aed,
            (COALESCE(abc.actual_aed, 0) - bbc.budget_aed)   -- never less than snapshot variance
          ),
          -- cap at 2× budget overrun for sanity (O20)
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

  -- Paginated rows
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

  -- topOverBudget
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
'Budget Burn portfolio rollup. v3 (mig 417): projectedOverUnderAed now uses month-grain
run-rate projection matching fn_budget_year_end_projection (= actual + (actual/months_elapsed) *
months_remaining - budget) with a 2× sanity cap to prevent early-FY runaway projections. Aligns
HERO-001 portfolio cell with the Projection tab (+12.7% vs +1.2B previously) and the +13%
Story 1 anchor.';
REVOKE EXECUTE ON FUNCTION fn_budget_burn_portfolio(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_burn_portfolio(BIGINT, JSONB) TO neondb_owner;

----------------------------------------------------------------------------
-- 2. Rewrite fn_budget_burn_compute — scope budget + actual to FY-current
--    (was summing all FYs which inflated HERO-001 totals to AED 1.1B).
--    Add optional p_fiscal_year param; default = current calendar year.
----------------------------------------------------------------------------
DO $$
DECLARE rec RECORD;
BEGIN
  FOR rec IN
    SELECT p.oid::regprocedure::TEXT AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.proname = 'fn_budget_burn_compute' AND n.nspname = 'public'
  LOOP
    EXECUTE 'DROP FUNCTION ' || rec.sig;
  END LOOP;
END $$;

CREATE FUNCTION fn_budget_burn_compute(
  p_actor_id     BIGINT,
  p_contract_id  BIGINT,
  p_fiscal_year  INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_contract_exists BOOLEAN;
  v_contract_rec    RECORD;
  v_result          JSONB;
  v_by_period       JSONB;
  v_monthly_actuals JSONB;
  v_cumulative_burn JSONB;
  v_total_budget    NUMERIC(18,2);
  v_total_actual    NUMERIC(18,2);
  v_threshold_pct   NUMERIC;
  v_fy              INTEGER;
BEGIN
  IF p_contract_id IS NULL THEN
    RAISE EXCEPTION 'contractId is required' USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS(SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE)
  INTO v_contract_exists;
  IF NOT v_contract_exists THEN RETURN NULL; END IF;

  SELECT id, contract_number, title_en, title_ar
  INTO v_contract_rec
  FROM contract WHERE id = p_contract_id AND is_active = TRUE;

  v_fy := COALESCE(p_fiscal_year, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);

  SELECT COALESCE(
    TRIM(BOTH '"' FROM (value::text))::NUMERIC, 5
  ) INTO v_threshold_pct
  FROM system_setting
  WHERE key = 'financial.budget.variance_threshold_pct' AND is_active = TRUE
  LIMIT 1;
  v_threshold_pct := COALESCE(v_threshold_pct, 5);

  -- O17: scope budget + actual to current FY only
  SELECT COALESCE(SUM(allocated_amount_aed), 0) INTO v_total_budget
  FROM contract_budget
  WHERE contract_id = p_contract_id AND is_active = TRUE AND fiscal_year = v_fy;

  SELECT COALESCE(SUM(actual_amount_aed), 0) INTO v_total_actual
  FROM contract_cost_actual
  WHERE contract_id = p_contract_id AND is_active = TRUE
    AND fiscal_year = v_fy AND period_type = 'month';

  -- Monthly actuals (current FY only)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'periodLabel',  ca.period_label,
    'costCategory', ca.cost_category,
    'actualAed',    ca.actual_aed::text
  ) ORDER BY ca.period_label, ca.cost_category), '[]'::jsonb)
  INTO v_monthly_actuals
  FROM (
    SELECT period_label, cost_category, SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual
    WHERE contract_id = p_contract_id AND is_active = TRUE
      AND period_type = 'month' AND fiscal_year = v_fy
    GROUP BY period_label, cost_category
  ) ca;

  -- Per-period (quarter) with category breakdown — also FY-scoped now.
  WITH budget_q AS (
    SELECT period_label, cost_category, SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget
    WHERE contract_id = p_contract_id AND is_active = TRUE AND fiscal_year = v_fy
    GROUP BY period_label, cost_category
  ),
  actual_m AS (
    SELECT period_label, cost_category, SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual
    WHERE contract_id = p_contract_id AND is_active = TRUE
      AND period_type = 'month' AND fiscal_year = v_fy
    GROUP BY period_label, cost_category
  ),
  actual_roll AS (
    SELECT
      CASE
        WHEN SUBSTRING(period_label FROM 6 FOR 2) IN ('01','02','03') THEN SUBSTRING(period_label FROM 1 FOR 4) || '-Q1'
        WHEN SUBSTRING(period_label FROM 6 FOR 2) IN ('04','05','06') THEN SUBSTRING(period_label FROM 1 FOR 4) || '-Q2'
        WHEN SUBSTRING(period_label FROM 6 FOR 2) IN ('07','08','09') THEN SUBSTRING(period_label FROM 1 FOR 4) || '-Q3'
        ELSE SUBSTRING(period_label FROM 1 FOR 4) || '-Q4'
      END AS quarter_label,
      cost_category,
      SUM(actual_aed) AS actual_aed
    FROM actual_m
    GROUP BY 1, 2
  ),
  periods AS (
    SELECT DISTINCT period_label, fiscal_year
    FROM contract_budget
    WHERE contract_id = p_contract_id AND is_active = TRUE AND fiscal_year = v_fy
  ),
  categories AS (
    SELECT DISTINCT cost_category
    FROM contract_budget
    WHERE contract_id = p_contract_id AND is_active = TRUE AND fiscal_year = v_fy
  ),
  period_cat_budget AS (
    SELECT p.period_label, p.fiscal_year, c.cost_category,
           COALESCE(bq.budget_aed, 0) AS budget_aed
    FROM periods p CROSS JOIN categories c
    LEFT JOIN budget_q bq ON bq.period_label = p.period_label AND bq.cost_category = c.cost_category
  ),
  period_cat_actual AS (
    SELECT pcb.period_label, pcb.fiscal_year, pcb.cost_category,
           COALESCE(ar.actual_aed, 0) AS actual_aed
    FROM period_cat_budget pcb
    LEFT JOIN actual_roll ar ON ar.quarter_label = pcb.period_label AND ar.cost_category = pcb.cost_category
  ),
  category_rows AS (
    SELECT pcb.period_label, pcb.fiscal_year, pcb.cost_category,
           pcb.budget_aed, pca.actual_aed,
           (pca.actual_aed - pcb.budget_aed) AS variance_aed,
           CASE WHEN pcb.budget_aed > 0
                THEN ROUND(((pca.actual_aed - pcb.budget_aed) / pcb.budget_aed * 100)::NUMERIC, 2)
                ELSE NULL END AS variance_pct
    FROM period_cat_budget pcb
    JOIN period_cat_actual pca USING (period_label, fiscal_year, cost_category)
  ),
  period_totals AS (
    SELECT period_label, fiscal_year,
           SUM(budget_aed) AS budget_aed,
           SUM(actual_aed) AS actual_aed,
           SUM(variance_aed) AS variance_aed
    FROM category_rows
    GROUP BY period_label, fiscal_year
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'periodLabel',  pt.period_label,
      'fiscalYear',   pt.fiscal_year,
      'budgetAed',    pt.budget_aed::text,
      'actualAed',    pt.actual_aed::text,
      'varianceAed',  pt.variance_aed::text,
      'variancePct',  CASE WHEN pt.budget_aed > 0
                           THEN ROUND((pt.variance_aed / pt.budget_aed * 100)::NUMERIC, 2)
                           ELSE NULL END,
      'byCategory',   (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'costCategory', cr.cost_category,
          'budgetAed',    cr.budget_aed::text,
          'actualAed',    cr.actual_aed::text,
          'varianceAed',  cr.variance_aed::text,
          'variancePct',  cr.variance_pct,
          'overThreshold', CASE WHEN cr.variance_pct IS NOT NULL
                                THEN cr.variance_pct >= v_threshold_pct
                                ELSE FALSE END
        ) ORDER BY cr.cost_category), '[]'::jsonb)
        FROM category_rows cr
        WHERE cr.period_label = pt.period_label
      )
    ) ORDER BY pt.fiscal_year, pt.period_label
  ), '[]'::jsonb)
  INTO v_by_period
  FROM period_totals pt;

  -- Cumulative burn (FY-scoped now)
  WITH period_agg AS (
    SELECT period_label,
           SUM(b.budget_aed) AS budget_aed,
           SUM(a.actual_aed) AS actual_aed
    FROM (
      SELECT period_label, SUM(allocated_amount_aed) AS budget_aed
      FROM contract_budget WHERE contract_id = p_contract_id AND is_active = TRUE AND fiscal_year = v_fy
      GROUP BY period_label
    ) b
    FULL JOIN (
      SELECT
        CASE
          WHEN SUBSTRING(period_label FROM 6 FOR 2) IN ('01','02','03') THEN SUBSTRING(period_label FROM 1 FOR 4) || '-Q1'
          WHEN SUBSTRING(period_label FROM 6 FOR 2) IN ('04','05','06') THEN SUBSTRING(period_label FROM 1 FOR 4) || '-Q2'
          WHEN SUBSTRING(period_label FROM 6 FOR 2) IN ('07','08','09') THEN SUBSTRING(period_label FROM 1 FOR 4) || '-Q3'
          ELSE SUBSTRING(period_label FROM 1 FOR 4) || '-Q4'
        END AS period_label,
        SUM(actual_amount_aed) AS actual_aed
      FROM contract_cost_actual
      WHERE contract_id = p_contract_id AND is_active = TRUE AND period_type = 'month' AND fiscal_year = v_fy
      GROUP BY 1
    ) a USING (period_label)
    GROUP BY period_label
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'periodLabel',          period_label,
    'cumulativeActualAed',  SUM(actual_aed) OVER (ORDER BY period_label ROWS UNBOUNDED PRECEDING)::text,
    'cumulativeBudgetAed',  SUM(budget_aed) OVER (ORDER BY period_label ROWS UNBOUNDED PRECEDING)::text
  ) ORDER BY period_label), '[]'::jsonb)
  INTO v_cumulative_burn
  FROM period_agg;

  RETURN jsonb_build_object(
    'contractId',         v_contract_rec.id,
    'contractNumber',     v_contract_rec.contract_number,
    'titleEn',            v_contract_rec.title_en,
    'titleAr',            v_contract_rec.title_ar,
    'currency',           'AED',
    'fiscalYear',         v_fy,
    'totalBudgetAed',     v_total_budget::text,
    'totalActualAed',     v_total_actual::text,
    'totalVarianceAed',   (v_total_actual - v_total_budget)::text,
    'totalVariancePct',   CASE WHEN v_total_budget > 0
                               THEN ROUND(((v_total_actual - v_total_budget) / v_total_budget * 100)::NUMERIC, 2)
                               ELSE 0 END,
    'pctBudgetConsumed',  CASE WHEN v_total_budget > 0
                               THEN ROUND((v_total_actual / v_total_budget * 100)::NUMERIC, 2)
                               ELSE 0 END,
    'remainingBudgetAed', (v_total_budget - v_total_actual)::text,
    'byPeriod',           v_by_period,
    'monthlyActuals',     v_monthly_actuals,
    'cumulativeBurn',     v_cumulative_burn
  );

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_budget_burn_compute: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_budget_burn_compute(BIGINT, BIGINT, INTEGER) IS
'CR-N M21 / Omar O17: Per-period × category budget-vs-actual for one contract. v2 (mig 417): scopes
budget + actual + cumulativeBurn to the current FY (param p_fiscal_year, default current calendar
year) so the Detail Overview totals agree with the Portfolio rollup + Projection tab. Aligns
HERO-001 to a single AED 845M FY 2026 baseline (was AED 1.1B all-FY before).';
REVOKE EXECUTE ON FUNCTION fn_budget_burn_compute(BIGINT, BIGINT, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_burn_compute(BIGINT, BIGINT, INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (417, '417_omar_cluster_c_projection_consistency — O17/O20/O21/O40 HERO-001 alignment', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK: restore fn_budget_burn_portfolio from mig 410 + fn_budget_burn_compute from mig 298.
