-- Migration: 420_omar_cluster_c_fix_burn_key_names.sql
-- Unit: Omar Operations QA Phase 3 — Cluster C followup #3
-- Targets: mig 306 renamed two return keys (pctBudgetConsumed → burnRatePct,
-- and added totalBudgetedAed alongside totalBudgetAed, plus byQuarter as alias
-- for byPeriod) that mig 417 reverted. Re-add them so the FE detail page
-- finds the keys it expects.

CREATE OR REPLACE FUNCTION fn_budget_burn_compute(
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

  SELECT id, contract_number, title_en, title_ar INTO v_contract_rec
  FROM contract WHERE id = p_contract_id AND is_active = TRUE;

  v_fy := COALESCE(p_fiscal_year, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);
  SELECT COALESCE(TRIM(BOTH '"' FROM (value::text))::NUMERIC, 5)
  INTO v_threshold_pct
  FROM system_setting WHERE key = 'financial.budget.variance_threshold_pct' AND is_active = TRUE LIMIT 1;
  v_threshold_pct := COALESCE(v_threshold_pct, 5);

  SELECT COALESCE(SUM(allocated_amount_aed), 0) INTO v_total_budget
  FROM contract_budget WHERE contract_id = p_contract_id AND is_active = TRUE AND fiscal_year = v_fy;
  SELECT COALESCE(SUM(actual_amount_aed), 0) INTO v_total_actual
  FROM contract_cost_actual WHERE contract_id = p_contract_id AND is_active = TRUE
    AND fiscal_year = v_fy AND period_type = 'month';

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
    GROUP BY period_label, cost_category
  ) ca;

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
    -- mig 306 + 417 + 420 alignment: keep all 4 key variants for FE/BE harmony.
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
$$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (420, '420_omar_cluster_c_fix_burn_key_names — restore burnRatePct + totalBudgetedAed + byQuarter aliases', NOW())
ON CONFLICT (version) DO NOTHING;
