-- Migration: 297_crn_create_contract_cost_actual.sql
-- Module: CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half)
-- Description: CREATE TABLE contract_cost_actual — actual-spend line items (mock ERP feed).
--              reference_no NOT NULL DEFAULT '' (idempotency key reliability — Postgres treats
--              NULLs as distinct in UNIQUE; see Design Notes §H item 1).
--              FORCE RLS + 3 policies. Audit trigger. NUMERIC(18,2) money — never float.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE TABLE contract_cost_actual (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID          NOT NULL REFERENCES tenant(id)   ON DELETE RESTRICT,
  contract_id          BIGINT        NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,

  period_type          TEXT          NOT NULL DEFAULT 'month'
                         CHECK (period_type IN ('month','quarter','year')),
  period_label         VARCHAR(20)   NOT NULL,
  fiscal_year          INTEGER       NOT NULL CHECK (fiscal_year BETWEEN 2000 AND 2100),
  cost_category        TEXT          NOT NULL
                         CHECK (cost_category IN ('day_rate','manpower','equipment','milestone','other')),

  actual_amount_aed    NUMERIC(18,2) NOT NULL CHECK (actual_amount_aed >= 0),
  currency             CHAR(3)       NOT NULL DEFAULT 'AED',
  source               TEXT          NOT NULL DEFAULT 'erp_feed'
                         CHECK (source IN ('erp_feed','manual')),
  -- NOT NULL DEFAULT '' — required for idempotency key (NULLs are distinct in UNIQUE)
  reference_no         VARCHAR(100)  NOT NULL DEFAULT '',
  recorded_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  notes                TEXT,
  data_classification  TEXT          NOT NULL DEFAULT 'demo'
                         CHECK (data_classification IN ('demo','pilot','production')),

  -- Standard audit columns
  created_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  created_by           BIGINT        REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by           BIGINT        REFERENCES "user"(id) ON DELETE SET NULL,
  is_active            BOOLEAN       NOT NULL DEFAULT TRUE,

  -- One active actual line per (tenant, contract, period, category, reference)
  CONSTRAINT contract_cost_actual_idempotency_key
    UNIQUE (tenant_id, contract_id, period_label, cost_category, reference_no)
);

COMMENT ON TABLE contract_cost_actual IS
  'CR-N M21 Financial Intelligence — actual-spend line items (mock ERP feed). Month grain. Tenant-scoped FORCE RLS. NUMERIC(18,2) money — never float. Rolled up to budget quarter by burn/variance fn_''s. No real ERP integration (CR-N out of scope).';
COMMENT ON COLUMN contract_cost_actual.source IS '''erp_feed'' = posted by the (mock) finance feed; ''manual'' = entered via fn_contract_cost_actual_record (finance.budget.manage).';
COMMENT ON COLUMN contract_cost_actual.reference_no IS 'ERP voucher/invoice reference. NOT NULL DEFAULT '''' — required for idempotency key reliability (Postgres treats NULLs as distinct in UNIQUE). BE Zod coalesces undefined → '''' before passing to fn_.';

-- Indexes
CREATE INDEX idx_contract_cost_actual_tenant_id    ON contract_cost_actual(tenant_id);
CREATE INDEX idx_contract_cost_actual_contract_id  ON contract_cost_actual(contract_id);
CREATE INDEX idx_contract_cost_actual_created_by   ON contract_cost_actual(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_contract_cost_actual_updated_by   ON contract_cost_actual(updated_by) WHERE updated_by IS NOT NULL;
CREATE INDEX idx_contract_cost_actual_active       ON contract_cost_actual(id) WHERE is_active = TRUE;
CREATE INDEX idx_contract_cost_actual_contract_fy_cat_period
  ON contract_cost_actual(contract_id, fiscal_year, cost_category, period_label) WHERE is_active = TRUE;

-- RLS
ALTER TABLE contract_cost_actual ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_cost_actual FORCE  ROW LEVEL SECURITY;

CREATE POLICY contract_cost_actual_tenant_select ON contract_cost_actual
  FOR SELECT USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.budget.read')
  );

CREATE POLICY contract_cost_actual_tenant_modify ON contract_cost_actual
  FOR ALL USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.budget.manage')
  ) WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.budget.manage')
  );

CREATE POLICY contract_cost_actual_deny_direct_delete ON contract_cost_actual
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger — BIGSERIAL id → standard fn_audit_trigger applies (S2-28)
CREATE TRIGGER audit_contract_cost_actual_changes
  AFTER INSERT OR UPDATE OR DELETE ON contract_cost_actual
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (297, '297_crn_create_contract_cost_actual', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_contract_cost_actual_changes ON contract_cost_actual;
-- DROP POLICY IF EXISTS contract_cost_actual_deny_direct_delete ON contract_cost_actual;
-- DROP POLICY IF EXISTS contract_cost_actual_tenant_modify ON contract_cost_actual;
-- DROP POLICY IF EXISTS contract_cost_actual_tenant_select ON contract_cost_actual;
-- DROP TABLE IF EXISTS contract_cost_actual;
-- DELETE FROM schema_migrations WHERE version = 297;
-- COMMIT;
-- ============================================================
