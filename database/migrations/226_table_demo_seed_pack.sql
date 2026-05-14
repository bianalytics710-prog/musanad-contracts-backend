-- Migration: 226_table_demo_seed_pack.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: demo_seed_pack master table + RLS + FORCE RLS + audit trigger + indexes.
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE demo_seed_pack (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID        NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  pack_id       TEXT        NOT NULL,
  version       INTEGER     NOT NULL DEFAULT 1,
  description   TEXT,
  fixture_path  TEXT,
  payload       JSONB,
  is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by    BIGINT      REFERENCES "user"(id),
  updated_by    BIGINT      REFERENCES "user"(id),
  CONSTRAINT demo_seed_pack_pack_id_per_tenant_uq UNIQUE (tenant_id, pack_id)
);

CREATE INDEX idx_demo_seed_pack_tenant   ON demo_seed_pack(tenant_id);
CREATE INDEX idx_demo_seed_pack_pack_id  ON demo_seed_pack(pack_id);
CREATE INDEX idx_demo_seed_pack_active   ON demo_seed_pack(id) WHERE is_active = TRUE;

COMMENT ON TABLE demo_seed_pack IS 'Versioned bundles of demo seed data referenced by demo_scenario.seed_pack_ref. Tenant-scoped.';
COMMENT ON COLUMN demo_seed_pack.fixture_path IS 'Filesystem path to seed fixture files; optional — payload column used when null.';
COMMENT ON COLUMN demo_seed_pack.payload IS 'Inlined fallback seed payload when fixture_path is null.';

-- RLS
ALTER TABLE demo_seed_pack ENABLE ROW LEVEL SECURITY;
ALTER TABLE demo_seed_pack FORCE ROW LEVEL SECURITY;

CREATE POLICY demo_seed_pack_isolation ON demo_seed_pack FOR ALL
  USING (tenant_id = current_setting('app.tenant_id', true)::UUID);

CREATE POLICY demo_seed_pack_admin_access ON demo_seed_pack FOR SELECT
  USING (fn_current_user_has_permission('demo.health_check.read'));

-- Audit trigger
CREATE TRIGGER audit_demo_seed_pack_changes
  AFTER INSERT OR UPDATE OR DELETE ON demo_seed_pack
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (226, '226_table_demo_seed_pack', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 226;
-- DROP TRIGGER IF EXISTS audit_demo_seed_pack_changes ON demo_seed_pack;
-- DROP POLICY IF EXISTS demo_seed_pack_admin_access ON demo_seed_pack;
-- DROP POLICY IF EXISTS demo_seed_pack_isolation ON demo_seed_pack;
-- DROP TABLE IF EXISTS demo_seed_pack;
-- ============================================================
