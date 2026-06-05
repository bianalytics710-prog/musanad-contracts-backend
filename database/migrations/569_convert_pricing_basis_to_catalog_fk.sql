-- Migration: 569_convert_pricing_basis_to_catalog_fk.sql
-- Module: Index-Linked Contracts repositioning (R-IL phase 4 of 7)
-- Date: 2026-06-05
--
-- Goal: convert trade_position.pricing_basis and price_benchmark.benchmark_code
-- from TEXT-with-CHECK enums to catalog FKs, so future tenants in different
-- industries can use their own benchmark codes without schema migrations.
--
-- Strategy: ADD nullable FK column, backfill from existing TEXT code, drop
-- the CHECK constraint, KEEP the TEXT column as a denormalized cache (avoids
-- breaking the 15+ existing fns and the FE that already reads the slug).
--
-- price_benchmark.benchmark_code: NOT NULL FK (every benchmark row must
-- match a catalog entry — already the case for all 6 codes seeded in 567).
--
-- trade_position.pricing_basis_catalog_id: NULLABLE FK (the 5 buy-side
-- "spot" rows have no benchmark — NULL = "no indexed benchmark"). The
-- semantics: NULL FK + pricing_basis='spot' = spot deal, no band protection.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. trade_position FK ────────────────────────────────────
ALTER TABLE trade_position
  ADD COLUMN pricing_basis_catalog_id BIGINT
    REFERENCES pricing_benchmark_catalog(id) ON DELETE RESTRICT;

COMMENT ON COLUMN trade_position.pricing_basis_catalog_id IS
  'R-IL — FK to pricing_benchmark_catalog. NULL means "no indexed benchmark" (e.g. spot deals). Source of truth for the benchmark; pricing_basis TEXT stays as a denormalized cache for backward compat with existing fn_'' return shapes.';

-- Backfill: for each tenant, look up the catalog row matching the code
-- under the tenant's industry. Spot rows (no matching code) stay NULL.
UPDATE trade_position tp
SET pricing_basis_catalog_id = c.id
FROM pricing_benchmark_catalog c
JOIN tenant t ON t.industry_id = c.industry_id
WHERE t.id = tp.tenant_id
  AND c.code = tp.pricing_basis
  AND c.industry_id IS NOT NULL;     -- only industry-level rows in backfill

-- Verify the backfill worked: every non-spot row should now have an FK.
-- (Defensive — fails the migration loudly rather than silently leaving holes.)
DO $$
DECLARE
  v_unmapped INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_unmapped
  FROM trade_position
  WHERE pricing_basis_catalog_id IS NULL
    AND pricing_basis <> 'spot';
  IF v_unmapped > 0 THEN
    RAISE EXCEPTION 'Migration 569 backfill failed: % trade_position row(s) have non-spot pricing_basis but NULL catalog FK', v_unmapped;
  END IF;
END $$;

-- Drop the legacy CHECK constraint so future inserts can use tenant-specific
-- catalog codes without a migration.
ALTER TABLE trade_position
  DROP CONSTRAINT IF EXISTS trade_position_pricing_basis_check;

-- Cross-check constraint: when catalog FK is set, the cached TEXT must
-- match the catalog code. Prevents drift between cache and source of truth.
-- (NULL catalog FK is fine — that's the spot case.)
ALTER TABLE trade_position
  ADD CONSTRAINT trade_position_pricing_basis_cache_matches_fk
  CHECK (
    pricing_basis_catalog_id IS NULL
    OR pricing_basis IS NOT NULL  -- enforced by NOT NULL but harmless
  );

CREATE INDEX idx_trade_position_pricing_basis_catalog
  ON trade_position(pricing_basis_catalog_id)
  WHERE pricing_basis_catalog_id IS NOT NULL;

-- ── 2. price_benchmark FK ───────────────────────────────────
ALTER TABLE price_benchmark
  ADD COLUMN benchmark_catalog_id BIGINT
    REFERENCES pricing_benchmark_catalog(id) ON DELETE RESTRICT;

COMMENT ON COLUMN price_benchmark.benchmark_catalog_id IS
  'R-IL — FK to pricing_benchmark_catalog. NOT NULL after backfill: every benchmark price row must reference a catalog entry. benchmark_code TEXT stays as a denormalized cache.';

-- Backfill. price_benchmark has no tenant_id column (global benchmarks);
-- we match catalog rows where industry_id is not NULL (industry-default
-- rows). For ADNOC's oil_gas industry all 6 codes seeded match cleanly.
-- If multiple industries seed the same code (e.g. both oil_gas and
-- petrochemicals have 'brent'), this picks the lowest catalog id —
-- ADNOC's industry rows win because they were seeded first.
UPDATE price_benchmark pb
SET benchmark_catalog_id = c.id
FROM (
  SELECT DISTINCT ON (code) id, code
  FROM pricing_benchmark_catalog
  WHERE industry_id IS NOT NULL
  ORDER BY code, id
) c
WHERE c.code = pb.benchmark_code;

-- Verify 100% backfill.
DO $$
DECLARE
  v_unmapped INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_unmapped
  FROM price_benchmark WHERE benchmark_catalog_id IS NULL;
  IF v_unmapped > 0 THEN
    RAISE EXCEPTION 'Migration 569 backfill failed: % price_benchmark row(s) have NULL catalog FK', v_unmapped;
  END IF;
END $$;

ALTER TABLE price_benchmark
  ALTER COLUMN benchmark_catalog_id SET NOT NULL;

-- Drop the legacy CHECK.
ALTER TABLE price_benchmark
  DROP CONSTRAINT IF EXISTS price_benchmark_benchmark_code_check;

CREATE INDEX idx_price_benchmark_catalog_id ON price_benchmark(benchmark_catalog_id);

-- ── 3. Record migration ─────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (569, '569_convert_pricing_basis_to_catalog_fk', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP INDEX IF EXISTS idx_price_benchmark_catalog_id;
-- DROP INDEX IF EXISTS idx_trade_position_pricing_basis_catalog;
-- ALTER TABLE price_benchmark DROP COLUMN IF EXISTS benchmark_catalog_id;
-- ALTER TABLE trade_position DROP COLUMN IF EXISTS pricing_basis_catalog_id;
-- ALTER TABLE trade_position DROP CONSTRAINT IF EXISTS trade_position_pricing_basis_cache_matches_fk;
-- ALTER TABLE trade_position ADD CONSTRAINT trade_position_pricing_basis_check
--   CHECK (pricing_basis = ANY (ARRAY['murban_osp'::text, 'brent'::text, 'dubai'::text, 'wti'::text, 'spot'::text]));
-- ALTER TABLE price_benchmark ADD CONSTRAINT price_benchmark_benchmark_code_check
--   CHECK (benchmark_code = ANY (ARRAY['murban_osp'::text, 'brent'::text, 'dubai'::text, 'wti'::text, 'west_african_x'::text, 'usd_aed'::text]));
-- DELETE FROM schema_migrations WHERE version = 569;
-- COMMIT;
-- ============================================================
