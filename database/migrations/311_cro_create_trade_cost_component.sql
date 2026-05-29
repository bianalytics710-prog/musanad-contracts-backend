-- Migration: 311_cro_create_trade_cost_component.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: CREATE TABLE trade_cost_component — per-bbl margin inputs per trade_position.
--              Seller cost legs: lifting/transport_charter/insurance/hedge.
--              Buyer cost legs: crude_purchase/refining/transport/storage.
--              Buyer revenue leg: downstream_sale (is_revenue=TRUE).
--              UNIQUE (tenant_id, trade_position_id, component_type) — one component per type per position.
--              FORCE RLS + 3 policies + audit trigger + BIGSERIAL PK.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE TABLE trade_cost_component (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  trade_position_id   BIGINT NOT NULL REFERENCES trade_position(id) ON DELETE RESTRICT,

  component_type      TEXT NOT NULL
    CHECK (component_type IN (
      'lifting','transport_charter','insurance','hedge',
      'crude_purchase','refining','transport','storage',
      'downstream_sale'
    )),
  amount_usd_per_bbl  NUMERIC(12,4) NOT NULL CHECK (amount_usd_per_bbl >= 0),
  is_revenue          BOOLEAN NOT NULL DEFAULT FALSE,
  notes               TEXT,
  data_classification TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT trade_cost_component_key UNIQUE (tenant_id, trade_position_id, component_type)
);

COMMENT ON TABLE trade_cost_component IS
  'CR-O M21 Financial Intelligence (Trade half) — per-bbl margin inputs per trade_position. Seller cost legs: lifting/transport_charter/insurance/hedge (is_revenue=FALSE). Buyer cost legs: crude_purchase/refining/transport/storage (is_revenue=FALSE). Buyer revenue leg: downstream_sale (is_revenue=TRUE). OSP revenue for seller is NOT stored here — resolved from price_benchmark at fn_margin_compute time. NUMERIC(12,4) per-bbl. UNIQUE (tenant_id, trade_position_id, component_type).';
COMMENT ON COLUMN trade_cost_component.amount_usd_per_bbl IS 'NUMERIC(12,4) USD per barrel. For downstream_sale (is_revenue=TRUE): this is the blended downstream sale price.';
COMMENT ON COLUMN trade_cost_component.is_revenue IS 'TRUE only for downstream_sale component (buyer revenue leg). FALSE for all cost legs.';

-- Indexes
CREATE INDEX idx_trade_cost_component_tenant_id  ON trade_cost_component(tenant_id);
CREATE INDEX idx_trade_cost_component_position   ON trade_cost_component(trade_position_id);
CREATE INDEX idx_trade_cost_component_created_by ON trade_cost_component(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_trade_cost_component_updated_by ON trade_cost_component(updated_by) WHERE updated_by IS NOT NULL;
CREATE INDEX idx_trade_cost_component_active     ON trade_cost_component(id) WHERE is_active = TRUE;

-- RLS
ALTER TABLE trade_cost_component ENABLE ROW LEVEL SECURITY;
ALTER TABLE trade_cost_component FORCE  ROW LEVEL SECURITY;

CREATE POLICY trade_cost_component_tenant_select ON trade_cost_component
  FOR SELECT USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.margin.read')
  );

CREATE POLICY trade_cost_component_tenant_modify ON trade_cost_component
  FOR ALL USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.trade.manage')
  ) WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.trade.manage')
  );

CREATE POLICY trade_cost_component_deny_direct_delete ON trade_cost_component
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger
CREATE TRIGGER audit_trade_cost_component_changes
  AFTER INSERT OR UPDATE OR DELETE ON trade_cost_component
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (311, '311_cro_create_trade_cost_component', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_trade_cost_component_changes ON trade_cost_component;
-- DROP POLICY IF EXISTS trade_cost_component_deny_direct_delete ON trade_cost_component;
-- DROP POLICY IF EXISTS trade_cost_component_tenant_modify ON trade_cost_component;
-- DROP POLICY IF EXISTS trade_cost_component_tenant_select ON trade_cost_component;
-- DROP TABLE IF EXISTS trade_cost_component;
-- DELETE FROM schema_migrations WHERE version = 311;
-- COMMIT;
-- ============================================================
