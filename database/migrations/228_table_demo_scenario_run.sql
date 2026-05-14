-- Migration: 228_table_demo_scenario_run.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: demo_scenario_run append-only table + RLS + FORCE RLS + RESTRICTIVE deny-DELETE policy.
--              Strategy A audit (no default trigger — single entry point fn_demo_scenario_trigger).
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE demo_scenario_run (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID        NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  demo_scenario_id  BIGINT      NOT NULL REFERENCES demo_scenario(id) ON DELETE RESTRICT,
  triggered_by      BIGINT      NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
  triggered_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  outcome           JSONB,
  success           BOOLEAN     NOT NULL,
  elapsed_ms        INTEGER,
  error_message     TEXT,
  is_active         BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by        BIGINT      REFERENCES "user"(id)
);

COMMENT ON TABLE demo_scenario_run IS 'Append-only audit of every scenario trigger event. Records actual outcome JSONB for assertion against demo_scenario.expected_outcomes. RESTRICTIVE DELETE policy denies row deletion; rows never deleted in normal operation.';
COMMENT ON COLUMN demo_scenario_run.error_message IS 'Populated only when success=FALSE. May leak SQLSTATE detail — redacted in audit logs.';
COMMENT ON COLUMN demo_scenario_run.outcome IS 'Actual trigger outcome: { correlationCount, alertCount, advisoryDraftCount, signalCount }.';

CREATE INDEX idx_demo_scenario_run_tenant         ON demo_scenario_run(tenant_id);
CREATE INDEX idx_demo_scenario_run_demo_scenario  ON demo_scenario_run(demo_scenario_id);
CREATE INDEX idx_demo_scenario_run_triggered_by   ON demo_scenario_run(triggered_by);
CREATE INDEX idx_demo_scenario_run_triggered_at   ON demo_scenario_run(triggered_at DESC);
CREATE INDEX idx_demo_scenario_run_success        ON demo_scenario_run(success);

-- RLS
ALTER TABLE demo_scenario_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE demo_scenario_run FORCE ROW LEVEL SECURITY;

CREATE POLICY demo_scenario_run_isolation ON demo_scenario_run FOR ALL
  USING (tenant_id = current_setting('app.tenant_id', true)::UUID);

CREATE POLICY demo_scenario_run_admin_access ON demo_scenario_run FOR SELECT
  USING (fn_current_user_has_permission('demo.health_check.read'));

-- RESTRICTIVE deny-DELETE policy — append-only enforcement at row level
CREATE POLICY demo_scenario_run_deny_delete ON demo_scenario_run
  AS RESTRICTIVE FOR DELETE TO PUBLIC USING (false);

-- NOTE: No default fn_audit_trigger applied — Strategy A in-fn audit INSERT
-- emitted by fn_demo_scenario_trigger with action_code='DEMO_SCENARIO_TRIGGER'.

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (228, '228_table_demo_scenario_run', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 228;
-- DROP POLICY IF EXISTS demo_scenario_run_deny_delete ON demo_scenario_run;
-- DROP POLICY IF EXISTS demo_scenario_run_admin_access ON demo_scenario_run;
-- DROP POLICY IF EXISTS demo_scenario_run_isolation ON demo_scenario_run;
-- DROP TABLE IF EXISTS demo_scenario_run;
-- ============================================================
