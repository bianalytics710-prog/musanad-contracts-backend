-- Migration: 567_pricing_benchmark_catalog.sql
-- Module: Index-Linked Contracts repositioning (R-IL phase 2 of 7)
-- Date: 2026-06-05
--
-- Goal: catalog the universe of pricing benchmarks ("Murban OSP", "Brent",
-- "Cement Index", etc.) so the Index-Linked Contracts module can render
-- tenant-appropriate labels + units instead of oil-trade hard-codes.
--
-- Scoping: dual-nullable (industry_id OR tenant_id, exactly one).
--   - Industry row  (industry_id set, tenant_id NULL) — default for every
--     tenant in that industry.
--   - Tenant row    (industry_id NULL, tenant_id set) — Platform-Admin-added
--     override or extension for one specific tenant.
--
-- Tenant resolution rule (implemented in mig 572 fn):
--   resolved set = industry rows ∪ tenant rows, with tenant rows winning
--   on code collision (override semantics).
--
-- Seed 6 oil_gas rows from the codes already in price_benchmark + the
-- pricing_basis enum (murban_osp, brent, dubai, wti, west_african_x,
-- usd_aed). usd_aed is a FX benchmark and tagged accordingly.
--
-- RLS: enabled but lenient. Reads are allowed for any tenant whose
-- industry_id matches OR whose tenant_id matches. Writes gated by
-- platform.catalog.manage (Platform Admin only) — enforced at the BE
-- controller layer (mig 571 adds the fn-level gate).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. Table ────────────────────────────────────────────────
CREATE TABLE pricing_benchmark_catalog (
  id                  BIGSERIAL PRIMARY KEY,
  industry_id         BIGINT REFERENCES industry(id) ON DELETE RESTRICT,
  tenant_id           UUID   REFERENCES tenant(id)   ON DELETE RESTRICT,

  code                TEXT NOT NULL,
  display_label_en    TEXT NOT NULL,
  display_label_ar    TEXT,
  unit_label          TEXT NOT NULL,           -- e.g. 'USD/bbl', 'AED/MT', 'USD/MWh'
  volume_unit_label   TEXT NOT NULL,           -- e.g. 'bbl', 'MT', 'MWh', 'm3'
  typical_low         NUMERIC(14,4),           -- what-if slider lower bound
  typical_high        NUMERIC(14,4),           -- what-if slider upper bound
  kicker_text         TEXT,                    -- detail-page kicker string
  is_fx               BOOLEAN NOT NULL DEFAULT FALSE,
  sort_order          INTEGER NOT NULL DEFAULT 100,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,

  -- Exactly one scope must be set (industry row XOR tenant row).
  CONSTRAINT pbc_scope_xor
    CHECK ((industry_id IS NOT NULL)::int + (tenant_id IS NOT NULL)::int = 1),

  -- Code is unique within scope (one industry can't have two 'murban_osp';
  -- one tenant can override an industry code with the same code).
  CONSTRAINT pbc_industry_code_uniq UNIQUE (industry_id, code),
  CONSTRAINT pbc_tenant_code_uniq   UNIQUE (tenant_id,   code),

  CONSTRAINT pbc_code_format
    CHECK (code ~ '^[a-z][a-z0-9_]*$'),
  CONSTRAINT pbc_typical_range
    CHECK (typical_low IS NULL OR typical_high IS NULL OR typical_low <= typical_high)
);

COMMENT ON TABLE pricing_benchmark_catalog IS
  'R-IL — Catalog of pricing benchmarks (Murban OSP, Brent, Cement Index, USD/AED FX, etc.) scoped per-industry (default) or per-tenant (override). Tenant rows win on code collision. unit_label / volume_unit_label drive FE rendering for any industry. typical_low/high bound the what-if simulator slider.';
COMMENT ON COLUMN pricing_benchmark_catalog.code IS
  'Stable slug (e.g. murban_osp, brent, cement_idx_uae). FK target for trade_position.pricing_basis after mig 569.';
COMMENT ON COLUMN pricing_benchmark_catalog.unit_label IS
  'Free-text unit shown in tables and charts. E.g. "USD/bbl" for crude, "AED/MT" for steel, "USD/MWh" for power.';
COMMENT ON COLUMN pricing_benchmark_catalog.volume_unit_label IS
  'Free-text volume unit (singular, used in "Volume" column header rendering). E.g. "bbl", "MT", "MWh", "m3".';
COMMENT ON COLUMN pricing_benchmark_catalog.kicker_text IS
  'Tenant-configurable kicker string above the Index-Linked Contracts H1 (e.g. "Sell-side oil-trade desk" for oil_gas, "Pass-through commodity exposure" for construction). NULL falls back to a generic default.';
COMMENT ON COLUMN pricing_benchmark_catalog.is_fx IS
  'TRUE for FX benchmarks (e.g. usd_aed). FX rows are not shown in the position-list price column but feed FX conversion.';

