-- Migration: 307_crn_fix_defect_db01_add_read_permission_gate.sql
-- Module: CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half)
-- Description: DEFECT-CRN-DB-01 (HIGH) fix — add finance.budget.read permission gate
--              at the DB layer to all 7 CR-N READ fn_'s:
--                fn_budget_burn_compute
--                fn_budget_variance_for_contract
--                fn_budget_year_end_projection
--                fn_budget_burn_portfolio
--                fn_contract_budget_list
--                fn_contract_budget_get
--                fn_contract_cost_actual_list
--              fn_contract_cost_actual_record (WRITE) already enforces finance.budget.manage
--              via mig 298 — leave it unchanged.
--              fn_contract_cost_actual_get_by_id is an internal helper (no gate needed).
--
--              Pattern: fn_current_user_has_permission('finance.budget.read')
--              identical to CR-M cascade read fn_'s (mig 289).
--              ERRCODE 42501 on failure.
--              S2-21: COMMENT + REVOKE PUBLIC EXECUTE + GRANT neondb_owner on every fn.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- 1. fn_contract_budget_list — add permission gate at top
-- Body otherwise byte-for-byte from mig 298 (STABLE INVOKER)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_budget_list(
  p_actor_id      BIGINT,
  p_contract_id   BIGINT  DEFAULT NULL,
  p_fiscal_year   INTEGER DEFAULT NULL,
  p_cost_category TEXT    DEFAULT NULL,
  p_page          INTEGER DEFAULT 1,
  p_limit         INTEGER DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_page    INTEGER;
  v_limit   INTEGER;
  v_offset  INTEGER;
  v_total   INTEGER;
  v_data    JSONB;
BEGIN
  -- Permission gate: finance.budget.read required (DEFECT-CRN-DB-01 fix)
  IF NOT fn_current_user_has_permission('finance.budget.read') THEN
    RAISE EXCEPTION 'Insufficient permission: finance.budget.read required'
      USING ERRCODE = '42501';
  END IF;

  v_page  := GREATEST(COALESCE(p_page, 1), 1);
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset := (v_page - 1) * v_limit;

  SELECT COUNT(*) INTO v_total
  FROM contract_budget cb
  WHERE cb.is_active = TRUE
    AND (p_contract_id   IS NULL OR cb.contract_id   = p_contract_id)
    AND (p_fiscal_year   IS NULL OR cb.fiscal_year   = p_fiscal_year)
    AND (p_cost_category IS NULL OR cb.cost_category = p_cost_category);

  SELECT COALESCE(jsonb_agg(row_data ORDER BY row_data->>'contractId', (row_data->>'fiscalYear')::int, row_data->>'periodLabel', row_data->>'costCategory'), '[]'::jsonb)
  INTO v_data
  FROM (
    SELECT jsonb_build_object(
      'id',                 cb.id,
      'contractId',         cb.contract_id,
      'contractNumber',     c.contract_number,
      'periodType',         cb.period_type,
      'periodLabel',        cb.period_label,
      'fiscalYear',         cb.fiscal_year,
      'costCategory',       cb.cost_category,
      'allocatedAmountAed', cb.allocated_amount_aed::text,
      'currency',           cb.currency,
      'notes',              cb.notes,
      'createdAt',          cb.created_at
    ) AS row_data
    FROM contract_budget cb
    JOIN contract c ON c.id = cb.contract_id
    WHERE cb.is_active = TRUE
      AND (p_contract_id   IS NULL OR cb.contract_id   = p_contract_id)
      AND (p_fiscal_year   IS NULL OR cb.fiscal_year   = p_fiscal_year)
      AND (p_cost_category IS NULL OR cb.cost_category = p_cost_category)
    ORDER BY cb.contract_id, cb.fiscal_year, cb.period_label, cb.cost_category
    LIMIT v_limit OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object(
    'data',       v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', CEIL(v_total::FLOAT / v_limit)::INTEGER
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_contract_budget_list: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_contract_budget_list(BIGINT, BIGINT, INTEGER, TEXT, INTEGER, INTEGER) IS
  'CR-N M21: Paginated budget lines optionally scoped by contract/fiscal_year/cost_category. STABLE INVOKER. DB-layer gate: finance.budget.read (DEFECT-CRN-DB-01 fix, mig 307).';
REVOKE EXECUTE ON FUNCTION fn_contract_budget_list(BIGINT, BIGINT, INTEGER, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_budget_list(BIGINT, BIGINT, INTEGER, TEXT, INTEGER, INTEGER) TO neondb_owner;

-- ============================================================
-- 2. fn_contract_budget_get — add permission gate at top
-- Body otherwise byte-for-byte from mig 298 (STABLE INVOKER)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_budget_get(
  p_actor_id BIGINT,
  p_id       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_result JSONB;
BEGIN
  -- Permission gate: finance.budget.read required (DEFECT-CRN-DB-01 fix)
  IF NOT fn_current_user_has_permission('finance.budget.read') THEN
    RAISE EXCEPTION 'Insufficient permission: finance.budget.read required'
      USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT jsonb_build_object(
    'id',                 cb.id,
    'contractId',         cb.contract_id,
    'contract',           jsonb_build_object(
                            'id',             c.id,
                            'contractNumber', c.contract_number,
                            'titleEn',        c.title_en,
                            'titleAr',        c.title_ar
                          ),
    'periodType',         cb.period_type,
    'periodLabel',        cb.period_label,
    'fiscalYear',         cb.fiscal_year,
    'costCategory',       cb.cost_category,
    'allocatedAmountAed', cb.allocated_amount_aed::text,
    'currency',           cb.currency,
    'notes',              cb.notes,
    'source',             cb.source,
    'createdAt',          cb.created_at,
    'updatedAt',          cb.updated_at,
    'createdBy',          cb.created_by,
    'updatedBy',          cb.updated_by,
    'isActive',           cb.is_active
  )
  INTO v_result
  FROM contract_budget cb
  JOIN contract c ON c.id = cb.contract_id
  WHERE cb.id = p_id AND cb.is_active = TRUE;

  RETURN v_result;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_contract_budget_get: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_contract_budget_get(BIGINT, BIGINT) IS
  'CR-N M21: One budget line by id with embedded contract summary. Returns NULL if not found (controller → 404). STABLE INVOKER. DB-layer gate: finance.budget.read (DEFECT-CRN-DB-01 fix, mig 307).';
REVOKE EXECUTE ON FUNCTION fn_contract_budget_get(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_budget_get(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- 3. fn_contract_cost_actual_list — add permission gate at top
-- Body otherwise byte-for-byte from mig 298 (STABLE INVOKER)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_cost_actual_list(
  p_actor_id      BIGINT,
  p_contract_id   BIGINT   DEFAULT NULL,
  p_fiscal_year   INTEGER  DEFAULT NULL,
  p_cost_category TEXT     DEFAULT NULL,
  p_period_label  VARCHAR  DEFAULT NULL,
  p_page          INTEGER  DEFAULT 1,
  p_limit         INTEGER  DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_page   INTEGER;
  v_limit  INTEGER;
  v_offset INTEGER;
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  -- Permission gate: finance.budget.read required (DEFECT-CRN-DB-01 fix)
  IF NOT fn_current_user_has_permission('finance.budget.read') THEN
    RAISE EXCEPTION 'Insufficient permission: finance.budget.read required'
      USING ERRCODE = '42501';
  END IF;

  v_page  := GREATEST(COALESCE(p_page, 1), 1);
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset := (v_page - 1) * v_limit;

  SELECT COUNT(*) INTO v_total
  FROM contract_cost_actual ca
  WHERE ca.is_active = TRUE
    AND (p_contract_id   IS NULL OR ca.contract_id   = p_contract_id)
    AND (p_fiscal_year   IS NULL OR ca.fiscal_year   = p_fiscal_year)
    AND (p_cost_category IS NULL OR ca.cost_category = p_cost_category)
    AND (p_period_label  IS NULL OR ca.period_label  = p_period_label);

  SELECT COALESCE(jsonb_agg(row_data ORDER BY row_data->>'periodLabel', row_data->>'costCategory'), '[]'::jsonb)
  INTO v_data
  FROM (
    SELECT jsonb_build_object(
      'id',             ca.id,
      'contractId',     ca.contract_id,
      'periodType',     ca.period_type,
      'periodLabel',    ca.period_label,
      'fiscalYear',     ca.fiscal_year,
      'costCategory',   ca.cost_category,
      'actualAmountAed', ca.actual_amount_aed::text,
      'currency',       ca.currency,
      'source',         ca.source,
      'referenceNo',    ca.reference_no,
      'recordedAt',     ca.recorded_at,
      'notes',          ca.notes
    ) AS row_data
    FROM contract_cost_actual ca
    WHERE ca.is_active = TRUE
      AND (p_contract_id   IS NULL OR ca.contract_id   = p_contract_id)
      AND (p_fiscal_year   IS NULL OR ca.fiscal_year   = p_fiscal_year)
      AND (p_cost_category IS NULL OR ca.cost_category = p_cost_category)
      AND (p_period_label  IS NULL OR ca.period_label  = p_period_label)
    ORDER BY ca.period_label, ca.cost_category
    LIMIT v_limit OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object(
    'data',       v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', CEIL(v_total::FLOAT / v_limit)::INTEGER
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_contract_cost_actual_list: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_contract_cost_actual_list(BIGINT, BIGINT, INTEGER, TEXT, VARCHAR, INTEGER, INTEGER) IS
  'CR-N M21: Paginated actual-spend lines with optional filters by contract/FY/category/period. STABLE INVOKER. DB-layer gate: finance.budget.read (DEFECT-CRN-DB-01 fix, mig 307).';
REVOKE EXECUTE ON FUNCTION fn_contract_cost_actual_list(BIGINT, BIGINT, INTEGER, TEXT, VARCHAR, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_cost_actual_list(BIGINT, BIGINT, INTEGER, TEXT, VARCHAR, INTEGER, INTEGER) TO neondb_owner;

-- ============================================================
-- 4. fn_budget_burn_compute — add permission gate at top
-- Body otherwise byte-for-byte from mig 306 (STABLE INVOKER, DEFECT-298-1 fixed)
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
  -- Permission gate: finance.budget.read required (DEFECT-CRN-DB-01 fix)
  IF NOT fn_current_user_has_permission('finance.budget.read') THEN
    RAISE EXCEPTION 'Insufficient permission: finance.budget.read required'
      USING ERRCODE = '42501';
  END IF;

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

  -- Cumulative burn — FIX-298-1: pre-compute running sums in cum_burn CTE, then jsonb_agg
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
    SELECT period_label,
           SUM(actual_aed)  OVER (ORDER BY period_label ROWS UNBOUNDED PRECEDING) AS cumulative_actual_aed,
           SUM(budget_aed)  OVER (ORDER BY period_label ROWS UNBOUNDED PRECEDING) AS cumulative_budget_aed
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
  'CR-N M21: Per-period x category budget-vs-actual, variance, cumulative burn for one contract. STABLE INVOKER. DB-layer gate: finance.budget.read (DEFECT-CRN-DB-01 fix, mig 307). FIX-298-1: cumulative running sum in cum_burn CTE (mig 306).';
REVOKE EXECUTE ON FUNCTION fn_budget_burn_compute(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_burn_compute(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- 5. fn_budget_variance_for_contract — add permission gate at top
-- Body otherwise byte-for-byte from mig 306 (STABLE INVOKER, DEFECT-298-2 fixed)
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
  -- Permission gate: finance.budget.read required (DEFECT-CRN-DB-01 fix)
  IF NOT fn_current_user_has_permission('finance.budget.read') THEN
    RAISE EXCEPTION 'Insufficient permission: finance.budget.read required'
      USING ERRCODE = '42501';
  END IF;

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
  -- S2-24: budget_monthly / actual_month / joined CTEs (split-aggregate)
  WITH budget_q AS (
    SELECT period_label AS quarter_label, cost_category, fiscal_year,
           SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget
    WHERE contract_id = p_contract_id AND is_active = TRUE
    GROUP BY period_label, cost_category, fiscal_year
  ),
  budget_monthly AS (
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
    SELECT period_label, cost_category, fiscal_year,
           SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual
    WHERE contract_id = p_contract_id AND is_active = TRUE AND period_type = 'month'
    GROUP BY period_label, cost_category, fiscal_year
  ),
  joined AS (
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
  'CR-N M21: List (period, category) month-level breaches vs pro-rated monthly budget. FIX-298-2: month-grain comparison (mig 306). STABLE INVOKER. DB-layer gate: finance.budget.read (DEFECT-CRN-DB-01 fix, mig 307).';
REVOKE EXECUTE ON FUNCTION fn_budget_variance_for_contract(BIGINT, BIGINT, NUMERIC) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_variance_for_contract(BIGINT, BIGINT, NUMERIC) TO neondb_owner;

-- ============================================================
-- 6. fn_budget_year_end_projection — add permission gate at top
-- Body otherwise byte-for-byte from mig 298 (STABLE INVOKER)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_budget_year_end_projection(
  p_actor_id      BIGINT,
  p_contract_id   BIGINT,
  p_as_of_period  VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_contract_exists   BOOLEAN;
  v_as_of_period      TEXT;
  v_fiscal_year       INTEGER;
  v_months_elapsed    INTEGER;
  v_months_remaining  INTEGER;
  v_actual_to_date    NUMERIC(18,2);
  v_run_rate          NUMERIC(18,2);
  v_projected_ye      NUMERIC(18,2);
  v_allocated_fy      NUMERIC(18,2);
  v_projected_ou      NUMERIC(18,2);
  v_projected_ou_pct  NUMERIC;
  v_confidence        TEXT;
BEGIN
  -- Permission gate: finance.budget.read required (DEFECT-CRN-DB-01 fix)
  IF NOT fn_current_user_has_permission('finance.budget.read') THEN
    RAISE EXCEPTION 'Insufficient permission: finance.budget.read required'
      USING ERRCODE = '42501';
  END IF;

  IF p_contract_id IS NULL THEN
    RAISE EXCEPTION 'contractId is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS(SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE)
  INTO v_contract_exists;
  IF NOT v_contract_exists THEN RETURN NULL; END IF;

  -- as_of = param or latest period with actuals
  IF p_as_of_period IS NOT NULL THEN
    v_as_of_period := p_as_of_period;
  ELSE
    SELECT MAX(period_label) INTO v_as_of_period
    FROM contract_cost_actual
    WHERE contract_id = p_contract_id AND is_active = TRUE AND period_type = 'month';
  END IF;

  -- fiscal_year from as_of_period
  IF v_as_of_period IS NOT NULL THEN
    v_fiscal_year := SUBSTRING(v_as_of_period FROM 1 FOR 4)::INTEGER;
  ELSE
    v_fiscal_year := EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER;
  END IF;

  -- S2-24: each SUM/COUNT in its own CTE
  WITH months_cte AS (
    SELECT COUNT(DISTINCT period_label)::INTEGER AS elapsed
    FROM contract_cost_actual
    WHERE contract_id = p_contract_id AND is_active = TRUE
      AND period_type = 'month'
      AND fiscal_year = v_fiscal_year
      AND (v_as_of_period IS NULL OR period_label <= v_as_of_period)
  ),
  actual_cte AS (
    SELECT COALESCE(SUM(actual_amount_aed), 0)::NUMERIC(18,2) AS total
    FROM contract_cost_actual
    WHERE contract_id = p_contract_id AND is_active = TRUE
      AND period_type = 'month'
      AND fiscal_year = v_fiscal_year
      AND (v_as_of_period IS NULL OR period_label <= v_as_of_period)
  ),
  budget_cte AS (
    SELECT COALESCE(SUM(allocated_amount_aed), 0)::NUMERIC(18,2) AS total
    FROM contract_budget
    WHERE contract_id = p_contract_id AND is_active = TRUE
      AND fiscal_year = v_fiscal_year
  )
  SELECT m.elapsed, a.total, b.total
  INTO v_months_elapsed, v_actual_to_date, v_allocated_fy
  FROM months_cte m, actual_cte a, budget_cte b;

  v_months_remaining := 12 - COALESCE(v_months_elapsed, 0);

  IF COALESCE(v_months_elapsed, 0) = 0 THEN
    RETURN jsonb_build_object(
      'contractId',            p_contract_id,
      'fiscalYear',            v_fiscal_year,
      'asOfPeriod',            v_as_of_period,
      'monthsElapsed',         0,
      'monthsRemaining',       12,
      'actualToDateAed',       NULL,
      'runRatePerMonthAed',    NULL,
      'projectedYearEndAed',   NULL,
      'allocatedFyAed',        COALESCE(v_allocated_fy, 0)::text,
      'projectedOverUnderAed', NULL,
      'projectedOverUnderPct', NULL,
      'isProjectedOverBudget', NULL,
      'confidenceNote',        'insufficient_data'
    );
  END IF;

  v_run_rate     := ROUND((v_actual_to_date / v_months_elapsed)::NUMERIC, 2);
  v_projected_ye := ROUND((v_actual_to_date + v_run_rate * v_months_remaining)::NUMERIC, 2);
  v_projected_ou := ROUND((v_projected_ye - COALESCE(v_allocated_fy, 0))::NUMERIC, 2);

  v_projected_ou_pct := CASE WHEN COALESCE(v_allocated_fy, 0) > 0
                              THEN ROUND((v_projected_ou / v_allocated_fy * 100)::NUMERIC, 2)
                              ELSE NULL END;

  v_confidence := CASE
    WHEN v_months_elapsed >= 6 THEN 'high'
    WHEN v_months_elapsed >= 3 THEN 'medium'
    ELSE 'low'
  END;

  RETURN jsonb_build_object(
    'contractId',            p_contract_id,
    'fiscalYear',            v_fiscal_year,
    'asOfPeriod',            v_as_of_period,
    'monthsElapsed',         v_months_elapsed,
    'monthsRemaining',       v_months_remaining,
    'actualToDateAed',       v_actual_to_date::text,
    'runRatePerMonthAed',    v_run_rate::text,
    'projectedYearEndAed',   v_projected_ye::text,
    'allocatedFyAed',        COALESCE(v_allocated_fy, 0)::text,
    'projectedOverUnderAed', v_projected_ou::text,
    'projectedOverUnderPct', v_projected_ou_pct,
    'isProjectedOverBudget', (v_projected_ou > 0),
    'confidenceNote',        v_confidence
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_budget_year_end_projection: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_budget_year_end_projection(BIGINT, BIGINT, VARCHAR) IS
  'CR-N M21: Run-rate extrapolation, projected FY-end spend vs allocated budget. STABLE INVOKER. Returns NULL if contract absent; insufficient_data when monthsElapsed=0. DB-layer gate: finance.budget.read (DEFECT-CRN-DB-01 fix, mig 307).';
REVOKE EXECUTE ON FUNCTION fn_budget_year_end_projection(BIGINT, BIGINT, VARCHAR) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_year_end_projection(BIGINT, BIGINT, VARCHAR) TO neondb_owner;

-- ============================================================
-- 7. fn_budget_burn_portfolio — add permission gate at top
-- Body otherwise byte-for-byte from mig 298 (STABLE INVOKER)
-- ============================================================

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
BEGIN
  -- Permission gate: finance.budget.read required (DEFECT-CRN-DB-01 fix)
  IF NOT fn_current_user_has_permission('finance.budget.read') THEN
    RAISE EXCEPTION 'Insufficient permission: finance.budget.read required'
      USING ERRCODE = '42501';
  END IF;

  v_fiscal_year      := COALESCE((p_filters->>'fiscalYear')::INTEGER, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);
  v_min_variance_pct := (p_filters->>'minVariancePct')::NUMERIC;
  v_cost_category    := p_filters->>'costCategory';
  v_page             := GREATEST(COALESCE((p_filters->>'page')::INTEGER, 1), 1);
  v_limit            := LEAST(GREATEST(COALESCE((p_filters->>'limit')::INTEGER, 20), 1), 100);
  v_offset           := (v_page - 1) * v_limit;

  -- S2-24: budget_by_contract and actual_by_contract are separate CTEs
  WITH budget_by_contract AS (
    SELECT contract_id,
           SUM(allocated_amount_aed) AS budget_aed
    FROM contract_budget
    WHERE is_active = TRUE
      AND fiscal_year = v_fiscal_year
      AND (v_cost_category IS NULL OR cost_category = v_cost_category)
    GROUP BY contract_id
  ),
  actual_by_contract AS (
    SELECT contract_id,
           SUM(actual_amount_aed) AS actual_aed
    FROM contract_cost_actual
    WHERE is_active = TRUE
      AND fiscal_year = v_fiscal_year
      AND period_type = 'month'
      AND (v_cost_category IS NULL OR cost_category = v_cost_category)
    GROUP BY contract_id
  ),
  joined AS (
    SELECT bbc.contract_id,
           bbc.budget_aed,
           COALESCE(abc.actual_aed, 0) AS actual_aed,
           COALESCE(abc.actual_aed, 0) - bbc.budget_aed AS variance_aed,
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
    COALESCE(SUM(CASE WHEN actual_aed > budget_aed THEN variance_aed ELSE 0 END), 0)::NUMERIC(18,2)
  INTO v_total, v_total_budget_aed, v_total_actual_aed, v_over_budget_count, v_proj_overrun
  FROM contract_rows;

  -- Paginated data
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
    SELECT bbc.contract_id, bbc.budget_aed, COALESCE(abc.actual_aed, 0) AS actual_aed,
           COALESCE(abc.actual_aed, 0) - bbc.budget_aed AS variance_aed,
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
      'projectedOverUnderAed', j.variance_aed::text,
      'varianceFlag',          (j.actual_aed > j.budget_aed)
    ) AS row_data
    FROM joined j
    JOIN contract c ON c.id = j.contract_id AND c.is_active = TRUE
    LEFT JOIN party cp ON cp.id = c.counterparty_id
    ORDER BY j.variance_pct DESC NULLS LAST
    LIMIT v_limit OFFSET v_offset
  ) sub;

  -- Top over-budget (up to 10, no pagination)
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
      'projectedOverUnderAed', (COALESCE(abc.actual_aed, 0) - bbc.budget_aed)::text,
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
                       'contractsWithBudget',      COALESCE(v_total, 0),
                       'totalBudgetAed',           COALESCE(v_total_budget_aed, 0)::text,
                       'totalActualAed',           COALESCE(v_total_actual_aed, 0)::text,
                       'totalVarianceAed',         (COALESCE(v_total_actual_aed, 0) - COALESCE(v_total_budget_aed, 0))::text,
                       'overBudgetCount',          COALESCE(v_over_budget_count, 0),
                       'totalProjectedOverrunAed', COALESCE(v_proj_overrun, 0)::text
                     ),
    'topOverBudget', COALESCE(v_top_over_budget, '[]'::jsonb),
    'data',          COALESCE(v_data, '[]'::jsonb),
    'pagination',    jsonb_build_object(
                       'total',      COALESCE(v_total, 0),
                       'page',       v_page,
                       'limit',      v_limit,
                       'totalPages', CASE WHEN COALESCE(v_total, 0) > 0 THEN CEIL(v_total::FLOAT / v_limit)::INTEGER ELSE 0 END
                     )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_budget_burn_portfolio: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_budget_burn_portfolio(BIGINT, JSONB) IS
  'CR-N M21: Portfolio rollup across all budgeted contracts (finance + executive). S2-24: split-aggregate CTEs. Never returns NULL. STABLE INVOKER. DB-layer gate: finance.budget.read (DEFECT-CRN-DB-01 fix, mig 307).';
REVOKE EXECUTE ON FUNCTION fn_budget_burn_portfolio(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_burn_portfolio(BIGINT, JSONB) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (307, '307_crn_fix_defect_db01_add_read_permission_gate', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- Re-apply mig 306 bodies for fn_budget_burn_compute / fn_budget_variance_for_contract
-- Re-apply mig 298 bodies for fn_contract_budget_list / fn_contract_budget_get /
--   fn_contract_cost_actual_list / fn_budget_year_end_projection / fn_budget_burn_portfolio
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 307;
-- COMMIT;
-- ============================================================
