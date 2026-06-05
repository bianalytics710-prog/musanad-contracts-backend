-- Migration: 566_industry_table_and_tenant_fk.sql
-- Module: Index-Linked Contracts repositioning (R-IL phase 1 of 7)
-- Date: 2026-06-05
--
-- Goal: introduce `industry` as a first-class catalog scope so the
-- Index-Linked Contracts module (currently hard-coded to oil-trade
-- vocabulary) can be reused by tenants in other industries via
-- per-industry pricing-benchmark + cost-component catalogs (mig 567/568).
--
-- Migration shape:
--   1. CREATE TABLE industry (global catalog, no RLS — platform-scoped).
--   2. Seed oil_gas (Oil & Gas).
--   3. Normalize tenant.industry (TEXT, currently NULL) into a real FK
--      industry_id BIGINT. Tag ADNOC -> oil_gas.
--   4. Drop the old tenant.industry TEXT column (no live data, safe).
--
-- NOTE: Industry is *global config* curated by Platform Admin, not tenant
-- data. No RLS, no tenant_id. Permission gate is via platform.catalog.manage
-- on the FE/BE layer (added in mig 571).
--
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. industry table ───────────────────────────────────────
CREATE TABLE industry (
  id                BIGSERIAL PRIMARY KEY,
  code              TEXT NOT NULL,
  display_label_en  TEXT NOT NULL,
  display_label_ar  TEXT,
  description       TEXT,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by        BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by        BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT industry_code_key UNIQUE (code),
  CONSTRAINT industry_code_format
    CHECK (code ~ '^[a-z][a-z0-9_]*$')
);

COMMENT ON TABLE industry IS
  'R-IL — Global industry catalog. Each tenant is tagged with one industry (tenant.industry_id). Drives which pricing_benchmark_catalog + trade_cost_component_catalog rows the Index-Linked Contracts module surfaces. Platform-scoped: no RLS, no tenant_id — curated by Platform Admin via permission platform.catalog.manage.';
COMMENT ON COLUMN industry.code IS
  'Slug: lowercase, underscores only (e.g. oil_gas, construction, fmcg_distribution). Stable across renames; used as the FK target for both catalogs.';
COMMENT ON COLUMN industry.display_label_en IS
  'Human-readable English label shown in Platform Admin UI and tenant module headers (e.g. "Oil & Gas").';
COMMENT ON COLUMN industry.display_label_ar IS
  'Optional Arabic label for i18n parity. NULL until provided.';

-- Audit trigger (standard pattern)
CREATE TRIGGER audit_industry_changes
  AFTER INSERT OR UPDATE OR DELETE ON industry
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ── 2. Seed oil_gas ─────────────────────────────────────────
INSERT INTO industry (code, display_label_en, display_label_ar, description)
VALUES (
  'oil_gas',
  'Oil & Gas',
  'النفط والغاز',
  'Upstream + downstream oil & gas. Covers Murban OSP-linked sell positions, crude-trade cost components (lifting, transport-charter, hedge, refining, downstream-sale).'
);

-- ── 3. Normalize tenant.industry TEXT into industry_id FK ───
ALTER TABLE tenant
  ADD COLUMN industry_id BIGINT REFERENCES industry(id) ON DELETE RESTRICT;

COMMENT ON COLUMN tenant.industry_id IS
  'R-IL — FK to industry catalog. Determines which pricing-benchmark + cost-component rows the tenant sees in the Index-Linked Contracts module. NULL = unconfigured (module blocks with empty state). Set by Platform Admin at onboarding.';

CREATE INDEX idx_tenant_industry_id ON tenant(industry_id);

-- Tag ADNOC tenant -> oil_gas
UPDATE tenant
SET industry_id = (SELECT id FROM industry WHERE code = 'oil_gas')
WHERE id = '00000000-0000-0000-0000-000000000001';

-- Drop the dangling legacy TEXT column (was NULL across the entire tenant
-- table; replaced wholesale by industry_id FK above).
ALTER TABLE tenant DROP COLUMN industry;

-- ── 4. Record migration ─────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (566, '566_industry_table_and_tenant_fk', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- ALTER TABLE tenant ADD COLUMN industry TEXT;
-- ALTER TABLE tenant DROP COLUMN industry_id;
-- DROP INDEX IF EXISTS idx_tenant_industry_id;
-- DROP TRIGGER IF EXISTS audit_industry_changes ON industry;
-- DROP TABLE IF EXISTS industry;
-- DELETE FROM schema_migrations WHERE version = 566;
-- COMMIT;
-- ============================================================
