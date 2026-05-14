-- Migration: 227_table_demo_scenario.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: demo_scenario master table + RLS + FORCE RLS + audit trigger + indexes.
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE demo_scenario (
  id                      BIGSERIAL PRIMARY KEY,
  tenant_id               UUID        NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  scenario_id             TEXT        NOT NULL,
  display_name_en         TEXT        NOT NULL,
  display_name_ar         TEXT        NOT NULL,
  description             TEXT,
  tier                    INTEGER     NOT NULL CHECK (tier IN (1, 2)),
  seed_pack_ref           TEXT        NOT NULL,
  event_injection_payload JSONB       NOT NULL,
  expected_outcomes       JSONB       NOT NULL,
  is_active               BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by              BIGINT      REFERENCES "user"(id),
  updated_by              BIGINT      REFERENCES "user"(id),
  CONSTRAINT demo_scenario_scenario_id_per_tenant_uq UNIQUE (tenant_id, scenario_id),
  CONSTRAINT demo_scenario_scenario_id_chk CHECK (
    scenario_id IN ('hormuz','ofac_sanctions','brent_review','epc_sla','renewal',
                    'cyclone','icv_shortfall','esg_subcontractor')
  )
);

CREATE INDEX idx_demo_scenario_tenant         ON demo_scenario(tenant_id);
CREATE INDEX idx_demo_scenario_seed_pack_ref  ON demo_scenario(seed_pack_ref);
CREATE INDEX idx_demo_scenario_tier           ON demo_scenario(tier);
CREATE INDEX idx_demo_scenario_active         ON demo_scenario(id) WHERE is_active = TRUE;

COMMENT ON TABLE demo_scenario IS '8 hero demo scenarios per tenant; binds a seed pack + event injection payload + expected outcome baselines. CHECK constraint on scenario_id is intentional — closed set per requirements; admin extension requires DDL.';
COMMENT ON COLUMN demo_scenario.seed_pack_ref IS 'Soft FK to demo_seed_pack.pack_id; validated in fn_demo_scenario_trigger body via EXISTS check (S2-23).';
COMMENT ON COLUMN demo_scenario.event_injection_payload IS 'Scenario event injection blueprint; may contain seeded counterparty/OFAC titles — redacted in audit logs.';
COMMENT ON COLUMN demo_scenario.expected_outcomes IS 'Expected outcome baseline: { correlationCount, alertCount, advisoryDraftCount, signalCount }.';

-- RLS
ALTER TABLE demo_scenario ENABLE ROW LEVEL SECURITY;
ALTER TABLE demo_scenario FORCE ROW LEVEL SECURITY;

CREATE POLICY demo_scenario_isolation ON demo_scenario FOR ALL
  USING (tenant_id = current_setting('app.tenant_id', true)::UUID);

CREATE POLICY demo_scenario_admin_access ON demo_scenario FOR SELECT
  USING (fn_current_user_has_permission('demo.health_check.read'));

-- Audit trigger
CREATE TRIGGER audit_demo_scenario_changes
  AFTER INSERT OR UPDATE OR DELETE ON demo_scenario
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (227, '227_table_demo_scenario', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 227;
-- DROP TRIGGER IF EXISTS audit_demo_scenario_changes ON demo_scenario;
-- DROP POLICY IF EXISTS demo_scenario_admin_access ON demo_scenario;
-- DROP POLICY IF EXISTS demo_scenario_isolation ON demo_scenario;
-- DROP TABLE IF EXISTS demo_scenario;
-- ============================================================
