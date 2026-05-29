-- Migration: 319_cro_seed_parties_and_benchmarks.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: Seed data migration 1/2.
--   E-1: 2 new party rows (Hanwha TotalEnergies + West Africa Crude Supplier) — CR-M seed pattern.
--   E-2: 7 price_benchmark rows (Murban OSP series + Brent/Dubai/WAF context + USD/AED FX).
--        CRITICAL: usd_aed row MUST be inserted before migration 320 bootstrap calls fn_margin_compute.
--   All rows idempotent (ON CONFLICT DO NOTHING).
--   Tenant: 00000000-0000-0000-0000-000000000001 (ADNOC).
--   created_by = MIN(id) FROM "user" WHERE is_active (CR-M seed pattern).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- E-1: party rows — Hanwha TotalEnergies + West Africa Crude Supplier
-- (resolves needed for migration 320 position FKs)
-- NOTE: party is a shared table with NO tenant_id column (per live schema — confirmed mig 285).
--       Idempotency: WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = x.name_en)
-- ============================================================
DO $$
DECLARE
  v_actor   BIGINT;
BEGIN
  SELECT MIN(id) INTO v_actor FROM "user" WHERE is_active = TRUE;

  -- Hanwha TotalEnergies (Korean refinery buyer for 2a seller positions)
  INSERT INTO party (
    party_type, name_en, name_ar, country,
    is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT 'company', 'Hanwha TotalEnergies', 'هانوا توتال إنرجيز', 'South Korea',
         TRUE, '{"tradeRole":"refinery_buyer","grade":"murban_term"}'::jsonb,
         NOW(), NOW(), v_actor, v_actor, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Hanwha TotalEnergies');

  -- West Africa Crude Supplier (spot seller for 2b buyer position)
  INSERT INTO party (
    party_type, name_en, name_ar, country,
    is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT 'company', 'West Africa Crude Supplier', 'مورد الخام لغرب أفريقيا', 'Nigeria',
         TRUE, '{"tradeRole":"spot_seller","grade":"west_african_x"}'::jsonb,
         NOW(), NOW(), v_actor, v_actor, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'West Africa Crude Supplier');
END $$;

-- ============================================================
-- E-2: price_benchmark rows — usd_aed FIRST (required by fn_margin_compute FX resolution)
-- ============================================================
DO $$
DECLARE
  v_actor  BIGINT;
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
BEGIN
  SELECT MIN(id) INTO v_actor FROM "user" WHERE is_active = TRUE;

  -- usd_aed FIRST — fn_margin_compute step 4 requires this row before bootstrap snapshots
  INSERT INTO price_benchmark (
    tenant_id, benchmark_code, price_date, price_value, unit, period_grain,
    source, notes, data_classification, created_at, updated_at, created_by, updated_by, is_active
  ) VALUES (
    v_tenant, 'usd_aed', '2026-05-01', 3.6725, 'aed_per_usd', 'monthly',
    'market', 'USD/AED FX rate — used for all AED conversion', 'demo',
    NOW(), NOW(), v_actor, v_actor, TRUE
  )
  ON CONFLICT (tenant_id, benchmark_code, price_date) DO NOTHING;

  -- Murban OSP historical context + bootstrap + AC#2 OSP-drop target
  INSERT INTO price_benchmark (
    tenant_id, benchmark_code, price_date, price_value, unit, period_grain,
    source, notes, data_classification, created_at, updated_at, created_by, updated_by, is_active
  ) VALUES
    (v_tenant, 'murban_osp', '2025-02-01', 63.0000, 'usd_per_bbl', 'monthly',
     'osp_official', 'Murban OSP Feb-25 (historical context low)', 'demo',
     NOW(), NOW(), v_actor, v_actor, TRUE),
    (v_tenant, 'murban_osp', '2026-05-01', 110.7500, 'usd_per_bbl', 'monthly',
     'osp_official', 'Murban OSP May-26 — bootstrap OSP for 2a hero', 'demo',
     NOW(), NOW(), v_actor, v_actor, TRUE),
    (v_tenant, 'murban_osp', '2026-06-01', 104.4400, 'usd_per_bbl', 'monthly',
     'osp_official', 'Murban OSP Jun-26 — OSP-drop recompute target (AC#2)', 'demo',
     NOW(), NOW(), v_actor, v_actor, TRUE)
  ON CONFLICT (tenant_id, benchmark_code, price_date) DO NOTHING;

  -- Market context benchmarks
  INSERT INTO price_benchmark (
    tenant_id, benchmark_code, price_date, price_value, unit, period_grain,
    source, notes, data_classification, created_at, updated_at, created_by, updated_by, is_active
  ) VALUES
    (v_tenant, 'brent',         '2026-05-15', 112.1000, 'usd_per_bbl', 'daily',
     'market', 'Brent spot context May-26', 'demo',
     NOW(), NOW(), v_actor, v_actor, TRUE),
    (v_tenant, 'dubai',         '2026-05-15', 108.8000, 'usd_per_bbl', 'daily',
     'market', 'Dubai spot context May-26', 'demo',
     NOW(), NOW(), v_actor, v_actor, TRUE),
    (v_tenant, 'west_african_x','2026-05-20',  96.2000, 'usd_per_bbl', 'spot',
     'market', 'WAF grade spot basis for 2b buy decision', 'demo',
     NOW(), NOW(), v_actor, v_actor, TRUE)
  ON CONFLICT (tenant_id, benchmark_code, price_date) DO NOTHING;
END $$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (319, '319_cro_seed_parties_and_benchmarks', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM price_benchmark
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--     AND benchmark_code IN ('murban_osp','brent','dubai','west_african_x','usd_aed')
--     AND data_classification = 'demo';
-- DELETE FROM party
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--     AND name_en IN ('Hanwha TotalEnergies','West Africa Crude Supplier')
--     AND is_seed = TRUE;
-- DELETE FROM schema_migrations WHERE version = 319;
-- COMMIT;
-- ============================================================
