-- Migration: 570_convert_cost_component_type_to_catalog_fk.sql
-- Module: Index-Linked Contracts repositioning (R-IL phase 5 of 7)
-- Date: 2026-06-05
--
-- Goal: convert trade_cost_component.component_type (TEXT with CHECK enum)
-- to FK on cost_component_catalog, so future tenants in different
-- industries can have their own waterfall component types without schema
-- migrations.
--
-- Same pattern as 569: ADD FK column, backfill, drop CHECK, keep TEXT as
-- denormalized cache for backward compat. NOT NULL FK after backfill.
--
-- Backfill resolves the component_type slug to a catalog row matching the
-- row's tenant industry.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. Add FK column ────────────────────────────────────────
ALTER TABLE trade_cost_component
  ADD COLUMN component_catalog_id BIGINT
    REFERENCES cost_component_catalog(id) ON DELETE RESTRICT;

COMMENT ON COLUMN trade_cost_component.component_catalog_id IS
  'R-IL — FK to cost_component_catalog. NOT NULL after backfill. Source of truth for the component type, sign, and waterfall ordering. component_type TEXT stays as a denormalized cache for backward compat.';

-- ── 2. Backfill from cached TEXT ────────────────────────────
UPDATE trade_cost_component tcc
SET component_catalog_id = c.id
FROM cost_component_catalog c
JOIN tenant t ON t.industry_id = c.industry_id
WHERE t.id = tcc.tenant_id
  AND c.code = tcc.component_type
  AND c.industry_id IS NOT NULL;

-- ── 3. Verify 100% backfill ─────────────────────────────────
DO $$
DECLARE
  v_unmapped INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_unmapped
  FROM trade_cost_component WHERE component_catalog_id IS NULL;
  IF v_unmapped > 0 THEN
    RAISE EXCEPTION 'Migration 570 backfill failed: % trade_cost_component row(s) have NULL catalog FK', v_unmapped;
  END IF;
END $$;

-- ── 4. Enforce NOT NULL + drop legacy CHECK ────────────────
ALTER TABLE trade_cost_component
  ALTER COLUMN component_catalog_id SET NOT NULL;

ALTER TABLE trade_cost_component
  DROP CONSTRAINT IF EXISTS trade_cost_component_component_type_check;

CREATE INDEX idx_trade_cost_component_catalog_id
  ON trade_cost_component(component_catalog_id);

-- ── 5. Record migration ─────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (570, '570_convert_cost_component_type_to_catalog_fk', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP INDEX IF EXISTS idx_trade_cost_component_catalog_id;
-- ALTER TABLE trade_cost_component DROP COLUMN IF EXISTS component_catalog_id;
-- ALTER TABLE trade_cost_component ADD CONSTRAINT trade_cost_component_component_type_check
--   CHECK (component_type = ANY (ARRAY['lifting'::text, 'transport_charter'::text, 'insurance'::text, 'hedge'::text, 'crude_purchase'::text, 'refining'::text, 'transport'::text, 'storage'::text, 'downstream_sale'::text]));
-- DELETE FROM schema_migrations WHERE version = 570;
-- COMMIT;
-- ============================================================
