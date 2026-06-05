-- MIGRATION: 563_contract_spend_health_canonical_source.sql
-- Date: 2026-06-05
-- Description:
--   Aligns "Contract Spend Health" (formerly "Budget Burn") on a single
--   source of truth and fixes two cross-surface inconsistencies the user
--   spotted on the executive dashboard:
--
--     1. The rollup KPI tile on the executive insights view said
--        "Over budget: 3", but the Budget Burn list page said
--        "Over budget: 0" for the same FY. Two different SQL definitions
--        for "over budget" coexisted:
--          - rollup (inline budgetBurnSummary in fn_dashboard_executive)
--              SUM all monthly actuals for FY, no period_label filter
--              → catches future-dated actuals (e.g. CRQ-DRL-001's
--                  pre-booked Q3 milestones), inflates "over budget"
--          - list (fn_budget_burn_portfolio.summary)
--              SUM monthly actuals WHERE period_label <= as-of-month
--              → conservative, true YTD, 0 contracts currently over
--
--     2. CRQ-DRL-001 detail page showed Total actual AED 538.4M
--        (lifetime / all-rows) while the list showed AED 215.4M (YTD).
--        Same root cause: fn_budget_burn_compute had no period filter
--        on v_total_actual.
--
--   Fix is two parts:
--     A. Extend fn_budget_burn_portfolio.summary with two additive
--        fields the FE rollup needs:
--          - contractsTotalCount         (active contracts platform-wide)
--          - contractsWithoutBudgetCount (= contractsTotalCount - contractsWithBudget)
--        + a new topProjectedOverrun3 array (top 3 trending-over by
--        projected variance, since with the YTD predicate
--        overBudgetCount drops to 0 mid-FY and topOverBudget would be
--        empty — the rollup needs the "trending over" leaderboard).
--
--        The FE rollup component switches to consume this endpoint
--        directly instead of the stale budgetBurnSummary key on the
--        exec-dashboard payload — guarantees the rollup and the
--        module page agree on every number going forward.
--
--     B. Patch fn_budget_burn_compute's v_total_actual SELECT to add
--        `AND period_label <= TO_CHAR(CURRENT_DATE, 'YYYY-MM')` (for
--        the current FY; for non-current FY use end-of-FY as as-of).
--        This makes the Detail Overview tile show the same YTD actual
--        as the list/rollup. The byPeriod / byCategory breakdowns
--        retain their full-FY view since that's the analytic surface.
--
--   Both fn signatures are preserved byte-for-byte; only body changes.
--   No API breaking changes.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────
-- A. fn_budget_burn_portfolio — extend summary + add topProjectedOverrun3
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_budget_burn_portfolio(
  p_actor_id bigint,
  p_filters jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_top_projected      JSONB;
  v_total_budget_aed   NUMERIC(18,2);
  v_total_actual_aed   NUMERIC(18,2);
  v_over_budget_count  INTEGER;
  v_proj_overrun       NUMERIC(18,2);
  v_trending_over_count INTEGER;
  v_months_in_fy       INTEGER := 12;
  v_as_of_period       TEXT;
  -- mig 563 additions
  v_contracts_total            INTEGER;
  v_contracts_without_budget   INTEGER;
BEGIN
  v_fiscal_year      := COALESCE((p_filters->>'fiscalYear')::INTEGER, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);
  v_min_variance_pct := (p_filters->>'minVariancePct')::NUMERIC;
  v_cost_category    := p_filters->>'costCategory';
  v_page             := GREATEST(COALESCE((p_filters->>'page')::INTEGER, 1), 1);
  v_limit            := LEAST(GREATEST(COALESCE((p_filters->>'limit')::INTEGER, 20), 1), 100);
  v_offset           := (v_page - 1) * v_limit;

  IF v_fiscal_year = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER THEN
    v_as_of_period := TO_CHAR(CURRENT_DATE, 'YYYY-MM');
  ELSE
    v_as_of_period := v_fiscal_year::text || '-12';
  END IF;

  -- mig 563 — total active contract count (for "X of Y contracts" rollup line)
  SELECT COUNT(*) INTO v_contracts_total
  FROM contract c WHERE c.is_active = TRUE;

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

  v_contracts_without_budget := GREATEST(v_contracts_total - COALESCE(v_total, 0), 0);

  -- Data page (unchanged from prior version)
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

  -- Top over budget (currently over, YTD) — unchanged
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

  -- mig 563 — Top 3 projected to overrun (trending-over leaderboard
  -- for the rollup). Includes contracts currently over AND contracts
  -- still under but trending toward overrun. Ordered by projected
  -- overrun AED desc so the rollup always has the most actionable 3
  -- even when nothing is currently over budget.
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
           ELSE 0 END AS variance_pct
    FROM budget_by_contract bbc
    LEFT JOIN actual_by_contract abc ON abc.contract_id = bbc.contract_id
  )
  SELECT COALESCE(jsonb_agg(row_data ORDER BY (row_data->>'projectedOverUnderAed')::NUMERIC DESC NULLS LAST), '[]'::jsonb)
  INTO v_top_projected
  FROM (
    SELECT jsonb_build_object(
      'contractId',            j.contract_id,
      'contractNumber',        c.contract_number,
      'titleEn',               c.title_en,
      'titleAr',               c.title_ar,
      'budgetAed',             j.budget_aed::text,
      'actualAed',             j.actual_aed::text,
      'variancePct',           j.variance_pct,
      'projectedOverUnderAed', j.projected_over_under_aed::text,
      'varianceFlag',          (j.actual_aed > j.budget_aed)
    ) AS row_data
    FROM joined j
    JOIN contract c ON c.id = j.contract_id AND c.is_active = TRUE
    WHERE j.projected_over_under_aed > 0
    ORDER BY j.projected_over_under_aed DESC
    LIMIT 3
  ) sub;

  RETURN jsonb_build_object(
    'summary',       jsonb_build_object(
                       'contractsWithBudget',          COALESCE(v_total, 0),
                       'contractsTotalCount',          COALESCE(v_contracts_total, 0),
                       'contractsWithoutBudgetCount',  COALESCE(v_contracts_without_budget, 0),
                       'totalBudgetAed',               COALESCE(v_total_budget_aed, 0)::text,
                       'totalActualAed',               COALESCE(v_total_actual_aed, 0)::text,
                       'totalVarianceAed',             (COALESCE(v_total_actual_aed, 0) - COALESCE(v_total_budget_aed, 0))::text,
                       'overBudgetContractCount',      COALESCE(v_over_budget_count, 0),
                       'totalProjectedOverrunAed',     COALESCE(v_proj_overrun, 0)::text,
                       'trendingOverContractCount',    COALESCE(v_trending_over_count, 0),
                       'asOfPeriod',                   v_as_of_period,
                       'fiscalYear',                   v_fiscal_year
                     ),
    'data',              v_data,
    'topOverBudget',     v_top_over_budget,
    'topProjectedOverrun3', v_top_projected,
    'pagination',    jsonb_build_object('page', v_page, 'limit', v_limit, 'total', v_total)
  );

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_budget_burn_portfolio: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_budget_burn_portfolio(bigint, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_budget_burn_portfolio(bigint, jsonb) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────────────
-- B. fn_budget_burn_compute — apply period_label <= as-of-month filter
--    to v_total_actual so Detail Overview tile aligns with the list.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_budget_burn_compute(
  p_actor_id bigint,
  p_contract_id bigint,
  p_fiscal_year integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_contract_exists BOOLEAN;
  v_contract_rec    RECORD;
  v_by_period       JSONB;
  v_monthly_actuals JSONB;
  v_cumulative_burn JSONB;
  v_total_budget    NUMERIC(18,2);
  v_total_actual    NUMERIC(18,2);
  v_threshold_pct   NUMERIC;
  v_fy              INTEGER;
  v_as_of_period    TEXT;
BEGIN
  IF p_contract_id IS NULL THEN
    RAISE EXCEPTION 'contractId is required' USING ERRCODE = '22023';
  END IF;
  SELECT EXISTS(SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE)
  INTO v_contract_exists;
  IF NOT v_contract_exists THEN RETURN NULL; END IF;

  SELECT id, contract_number, title_en, title_ar INTO v_contract_rec
  FROM contract WHERE id = p_contract_id AND is_active = TRUE;

  v_fy := COALESCE(p_fiscal_year, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);

  -- mig 563 — as-of boundary so the Overview tiles match list/rollup.
  IF v_fy = EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER THEN
    v_as_of_period := TO_CHAR(CURRENT_DATE, 'YYYY-MM');
  ELSE
    v_as_of_period := v_fy::text || '-12';
  END IF;

  SELECT COALESCE(TRIM(BOTH '"' FROM (value::text))::NUMERIC, 5)
  INTO v_threshold_pct
  FROM system_setting WHERE key = 'financial.budget.variance_threshold_pct' AND is_active = TRUE LIMIT 1;
  v_threshold_pct := COALESCE(v_threshold_pct, 5);

  SELECT COALESCE(SUM(allocated_amount_aed), 0) INTO v_total_budget
  FROM contract_budget WHERE contract_id = p_contract_id AND is_active = TRUE AND fiscal_year = v_fy;

  -- mig 563 — apply period_label <= v_as_of_period to total actual.
  -- (Was unfiltered; pre-booked future-period actuals were leaking into
  -- the Overview tile and producing "538M actual" for CRQ-DRL-001 even
  -- though only 215M had landed YTD.)
  SELECT COALESCE(SUM(actual_amount_aed), 0) INTO v_total_actual
  FROM contract_cost_actual
  WHERE contract_id = p_contract_id
    AND is_active = TRUE
    AND fiscal_year = v_fy
    AND period_type = 'month'
    AND period_label <= v_as_of_period;

  -- monthlyActuals — also bound to as-of so the Period × Category tab's
  -- "actual to date" cells are consistent with the Overview tiles.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'periodLabel',  ca.period_label,
    'costCategory', ca.cost_category,
    'actualAed',    ca.actual_aed::text
  ) ORDER BY ca.period_label, ca.cost_category), '[]'::jsonb)
  INTO v_monthly_actuals
  FROM (
    SELECT period_label, cost_category, SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual
    WHERE contract_id = p_contract_id AND is_active = TRUE AND period_type = 'month' AND fiscal_year = v_fy
      AND period_label <= v_as_of_period
    GROUP BY period_label, cost_category
  ) ca;

  -- byPeriod / byCategory breakdown — kept unfiltered on PURPOSE so the
  -- Period × Category tab can show forward-loaded actuals (e.g.
  -- pre-billed milestones). The Overview tiles use the bounded numbers
  -- above; this breakdown is the analytic surface.
  WITH budget_q AS (
    SELECT period_label, cost_category, SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget WHERE contract_id = p_contract_id AND is_active = TRUE AND fiscal_year = v_fy
    GROUP BY period_label, cost_category
  ),
  actual_m AS (
    SELECT period_label, cost_category, SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual WHERE contract_id = p_contract_id AND is_active = TRUE AND period_type = 'month' AND fiscal_year = v_fy
    GROUP BY period_label, cost_category
  ),
  actual_roll AS (
    SELECT
      CASE
        WHEN SUBSTRING(period_label FROM 6 FOR 2) IN ('01','02','03') THEN SUBSTRING(period_label FROM 1 FOR 4) || '-Q1'
        WHEN SUBSTRING(period_label FROM 6 FOR 2) IN ('04','05','06') THEN SUBSTRING(period_label FROM 1 FOR 4) || '-Q2'
        WHEN SUBSTRING(period_label FROM 6 FOR 2) IN ('07','08','09') THEN SUBSTRING(period_label FROM 1 FOR 4) || '-Q3'
        ELSE SUBSTRING(period_label FROM 1 FOR 4) || '-Q4'
      END AS quarter_label, cost_category, SUM(actual_aed) AS actual_aed
    FROM actual_m GROUP BY 1, 2
  ),
  periods AS (
    SELECT DISTINCT period_label, fiscal_year FROM contract_budget
    WHERE contract_id = p_contract_id AND is_active = TRUE AND fiscal_year = v_fy
  ),
  categories AS (
    SELECT DISTINCT cost_category FROM contract_budget
    WHERE contract_id = p_contract_id AND is_active = TRUE AND fiscal_year = v_fy
  ),
  period_cat_budget AS (
    SELECT p.period_label, p.fiscal_year, c.cost_category, COALESCE(bq.budget_aed, 0) AS budget_aed
    FROM periods p CROSS JOIN categories c
    LEFT JOIN budget_q bq ON bq.period_label = p.period_label AND bq.cost_category = c.cost_category
  ),
  period_cat_actual AS (
    SELECT pcb.period_label, pcb.fiscal_year, pcb.cost_category, COALESCE(ar.actual_aed, 0) AS actual_aed
    FROM period_cat_budget pcb
    LEFT JOIN actual_roll ar ON ar.quarter_label = pcb.period_label AND ar.cost_category = pcb.cost_category
  ),
  category_rows AS (
    SELECT pcb.period_label, pcb.fiscal_year, pcb.cost_category,
           pcb.budget_aed, pca.actual_aed,
           (pca.actual_aed - pcb.budget_aed) AS variance_aed,
           CASE WHEN pcb.budget_aed > 0
                THEN ROUND(((pca.actual_aed - pcb.budget_aed) / pcb.budget_aed * 100)::NUMERIC, 2) ELSE NULL END AS variance_pct
    FROM period_cat_budget pcb JOIN period_cat_actual pca USING (period_label, fiscal_year, cost_category)
  ),
  period_totals AS (
    SELECT period_label, fiscal_year, SUM(budget_aed) AS budget_aed, SUM(actual_aed) AS actual_aed, SUM(variance_aed) AS variance_aed
    FROM category_rows GROUP BY period_label, fiscal_year
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'periodLabel',  pt.period_label,
      'fiscalYear',   pt.fiscal_year,
      'budgetAed',    pt.budget_aed::text,
      'actualAed',    pt.actual_aed::text,
      'varianceAed',  pt.variance_aed::text,
      'variancePct',  CASE WHEN pt.budget_aed > 0 THEN ROUND((pt.variance_aed / pt.budget_aed * 100)::NUMERIC, 2) ELSE NULL END,
      'byCategory',   (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'costCategory', cr.cost_category,
          'budgetAed',    cr.budget_aed::text,
          'actualAed',    cr.actual_aed::text,
          'varianceAed',  cr.variance_aed::text,
          'variancePct',  cr.variance_pct,
          'overThreshold', CASE WHEN cr.variance_pct IS NOT NULL THEN cr.variance_pct >= v_threshold_pct ELSE FALSE END
        ) ORDER BY cr.cost_category), '[]'::jsonb)
        FROM category_rows cr WHERE cr.period_label = pt.period_label
      )
    ) ORDER BY pt.fiscal_year, pt.period_label
  ), '[]'::jsonb)
  INTO v_by_period
  FROM period_totals pt;

  -- cumulativeBurn — applies as-of bound (Trends tab plots actual vs
  -- planned through today; future months should not appear)
  WITH period_agg AS (
    SELECT b.period_label, COALESCE(b.budget_aed, 0) AS budget_aed, COALESCE(a.actual_aed, 0) AS actual_aed
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
        END AS period_label, SUM(actual_amount_aed) AS actual_aed
      FROM contract_cost_actual WHERE contract_id = p_contract_id AND is_active = TRUE AND period_type = 'month' AND fiscal_year = v_fy
        AND period_label <= v_as_of_period
      GROUP BY 1
    ) a USING (period_label)
  ),
  cum_burn AS (
    SELECT period_label,
           SUM(actual_aed) OVER (ORDER BY period_label ROWS UNBOUNDED PRECEDING) AS cumulative_actual_aed,
           SUM(budget_aed) OVER (ORDER BY period_label ROWS UNBOUNDED PRECEDING) AS cumulative_budget_aed
    FROM period_agg
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'periodLabel',          period_label,
    'cumulativeActualAed',  cumulative_actual_aed::text,
    'cumulativeBudgetAed',  cumulative_budget_aed::text
  ) ORDER BY period_label), '[]'::jsonb)
  INTO v_cumulative_burn
  FROM cum_burn;

  RETURN jsonb_build_object(
    'contractId',         v_contract_rec.id,
    'contractNumber',     v_contract_rec.contract_number,
    'titleEn',            v_contract_rec.title_en,
    'titleAr',            v_contract_rec.title_ar,
    'currency',           'AED',
    'fiscalYear',         v_fy,
    'asOfPeriod',         v_as_of_period,
    'totalBudgetedAed',   v_total_budget::text,
    'totalBudgetAed',     v_total_budget::text,
    'totalActualAed',     v_total_actual::text,
    'totalVarianceAed',   (v_total_actual - v_total_budget)::text,
    'totalVariancePct',   CASE WHEN v_total_budget > 0
                               THEN ROUND(((v_total_actual - v_total_budget) / v_total_budget * 100)::NUMERIC, 2)
                               ELSE 0 END,
    'burnRatePct',        CASE WHEN v_total_budget > 0
                               THEN ROUND((v_total_actual / v_total_budget * 100)::NUMERIC, 2)
                               ELSE 0 END,
    'pctBudgetConsumed',  CASE WHEN v_total_budget > 0
                               THEN ROUND((v_total_actual / v_total_budget * 100)::NUMERIC, 2)
                               ELSE 0 END,
    'remainingBudgetAed', (v_total_budget - v_total_actual)::text,
    'byPeriod',           v_by_period,
    'byQuarter',          v_by_period,
    'monthlyActuals',     v_monthly_actuals,
    'cumulativeBurn',     v_cumulative_burn
  );

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_budget_burn_compute: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_budget_burn_compute(bigint, bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_budget_burn_compute(bigint, bigint, integer) TO neondb_owner;

COMMIT;
