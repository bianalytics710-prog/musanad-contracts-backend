-- Migration: 367_fatima_projection_and_variance.sql
-- Unit: Fatima Finance QA Phase 3.5 (F1-F80 audit pass)
-- Targets:
--   F31/F37   HERO-001 variance alert (was "+464.1% in 2026-07" vs demo +13%).
--             The mig 364 +95M July spike overshot the demo narrative — reduce
--             to ~+20M so monthly variance lands near +13% while keeping the
--             year-end projection still over budget.
--   F33/F34   fn_budget_year_end_projection — cap `as_of_period` at the
--             current month so future-month actuals don't push the projection
--             header into "as of 2026-10" when today is 2026-05.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
  v_hero   BIGINT;
BEGIN
  SELECT id INTO v_hero FROM contract WHERE contract_number = 'CRN-296-HERO-001';
  IF v_hero IS NULL THEN
    RAISE NOTICE 'mig 367: HERO-001 absent, skipping.';
    RETURN;
  END IF;

  -- F31/F37 — reduce the +95M July spike (mig 364) toward the demo narrative.
  -- Existing E13 row has reference_no = 'E13-HERO-001-JUL26' and amount 95M.
  -- Bring it down to 20M (≈ +13% monthly variance against ~17.6M monthly
  -- day_rate budget). Year-end projection still surfaces over budget because
  -- the cumulative actuals across the rest of the FY stay elevated.
  UPDATE contract_cost_actual
     SET actual_amount_aed = 20000000.00,
         notes = 'F31/F37 calibration — Jul-26 day-rate spike reduced to match +13% demo narrative.',
         updated_at = NOW()
   WHERE contract_id = v_hero
     AND reference_no = 'E13-HERO-001-JUL26'
     AND period_label = '2026-07'
     AND cost_category = 'day_rate';

  RAISE NOTICE 'mig 367: HERO-001 July spike calibrated.';
END $$;

-- F33/F34 — Cap as_of_period at the current month so the projection header
-- never reads as a future month when the seed data has rows past now().
-- Approach: replace fn_budget_year_end_projection with a body that takes
-- MIN(MAX(period_label), TO_CHAR(NOW(), 'YYYY-MM')) as v_as_of_period.

CREATE OR REPLACE FUNCTION fn_budget_year_end_projection(
  p_actor_id       BIGINT,
  p_contract_id    BIGINT,
  p_as_of_period   VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_contract_exists  BOOLEAN;
  v_as_of_period     TEXT;
  v_current_period   TEXT;
  v_fiscal_year      INTEGER;
  v_months_elapsed   INTEGER;
  v_months_remaining INTEGER;
  v_actual_to_date   NUMERIC(18,2);
  v_allocated_fy     NUMERIC(18,2);
  v_run_rate         NUMERIC(18,2);
  v_projected_ye     NUMERIC(18,2);
  v_over_under       NUMERIC(18,2);
  v_over_under_pct   NUMERIC(10,2);
  v_confidence       TEXT;
BEGIN
  -- Permission gate: finance.budget.read or executive read scope
  IF NOT (
    fn_current_user_has_permission('finance.budget.read')
    OR fn_current_user_has_permission('insights.executive')
    OR fn_current_user_has_permission('insights.finance_treasury')
    OR fn_current_user_has_permission('contract.read.all')
  ) THEN
    RAISE EXCEPTION 'permission_denied: finance.budget.read required'
      USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS(SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE)
  INTO v_contract_exists;
  IF NOT v_contract_exists THEN RETURN NULL; END IF;

  -- F33/F34 — current month becomes a hard cap on as_of_period.
  v_current_period := TO_CHAR(NOW(), 'YYYY-MM');

  IF p_as_of_period IS NOT NULL THEN
    v_as_of_period := p_as_of_period;
  ELSE
    SELECT LEAST(MAX(period_label), v_current_period)
      INTO v_as_of_period
      FROM contract_cost_actual
     WHERE contract_id = p_contract_id
       AND is_active = TRUE
       AND period_type = 'month'
       AND period_label <= v_current_period;
  END IF;

  IF v_as_of_period IS NOT NULL THEN
    v_fiscal_year := SUBSTRING(v_as_of_period FROM 1 FOR 4)::INTEGER;
  ELSE
    v_fiscal_year := EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER;
  END IF;

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
  v_projected_ye := ROUND((v_run_rate * 12)::NUMERIC, 2);
  v_over_under   := ROUND((v_projected_ye - v_allocated_fy)::NUMERIC, 2);
  v_over_under_pct := CASE WHEN v_allocated_fy > 0
                           THEN ROUND((v_over_under / v_allocated_fy * 100)::NUMERIC, 2)
                           ELSE NULL END;

  v_confidence := CASE
    WHEN v_months_elapsed < 3 THEN 'low'
    WHEN v_months_elapsed < 6 THEN 'medium'
    ELSE 'high'
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
    'allocatedFyAed',        v_allocated_fy::text,
    'projectedOverUnderAed', v_over_under::text,
    'projectedOverUnderPct', v_over_under_pct,
    'isProjectedOverBudget', (v_over_under > 0),
    'confidenceNote',        v_confidence
  );
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_budget_year_end_projection: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_budget_year_end_projection(BIGINT, BIGINT, VARCHAR) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_year_end_projection(BIGINT, BIGINT, VARCHAR) TO neondb_owner;
COMMENT ON FUNCTION fn_budget_year_end_projection(BIGINT, BIGINT, VARCHAR) IS
  'Budget burn year-end projection. v367 (F33/F34): caps as_of_period at TO_CHAR(NOW(),''YYYY-MM'') so future-month actuals never push the projection header beyond today. Args: (actor_id, contract_id, as_of_period?).';
