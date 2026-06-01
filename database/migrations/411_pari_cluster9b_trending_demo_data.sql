-- Migration: 411_pari_cluster9b_trending_demo_data.sql
-- Unit: Pari Procurement QA Phase 3.7 (2026-06-01) — Cluster 9b / P40
-- Closes: P40 — After mig 410 exposed a real year-end projection, the FE 3-state badge can fire.
--         But the live data has no row in the "under today, projected over by year-end" sweet spot
--         (most under-budget contracts are at ~25-35% consumed mid-year, projecting ~50-70%).
--         Bump 2 contracts' YTD actuals so they sit at ~58% consumed today, projecting to ~120%
--         by year-end → the "Trending over" amber badge surfaces and the demo narrative
--         (HERO-001 over today + 2 more trending over) tells a richer story.
--
-- Idempotent: skip if either target already shows actuals > 50% of its budget.

BEGIN;

DO $$
DECLARE
  v_fiscal_year INTEGER := EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER;
  v_target_contract_1 BIGINT;  -- CRQ-OFF-001 — currently 34.7% consumed
  v_target_contract_2 BIGINT;  -- CRQ-ONS-001 — currently 33.6% consumed
  v_target_actual_1 NUMERIC;
  v_target_actual_2 NUMERIC;
  v_existing_actual_1 NUMERIC;
  v_existing_actual_2 NUMERIC;
  v_budget_1 NUMERIC;
  v_budget_2 NUMERIC;
BEGIN
  SELECT id INTO v_target_contract_1 FROM contract WHERE contract_number = 'CRQ-OFF-001' LIMIT 1;
  SELECT id INTO v_target_contract_2 FROM contract WHERE contract_number = 'CRQ-ONS-001' LIMIT 1;

  IF v_target_contract_1 IS NULL OR v_target_contract_2 IS NULL THEN
    RAISE NOTICE 'Skipping pari-trending-demo data bump — target contracts not present in this branch.';
    RETURN;
  END IF;

  SELECT SUM(allocated_amount_aed) INTO v_budget_1 FROM contract_budget
    WHERE contract_id = v_target_contract_1 AND fiscal_year = v_fiscal_year AND is_active = TRUE;
  SELECT SUM(allocated_amount_aed) INTO v_budget_2 FROM contract_budget
    WHERE contract_id = v_target_contract_2 AND fiscal_year = v_fiscal_year AND is_active = TRUE;
  SELECT COALESCE(SUM(actual_amount_aed), 0) INTO v_existing_actual_1 FROM contract_cost_actual
    WHERE contract_id = v_target_contract_1 AND fiscal_year = v_fiscal_year AND is_active = TRUE;
  SELECT COALESCE(SUM(actual_amount_aed), 0) INTO v_existing_actual_2 FROM contract_cost_actual
    WHERE contract_id = v_target_contract_2 AND fiscal_year = v_fiscal_year AND is_active = TRUE;

  -- Idempotency guard
  IF v_existing_actual_1 > v_budget_1 * 0.5 AND v_existing_actual_2 > v_budget_2 * 0.5 THEN
    RAISE NOTICE 'Pari trending-demo bump already applied (actuals exceed 50 pct on both targets). Skipping.';
    RETURN;
  END IF;

  -- Compute the top-up so target actual = ~58% of budget for both
  v_target_actual_1 := v_budget_1 * 0.58 - v_existing_actual_1;
  v_target_actual_2 := v_budget_2 * 0.58 - v_existing_actual_2;

  -- Insert a single "catch-up" actual row in the current month per contract.
  -- Schema (mig 297) requires: tenant_id, period_label, source, reference_no, cost_category IN
  -- ('day_rate','manpower','equipment','milestone','other'). Use 'manual' source + a unique
  -- pari-trending-XX reference so the idempotency UNIQUE (tenant, contract, period_label,
  -- cost_category, reference_no) doesn't collide if this migration is re-run.
  IF v_target_actual_1 > 0 THEN
    INSERT INTO contract_cost_actual (
      tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      data_classification, is_active, created_at, updated_at
    ) VALUES (
      '00000000-0000-0000-0000-000000000001'::UUID, v_target_contract_1, 'month',
      to_char(CURRENT_DATE, 'YYYY-MM'), v_fiscal_year,
      'milestone', v_target_actual_1, 'AED', 'manual', 'pari-trending-bump-411',
      'demo', TRUE, NOW(), NOW()
    )
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO NOTHING;
  END IF;

  IF v_target_actual_2 > 0 THEN
    INSERT INTO contract_cost_actual (
      tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      data_classification, is_active, created_at, updated_at
    ) VALUES (
      '00000000-0000-0000-0000-000000000001'::UUID, v_target_contract_2, 'month',
      to_char(CURRENT_DATE, 'YYYY-MM'), v_fiscal_year,
      'milestone', v_target_actual_2, 'AED', 'manual', 'pari-trending-bump-411',
      'demo', TRUE, NOW(), NOW()
    )
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO NOTHING;
  END IF;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (411, '411_pari_cluster9b_trending_demo_data', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
