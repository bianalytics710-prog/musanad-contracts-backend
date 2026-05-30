-- Migration: 329_crq_hero001_actuals_extend.sql
-- Module: CR-Q — ADNOC Data Scale-Up (v1.4 foundation)
-- Description: Extends HERO-001 contract_cost_actual from months 1–4 (mig 304) to months 1–10.
--              Adds months 5–10 (40 rows: 6 months × 4 categories).
--              day_rate trajectory: month-4 established at 47,880,000 (+8%).
--              Months 5–6: slight further creep to ~49M (market mobilisation pressure).
--              Months 7–8: stabilise near 50M (new drill-string tender awarded above budget).
--              Months 9–10: modest reduction to 49.5M (remediation in progress — visible in chart).
--              Other categories (manpower, equipment, milestone) stay near plan throughout.
--              Idempotent via ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key.
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
  v_hero1_id  BIGINT;
BEGIN
  SELECT MIN(id) INTO v_seed_user FROM "user" WHERE is_active = TRUE;
  SELECT id INTO v_hero1_id FROM contract WHERE contract_number = 'CRN-296-HERO-001';

  IF v_hero1_id IS NULL THEN
    RAISE EXCEPTION '329: HERO-001 contract not found — ensure migration 303 has been applied'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM set_config('app.current_user_id', v_seed_user::text, false);

  -- ==============================================================
  -- HERO-001: months 5–10 (24 rows: 6 months × 4 categories)
  -- Monthly day_rate plan = 44,333,333 (532M / 12)
  -- Month-5:  49,210,000 (+11.0% — creep continues after M4 breach)
  -- Month-6:  49,650,000 (+12.0% — mobilisation overrun persists)
  -- Month-7:  50,100,000 (+13.0% — drill-string tender above budget)
  -- Month-8:  50,100,000 (+13.0% — stable elevated run-rate)
  -- Month-9:  49,500,000 (+11.6% — partial remediation in progress)
  -- Month-10: 49,000,000 (+10.5% — trajectory turning; new contract terms negotiated)
  -- Other categories stay on plan: manpower 16,666,667/mo, equipment 6,666,667/mo, milestone 2,750,000/mo
  -- ==============================================================

  INSERT INTO contract_cost_actual (
    tenant_id, contract_id, period_type, period_label, fiscal_year,
    cost_category, actual_amount_aed, currency, source, reference_no,
    recorded_at, data_classification, created_by, updated_by, is_active, created_at, updated_at
  ) VALUES
    -- 2026-05
    (v_tenant_id, v_hero1_id, 'month', '2026-05', 2026, 'day_rate',   49210000.00, 'AED', 'erp_feed', 'ERP-HERO1-202605-DR', '2026-05-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-05', 2026, 'manpower',   16666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202605-MP', '2026-05-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-05', 2026, 'equipment',   6666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202605-EQ', '2026-05-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-05', 2026, 'milestone',   2750000.00, 'AED', 'erp_feed', 'ERP-HERO1-202605-MS', '2026-05-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- 2026-06
    (v_tenant_id, v_hero1_id, 'month', '2026-06', 2026, 'day_rate',   49650000.00, 'AED', 'erp_feed', 'ERP-HERO1-202606-DR', '2026-06-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-06', 2026, 'manpower',   16666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202606-MP', '2026-06-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-06', 2026, 'equipment',   6666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202606-EQ', '2026-06-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-06', 2026, 'milestone',   2750000.00, 'AED', 'erp_feed', 'ERP-HERO1-202606-MS', '2026-06-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- 2026-07
    (v_tenant_id, v_hero1_id, 'month', '2026-07', 2026, 'day_rate',   50100000.00, 'AED', 'erp_feed', 'ERP-HERO1-202607-DR', '2026-07-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-07', 2026, 'manpower',   16666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202607-MP', '2026-07-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-07', 2026, 'equipment',   6666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202607-EQ', '2026-07-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-07', 2026, 'milestone',   2750000.00, 'AED', 'erp_feed', 'ERP-HERO1-202607-MS', '2026-07-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- 2026-08
    (v_tenant_id, v_hero1_id, 'month', '2026-08', 2026, 'day_rate',   50100000.00, 'AED', 'erp_feed', 'ERP-HERO1-202608-DR', '2026-08-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-08', 2026, 'manpower',   16666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202608-MP', '2026-08-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-08', 2026, 'equipment',   6666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202608-EQ', '2026-08-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-08', 2026, 'milestone',   2750000.00, 'AED', 'erp_feed', 'ERP-HERO1-202608-MS', '2026-08-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- 2026-09
    (v_tenant_id, v_hero1_id, 'month', '2026-09', 2026, 'day_rate',   49500000.00, 'AED', 'erp_feed', 'ERP-HERO1-202609-DR', '2026-09-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-09', 2026, 'manpower',   16666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202609-MP', '2026-09-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-09', 2026, 'equipment',   6666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202609-EQ', '2026-09-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-09', 2026, 'milestone',   2750000.00, 'AED', 'erp_feed', 'ERP-HERO1-202609-MS', '2026-09-30'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    -- 2026-10
    (v_tenant_id, v_hero1_id, 'month', '2026-10', 2026, 'day_rate',   49000000.00, 'AED', 'erp_feed', 'ERP-HERO1-202610-DR', '2026-10-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-10', 2026, 'manpower',   16666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202610-MP', '2026-10-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-10', 2026, 'equipment',   6666667.00, 'AED', 'erp_feed', 'ERP-HERO1-202610-EQ', '2026-10-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW()),
    (v_tenant_id, v_hero1_id, 'month', '2026-10', 2026, 'milestone',   2750000.00, 'AED', 'erp_feed', 'ERP-HERO1-202610-MS', '2026-10-31'::timestamptz, 'demo', v_seed_user, v_seed_user, TRUE, NOW(), NOW())
  ON CONFLICT ON CONSTRAINT contract_cost_actual_idempotency_key DO UPDATE SET
    actual_amount_aed = EXCLUDED.actual_amount_aed,
    recorded_at       = EXCLUDED.recorded_at,
    updated_at        = NOW(),
    updated_by        = EXCLUDED.updated_by;

  RAISE NOTICE '329: HERO-001 actuals extended to months 5–10 (24 rows inserted/upserted).';
END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (329, '329_crq_hero001_actuals_extend', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM contract_cost_actual
--   WHERE contract_id = (SELECT id FROM contract WHERE contract_number = 'CRN-296-HERO-001')
--     AND period_label IN ('2026-05','2026-06','2026-07','2026-08','2026-09','2026-10');
-- DELETE FROM schema_migrations WHERE version = 329;
-- COMMIT;
-- ============================================================
