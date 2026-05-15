-- Migration: 253_crk_create_risk_case.sql
-- Module: M19 — CR-K Risk Cases
-- CR: CR-K
-- Date: 2026-05-15
-- Description: Create risk_case primary table + indexes + FORCE RLS + 3 policies
--              + default fn_audit_trigger (Strategy B).
-- ADAPTATION NOTE (DEFECT-CRKL-DB-A9): Design references contract.title — actual
--              column is title_en/title_ar. Indexes do not reference title_*; only
--              fn bodies adapt this. No DDL impact.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE risk_case (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  correlation_id      BIGINT NULL REFERENCES correlation(id) ON DELETE SET NULL,
  contract_id         BIGINT NULL REFERENCES contract(id) ON DELETE SET NULL,
  case_type           TEXT NOT NULL CHECK (case_type IN ('correlation_alert', 'obligation_due', 'sla_breach', 'system', 'manual')),
  priority            TEXT NOT NULL CHECK (priority IN ('low', 'medium', 'high', 'critical')),
  title               TEXT NOT NULL CHECK (length(trim(title)) > 0),
  body                TEXT NULL,
  assigned_role       TEXT NULL,
  assigned_user_id    BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  status              TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_review', 'approved', 'rejected', 'escalated', 'accept_risk', 'snoozed', 'closed')),
  sla_hours           INTEGER NULL CHECK (sla_hours IS NULL OR sla_hours > 0),
  due_at              TIMESTAMPTZ NULL,
  snoozed_until       TIMESTAMPTZ NULL,
  closed_at           TIMESTAMPTZ NULL,
  closed_by           BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  closure_outcome     TEXT NULL CHECK (closure_outcome IS NULL OR closure_outcome IN ('mitigated', 'accepted', 'no_action', 'advisory_dispatched')),
  dedupe_key          TEXT NULL,
  metadata            JSONB NOT NULL DEFAULT '{}',
  data_classification TEXT NOT NULL DEFAULT 'internal' CHECK (data_classification IN ('public', 'internal', 'restricted', 'sensitive')),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by          BIGINT NULL REFERENCES "user"(id),
  updated_by          BIGINT NULL REFERENCES "user"(id),
  is_active           BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE UNIQUE INDEX uq_risk_case_tenant_dedupe ON risk_case(tenant_id, dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX idx_risk_case_tenant_id ON risk_case(tenant_id);
CREATE INDEX idx_risk_case_correlation_id ON risk_case(correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX idx_risk_case_contract_id ON risk_case(contract_id) WHERE contract_id IS NOT NULL;
CREATE INDEX idx_risk_case_assigned_user_id ON risk_case(assigned_user_id) WHERE assigned_user_id IS NOT NULL;
CREATE INDEX idx_risk_case_assigned_role ON risk_case(assigned_role) WHERE assigned_role IS NOT NULL;
CREATE INDEX idx_risk_case_status_priority ON risk_case(status, priority) WHERE is_active = TRUE;
CREATE INDEX idx_risk_case_due_at ON risk_case(due_at) WHERE status NOT IN ('approved','rejected','closed','accept_risk') AND is_active = TRUE;
CREATE INDEX idx_risk_case_active ON risk_case(id) WHERE is_active = TRUE;

COMMENT ON TABLE risk_case IS 'Unified risk-case primitive: alert + workflow_task + evidence + escalation lifecycle. 8-state machine; tenant-scoped; FORCE RLS. dedupe_key=correlation:<id> for auto-create idempotency.';
COMMENT ON COLUMN risk_case.body IS 'Free-text case body / narrative. Sensitive — redacted in audit_log + Pino.';
COMMENT ON COLUMN risk_case.dedupe_key IS 'Idempotency key for auto-create from correlation; format: correlation:<id> or null for manual cases.';
COMMENT ON COLUMN risk_case.status IS 'State machine: open -> in_review -> approved | rejected | escalated | accept_risk | snoozed -> closed. Strict validation per HITL Q3.';
COMMENT ON COLUMN risk_case.assigned_role IS 'Role name (FK-by-name to role.name). Validated against active roles in mutation fn body.';

ALTER TABLE risk_case ENABLE ROW LEVEL SECURITY;
ALTER TABLE risk_case FORCE ROW LEVEL SECURITY;

CREATE POLICY risk_case_tenant_select ON risk_case
  FOR SELECT
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID);

CREATE POLICY risk_case_tenant_modify ON risk_case
  FOR ALL
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID);

CREATE POLICY risk_case_deny_direct_delete ON risk_case
  AS RESTRICTIVE
  FOR DELETE
  USING (FALSE);

CREATE TRIGGER audit_risk_case_changes
  AFTER INSERT OR UPDATE OR DELETE ON risk_case
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (253, '253_crk_create_risk_case', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP TABLE IF EXISTS risk_case CASCADE;
-- DELETE FROM schema_migrations WHERE version = 253;
-- ============================================================
