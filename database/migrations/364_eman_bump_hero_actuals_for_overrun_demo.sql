-- Migration: 364_eman_bump_hero_actuals_for_overrun_demo.sql
-- Unit: Eman Executive QA Phase 3.4 (2026-05-31)
-- Fix:
--   E13/E37 follow-up — The BE projection (projectedOverUnderAed) uses a
--   simplistic full-year run-rate that for HERO-001 still returns under
--   budget, even though the demo narrative says HERO-001 has a +13%
--   variance spike in 2026-07 → year-end overrun. To make the row truly
--   demo-credible, bump HERO-001's 2026-07 actuals so the projection
--   crosses into positive territory. Also bump 2 other contracts so the
--   new "Trending over" badge has a small cohort of rows to surface.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
  v_hero BIGINT;
  v_drl BIGINT;
  v_ons BIGINT;
BEGIN
  SELECT id INTO v_hero FROM contract WHERE contract_number = 'CRN-296-HERO-001';
  SELECT id INTO v_drl  FROM contract WHERE contract_number = 'CRQ-DRL-001';
  SELECT id INTO v_ons  FROM contract WHERE contract_number = 'CRQ-ONS-030';

  IF v_hero IS NULL THEN
    RAISE NOTICE 'Skipping HERO-001 actuals bump — contract not present.';
    RETURN;
  END IF;

  -- HERO-001 — single +AED 95M July spike row to lift projection over budget.
  INSERT INTO contract_cost_actual
    (tenant_id, contract_id, fiscal_year, period_type, period_label,
     cost_category, actual_amount_aed, currency, source, reference_no, recorded_at,
     data_classification, created_by, updated_by, is_active, notes)
  SELECT v_tenant, v_hero, 2026, 'month', '2026-07',
         'day_rate', 95000000.00, 'AED', 'manual', 'E13-HERO-001-JUL26', NOW(),
         'demo', 1, 1, TRUE,
         'E13 seed: +13% July variance breach pushing year-end projection over budget'
  WHERE NOT EXISTS (
    SELECT 1 FROM contract_cost_actual
    WHERE contract_id = v_hero AND reference_no = 'E13-HERO-001-JUL26'
  );

  IF v_drl IS NOT NULL THEN
    INSERT INTO contract_cost_actual
      (tenant_id, contract_id, fiscal_year, period_type, period_label,
       cost_category, actual_amount_aed, currency, source, reference_no, recorded_at,
       data_classification, created_by, updated_by, is_active, notes)
    SELECT v_tenant, v_drl, 2026, 'month', '2026-07',
           'day_rate', 80000000.00, 'AED', 'manual', 'E13-DRL-001-JUL26', NOW(),
           'demo', 1, 1, TRUE,
           'E13 seed: scope-creep absorption pushing projection over budget'
    WHERE NOT EXISTS (
      SELECT 1 FROM contract_cost_actual
      WHERE contract_id = v_drl AND reference_no = 'E13-DRL-001-JUL26'
    );
  END IF;

  IF v_ons IS NOT NULL THEN
    INSERT INTO contract_cost_actual
      (tenant_id, contract_id, fiscal_year, period_type, period_label,
       cost_category, actual_amount_aed, currency, source, reference_no, recorded_at,
       data_classification, created_by, updated_by, is_active, notes)
    SELECT v_tenant, v_ons, 2026, 'month', '2026-07',
           'manpower', 45000000.00, 'AED', 'manual', 'E13-ONS-030-JUL26', NOW(),
           'demo', 1, 1, TRUE,
           'E13 seed: catering scope expansion pushing projection over budget'
    WHERE NOT EXISTS (
      SELECT 1 FROM contract_cost_actual
      WHERE contract_id = v_ons AND reference_no = 'E13-ONS-030-JUL26'
    );
  END IF;
END $$;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM contract_cost_actual WHERE source = 'manual';
-- ============================================================
