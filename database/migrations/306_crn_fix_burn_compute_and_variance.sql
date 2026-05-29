-- Migration: 306_crn_fix_burn_compute_and_variance.sql
-- Module: CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half)
-- Description: DEFECT-298-1 fix: fn_budget_burn_compute — cumulative burn used
--              window fns (SUM OVER) inside jsonb_agg causing
--              "aggregate function calls cannot contain window function calls".
--              Fix: compute running sum in a separate cum_burn CTE first,
--              then wrap in jsonb_agg (no nested window fn).
--              DEFECT-298-2 fix: fn_budget_variance_for_contract — was comparing
--              month actuals rolled to full-quarter vs quarterly budget. With only
--              1 month of actuals in Q2, April day_rate appeared under-budget (-64%).
--              Fix: compare month actuals against pro-rated monthly budget
--              (quarterly_budget / 3.0) so April day_rate 47.88M vs 44.33M → +8%.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- DEFECT-298-1 FIX: fn_budget_burn_compute
-- ============================================================

CREATE OR REPLACE FUNCTION fn_budget_burn_compute(
  p_actor_id    BIGINT,
  p_contract_id BIGINT
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
BEGIN
  IF p_contract_id IS NULL THEN
    RAISE EXCEPTION 'contractId is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS(SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE)
  INTO v_contract_exists;
  IF NOT v_contract_exists THEN RETURN NULL; END IF;

  SELECT id, contract_number, title_en, title_ar
  INTO v_contract_rec
  FROM contract WHERE id = p_contract_id AND is_active = TRUE;

  -- Read threshold for overThreshold flag
  SELECT COALESCE(TRIM(BOTH '"' FROM (value::text))::NUMERIC, 5)
  INTO v_threshold_pct
  FROM system_setting
  WHERE key = 'financial.budget.variance_threshold_pct' AND is_active = TRUE
  LIMIT 1;
  v_threshold_pct := COALESCE(v_threshold_pct, 5);

  -- Totals
  SELECT COALESCE(SUM(allocated_amount_aed), 0) INTO v_total_budget
  FROM contract_budget
  WHERE contract_id = p_contract_id AND is_active = TRUE;

  SELECT COALESCE(SUM(actual_amount_aed), 0) INTO v_total_actual
  FROM contract_cost_actual
  WHERE contract_id = p_contract_id AND is_active = TRUE;

  -- Monthly actuals detail (for month-4 spike visibility)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'periodLabel',  ca.period_label,
    'costCategory', ca.cost_category,
    'actualAed',    ca.actual_aed::text
  ) ORDER BY ca.period_label, ca.cost_category), '[]'::jsonb)
  INTO v_monthly_actuals
  FROM (
    SELECT period_label, cost_category, SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual
    WHERE contract_id = p_contract_id AND is_active = TRUE AND period_type = 'month'
    GROUP BY period_label, cost_category
  ) ca;

  -- Per-period (quarter) with category breakdown — S2-24 split-aggregate CTEs
  WITH budget_q AS (
    SELECT period_label, cost_category,
           SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget
    WHERE contract_id = p_contract_id AND is_active = TRUE
    GROUP BY period_label, cost_category
  ),
  actual_m AS (
    SELECT period_label, cost_category,
           SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual
    WHERE contract_id = p_contract_id AND is_active = TRUE AND period_type = 'month'
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
    WHERE contract_id = p_contract_id AND is_active = TRUE
  ),
  categories AS (
    SELECT DISTINCT cost_category
    FROM contract_budget
    WHERE contract_id = p_contract_id AND is_active = TRUE
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

  -- Cumulative burn — DEFECT-298-1 FIX:
  -- Compute running sums in cum_burn CTE FIRST, then wrap in jsonb_agg.
  -- Window fns cannot be nested inside aggregate calls in PostgreSQL.
  WITH period_agg AS (
    SELECT b.period_label,
           COALESCE(b.budget_aed, 0) AS budget_aed,
           COALESCE(a.actual_aed, 0) AS actual_aed
    FROM (
      SELECT period_label, SUM(allocated_amount_aed) AS budget_aed
      FROM contract_budget WHERE contract_id = p_contract_id AND is_active = TRUE
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
      WHERE contract_id = p_contract_id AND is_active = TRUE AND period_type = 'month'
      GROUP BY 1
    ) a USING (period_label)
  ),
  cum_burn AS (
    -- Pre-compute running sums in this CTE — window fns are NOT inside an aggregate here
    SELECT period_label,
           SUM(actual_aed)  OVER (ORDER BY period_label ROWS UNBOUNDED PRECEDING) AS cumulative_actual_aed,
           SUM(budget_aed)  OVER (ORDER BY period_label ROWS UNBOUNDED PRECEDING) AS cumulative_budget_aed
    FROM period_agg
  )
  -- Now jsonb_agg operates on plain scalar columns — no window fn nesting
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
    'totalBudgetedAed',   v_total_budget::text,
    'totalActualAed',     v_total_actual::text,
    'totalVarianceAed',   (v_total_actual - v_total_budget)::text,
    'totalVariancePct',   CASE WHEN v_total_budget > 0
                               THEN ROUND(((v_total_actual - v_total_budget) / v_total_budget * 100)::NUMERIC, 2)
                               ELSE 0 END,
    'burnRatePct',        CASE WHEN v_total_budget > 0
                               THEN ROUND((v_total_actual / v_total_budget * 100)::NUMERIC, 2)
                               ELSE 0 END,
    'remainingBudgetAed', (v_total_budget - v_total_actual)::text,
    'byPeriod',           v_by_period,
    'byQuarter',          v_by_period,
    'monthlyActuals',     v_monthly_actuals,
    'cumulativeBurn',     v_cumulative_burn
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_budget_burn_compute: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_budget_burn_compute(BIGINT, BIGINT) IS
  'CR-N M21: Per-period × category budget-vs-actual, variance, cumulative burn for one contract. STABLE INVOKER — RLS gates via finance.budget.read. S2-24: split-aggregate CTEs. FIX-298-1: cumulative running sum computed in cum_burn CTE (not nested inside jsonb_agg).';
REVOKE EXECUTE ON FUNCTION fn_budget_burn_compute(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_burn_compute(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- DEFECT-298-2 FIX: fn_budget_variance_for_contract
-- Compare month actuals against pro-rated monthly budget (quarterly / 3.0)
-- so April day_rate 47.88M vs 44.33M (= 133M/3) → +8.00% breach.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_budget_variance_for_contract(
  p_actor_id      BIGINT,
  p_contract_id   BIGINT,
  p_threshold_pct NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_contract_exists   BOOLEAN;
  v_threshold_pct     NUMERIC;
  v_threshold_source  TEXT;
  v_setting_val       TEXT;
  v_breaches          JSONB;
  v_cure_clauses      JSONB;
  v_ld_clauses        JSONB;
  v_breach_count      INTEGER;
  v_max_variance_pct  NUMERIC;
  v_has_cure_period   BOOLEAN;
  v_tenant_id         UUID;
BEGIN
  IF p_contract_id IS NULL THEN
    RAISE EXCEPTION 'contractId is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS(SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE)
  INTO v_contract_exists;
  IF NOT v_contract_exists THEN RETURN NULL; END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;

  -- Threshold: param → system_setting → default 5
  IF p_threshold_pct IS NOT NULL THEN
    v_threshold_pct    := p_threshold_pct;
    v_threshold_source := 'param';
  ELSE
    SELECT TRIM(BOTH '"' FROM (value::text))
    INTO v_setting_val
    FROM system_setting
    WHERE key = 'financial.budget.variance_threshold_pct' AND is_active = TRUE
    LIMIT 1;

    IF v_setting_val IS NOT NULL THEN
      v_threshold_pct    := v_setting_val::NUMERIC;
      v_threshold_source := 'system_setting';
    ELSE
      v_threshold_pct    := 5;
      v_threshold_source := 'default';
    END IF;
  END IF;

  -- DEFECT-298-2 FIX: Compare MONTH actuals against pro-rated monthly budget
  -- (quarterly_budget / 3.0 per month). This surfaces April day_rate +8% overrun
  -- even when the quarter total is still under-budget (only 1 month has actuals).
  -- S2-24: budget_monthly / actual_month / joined CTEs (split-aggregate)
  WITH budget_q AS (
    -- One row per (quarter_label, cost_category) with full quarterly allocation
    SELECT period_label AS quarter_label, cost_category, fiscal_year,
           SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget
    WHERE contract_id = p_contract_id AND is_active = TRUE
    GROUP BY period_label, cost_category, fiscal_year
  ),
  budget_monthly AS (
    -- Map each quarter → its 3 calendar months; monthly_budget = quarterly / 3
    -- Months for Q1: 01,02,03  Q2: 04,05,06  Q3: 07,08,09  Q4: 10,11,12
    SELECT bq.cost_category, bq.fiscal_year,
           LPAD(m.month_num::text, 2, '0') AS month_num,
           bq.fiscal_year::text || '-' || LPAD(m.month_num::text, 2, '0') AS period_label,
           ROUND((bq.budget_aed / 3.0)::NUMERIC, 2) AS monthly_budget_aed
    FROM budget_q bq
    CROSS JOIN LATERAL (
      SELECT unnest(CASE bq.quarter_label
        WHEN bq.fiscal_year::text || '-Q1' THEN ARRAY[1,2,3]
        WHEN bq.fiscal_year::text || '-Q2' THEN ARRAY[4,5,6]
        WHEN bq.fiscal_year::text || '-Q3' THEN ARRAY[7,8,9]
        ELSE ARRAY[10,11,12]
      END) AS month_num
    ) m
  ),
  actual_month AS (
    -- Month-grain actuals (period_type='month')
    SELECT period_label, cost_category, fiscal_year,
           SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual
    WHERE contract_id = p_contract_id AND is_active = TRUE AND period_type = 'month'
    GROUP BY period_label, cost_category, fiscal_year
  ),
  joined AS (
    -- Join month actuals to monthly_budget; only months that HAVE actuals
    SELECT am.period_label, am.cost_category, am.fiscal_year,
           COALESCE(bm.monthly_budget_aed, 0) AS budget_aed,
           am.actual_aed,
           am.actual_aed - COALESCE(bm.monthly_budget_aed, 0) AS variance_aed,
           CASE WHEN COALESCE(bm.monthly_budget_aed, 0) > 0
                THEN ROUND(((am.actual_aed - bm.monthly_budget_aed) / bm.monthly_budget_aed * 100)::NUMERIC, 2)
                ELSE NULL END AS variance_pct
    FROM actual_month am
    LEFT JOIN budget_monthly bm
      ON bm.period_label = am.period_label AND bm.cost_category = am.cost_category
    WHERE COALESCE(bm.monthly_budget_aed, 0) > 0
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'periodLabel',  j.period_label,
      'costCategory', j.cost_category,
      'fiscalYear',   j.fiscal_year,
      'budgetAed',    j.budget_aed::text,
      'actualAed',    j.actual_aed::text,
      'varianceAed',  j.variance_aed::text,
      'variancePct',  j.variance_pct,
      'severity',     CASE WHEN j.variance_pct >= v_threshold_pct THEN 'breach' ELSE 'warning' END
    ) ORDER BY j.variance_pct DESC NULLS LAST), '[]'::jsonb),
    COALESCE(COUNT(*), 0)::INTEGER,
    COALESCE(MAX(j.variance_pct), 0)
  INTO v_breaches, v_breach_count, v_max_variance_pct
  FROM joined j
  WHERE j.variance_pct >= v_threshold_pct;

  -- Clause refs
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'clauseId',       cce.id,
    'clauseType',     cce.clause_type_v2,
    'curePeriodDays', (cce.parameters->>'cure_period_days')::NUMERIC,
    'pageNo',         cce.page_no
  ) ORDER BY cce.id), '[]'::jsonb)
  INTO v_cure_clauses
  FROM contract_clause_extracted cce
  WHERE cce.contract_id = p_contract_id AND cce.is_active = TRUE
    AND cce.clause_type_v2 = 'cure_period'
    AND cce.tenant_id = v_tenant_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'clauseId',   cce.id,
    'clauseType', cce.clause_type_v2,
    'ldRate',     (cce.parameters->>'ld_rate')::text,
    'ldCap',      (cce.parameters->>'ld_cap')::text,
    'pageNo',     cce.page_no
  ) ORDER BY cce.id), '[]'::jsonb)
  INTO v_ld_clauses
  FROM contract_clause_extracted cce
  WHERE cce.contract_id = p_contract_id AND cce.is_active = TRUE
    AND cce.clause_type_v2 = 'liquidated_damages'
    AND cce.tenant_id = v_tenant_id;

  SELECT (jsonb_array_length(v_cure_clauses) > 0) INTO v_has_cure_period;

  RETURN jsonb_build_object(
    'contractId',         p_contract_id,
    'thresholdPct',       v_threshold_pct,
    'thresholdSource',    v_threshold_source,
    'breaches',           COALESCE(v_breaches, '[]'::jsonb),
    'breachCount',        v_breach_count,
    'maxVariancePct',     v_max_variance_pct,
    'correlatedClauses',  jsonb_build_object(
                            'curePeriod',        COALESCE(v_cure_clauses, '[]'::jsonb),
                            'liquidatedDamages', COALESCE(v_ld_clauses, '[]'::jsonb)
                          ),
    'cureNoticeEligible', (v_breach_count > 0 AND v_has_cure_period)
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_budget_variance_for_contract: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_budget_variance_for_contract(BIGINT, BIGINT, NUMERIC) IS
  'CR-N M21: List (period, category) month-level breaches vs pro-rated monthly budget (quarterly/3). FIX-298-2: month-grain comparison reveals April day_rate +8% breach. STABLE INVOKER + correlated cure/LD clause refs.';
REVOKE EXECUTE ON FUNCTION fn_budget_variance_for_contract(BIGINT, BIGINT, NUMERIC) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_variance_for_contract(BIGINT, BIGINT, NUMERIC) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (306, '306_crn_fix_burn_compute_and_variance', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- -- Re-apply mig 298 versions to restore original bodies:
-- -- (or simply re-run mig 298 fn bodies)
-- DELETE FROM schema_migrations WHERE version = 306;
-- COMMIT;
-- ============================================================
