-- Migration: 330_crq_seed_budget_tracked_contracts.sql
-- Module: CR-Q — ADNOC Data Scale-Up (v1.4 foundation)
-- Description: Seeds 10 additional budget-tracked contracts from the CRQ-% pool.
--              Picked contracts: CRQ-ONS-001 CRQ-ONS-010 CRQ-ONS-020 CRQ-ONS-030
--                                CRQ-OFF-001 CRQ-OFF-010 CRQ-DRL-001 CRQ-DRL-010
--                                CRQ-GAS-001 CRQ-AGT-001
--              Mix: 4 on-track (actuals ≤103% plan) · 4 mild overrun (105–108%) ·
--                   1 hero-like +7% day_rate breach · 1 buffer (on-track).
--              Each gets contract_budget (4 quarters FY2026 × 4 categories) +
--              contract_cost_actual (months 1–4; hero-like gets months 1–8).
--              Idempotent via ON CONFLICT ON CONSTRAINT.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

SELECT set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', false);

DO $$
DECLARE
  v_tenant_id UUID   := '00000000-0000-0000-0000-000000000001';
  v_seed_user BIGINT;

  -- Contract IDs (resolved by number)
  v_ons001 BIGINT; v_ons010 BIGINT; v_ons020 BIGINT; v_ons030 BIGINT;
  v_off001 BIGINT; v_off010 BIGINT;
  v_drl001 BIGINT; v_drl010 BIGINT;
  v_gas001 BIGINT;
  v_agt001 BIGINT;

