-- Migration: 308_crn_fix_variance_gate_for_cure_notice.sql
-- Module: CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half)
-- Description: Targeted fix to fn_budget_variance_for_contract permission gate (mig 307).
--              The draft-cure-notice service (POST /variance/:contractId/draft-cure-notice)
--              calls fn_budget_variance_for_contract as a legal_counsel actor who holds
--              advisory.draft.review but NOT finance.budget.read. Mig 307's single-permission
--              gate blocked this seam with 42501.
--
--              Fix: allow finance.budget.read OR advisory.draft.review — identical pattern to
--              fn_regulatory_cascade_item_link_draft (mig 289) which gates on
--              advisory.draft.review OR regulatory.cascade.run.
--
--              All other 6 read fn_'s keep the single finance.budget.read gate from mig 307
--              (only variance is called from the advisory-draft seam).
--
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- fn_budget_variance_for_contract — dual permission gate
-- Body identical to mig 307 except the permission check block.
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
  -- Permission gate: finance.budget.read OR advisory.draft.review (mig 308 fix)
  -- finance actors read variance directly; advisory-draft service calls this as legal_counsel.
  -- Pattern mirrors fn_regulatory_cascade_item_link_draft (mig 289).
  IF NOT fn_current_user_has_permission('finance.budget.read')
     AND NOT fn_current_user_has_permission('advisory.draft.review') THEN
    RAISE EXCEPTION 'Insufficient permission: finance.budget.read or advisory.draft.review required'
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

  -- DEFECT-298-2 FIX (mig 306): Compare MONTH actuals against pro-rated monthly budget
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
  'CR-N M21: List (period, category) month-level breaches vs pro-rated monthly budget. FIX-298-2 (mig 306). STABLE INVOKER. DB-layer gate: finance.budget.read OR advisory.draft.review (mig 308 — allows cure-notice seam via legal_counsel). Drafter (neither permission) still blocked 42501.';
REVOKE EXECUTE ON FUNCTION fn_budget_variance_for_contract(BIGINT, BIGINT, NUMERIC) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_variance_for_contract(BIGINT, BIGINT, NUMERIC) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (308, '308_crn_fix_variance_gate_for_cure_notice', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- Re-apply mig 307 fn_budget_variance_for_contract body (single finance.budget.read gate).
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 308;
-- COMMIT;
-- ============================================================
