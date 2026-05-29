-- Migration: 296_crn_create_contract_budget.sql
-- Module: CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half)
-- Description: CREATE TABLE contract_budget — period × category budget allocation (the PLAN).
--              FORCE RLS + 3 policies (finance.budget.read / finance.budget.manage / deny direct DELETE).
--              Audit trigger binding. BIGSERIAL PRIMARY KEY → standard fn_audit_trigger applies.
--              Query indexes for burn/variance scan. NUMERIC(18,2) money — never float.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE TABLE contract_budget (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID          NOT NULL REFERENCES tenant(id)   ON DELETE RESTRICT,
  contract_id          BIGINT        NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,

  period_type          TEXT          NOT NULL DEFAULT 'quarter'
                         CHECK (period_type IN ('month','quarter','year')),
  period_label         VARCHAR(20)   NOT NULL,
  fiscal_year          INTEGER       NOT NULL CHECK (fiscal_year BETWEEN 2000 AND 2100),
  cost_category        TEXT          NOT NULL
                         CHECK (cost_category IN ('day_rate','manpower','equipment','milestone','other')),

  allocated_amount_aed NUMERIC(18,2) NOT NULL CHECK (allocated_amount_aed >= 0),
  currency             CHAR(3)       NOT NULL DEFAULT 'AED',
  notes                TEXT,
  source               TEXT          NOT NULL DEFAULT 'demo_seed'
                         CHECK (source IN ('manual','demo_seed','import')),
  data_classification  TEXT          NOT NULL DEFAULT 'demo'
                         CHECK (data_classification IN ('demo','pilot','production')),

  -- Standard audit columns
  created_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  created_by           BIGINT        REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by           BIGINT        REFERENCES "user"(id) ON DELETE SET NULL,
  is_active            BOOLEAN       NOT NULL DEFAULT TRUE,

  -- One active budget line per (tenant, contract, period, category)
  CONSTRAINT contract_budget_idempotency_key
    UNIQUE (tenant_id, contract_id, period_label, cost_category)
);

COMMENT ON TABLE contract_budget IS
  'CR-N M21 Financial Intelligence — period×category budget allocation (the PLAN) per contract. Quarter grain by default (finance plans quarterly). Tenant-scoped FORCE RLS. NUMERIC(18,2) money — never float. Variance computed on-read against contract_cost_actual.';
COMMENT ON COLUMN contract_budget.period_label IS 'Human/sortable label: ''YYYY-Qn'' for quarter, ''YYYY-MM'' for month, ''YYYY'' for year. Drives rollup join to cost actuals.';
COMMENT ON COLUMN contract_budget.allocated_amount_aed IS 'Planned spend for this period+category. NUMERIC(18,2). Not redacted — operational figure, not a secret.';
COMMENT ON COLUMN contract_budget.currency IS 'Budget-line currency. AED-only for CR-N (multi-currency out of scope). Property of the line, not inherited from contract.';

-- Indexes
CREATE INDEX idx_contract_budget_tenant_id    ON contract_budget(tenant_id);
CREATE INDEX idx_contract_budget_contract_id  ON contract_budget(contract_id);
CREATE INDEX idx_contract_budget_created_by   ON contract_budget(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_contract_budget_updated_by   ON contract_budget(updated_by) WHERE updated_by IS NOT NULL;
CREATE INDEX idx_contract_budget_active       ON contract_budget(id) WHERE is_active = TRUE;
CREATE INDEX idx_contract_budget_contract_fy_cat
  ON contract_budget(contract_id, fiscal_year, cost_category) WHERE is_active = TRUE;

-- RLS
ALTER TABLE contract_budget ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_budget FORCE  ROW LEVEL SECURITY;

CREATE POLICY contract_budget_tenant_select ON contract_budget
  FOR SELECT USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.budget.read')
  );

CREATE POLICY contract_budget_tenant_modify ON contract_budget
  FOR ALL USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.budget.manage')
  ) WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.budget.manage')
  );

CREATE POLICY contract_budget_deny_direct_delete ON contract_budget
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger — BIGSERIAL id → standard fn_audit_trigger applies (S2-28)
CREATE TRIGGER audit_contract_budget_changes
  AFTER INSERT OR UPDATE OR DELETE ON contract_budget
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (296, '296_crn_create_contract_budget', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_contract_budget_changes ON contract_budget;
-- DROP POLICY IF EXISTS contract_budget_deny_direct_delete ON contract_budget;
-- DROP POLICY IF EXISTS contract_budget_tenant_modify ON contract_budget;
-- DROP POLICY IF EXISTS contract_budget_tenant_select ON contract_budget;
-- DROP TABLE IF EXISTS contract_budget;
-- DELETE FROM schema_migrations WHERE version = 296;
-- COMMIT;
-- ============================================================
