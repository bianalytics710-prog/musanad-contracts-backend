-- Migration: 304_crn_seed_budget_and_actuals.sql
-- Module: CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half)
-- Description: Seed contract_budget (quarterly × 4 categories for HERO-001/002/003) +
--              contract_cost_actual (monthly 4 months HERO-001; 3 months HERO-002/003).
--              HERO-001 month-4 day_rate = plan × 1.08 (+8% — triggers 5% threshold breach).
--              Expected counts: budget 52 rows; actuals 40 rows.
--              Tenant GUC set before INSERT (mig 143 pattern).
--              reference_no NOT NULL DEFAULT '' — explicit refs for idempotency.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Set tenant GUC (required by RLS FORCE policies on both new tables)
SELECT set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', false);

DO $$
DECLARE
  v_tenant_id UUID   := '00000000-0000-0000-0000-000000000001';
  v_seed_user BIGINT;
  v_hero1_id  BIGINT;
  v_hero2_id  BIGINT;
  v_hero3_id  BIGINT;

BEGIN
  SELECT MIN(id) INTO v_seed_user FROM "user" WHERE is_active = TRUE;
  SELECT id INTO v_hero1_id FROM contract WHERE contract_number = 'CRN-296-HERO-001';
  SELECT id INTO v_hero2_id FROM contract WHERE contract_number = 'CRN-296-HERO-002';
  SELECT id INTO v_hero3_id FROM contract WHERE contract_number = 'CRN-296-HERO-003';

  IF v_hero1_id IS NULL THEN
    RAISE EXCEPTION 'HERO-001 contract not found — ensure migration 303 has been applied'
      USING ERRCODE = 'P0002';
  END IF;

  -- Also set the permission GUC so RLS policies pass for this SECURITY INVOKER context
  -- During migration (run as neondb_owner which is BYPASSRLS), RLS is bypassed for owner.
  -- We still set the GUC for completeness/audit consistency.
  PERFORM set_config('app.current_user_id', v_seed_user::text, false);

  -- ==============================================================
  -- HERO-001: contract_budget (20 rows: 16 FY2026 + 4 FY2025 Q4)
  -- Per-quarter total AED 211,250,000; FY2026 total AED 845,000,000
  -- ==============================================================

  INSERT INTO contract_budget (
    tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, allocated_amount_aed, currency, source, data_classification,
    created_by, updated_by, is_active, created_at, updated_at
  ) VALUES
    -- FY2026 Q1
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q1', 2026, 'day_rate',   133000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q1', 2026, 'manpower',    50000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q1', 2026, 'equipment',   20000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q1', 2026, 'milestone',    8250000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- FY2026 Q2
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q2', 2026, 'day_rate',   133000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q2', 2026, 'manpower',    50000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q2', 2026, 'equipment',   20000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q2', 2026, 'milestone',    8250000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- FY2026 Q3
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q3', 2026, 'day_rate',   133000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q3', 2026, 'manpower',    50000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q3', 2026, 'equipment',   20000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q3', 2026, 'milestone',    8250000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- FY2026 Q4
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q4', 2026, 'day_rate',   133000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q4', 2026, 'manpower',    50000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q4', 2026, 'equipment',   20000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2026-Q4', 2026, 'milestone',    8250000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- Prior period FY2025 Q4 (history)
    (v_tenant_id, v_hero1_id, 'quarter', '2025-Q4', 2025, 'day_rate',   133000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2025-Q4', 2025, 'manpower',    50000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2025-Q4', 2025, 'equipment',   20000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'quarter', '2025-Q4', 2025, 'milestone',    8250000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW())
  ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
    allocated_amount_aed = EXCLUDED.allocated_amount_aed,
    updated_at           = NOW(),
    updated_by           = EXCLUDED.updated_by;

  -- ==============================================================
  -- HERO-002: contract_budget (16 rows FY2026 × 4 quarters × 4 categories)
  -- FY2026 total AED 36,000,000 (~AED 9,000,000/quarter)
  -- ==============================================================
  IF v_hero2_id IS NOT NULL THEN
    INSERT INTO contract_budget (
      tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, allocated_amount_aed, currency, source, data_classification,
      created_by, updated_by, is_active, created_at, updated_at
    ) VALUES
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q1', 2026, 'day_rate',  5400000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q1', 2026, 'manpower',  2100000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q1', 2026, 'equipment', 1000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q1', 2026, 'milestone',  500000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q2', 2026, 'day_rate',  5400000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q2', 2026, 'manpower',  2100000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q2', 2026, 'equipment', 1000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q2', 2026, 'milestone',  500000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q3', 2026, 'day_rate',  5400000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q3', 2026, 'manpower',  2100000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q3', 2026, 'equipment', 1000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q3', 2026, 'milestone',  500000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q4', 2026, 'day_rate',  5400000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q4', 2026, 'manpower',  2100000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q4', 2026, 'equipment', 1000000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'quarter', '2026-Q4', 2026, 'milestone',  500000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW())
    ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
      allocated_amount_aed = EXCLUDED.allocated_amount_aed,
      updated_at = NOW(), updated_by = EXCLUDED.updated_by;
  END IF;

  -- ==============================================================
  -- HERO-003: contract_budget (16 rows FY2026 × 4 quarters × 4 categories)
  -- FY2026 total AED 19,000,000 (~AED 4,750,000/quarter)
  -- ==============================================================
  IF v_hero3_id IS NOT NULL THEN
    INSERT INTO contract_budget (
      tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, allocated_amount_aed, currency, source, data_classification,
      created_by, updated_by, is_active, created_at, updated_at
    ) VALUES
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q1', 2026, 'day_rate',  2375000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q1', 2026, 'manpower',  1425000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q1', 2026, 'equipment',  665000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q1', 2026, 'milestone',  285000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q2', 2026, 'day_rate',  2375000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q2', 2026, 'manpower',  1425000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q2', 2026, 'equipment',  665000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q2', 2026, 'milestone',  285000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q3', 2026, 'day_rate',  2375000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q3', 2026, 'manpower',  1425000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q3', 2026, 'equipment',  665000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q3', 2026, 'milestone',  285000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q4', 2026, 'day_rate',  2375000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q4', 2026, 'manpower',  1425000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q4', 2026, 'equipment',  665000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'quarter', '2026-Q4', 2026, 'milestone',  285000.00, 'AED', 'demo_seed', 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW())
    ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
      allocated_amount_aed = EXCLUDED.allocated_amount_aed,
      updated_at = NOW(), updated_by = EXCLUDED.updated_by;
  END IF;

  -- ==============================================================
  -- HERO-001: contract_cost_actual (16 rows — 4 months × 4 categories)
  -- Month-4 day_rate = 47,880,000 (+8% — breaches 5% threshold)
  -- Monthly plan = 532,000,000 / 12 = 44,333,333 (rounded)
  -- ==============================================================

  INSERT INTO contract_cost_actual (
    tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, actual_amount_aed, currency, source, reference_no,
    recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at
  ) VALUES
    -- 2026-01: on plan
    (v_tenant_id, v_hero1_id, 'month', '2026-01', 2026, 'day_rate',   44333333.00, 'AED', 'erp_feed', 'ERP-HERO1-202601-DR', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-01', 2026, 'manpower',   16666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202601-MP', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-01', 2026, 'equipment',   6666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202601-EQ', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-01', 2026, 'milestone',   2750000.00, 'AED', 'erp_feed', 'ERP-HERO1-202601-MS', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- 2026-02: on plan
    (v_tenant_id, v_hero1_id, 'month', '2026-02', 2026, 'day_rate',   44333333.00, 'AED', 'erp_feed', 'ERP-HERO1-202602-DR', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-02', 2026, 'manpower',   16666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202602-MP', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-02', 2026, 'equipment',   6666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202602-EQ', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-02', 2026, 'milestone',   2750000.00, 'AED', 'erp_feed', 'ERP-HERO1-202602-MS', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- 2026-03: on plan
    (v_tenant_id, v_hero1_id, 'month', '2026-03', 2026, 'day_rate',   44333333.00, 'AED', 'erp_feed', 'ERP-HERO1-202603-DR', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-03', 2026, 'manpower',   16666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202603-MP', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-03', 2026, 'equipment',   6666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202603-EQ', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-03', 2026, 'milestone',   2750000.00, 'AED', 'erp_feed', 'ERP-HERO1-202603-MS', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- 2026-04: day_rate +8% overrun (47,880,000 vs 44,333,333 plan = +8.00%)
    (v_tenant_id, v_hero1_id, 'month', '2026-04', 2026, 'day_rate',   47880000.00, 'AED', 'erp_feed', 'ERP-HERO1-202604-DR', '2026-04-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-04', 2026, 'manpower',   16666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202604-MP', '2026-04-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-04', 2026, 'equipment',   6666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202604-EQ', '2026-04-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-04', 2026, 'milestone',   2750000.00, 'AED', 'erp_feed', 'ERP-HERO1-202604-MS', '2026-04-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW())
  ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
    actual_amount_aed = EXCLUDED.actual_amount_aed,
    recorded_at       = EXCLUDED.recorded_at,
    updated_at        = NOW(),
    updated_by        = EXCLUDED.updated_by;

  -- ==============================================================
  -- HERO-002: contract_cost_actual (12 rows — 3 months × 4 categories, on plan)
  -- Monthly total AED 3,000,000 = day_rate 1.8M + manpower 0.7M + equipment 0.333M + milestone 0.167M
  -- ==============================================================
  IF v_hero2_id IS NOT NULL THEN
    INSERT INTO contract_cost_actual (
      tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at
    ) VALUES
      (v_tenant_id, v_hero2_id, 'month', '2026-01', 2026, 'day_rate',  1800000.00, 'AED', 'erp_feed', 'ERP-HERO2-202601-DR', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'month', '2026-01', 2026, 'manpower',   700000.00, 'AED', 'erp_feed', 'ERP-HERO2-202601-MP', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'month', '2026-01', 2026, 'equipment',  333333.00, 'AED', 'erp_feed', 'ERP-HERO2-202601-EQ', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'month', '2026-01', 2026, 'milestone',  166667.00, 'AED', 'erp_feed', 'ERP-HERO2-202601-MS', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'month', '2026-02', 2026, 'day_rate',  1800000.00, 'AED', 'erp_feed', 'ERP-HERO2-202602-DR', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'month', '2026-02', 2026, 'manpower',   700000.00, 'AED', 'erp_feed', 'ERP-HERO2-202602-MP', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'month', '2026-02', 2026, 'equipment',  333333.00, 'AED', 'erp_feed', 'ERP-HERO2-202602-EQ', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'month', '2026-02', 2026, 'milestone',  166667.00, 'AED', 'erp_feed', 'ERP-HERO2-202602-MS', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'month', '2026-03', 2026, 'day_rate',  1800000.00, 'AED', 'erp_feed', 'ERP-HERO2-202603-DR', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'month', '2026-03', 2026, 'manpower',   700000.00, 'AED', 'erp_feed', 'ERP-HERO2-202603-MP', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'month', '2026-03', 2026, 'equipment',  333333.00, 'AED', 'erp_feed', 'ERP-HERO2-202603-EQ', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero2_id, 'month', '2026-03', 2026, 'milestone',  166667.00, 'AED', 'erp_feed', 'ERP-HERO2-202603-MS', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed = EXCLUDED.actual_amount_aed,
      recorded_at = EXCLUDED.recorded_at, updated_at = NOW(), updated_by = EXCLUDED.updated_by;
  END IF;

  -- ==============================================================
  -- HERO-003: contract_cost_actual (12 rows — 3 months × 4 categories, on plan)
  -- Monthly total AED ~1,583,333 = day_rate 791,667 + manpower 475,000 + equip 221,667 + milestone 95,000
  -- ==============================================================
  IF v_hero3_id IS NOT NULL THEN
    INSERT INTO contract_cost_actual (
      tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at
    ) VALUES
      (v_tenant_id, v_hero3_id, 'month', '2026-01', 2026, 'day_rate',  791667.00, 'AED', 'erp_feed', 'ERP-HERO3-202601-DR', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'month', '2026-01', 2026, 'manpower',  475000.00, 'AED', 'erp_feed', 'ERP-HERO3-202601-MP', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'month', '2026-01', 2026, 'equipment', 221667.00, 'AED', 'erp_feed', 'ERP-HERO3-202601-EQ', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'month', '2026-01', 2026, 'milestone',  95000.00, 'AED', 'erp_feed', 'ERP-HERO3-202601-MS', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'month', '2026-02', 2026, 'day_rate',  791667.00, 'AED', 'erp_feed', 'ERP-HERO3-202602-DR', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'month', '2026-02', 2026, 'manpower',  475000.00, 'AED', 'erp_feed', 'ERP-HERO3-202602-MP', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'month', '2026-02', 2026, 'equipment', 221667.00, 'AED', 'erp_feed', 'ERP-HERO3-202602-EQ', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'month', '2026-02', 2026, 'milestone',  95000.00, 'AED', 'erp_feed', 'ERP-HERO3-202602-MS', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'month', '2026-03', 2026, 'day_rate',  791667.00, 'AED', 'erp_feed', 'ERP-HERO3-202603-DR', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'month', '2026-03', 2026, 'manpower',  475000.00, 'AED', 'erp_feed', 'ERP-HERO3-202603-MP', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'month', '2026-03', 2026, 'equipment', 221667.00, 'AED', 'erp_feed', 'ERP-HERO3-202603-EQ', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
      (v_tenant_id, v_hero3_id, 'month', '2026-03', 2026, 'milestone',  95000.00, 'AED', 'erp_feed', 'ERP-HERO3-202603-MS', NOW(), 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed = EXCLUDED.actual_amount_aed,
      recorded_at = EXCLUDED.recorded_at, updated_at = NOW(), updated_by = EXCLUDED.updated_by;
  END IF;

END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (304, '304_crn_seed_budget_and_actuals', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM contract_cost_actual
--   WHERE contract_id IN (SELECT id FROM contract WHERE contract_number IN ('CRN-296-HERO-001','CRN-296-HERO-002','CRN-296-HERO-003'));
-- DELETE FROM contract_budget
--   WHERE contract_id IN (SELECT id FROM contract WHERE contract_number IN ('CRN-296-HERO-001','CRN-296-HERO-002','CRN-296-HERO-003'));
-- DELETE FROM schema_migrations WHERE version = 304;
-- COMMIT;
-- ============================================================