BEGIN
  SELECT MIN(id) INTO v_seed_user FROM "user" WHERE is_active = TRUE;
  PERFORM set_config('app.current_user_id', v_seed_user::text, false);

  SELECT id INTO v_ons001 FROM contract WHERE contract_number = 'CRQ-ONS-001';
  SELECT id INTO v_ons010 FROM contract WHERE contract_number = 'CRQ-ONS-010';
  SELECT id INTO v_ons020 FROM contract WHERE contract_number = 'CRQ-ONS-020';
  SELECT id INTO v_ons030 FROM contract WHERE contract_number = 'CRQ-ONS-030';
  SELECT id INTO v_off001 FROM contract WHERE contract_number = 'CRQ-OFF-001';
  SELECT id INTO v_off010 FROM contract WHERE contract_number = 'CRQ-OFF-010';
  SELECT id INTO v_drl001 FROM contract WHERE contract_number = 'CRQ-DRL-001';
  SELECT id INTO v_drl010 FROM contract WHERE contract_number = 'CRQ-DRL-010';
  SELECT id INTO v_gas001 FROM contract WHERE contract_number = 'CRQ-GAS-001';
  SELECT id INTO v_agt001 FROM contract WHERE contract_number = 'CRQ-AGT-001';

  -- ============================================================
  -- CONTRACT BUDGETS (4 quarters FY2026 × 4 categories each)
  -- ============================================================

  -- CRQ-ONS-001: ON-TRACK (AED 480M total; day_rate 60M/qtr)
  INSERT INTO contract_budget (tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, allocated_amount_aed, currency, source, data_classification,
    created_by, updated_by, is_active, created_at, updated_at)
  SELECT v_tenant_id, v_ons001, 'quarter', q.lbl, 2026, c.cat, c.amt, 'AED', 'demo_seed', 'demo',
    v_seed_user, v_seed_user, TRUE, NOW(), NOW()
  FROM (VALUES ('2026-Q1'),('2026-Q2'),('2026-Q3'),('2026-Q4')) AS q(lbl)
  CROSS JOIN (VALUES ('day_rate',60000000),('manpower',30000000),('equipment',15000000),('milestone',15000000)) AS c(cat,amt)
  WHERE v_ons001 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
    allocated_amount_aed = EXCLUDED.allocated_amount_aed, updated_at = NOW(), updated_by = EXCLUDED.updated_by;

  -- CRQ-ONS-010: MILD OVERRUN (AED 320M total; day_rate 40M/qtr)
  INSERT INTO contract_budget (tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, allocated_amount_aed, currency, source, data_classification,
    created_by, updated_by, is_active, created_at, updated_at)
  SELECT v_tenant_id, v_ons010, 'quarter', q.lbl, 2026, c.cat, c.amt, 'AED', 'demo_seed', 'demo',
    v_seed_user, v_seed_user, TRUE, NOW(), NOW()
  FROM (VALUES ('2026-Q1'),('2026-Q2'),('2026-Q3'),('2026-Q4')) AS q(lbl)
  CROSS JOIN (VALUES ('day_rate',40000000),('manpower',20000000),('equipment',12000000),('milestone',8000000)) AS c(cat,amt)
  WHERE v_ons010 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
    allocated_amount_aed = EXCLUDED.allocated_amount_aed, updated_at = NOW(), updated_by = EXCLUDED.updated_by;

  -- CRQ-ONS-020: ON-TRACK (AED 200M total; day_rate 25M/qtr)
  INSERT INTO contract_budget (tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, allocated_amount_aed, currency, source, data_classification,
    created_by, updated_by, is_active, created_at, updated_at)
  SELECT v_tenant_id, v_ons020, 'quarter', q.lbl, 2026, c.cat, c.amt, 'AED', 'demo_seed', 'demo',
    v_seed_user, v_seed_user, TRUE, NOW(), NOW()
  FROM (VALUES ('2026-Q1'),('2026-Q2'),('2026-Q3'),('2026-Q4')) AS q(lbl)
  CROSS JOIN (VALUES ('day_rate',25000000),('manpower',12500000),('equipment',7500000),('milestone',5000000)) AS c(cat,amt)
  WHERE v_ons020 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
    allocated_amount_aed = EXCLUDED.allocated_amount_aed, updated_at = NOW(), updated_by = EXCLUDED.updated_by;

  -- CRQ-ONS-030: MILD OVERRUN (AED 160M total; day_rate 20M/qtr)
  INSERT INTO contract_budget (tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, allocated_amount_aed, currency, source, data_classification,
    created_by, updated_by, is_active, created_at, updated_at)
  SELECT v_tenant_id, v_ons030, 'quarter', q.lbl, 2026, c.cat, c.amt, 'AED', 'demo_seed', 'demo',
    v_seed_user, v_seed_user, TRUE, NOW(), NOW()
  FROM (VALUES ('2026-Q1'),('2026-Q2'),('2026-Q3'),('2026-Q4')) AS q(lbl)
  CROSS JOIN (VALUES ('day_rate',20000000),('manpower',10000000),('equipment',6000000),('milestone',4000000)) AS c(cat,amt)
  WHERE v_ons030 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
    allocated_amount_aed = EXCLUDED.allocated_amount_aed, updated_at = NOW(), updated_by = EXCLUDED.updated_by;

  -- CRQ-OFF-001: MILD OVERRUN (AED 560M total; day_rate 70M/qtr)
  INSERT INTO contract_budget (tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, allocated_amount_aed, currency, source, data_classification,
    created_by, updated_by, is_active, created_at, updated_at)
  SELECT v_tenant_id, v_off001, 'quarter', q.lbl, 2026, c.cat, c.amt, 'AED', 'demo_seed', 'demo',
    v_seed_user, v_seed_user, TRUE, NOW(), NOW()
  FROM (VALUES ('2026-Q1'),('2026-Q2'),('2026-Q3'),('2026-Q4')) AS q(lbl)
  CROSS JOIN (VALUES ('day_rate',70000000),('manpower',40000000),('equipment',20000000),('milestone',10000000)) AS c(cat,amt)
  WHERE v_off001 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
    allocated_amount_aed = EXCLUDED.allocated_amount_aed, updated_at = NOW(), updated_by = EXCLUDED.updated_by;

  -- CRQ-OFF-010: ON-TRACK (AED 240M total; day_rate 30M/qtr)
  INSERT INTO contract_budget (tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, allocated_amount_aed, currency, source, data_classification,
    created_by, updated_by, is_active, created_at, updated_at)
  SELECT v_tenant_id, v_off010, 'quarter', q.lbl, 2026, c.cat, c.amt, 'AED', 'demo_seed', 'demo',
    v_seed_user, v_seed_user, TRUE, NOW(), NOW()
  FROM (VALUES ('2026-Q1'),('2026-Q2'),('2026-Q3'),('2026-Q4')) AS q(lbl)
  CROSS JOIN (VALUES ('day_rate',30000000),('manpower',15000000),('equipment',9000000),('milestone',6000000)) AS c(cat,amt)
  WHERE v_off010 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
    allocated_amount_aed = EXCLUDED.allocated_amount_aed, updated_at = NOW(), updated_by = EXCLUDED.updated_by;

  -- CRQ-DRL-001: HERO-LIKE +7% day_rate breach (AED 440M total; day_rate 55M/qtr)
  INSERT INTO contract_budget (tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, allocated_amount_aed, currency, source, data_classification,
    created_by, updated_by, is_active, created_at, updated_at)
  SELECT v_tenant_id, v_drl001, 'quarter', q.lbl, 2026, c.cat, c.amt, 'AED', 'demo_seed', 'demo',
    v_seed_user, v_seed_user, TRUE, NOW(), NOW()
  FROM (VALUES ('2026-Q1'),('2026-Q2'),('2026-Q3'),('2026-Q4')) AS q(lbl)
  CROSS JOIN (VALUES ('day_rate',55000000),('manpower',28000000),('equipment',14000000),('milestone',8000000)) AS c(cat,amt)
  WHERE v_drl001 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
    allocated_amount_aed = EXCLUDED.allocated_amount_aed, updated_at = NOW(), updated_by = EXCLUDED.updated_by;

  -- CRQ-DRL-010: MILD OVERRUN (AED 300M total; day_rate 37.5M/qtr)
  INSERT INTO contract_budget (tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, allocated_amount_aed, currency, source, data_classification,
    created_by, updated_by, is_active, created_at, updated_at)
  SELECT v_tenant_id, v_drl010, 'quarter', q.lbl, 2026, c.cat, c.amt, 'AED', 'demo_seed', 'demo',
    v_seed_user, v_seed_user, TRUE, NOW(), NOW()
  FROM (VALUES ('2026-Q1'),('2026-Q2'),('2026-Q3'),('2026-Q4')) AS q(lbl)
  CROSS JOIN (VALUES ('day_rate',37500000),('manpower',18750000),('equipment',9375000),('milestone',9375000)) AS c(cat,amt)
  WHERE v_drl010 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
    allocated_amount_aed = EXCLUDED.allocated_amount_aed, updated_at = NOW(), updated_by = EXCLUDED.updated_by;

  -- CRQ-GAS-001: ON-TRACK / buffer (AED 120M total; day_rate 15M/qtr)
  INSERT INTO contract_budget (tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, allocated_amount_aed, currency, source, data_classification,
    created_by, updated_by, is_active, created_at, updated_at)
  SELECT v_tenant_id, v_gas001, 'quarter', q.lbl, 2026, c.cat, c.amt, 'AED', 'demo_seed', 'demo',
    v_seed_user, v_seed_user, TRUE, NOW(), NOW()
  FROM (VALUES ('2026-Q1'),('2026-Q2'),('2026-Q3'),('2026-Q4')) AS q(lbl)
  CROSS JOIN (VALUES ('day_rate',15000000),('manpower',8000000),('equipment',4000000),('milestone',3000000)) AS c(cat,amt)
  WHERE v_gas001 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
    allocated_amount_aed = EXCLUDED.allocated_amount_aed, updated_at = NOW(), updated_by = EXCLUDED.updated_by;

  -- CRQ-AGT-001: ON-TRACK (AED 80M total; day_rate 10M/qtr)
  INSERT INTO contract_budget (tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, allocated_amount_aed, currency, source, data_classification,
    created_by, updated_by, is_active, created_at, updated_at)
  SELECT v_tenant_id, v_agt001, 'quarter', q.lbl, 2026, c.cat, c.amt, 'AED', 'demo_seed', 'demo',
    v_seed_user, v_seed_user, TRUE, NOW(), NOW()
  FROM (VALUES ('2026-Q1'),('2026-Q2'),('2026-Q3'),('2026-Q4')) AS q(lbl)
  CROSS JOIN (VALUES ('day_rate',10000000),('manpower',5500000),('equipment',2500000),('milestone',2000000)) AS c(cat,amt)
  WHERE v_agt001 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_budget_idempotency_key DO UPDATE SET
    allocated_amount_aed = EXCLUDED.allocated_amount_aed, updated_at = NOW(), updated_by = EXCLUDED.updated_by;

  -- ============================================================
  -- CONTRACT COST ACTUALS (months 1–4 for all; months 1–8 for hero-like DRL-001)
  -- ============================================================

  -- CRQ-ONS-001: ON-TRACK — actuals at ~101% of monthly plan
  -- monthly day_rate plan = 60M/3 = 20,000,000
  IF v_ons001 IS NOT NULL THEN
    INSERT INTO contract_cost_actual (tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at)
    VALUES
      (v_tenant_id,v_ons001,'month','2026-01',2026,'day_rate',  20200000,'AED','erp_feed','ERP-ONS001-202601-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-01',2026,'manpower',  10050000,'AED','erp_feed','ERP-ONS001-202601-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-01',2026,'equipment',  5010000,'AED','erp_feed','ERP-ONS001-202601-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-01',2026,'milestone',  5010000,'AED','erp_feed','ERP-ONS001-202601-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-02',2026,'day_rate',  20200000,'AED','erp_feed','ERP-ONS001-202602-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-02',2026,'manpower',  10050000,'AED','erp_feed','ERP-ONS001-202602-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-02',2026,'equipment',  5010000,'AED','erp_feed','ERP-ONS001-202602-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-02',2026,'milestone',  5010000,'AED','erp_feed','ERP-ONS001-202602-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-03',2026,'day_rate',  20300000,'AED','erp_feed','ERP-ONS001-202603-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-03',2026,'manpower',  10100000,'AED','erp_feed','ERP-ONS001-202603-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-03',2026,'equipment',  5020000,'AED','erp_feed','ERP-ONS001-202603-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-03',2026,'milestone',  5020000,'AED','erp_feed','ERP-ONS001-202603-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-04',2026,'day_rate',  20250000,'AED','erp_feed','ERP-ONS001-202604-DR','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-04',2026,'manpower',  10100000,'AED','erp_feed','ERP-ONS001-202604-MP','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-04',2026,'equipment',  5020000,'AED','erp_feed','ERP-ONS001-202604-EQ','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons001,'month','2026-04',2026,'milestone',  5020000,'AED','erp_feed','ERP-ONS001-202604-MS','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed=EXCLUDED.actual_amount_aed,recorded_at=EXCLUDED.recorded_at,updated_at=NOW(),updated_by=EXCLUDED.updated_by;
  END IF;

  -- CRQ-ONS-010: MILD OVERRUN ~106% day_rate
  -- monthly day_rate plan = 40M/3 = 13,333,333
  IF v_ons010 IS NOT NULL THEN
    INSERT INTO contract_cost_actual (tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at)
    VALUES
      (v_tenant_id,v_ons010,'month','2026-01',2026,'day_rate',  13333333,'AED','erp_feed','ERP-ONS010-202601-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-01',2026,'manpower',   6700000,'AED','erp_feed','ERP-ONS010-202601-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-01',2026,'equipment',  4000000,'AED','erp_feed','ERP-ONS010-202601-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-01',2026,'milestone',  2700000,'AED','erp_feed','ERP-ONS010-202601-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-02',2026,'day_rate',  14000000,'AED','erp_feed','ERP-ONS010-202602-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-02',2026,'manpower',   6700000,'AED','erp_feed','ERP-ONS010-202602-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-02',2026,'equipment',  4000000,'AED','erp_feed','ERP-ONS010-202602-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-02',2026,'milestone',  2700000,'AED','erp_feed','ERP-ONS010-202602-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-03',2026,'day_rate',  14100000,'AED','erp_feed','ERP-ONS010-202603-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-03',2026,'manpower',   6900000,'AED','erp_feed','ERP-ONS010-202603-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-03',2026,'equipment',  4100000,'AED','erp_feed','ERP-ONS010-202603-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-03',2026,'milestone',  2750000,'AED','erp_feed','ERP-ONS010-202603-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-04',2026,'day_rate',  14200000,'AED','erp_feed','ERP-ONS010-202604-DR','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-04',2026,'manpower',   6900000,'AED','erp_feed','ERP-ONS010-202604-MP','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-04',2026,'equipment',  4200000,'AED','erp_feed','ERP-ONS010-202604-EQ','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons010,'month','2026-04',2026,'milestone',  2800000,'AED','erp_feed','ERP-ONS010-202604-MS','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed=EXCLUDED.actual_amount_aed,recorded_at=EXCLUDED.recorded_at,updated_at=NOW(),updated_by=EXCLUDED.updated_by;
  END IF;

  -- CRQ-ONS-020: ON-TRACK ~102%
  -- monthly day_rate plan = 25M/3 = 8,333,333
  IF v_ons020 IS NOT NULL THEN
    INSERT INTO contract_cost_actual (tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at)
    VALUES
      (v_tenant_id,v_ons020,'month','2026-01',2026,'day_rate',  8500000,'AED','erp_feed','ERP-ONS020-202601-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-01',2026,'manpower',  4200000,'AED','erp_feed','ERP-ONS020-202601-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-01',2026,'equipment', 2510000,'AED','erp_feed','ERP-ONS020-202601-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-01',2026,'milestone', 1680000,'AED','erp_feed','ERP-ONS020-202601-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-02',2026,'day_rate',  8500000,'AED','erp_feed','ERP-ONS020-202602-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-02',2026,'manpower',  4200000,'AED','erp_feed','ERP-ONS020-202602-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-02',2026,'equipment', 2500000,'AED','erp_feed','ERP-ONS020-202602-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-02',2026,'milestone', 1670000,'AED','erp_feed','ERP-ONS020-202602-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-03',2026,'day_rate',  8520000,'AED','erp_feed','ERP-ONS020-202603-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-03',2026,'manpower',  4220000,'AED','erp_feed','ERP-ONS020-202603-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-03',2026,'equipment', 2510000,'AED','erp_feed','ERP-ONS020-202603-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-03',2026,'milestone', 1680000,'AED','erp_feed','ERP-ONS020-202603-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-04',2026,'day_rate',  8530000,'AED','erp_feed','ERP-ONS020-202604-DR','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-04',2026,'manpower',  4220000,'AED','erp_feed','ERP-ONS020-202604-MP','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-04',2026,'equipment', 2510000,'AED','erp_feed','ERP-ONS020-202604-EQ','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons020,'month','2026-04',2026,'milestone', 1680000,'AED','erp_feed','ERP-ONS020-202604-MS','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed=EXCLUDED.actual_amount_aed,recorded_at=EXCLUDED.recorded_at,updated_at=NOW(),updated_by=EXCLUDED.updated_by;
  END IF;

  -- CRQ-ONS-030: MILD OVERRUN ~108% day_rate
  -- monthly day_rate plan = 20M/3 = 6,666,667
  IF v_ons030 IS NOT NULL THEN
    INSERT INTO contract_cost_actual (tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at)
    VALUES
      (v_tenant_id,v_ons030,'month','2026-01',2026,'day_rate',  7000000,'AED','erp_feed','ERP-ONS030-202601-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-01',2026,'manpower',  3400000,'AED','erp_feed','ERP-ONS030-202601-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-01',2026,'equipment', 2000000,'AED','erp_feed','ERP-ONS030-202601-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-01',2026,'milestone', 1350000,'AED','erp_feed','ERP-ONS030-202601-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-02',2026,'day_rate',  7100000,'AED','erp_feed','ERP-ONS030-202602-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-02',2026,'manpower',  3450000,'AED','erp_feed','ERP-ONS030-202602-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-02',2026,'equipment', 2050000,'AED','erp_feed','ERP-ONS030-202602-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-02',2026,'milestone', 1380000,'AED','erp_feed','ERP-ONS030-202602-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-03',2026,'day_rate',  7150000,'AED','erp_feed','ERP-ONS030-202603-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-03',2026,'manpower',  3450000,'AED','erp_feed','ERP-ONS030-202603-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-03',2026,'equipment', 2060000,'AED','erp_feed','ERP-ONS030-202603-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-03',2026,'milestone', 1380000,'AED','erp_feed','ERP-ONS030-202603-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-04',2026,'day_rate',  7200000,'AED','erp_feed','ERP-ONS030-202604-DR','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-04',2026,'manpower',  3460000,'AED','erp_feed','ERP-ONS030-202604-MP','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-04',2026,'equipment', 2070000,'AED','erp_feed','ERP-ONS030-202604-EQ','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_ons030,'month','2026-04',2026,'milestone', 1390000,'AED','erp_feed','ERP-ONS030-202604-MS','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed=EXCLUDED.actual_amount_aed,recorded_at=EXCLUDED.recorded_at,updated_at=NOW(),updated_by=EXCLUDED.updated_by;
  END IF;

  -- CRQ-OFF-001: MILD OVERRUN ~107% day_rate
  -- monthly day_rate plan = 70M/3 = 23,333,333
  IF v_off001 IS NOT NULL THEN
    INSERT INTO contract_cost_actual (tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at)
    VALUES
      (v_tenant_id,v_off001,'month','2026-01',2026,'day_rate',  24500000,'AED','erp_feed','ERP-OFF001-202601-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-01',2026,'manpower',  13400000,'AED','erp_feed','ERP-OFF001-202601-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-01',2026,'equipment',  6700000,'AED','erp_feed','ERP-OFF001-202601-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-01',2026,'milestone',  3400000,'AED','erp_feed','ERP-OFF001-202601-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-02',2026,'day_rate',  24800000,'AED','erp_feed','ERP-OFF001-202602-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-02',2026,'manpower',  13500000,'AED','erp_feed','ERP-OFF001-202602-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-02',2026,'equipment',  6750000,'AED','erp_feed','ERP-OFF001-202602-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-02',2026,'milestone',  3400000,'AED','erp_feed','ERP-OFF001-202602-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-03',2026,'day_rate',  25000000,'AED','erp_feed','ERP-OFF001-202603-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-03',2026,'manpower',  13500000,'AED','erp_feed','ERP-OFF001-202603-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-03',2026,'equipment',  6800000,'AED','erp_feed','ERP-OFF001-202603-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-03',2026,'milestone',  3450000,'AED','erp_feed','ERP-OFF001-202603-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-04',2026,'day_rate',  25100000,'AED','erp_feed','ERP-OFF001-202604-DR','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-04',2026,'manpower',  13600000,'AED','erp_feed','ERP-OFF001-202604-MP','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-04',2026,'equipment',  6800000,'AED','erp_feed','ERP-OFF001-202604-EQ','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off001,'month','2026-04',2026,'milestone',  3450000,'AED','erp_feed','ERP-OFF001-202604-MS','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed=EXCLUDED.actual_amount_aed,recorded_at=EXCLUDED.recorded_at,updated_at=NOW(),updated_by=EXCLUDED.updated_by;
  END IF;

  -- CRQ-OFF-010: ON-TRACK ~102%
  -- monthly day_rate plan = 30M/3 = 10,000,000
  IF v_off010 IS NOT NULL THEN
    INSERT INTO contract_cost_actual (tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at)
    VALUES
      (v_tenant_id,v_off010,'month','2026-01',2026,'day_rate',  10200000,'AED','erp_feed','ERP-OFF010-202601-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-01',2026,'manpower',   5050000,'AED','erp_feed','ERP-OFF010-202601-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-01',2026,'equipment',  3010000,'AED','erp_feed','ERP-OFF010-202601-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-01',2026,'milestone',  2010000,'AED','erp_feed','ERP-OFF010-202601-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-02',2026,'day_rate',  10150000,'AED','erp_feed','ERP-OFF010-202602-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-02',2026,'manpower',   5020000,'AED','erp_feed','ERP-OFF010-202602-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-02',2026,'equipment',  3000000,'AED','erp_feed','ERP-OFF010-202602-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-02',2026,'milestone',  2000000,'AED','erp_feed','ERP-OFF010-202602-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-03',2026,'day_rate',  10200000,'AED','erp_feed','ERP-OFF010-202603-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-03',2026,'manpower',   5050000,'AED','erp_feed','ERP-OFF010-202603-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-03',2026,'equipment',  3020000,'AED','erp_feed','ERP-OFF010-202603-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-03',2026,'milestone',  2010000,'AED','erp_feed','ERP-OFF010-202603-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-04',2026,'day_rate',  10200000,'AED','erp_feed','ERP-OFF010-202604-DR','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-04',2026,'manpower',   5050000,'AED','erp_feed','ERP-OFF010-202604-MP','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-04',2026,'equipment',  3010000,'AED','erp_feed','ERP-OFF010-202604-EQ','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_off010,'month','2026-04',2026,'milestone',  2010000,'AED','erp_feed','ERP-OFF010-202604-MS','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed=EXCLUDED.actual_amount_aed,recorded_at=EXCLUDED.recorded_at,updated_at=NOW(),updated_by=EXCLUDED.updated_by;
  END IF;

  -- CRQ-DRL-001: HERO-LIKE +7% day_rate breach — 8 months
  -- monthly day_rate plan = 55M/3 = 18,333,333
  -- Month 1-2 on plan, month 3 starts drift, months 4-8 at +7% and rising
  IF v_drl001 IS NOT NULL THEN
    INSERT INTO contract_cost_actual (tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at)
    VALUES
      (v_tenant_id,v_drl001,'month','2026-01',2026,'day_rate',  18333333,'AED','erp_feed','ERP-DRL001-202601-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-01',2026,'manpower',   9380000,'AED','erp_feed','ERP-DRL001-202601-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-01',2026,'equipment',  4680000,'AED','erp_feed','ERP-DRL001-202601-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-01',2026,'milestone',  2680000,'AED','erp_feed','ERP-DRL001-202601-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-02',2026,'day_rate',  18333333,'AED','erp_feed','ERP-DRL001-202602-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-02',2026,'manpower',   9380000,'AED','erp_feed','ERP-DRL001-202602-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-02',2026,'equipment',  4680000,'AED','erp_feed','ERP-DRL001-202602-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-02',2026,'milestone',  2680000,'AED','erp_feed','ERP-DRL001-202602-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-03',2026,'day_rate',  19000000,'AED','erp_feed','ERP-DRL001-202603-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-03',2026,'manpower',   9400000,'AED','erp_feed','ERP-DRL001-202603-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-03',2026,'equipment',  4700000,'AED','erp_feed','ERP-DRL001-202603-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-03',2026,'milestone',  2690000,'AED','erp_feed','ERP-DRL001-202603-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-04',2026,'day_rate',  19600000,'AED','erp_feed','ERP-DRL001-202604-DR','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-04',2026,'manpower',   9420000,'AED','erp_feed','ERP-DRL001-202604-MP','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-04',2026,'equipment',  4720000,'AED','erp_feed','ERP-DRL001-202604-EQ','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-04',2026,'milestone',  2700000,'AED','erp_feed','ERP-DRL001-202604-MS','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-05',2026,'day_rate',  19620000,'AED','erp_feed','ERP-DRL001-202605-DR','2026-05-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-05',2026,'manpower',   9430000,'AED','erp_feed','ERP-DRL001-202605-MP','2026-05-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-05',2026,'equipment',  4730000,'AED','erp_feed','ERP-DRL001-202605-EQ','2026-05-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-05',2026,'milestone',  2700000,'AED','erp_feed','ERP-DRL001-202605-MS','2026-05-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-06',2026,'day_rate',  19650000,'AED','erp_feed','ERP-DRL001-202606-DR','2026-06-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-06',2026,'manpower',   9440000,'AED','erp_feed','ERP-DRL001-202606-MP','2026-06-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-06',2026,'equipment',  4740000,'AED','erp_feed','ERP-DRL001-202606-EQ','2026-06-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-06',2026,'milestone',  2710000,'AED','erp_feed','ERP-DRL001-202606-MS','2026-06-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-07',2026,'day_rate',  19650000,'AED','erp_feed','ERP-DRL001-202607-DR','2026-07-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-07',2026,'manpower',   9440000,'AED','erp_feed','ERP-DRL001-202607-MP','2026-07-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-07',2026,'equipment',  4740000,'AED','erp_feed','ERP-DRL001-202607-EQ','2026-07-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-07',2026,'milestone',  2710000,'AED','erp_feed','ERP-DRL001-202607-MS','2026-07-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-08',2026,'day_rate',  19620000,'AED','erp_feed','ERP-DRL001-202608-DR','2026-08-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-08',2026,'manpower',   9430000,'AED','erp_feed','ERP-DRL001-202608-MP','2026-08-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-08',2026,'equipment',  4730000,'AED','erp_feed','ERP-DRL001-202608-EQ','2026-08-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl001,'month','2026-08',2026,'milestone',  2700000,'AED','erp_feed','ERP-DRL001-202608-MS','2026-08-31'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed=EXCLUDED.actual_amount_aed,recorded_at=EXCLUDED.recorded_at,updated_at=NOW(),updated_by=EXCLUDED.updated_by;
  END IF;

  -- CRQ-DRL-010: MILD OVERRUN ~105% day_rate
  -- monthly day_rate plan = 37.5M/3 = 12,500,000
  IF v_drl010 IS NOT NULL THEN
    INSERT INTO contract_cost_actual (tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at)
    VALUES
      (v_tenant_id,v_drl010,'month','2026-01',2026,'day_rate',  13000000,'AED','erp_feed','ERP-DRL010-202601-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-01',2026,'manpower',   6280000,'AED','erp_feed','ERP-DRL010-202601-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-01',2026,'equipment',  3140000,'AED','erp_feed','ERP-DRL010-202601-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-01',2026,'milestone',  3140000,'AED','erp_feed','ERP-DRL010-202601-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-02',2026,'day_rate',  13125000,'AED','erp_feed','ERP-DRL010-202602-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-02',2026,'manpower',   6300000,'AED','erp_feed','ERP-DRL010-202602-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-02',2026,'equipment',  3150000,'AED','erp_feed','ERP-DRL010-202602-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-02',2026,'milestone',  3150000,'AED','erp_feed','ERP-DRL010-202602-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-03',2026,'day_rate',  13200000,'AED','erp_feed','ERP-DRL010-202603-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-03',2026,'manpower',   6320000,'AED','erp_feed','ERP-DRL010-202603-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-03',2026,'equipment',  3160000,'AED','erp_feed','ERP-DRL010-202603-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-03',2026,'milestone',  3160000,'AED','erp_feed','ERP-DRL010-202603-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-04',2026,'day_rate',  13250000,'AED','erp_feed','ERP-DRL010-202604-DR','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-04',2026,'manpower',   6320000,'AED','erp_feed','ERP-DRL010-202604-MP','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-04',2026,'equipment',  3160000,'AED','erp_feed','ERP-DRL010-202604-EQ','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_drl010,'month','2026-04',2026,'milestone',  3160000,'AED','erp_feed','ERP-DRL010-202604-MS','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed=EXCLUDED.actual_amount_aed,recorded_at=EXCLUDED.recorded_at,updated_at=NOW(),updated_by=EXCLUDED.updated_by;
  END IF;

  -- CRQ-GAS-001: ON-TRACK / buffer ~101%
  -- monthly day_rate plan = 15M/3 = 5,000,000
  IF v_gas001 IS NOT NULL THEN
    INSERT INTO contract_cost_actual (tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at)
    VALUES
      (v_tenant_id,v_gas001,'month','2026-01',2026,'day_rate',  5050000,'AED','erp_feed','ERP-GAS001-202601-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-01',2026,'manpower',  2690000,'AED','erp_feed','ERP-GAS001-202601-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-01',2026,'equipment', 1340000,'AED','erp_feed','ERP-GAS001-202601-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-01',2026,'milestone', 1010000,'AED','erp_feed','ERP-GAS001-202601-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-02',2026,'day_rate',  5050000,'AED','erp_feed','ERP-GAS001-202602-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-02',2026,'manpower',  2690000,'AED','erp_feed','ERP-GAS001-202602-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-02',2026,'equipment', 1340000,'AED','erp_feed','ERP-GAS001-202602-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-02',2026,'milestone', 1010000,'AED','erp_feed','ERP-GAS001-202602-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-03',2026,'day_rate',  5060000,'AED','erp_feed','ERP-GAS001-202603-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-03',2026,'manpower',  2700000,'AED','erp_feed','ERP-GAS001-202603-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-03',2026,'equipment', 1350000,'AED','erp_feed','ERP-GAS001-202603-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-03',2026,'milestone', 1010000,'AED','erp_feed','ERP-GAS001-202603-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-04',2026,'day_rate',  5060000,'AED','erp_feed','ERP-GAS001-202604-DR','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-04',2026,'manpower',  2700000,'AED','erp_feed','ERP-GAS001-202604-MP','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-04',2026,'equipment', 1350000,'AED','erp_feed','ERP-GAS001-202604-EQ','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_gas001,'month','2026-04',2026,'milestone', 1010000,'AED','erp_feed','ERP-GAS001-202604-MS','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed=EXCLUDED.actual_amount_aed,recorded_at=EXCLUDED.recorded_at,updated_at=NOW(),updated_by=EXCLUDED.updated_by;
  END IF;

  -- CRQ-AGT-001: ON-TRACK ~102%
  -- monthly day_rate plan = 10M/3 = 3,333,333
  IF v_agt001 IS NOT NULL THEN
    INSERT INTO contract_cost_actual (tenant_id, contract_id, period_type, period_label, fiscal_year,
      cost_category, actual_amount_aed, currency, source, reference_no,
      recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at)
    VALUES
      (v_tenant_id,v_agt001,'month','2026-01',2026,'day_rate',  3400000,'AED','erp_feed','ERP-AGT001-202601-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-01',2026,'manpower',  1850000,'AED','erp_feed','ERP-AGT001-202601-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-01',2026,'equipment',  840000,'AED','erp_feed','ERP-AGT001-202601-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-01',2026,'milestone',  680000,'AED','erp_feed','ERP-AGT001-202601-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-02',2026,'day_rate',  3400000,'AED','erp_feed','ERP-AGT001-202602-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-02',2026,'manpower',  1850000,'AED','erp_feed','ERP-AGT001-202602-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-02',2026,'equipment',  840000,'AED','erp_feed','ERP-AGT001-202602-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-02',2026,'milestone',  680000,'AED','erp_feed','ERP-AGT001-202602-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-03',2026,'day_rate',  3410000,'AED','erp_feed','ERP-AGT001-202603-DR',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-03',2026,'manpower',  1855000,'AED','erp_feed','ERP-AGT001-202603-MP',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-03',2026,'equipment',  842000,'AED','erp_feed','ERP-AGT001-202603-EQ',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-03',2026,'milestone',  682000,'AED','erp_feed','ERP-AGT001-202603-MS',NOW(),'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-04',2026,'day_rate',  3410000,'AED','erp_feed','ERP-AGT001-202604-DR','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-04',2026,'manpower',  1855000,'AED','erp_feed','ERP-AGT001-202604-MP','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-04',2026,'equipment',  842000,'AED','erp_feed','ERP-AGT001-202604-EQ','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW()),
      (v_tenant_id,v_agt001,'month','2026-04',2026,'milestone',  682000,'AED','erp_feed','ERP-AGT001-202604-MS','2026-04-30'::timestamptz,'demo',v_seed_user,v_seed_user,TRUE,NOW(),NOW())
    ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
      actual_amount_aed=EXCLUDED.actual_amount_aed,recorded_at=EXCLUDED.recorded_at,updated_at=NOW(),updated_by=EXCLUDED.updated_by;
  END IF;

  RAISE NOTICE '330: 10 budget-tracked CRQ contracts seeded (budget 160 rows + actuals 160 rows).';
END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (330, '330_crq_seed_budget_tracked_contracts', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM contract_cost_actual
--   WHERE contract_id IN (
--     SELECT id FROM contract WHERE contract_number IN (
--       'CRQ-ONS-001','CRQ-ONS-010','CRQ-ONS-020','CRQ-ONS-030',
--       'CRQ-OFF-001','CRQ-OFF-010','CRQ-DRL-001','CRQ-DRL-010',
--       'CRQ-GAS-001','CRQ-AGT-001'
--     )
--   );
-- DELETE FROM contract_budget
--   WHERE contract_id IN (
--     SELECT id FROM contract WHERE contract_number IN (
--       'CRQ-ONS-001','CRQ-ONS-010','CRQ-ONS-020','CRQ-ONS-030',
--       'CRQ-OFF-001','CRQ-OFF-010','CRQ-DRL-001','CRQ-DRL-010',
--       'CRQ-GAS-001','CRQ-AGT-001'
--     )
--   );
-- DELETE FROM schema_migrations WHERE version = 330;
-- COMMIT;
-- ============================================================
