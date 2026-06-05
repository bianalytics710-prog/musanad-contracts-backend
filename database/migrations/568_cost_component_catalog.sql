-- Migration: 568_cost_component_catalog.sql
-- Module: Index-Linked Contracts repositioning (R-IL phase 3 of 7)
-- Date: 2026-06-05
--
-- Goal: catalog the universe of margin-waterfall components (Lifting,
-- Transport, Hedge, Cement-purchase, Equipment-lease, etc.) so the
-- Margin Breakdown tab can render tenant-appropriate labels and the
-- correct +/- sign for each row, replacing the hard-coded CHECK enum on
-- trade_cost_component.component_type (mig 311).
--
-- Same dual-nullable scoping pattern as pricing_benchmark_catalog (567):
-- (industry_id XOR tenant_id). Tenant rows override industry rows on code
-- collision.
--
-- sign: '+' (revenue / added in the waterfall) or '-' (cost / subtracted).
-- This is what drives the Margin Breakdown waterfall layout — the FE no
-- longer needs to know which slugs are revenue.
--
-- sort_order drives the row order in the waterfall (e.g. revenue tiles
-- first, then costs, then net).
--
-- Seed 9 oil_gas rows from the trade_cost_component.component_type values
-- in use today (8 distinct: crude_purchase, downstream_sale, hedge,
-- insurance, refining, storage, transport, transport_charter), plus
-- lifting which is in the CHECK enum but unused by data.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. Table ────────────────────────────────────────────────
CREATE TABLE cost_component_catalog (
  id                  BIGSERIAL PRIMARY KEY,
  industry_id         BIGINT REFERENCES industry(id) ON DELETE RESTRICT,
  tenant_id           UUID   REFERENCES tenant(id)   ON DELETE RESTRICT,

  code                TEXT NOT NULL,
  display_label_en    TEXT NOT NULL,
  display_label_ar    TEXT,
  sign                TEXT NOT NULL CHECK (sign IN ('+', '-')),
  is_revenue          BOOLEAN NOT NULL DEFAULT FALSE,
  sort_order          INTEGER NOT NULL DEFAULT 100,
  description         TEXT,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT ccc_scope_xor
    CHECK ((industry_id IS NOT NULL)::int + (tenant_id IS NOT NULL)::int = 1),

  CONSTRAINT ccc_industry_code_uniq UNIQUE (industry_id, code),
  CONSTRAINT ccc_tenant_code_uniq   UNIQUE (tenant_id,   code),

  CONSTRAINT ccc_code_format
    CHECK (code ~ '^[a-z][a-z0-9_]*$'),

  -- sign + is_revenue must agree: revenue is always '+'.
  CONSTRAINT ccc_revenue_sign_agree
    CHECK ((is_revenue = TRUE AND sign = '+') OR is_revenue = FALSE)
);

COMMENT ON TABLE cost_component_catalog IS
  'R-IL — Catalog of margin-waterfall components (revenue lines + cost lines) scoped per-industry (default) or per-tenant (override). sign drives the +/- visual in the waterfall. sort_order drives left-to-right placement. FK target for trade_cost_component.component_type after mig 570.';
COMMENT ON COLUMN cost_component_catalog.code IS
  'Stable slug (e.g. transport_charter, lifting, cement_purchase). FK target.';
COMMENT ON COLUMN cost_component_catalog.sign IS
  'Display sign in the waterfall: "+" for revenue/upward bars, "-" for cost/downward bars. Drives both the math and the colour pill (success vs terracotta).';
COMMENT ON COLUMN cost_component_catalog.is_revenue IS
  'TRUE means this row is on the revenue side (sale, hedge gain, premium). FALSE means cost. Used by aggregation queries to compute gross revenue vs total cost.';
COMMENT ON COLUMN cost_component_catalog.sort_order IS
  'Lower sorts earlier in the waterfall. Revenue rows by convention sit at 10-50; costs at 100-900; net is rendered by the FE outside the catalog.';

