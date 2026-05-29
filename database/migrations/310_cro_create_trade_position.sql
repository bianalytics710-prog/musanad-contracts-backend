-- Migration: 310_cro_create_trade_position.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: CREATE TABLE trade_position — a cargo or term-deal leg (sell or buy side).
--              Links to party (counterparty_id), party (internal_entity_id), contract (linked_contract_id).
--              NOTE: contract has NO tenant_id column (CR-F DEFECT-3) — tenant sourced from GUC.
--              FORCE RLS + 3 policies + audit trigger + BIGSERIAL PK.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE TABLE trade_position (
  id                 BIGSERIAL PRIMARY KEY,
  tenant_id          UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,

  position_ref       VARCHAR(60) NOT NULL,
  side               TEXT NOT NULL CHECK (side IN ('sell','buy')),
  grade              TEXT NOT NULL
    CHECK (grade IN ('murban','west_african_x','brent','dubai','wti','other')),
  counterparty_id    BIGINT NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  internal_entity_id BIGINT REFERENCES party(id) ON DELETE SET NULL,
  volume_bbl         NUMERIC(18,2) NOT NULL CHECK (volume_bbl > 0),
  pricing_basis      TEXT NOT NULL
    CHECK (pricing_basis IN ('murban_osp','brent','dubai','wti','spot')),
  delivery_month     DATE NOT NULL,
  term_or_spot       TEXT NOT NULL DEFAULT 'term'
    CHECK (term_or_spot IN ('term','spot')),
  linked_contract_id BIGINT REFERENCES contract(id) ON DELETE SET NULL,
  status             TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','priced','closed')),
  notes              TEXT,
  data_classification TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),

  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by         BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by         BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active          BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT trade_position_ref_key UNIQUE (tenant_id, position_ref)
);

COMMENT ON TABLE trade_position IS
  'CR-O M21 Financial Intelligence (Trade half) — a cargo or term-deal leg for sell or buy side. UNIQUE (tenant_id, position_ref). Column inheritance: counterparty name/country via party FK join; contract number/title via contract FK join (contract has no tenant_id — tenant from GUC per CR-F DEFECT-3 lesson). FORCE RLS.';
COMMENT ON COLUMN trade_position.pricing_basis IS 'Benchmark code driving seller revenue resolution (murban_osp | brent | dubai | wti) or spot for buyer/bespoke spot deals.';
COMMENT ON COLUMN trade_position.delivery_month IS 'First day of delivery month (e.g. 2026-06-01 for Jun-26).';
COMMENT ON COLUMN trade_position.volume_bbl IS 'NUMERIC(18,2) — volume in barrels. Typically 2,000,000 for Murban term cargoes.';

-- Indexes
CREATE INDEX idx_trade_position_tenant_id          ON trade_position(tenant_id);
CREATE INDEX idx_trade_position_counterparty_id    ON trade_position(counterparty_id);
CREATE INDEX idx_trade_position_internal_entity_id ON trade_position(internal_entity_id) WHERE internal_entity_id IS NOT NULL;
CREATE INDEX idx_trade_position_linked_contract_id ON trade_position(linked_contract_id) WHERE linked_contract_id IS NOT NULL;
CREATE INDEX idx_trade_position_created_by         ON trade_position(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_trade_position_updated_by         ON trade_position(updated_by) WHERE updated_by IS NOT NULL;
CREATE INDEX idx_trade_position_active             ON trade_position(id) WHERE is_active = TRUE;
CREATE INDEX idx_trade_position_basis_status       ON trade_position(tenant_id, pricing_basis, status) WHERE is_active = TRUE;
CREATE INDEX idx_trade_position_side_delivery      ON trade_position(tenant_id, side, delivery_month) WHERE is_active = TRUE;

-- RLS
ALTER TABLE trade_position ENABLE ROW LEVEL SECURITY;
ALTER TABLE trade_position FORCE  ROW LEVEL SECURITY;

CREATE POLICY trade_position_tenant_select ON trade_position
  FOR SELECT USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.margin.read')
  );

CREATE POLICY trade_position_tenant_modify ON trade_position
  FOR ALL USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.trade.manage')
  ) WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.trade.manage')
  );

CREATE POLICY trade_position_deny_direct_delete ON trade_position
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger
CREATE TRIGGER audit_trade_position_changes
  AFTER INSERT OR UPDATE OR DELETE ON trade_position
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (310, '310_cro_create_trade_position', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_trade_position_changes ON trade_position;
-- DROP POLICY IF EXISTS trade_position_deny_direct_delete ON trade_position;
-- DROP POLICY IF EXISTS trade_position_tenant_modify ON trade_position;
-- DROP POLICY IF EXISTS trade_position_tenant_select ON trade_position;
-- DROP TABLE IF EXISTS trade_position;
-- DELETE FROM schema_migrations WHERE version = 310;
-- COMMIT;
-- ============================================================