-- ── 2. Indexes ──────────────────────────────────────────────
CREATE INDEX idx_pbc_industry_active     ON pricing_benchmark_catalog(industry_id) WHERE is_active = TRUE AND industry_id IS NOT NULL;
CREATE INDEX idx_pbc_tenant_active       ON pricing_benchmark_catalog(tenant_id)   WHERE is_active = TRUE AND tenant_id   IS NOT NULL;
CREATE INDEX idx_pbc_code                ON pricing_benchmark_catalog(code);
CREATE INDEX idx_pbc_created_by          ON pricing_benchmark_catalog(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_pbc_updated_by          ON pricing_benchmark_catalog(updated_by) WHERE updated_by IS NOT NULL;

-- ── 3. RLS ─────────────────────────────────────────────────
ALTER TABLE pricing_benchmark_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE pricing_benchmark_catalog FORCE  ROW LEVEL SECURITY;

-- Read: tenant sees their industry's rows + their own tenant rows.
-- Industry-only readers (Platform Admin) also covered by the FE BE layer.
CREATE POLICY pbc_tenant_select ON pricing_benchmark_catalog
  FOR SELECT USING (
    -- Industry row: tenant must be in this industry.
    (industry_id IS NOT NULL AND industry_id = (
       SELECT t.industry_id FROM tenant t
       WHERE t.id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    ))
    OR
    -- Tenant row: must match GUC tenant.
    (tenant_id IS NOT NULL AND tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid)
    OR
    -- Platform admin reads everything.
    fn_current_user_has_permission('platform.catalog.manage')
  );

-- Write: platform admin only.
CREATE POLICY pbc_admin_modify ON pricing_benchmark_catalog
  FOR ALL USING (
    fn_current_user_has_permission('platform.catalog.manage')
  ) WITH CHECK (
    fn_current_user_has_permission('platform.catalog.manage')
  );

CREATE POLICY pbc_deny_direct_delete ON pricing_benchmark_catalog
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- ── 4. Audit trigger ────────────────────────────────────────
CREATE TRIGGER audit_pricing_benchmark_catalog_changes
  AFTER INSERT OR UPDATE OR DELETE ON pricing_benchmark_catalog
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ── 5. Seed oil_gas industry-level rows ─────────────────────
INSERT INTO pricing_benchmark_catalog
  (industry_id, code, display_label_en, display_label_ar, unit_label, volume_unit_label, typical_low, typical_high, kicker_text, is_fx, sort_order)
SELECT
  i.id,
  v.code,
  v.label_en,
  v.label_ar,
  v.unit_label,
  v.vol_unit,
  v.lo,
  v.hi,
  v.kicker,
  v.is_fx,
  v.sort_order
FROM industry i,
  (VALUES
    ('murban_osp',     'Murban OSP',           'سعر مربان الرسمي',     'USD/bbl', 'bbl', 60::NUMERIC,  140::NUMERIC, 'Sell-side oil-trade desk', FALSE, 10),
    ('brent',          'Brent',                'برنت',                  'USD/bbl', 'bbl', 55::NUMERIC,  135::NUMERIC, NULL, FALSE, 20),
    ('dubai',          'Dubai',                'دبي',                   'USD/bbl', 'bbl', 55::NUMERIC,  135::NUMERIC, NULL, FALSE, 30),
    ('wti',            'WTI',                  'غرب تكساس الوسيط',     'USD/bbl', 'bbl', 50::NUMERIC,  130::NUMERIC, NULL, FALSE, 40),
    ('west_african_x', 'West African (XCFA)',  'الخام الأفريقي الغربي', 'USD/bbl', 'bbl', 55::NUMERIC,  135::NUMERIC, NULL, FALSE, 50),
    ('usd_aed',        'USD / AED',            'دولار أمريكي / درهم',  'AED/USD', 'USD', 3.67::NUMERIC, 3.67::NUMERIC, NULL, TRUE, 100)
  ) AS v(code, label_en, label_ar, unit_label, vol_unit, lo, hi, kicker, is_fx, sort_order)
WHERE i.code = 'oil_gas';

-- ── 6. Record migration ─────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (567, '567_pricing_benchmark_catalog', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_pricing_benchmark_catalog_changes ON pricing_benchmark_catalog;
-- DROP POLICY IF EXISTS pbc_deny_direct_delete ON pricing_benchmark_catalog;
-- DROP POLICY IF EXISTS pbc_admin_modify ON pricing_benchmark_catalog;
-- DROP POLICY IF EXISTS pbc_tenant_select ON pricing_benchmark_catalog;
-- DROP TABLE IF EXISTS pricing_benchmark_catalog;
-- DELETE FROM schema_migrations WHERE version = 567;
-- COMMIT;
-- ============================================================