-- ── 2. Indexes ──────────────────────────────────────────────
CREATE INDEX idx_ccc_industry_active ON cost_component_catalog(industry_id) WHERE is_active = TRUE AND industry_id IS NOT NULL;
CREATE INDEX idx_ccc_tenant_active   ON cost_component_catalog(tenant_id)   WHERE is_active = TRUE AND tenant_id   IS NOT NULL;
CREATE INDEX idx_ccc_code            ON cost_component_catalog(code);
CREATE INDEX idx_ccc_created_by      ON cost_component_catalog(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_ccc_updated_by      ON cost_component_catalog(updated_by) WHERE updated_by IS NOT NULL;

-- ── 3. RLS ─────────────────────────────────────────────────
ALTER TABLE cost_component_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE cost_component_catalog FORCE  ROW LEVEL SECURITY;

CREATE POLICY ccc_tenant_select ON cost_component_catalog
  FOR SELECT USING (
    (industry_id IS NOT NULL AND industry_id = (
       SELECT t.industry_id FROM tenant t
       WHERE t.id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    ))
    OR
    (tenant_id IS NOT NULL AND tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid)
    OR
    fn_current_user_has_permission('platform.catalog.manage')
  );

CREATE POLICY ccc_admin_modify ON cost_component_catalog
  FOR ALL USING (
    fn_current_user_has_permission('platform.catalog.manage')
  ) WITH CHECK (
    fn_current_user_has_permission('platform.catalog.manage')
  );

CREATE POLICY ccc_deny_direct_delete ON cost_component_catalog
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- ── 4. Audit trigger ────────────────────────────────────────
CREATE TRIGGER audit_cost_component_catalog_changes
  AFTER INSERT OR UPDATE OR DELETE ON cost_component_catalog
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ── 5. Seed oil_gas industry-level rows ─────────────────────
-- 9 rows: 1 revenue (downstream_sale) + 8 costs.
INSERT INTO cost_component_catalog
  (industry_id, code, display_label_en, display_label_ar, sign, is_revenue, sort_order, description)
SELECT
  i.id,
  v.code,
  v.label_en,
  v.label_ar,
  v.sign,
  v.is_revenue,
  v.sort_order,
  v.description
FROM industry i,
  (VALUES
    -- Revenue side
    ('downstream_sale',   'Downstream sale',     'البيع النهائي',          '+', TRUE,   10,  'Realised buyer price (= benchmark + buyer premium). Top of the margin waterfall.'),

    -- Cost side
    ('crude_purchase',    'Crude transfer-in',   'استلام النفط الخام',     '-', FALSE, 110,  'Transfer-in price from upstream (typically at OSP). The producer-margin sits with upstream; trading desk earns the premium net of delivery.'),
    ('lifting',           'Lifting',             'الشحن من المنشأ',        '-', FALSE, 120,  'Cost of physical lifting from terminal / production point.'),
    ('transport_charter', 'Transport / Charter', 'النقل والاستئجار',       '-', FALSE, 130,  'Vessel charter or pipeline transit cost from lifting point to discharge port.'),
    ('transport',         'Transport',           'النقل',                  '-', FALSE, 135,  'Generic inland or last-mile transport cost (used when transport_charter does not apply).'),
    ('insurance',         'Insurance',           'التأمين',                '-', FALSE, 140,  'Cargo insurance + war-risk uplift over the voyage window.'),
    ('hedge',             'Hedge',               'التحوط',                 '-', FALSE, 150,  'Hedging cost (LC financing + freight/fuel hedge premium). Negative when the desk pays to hedge; can be positive net in unusual markets.'),
    ('storage',           'Storage',             'التخزين',                '-', FALSE, 160,  'Floating- or tank-storage costs when the cargo is held before delivery.'),
    ('refining',          'Refining',            'التكرير',                '-', FALSE, 170,  'Refining throughput cost (relevant when the desk takes the cargo into a refinery rather than re-selling crude).')
  ) AS v(code, label_en, label_ar, sign, is_revenue, sort_order, description)
WHERE i.code = 'oil_gas';

-- ── 6. Record migration ─────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (568, '568_cost_component_catalog', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_cost_component_catalog_changes ON cost_component_catalog;
-- DROP POLICY IF EXISTS ccc_deny_direct_delete ON cost_component_catalog;
-- DROP POLICY IF EXISTS ccc_admin_modify ON cost_component_catalog;
-- DROP POLICY IF EXISTS ccc_tenant_select ON cost_component_catalog;
-- DROP TABLE IF EXISTS cost_component_catalog;
-- DELETE FROM schema_migrations WHERE version = 568;
-- COMMIT;
-- ============================================================
