-- Migration: 333_crq_seed_price_benchmarks.sql
-- Module: CR-Q — ADNOC Data Scale-Up (v1.4 foundation)
-- Description: Seeds full price_benchmark series Feb-2025 → Dec-2026 for:
--              - murban_osp monthly (~23 rows) — PRESERVES $63.00 Feb-2025, $110.75 May-2026, $104.44 Jun-2026
--              - brent monthly (~23 rows) — Brent runs ~$1–3 above Murban
--              - dubai monthly (~23 rows) — Dubai close to Murban, ~$1–4 differential
--              - wti quarterly (~8 rows) — context only
--              - usd_aed monthly (~23 rows) — near 3.6725 peg, tiny variation (unit=aed_per_usd)
--              Column names: price_value (not price_usd); unit (usd_per_bbl/aed_per_usd)
--              Source CHECK: 'osp_official','market','mock' — use osp_official for murban/usd_aed, market for brent/dubai/wti
--              Idempotent: ON CONFLICT ON CONSTRAINT price_benchmark_idempotency_key DO NOTHING.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

SELECT set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', false);

DO $$
DECLARE
  v_tenant UUID   := '00000000-0000-0000-0000-000000000001';
  v_actor  BIGINT;
BEGIN
  SELECT MIN(id) INTO v_actor FROM "user" WHERE is_active = TRUE;
  PERFORM set_config('app.current_user_id', v_actor::text, false);

  -- ============================================================
  -- MURBAN OSP monthly series Feb-2025 → Dec-2026
  -- Anchors: $63.00 Feb-2025; $110.75 May-2026; $104.44 Jun-2026
  -- unit=usd_per_bbl; source=osp_official
  -- ============================================================
  INSERT INTO price_benchmark (
    tenant_id, benchmark_code, price_date, price_value, unit,
    period_grain, source, data_classification,
    created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT v_tenant, 'murban_osp', d::date, p, 'usd_per_bbl',
    'monthly', 'osp_official', 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM (VALUES
    ('2025-02-01',  63.00::numeric),
    ('2025-03-01',  66.50::numeric),
    ('2025-04-01',  70.20::numeric),
    ('2025-05-01',  73.80::numeric),
    ('2025-06-01',  77.40::numeric),
    ('2025-07-01',  81.10::numeric),
    ('2025-08-01',  84.60::numeric),
    ('2025-09-01',  87.90::numeric),
    ('2025-10-01',  91.20::numeric),
    ('2025-11-01',  94.50::numeric),
    ('2025-12-01',  98.00::numeric),
    ('2026-01-01', 101.30::numeric),
    ('2026-02-01', 104.10::numeric),
    ('2026-03-01', 107.20::numeric),
    ('2026-04-01', 109.80::numeric),
    ('2026-05-01', 110.75::numeric),  -- ANCHOR (real published value)
    ('2026-06-01', 104.44::numeric),  -- ANCHOR (real published value)
    ('2026-07-01', 102.00::numeric),
    ('2026-08-01', 100.50::numeric),
    ('2026-09-01',  99.80::numeric),
    ('2026-10-01', 100.20::numeric),
    ('2026-11-01', 101.50::numeric),
    ('2026-12-01', 103.00::numeric)
  ) AS x(d, p)
  ON CONFLICT ON CONSTRAINT price_benchmark_idempotency_key DO NOTHING;

  -- ============================================================
  -- BRENT monthly series Feb-2025 → Dec-2026 (~$1–3 above Murban)
  -- ============================================================
  INSERT INTO price_benchmark (
    tenant_id, benchmark_code, price_date, price_value, unit,
    period_grain, source, data_classification,
    created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT v_tenant, 'brent', d::date, p, 'usd_per_bbl',
    'monthly', 'market', 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM (VALUES
    ('2025-02-01',  65.10::numeric),
    ('2025-03-01',  68.80::numeric),
    ('2025-04-01',  72.40::numeric),
    ('2025-05-01',  76.10::numeric),
    ('2025-06-01',  79.60::numeric),
    ('2025-07-01',  83.20::numeric),
    ('2025-08-01',  86.80::numeric),
    ('2025-09-01',  90.00::numeric),
    ('2025-10-01',  93.30::numeric),
    ('2025-11-01',  96.50::numeric),
    ('2025-12-01', 100.10::numeric),
    ('2026-01-01', 103.30::numeric),
    ('2026-02-01', 106.20::numeric),
    ('2026-03-01', 109.40::numeric),
    ('2026-04-01', 111.90::numeric),
    ('2026-05-01', 113.00::numeric),
    ('2026-06-01', 106.60::numeric),
    ('2026-07-01', 104.20::numeric),
    ('2026-08-01', 102.50::numeric),
    ('2026-09-01', 101.80::numeric),
    ('2026-10-01', 102.30::numeric),
    ('2026-11-01', 103.50::numeric),
    ('2026-12-01', 105.10::numeric)
  ) AS x(d, p)
  ON CONFLICT ON CONSTRAINT price_benchmark_idempotency_key DO NOTHING;

  -- ============================================================
  -- DUBAI monthly series Feb-2025 → Dec-2026 (~$1–4 below Murban)
  -- ============================================================
  INSERT INTO price_benchmark (
    tenant_id, benchmark_code, price_date, price_value, unit,
    period_grain, source, data_classification,
    created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT v_tenant, 'dubai', d::date, p, 'usd_per_bbl',
    'monthly', 'market', 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM (VALUES
    ('2025-02-01',  61.50::numeric),
    ('2025-03-01',  65.00::numeric),
    ('2025-04-01',  68.70::numeric),
    ('2025-05-01',  72.30::numeric),
    ('2025-06-01',  75.90::numeric),
    ('2025-07-01',  79.50::numeric),
    ('2025-08-01',  83.10::numeric),
    ('2025-09-01',  86.40::numeric),
    ('2025-10-01',  89.70::numeric),
    ('2025-11-01',  93.00::numeric),
    ('2025-12-01',  96.50::numeric),
    ('2026-01-01',  99.80::numeric),
    ('2026-02-01', 102.60::numeric),
    ('2026-03-01', 105.70::numeric),
    ('2026-04-01', 108.20::numeric),
    ('2026-05-01', 108.90::numeric),
    ('2026-06-01', 102.40::numeric),
    ('2026-07-01', 100.10::numeric),
    ('2026-08-01',  98.60::numeric),
    ('2026-09-01',  97.90::numeric),
    ('2026-10-01',  98.40::numeric),
    ('2026-11-01',  99.80::numeric),
    ('2026-12-01', 101.20::numeric)
  ) AS x(d, p)
  ON CONFLICT ON CONSTRAINT price_benchmark_idempotency_key DO NOTHING;

  -- ============================================================
  -- WTI quarterly Feb-2025 → Dec-2026 (~$2–4 below Brent)
  -- ============================================================
  INSERT INTO price_benchmark (
    tenant_id, benchmark_code, price_date, price_value, unit,
    period_grain, source, data_classification,
    created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT v_tenant, 'wti', d::date, p, 'usd_per_bbl',
    'monthly', 'market', 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM (VALUES
    ('2025-03-01',  62.40::numeric),
    ('2025-06-01',  75.50::numeric),
    ('2025-09-01',  86.20::numeric),
    ('2025-12-01',  96.80::numeric),
    ('2026-03-01', 105.80::numeric),
    ('2026-06-01', 103.20::numeric),
    ('2026-09-01',  98.60::numeric),
    ('2026-12-01', 101.70::numeric)
  ) AS x(d, p)
  ON CONFLICT ON CONSTRAINT price_benchmark_idempotency_key DO NOTHING;

  -- ============================================================
  -- USD/AED monthly Feb-2025 → Dec-2026 (near 3.6725 peg; unit=aed_per_usd)
  -- ============================================================
  INSERT INTO price_benchmark (
    tenant_id, benchmark_code, price_date, price_value, unit,
    period_grain, source, data_classification,
    created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT v_tenant, 'usd_aed', d::date, p, 'aed_per_usd',
    'monthly', 'osp_official', 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM (VALUES
    ('2025-02-01', 3.6725::numeric),
    ('2025-03-01', 3.6726::numeric),
    ('2025-04-01', 3.6724::numeric),
    ('2025-05-01', 3.6725::numeric),
    ('2025-06-01', 3.6727::numeric),
    ('2025-07-01', 3.6725::numeric),
    ('2025-08-01', 3.6724::numeric),
    ('2025-09-01', 3.6726::numeric),
    ('2025-10-01', 3.6725::numeric),
    ('2025-11-01', 3.6725::numeric),
    ('2025-12-01', 3.6724::numeric),
    ('2026-01-01', 3.6725::numeric),
    ('2026-02-01', 3.6726::numeric),
    ('2026-03-01', 3.6725::numeric),
    ('2026-04-01', 3.6724::numeric),
    ('2026-05-01', 3.6725::numeric),
    ('2026-06-01', 3.6726::numeric),
    ('2026-07-01', 3.6725::numeric),
    ('2026-08-01', 3.6724::numeric),
    ('2026-09-01', 3.6725::numeric),
    ('2026-10-01', 3.6726::numeric),
    ('2026-11-01', 3.6725::numeric),
    ('2026-12-01', 3.6724::numeric)
  ) AS x(d, p)
  ON CONFLICT ON CONSTRAINT price_benchmark_idempotency_key DO NOTHING;

  RAISE NOTICE '333: Price benchmarks seeded — murban_osp 23 + brent 23 + dubai 23 + wti 8 + usd_aed 23 (ON CONFLICT DO NOTHING).';
END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (333, '333_crq_seed_price_benchmarks', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM price_benchmark
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--     AND benchmark_code IN ('murban_osp','brent','dubai','wti','usd_aed')
--     AND price_date BETWEEN '2025-02-01' AND '2026-12-01'
--     AND data_classification = 'demo'
--     AND source IN ('osp_official','market');
-- DELETE FROM schema_migrations WHERE version = 333;
-- COMMIT;
-- ============================================================
