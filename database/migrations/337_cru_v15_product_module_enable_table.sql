-- Migration: 337_cru_v15_product_module_enable_table.sql
-- Module: CR-U — Product Module Toggle (wave v1.5)
-- Description: Runtime per-tenant module enable table (Layer-2 override).
--              Read policy: tenant_id IS NULL OR matches current_setting GUC.
--              Write policy: platform_admin + Super Admin (via role.name).
--              UNIQUE(tenant_id, module_key) enforces single override per
--              tenant + module. ADNOC tenant seed lives in 341.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- 1. product_module_enable table
-- ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS product_module_enable (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID,
  module_key  TEXT NOT NULL REFERENCES product_module(key) ON UPDATE CASCADE,
  is_enabled  BOOLEAN NOT NULL,
  reason      TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  UNIQUE (tenant_id, module_key)
);

COMMENT ON TABLE  product_module_enable             IS 'CR-U v1.5: Per-tenant module on/off override. tenant_id NULL = system default (fallback when no tenant-specific row exists). UNIQUE(tenant_id, module_key) — one override per tenant per module.';
COMMENT ON COLUMN product_module_enable.id          IS 'Surrogate PK. BIGSERIAL required by fn_audit_trigger.';
COMMENT ON COLUMN product_module_enable.tenant_id   IS 'NULL = system default (used as fallback when no tenant row exists). Multi-tenant ready — full multi-tenant requires tenant resolution from JWT/subdomain (separate work).';
COMMENT ON COLUMN product_module_enable.module_key  IS 'Module being toggled. References product_module(key).';
COMMENT ON COLUMN product_module_enable.is_enabled  IS 'TRUE = module accessible for this tenant; FALSE = hidden from sidebar, 404 from routes, skipped by workers.';
COMMENT ON COLUMN product_module_enable.reason      IS 'Free-text justification for the toggle (audit aid). Captured in audit_log new_values when changed.';
COMMENT ON COLUMN product_module_enable.is_active   IS 'Soft-delete flag. is_active=FALSE removes the override (module falls back to default_enabled).';

-- ──────────────────────────────────────────────────────────────────────────
-- 2. Indexes
-- ──────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_product_module_enable_lookup
  ON product_module_enable (module_key, tenant_id) WHERE is_active = TRUE;

-- ──────────────────────────────────────────────────────────────────────────
-- 3. RLS — tenant-scoped reads, admin-only writes
-- ──────────────────────────────────────────────────────────────────────────
ALTER TABLE product_module_enable ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_module_enable FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS product_module_enable_select_tenant ON product_module_enable;
CREATE POLICY product_module_enable_select_tenant ON product_module_enable
  FOR SELECT
  USING (
    NULLIF(current_setting('app.current_user_id', true), '')::BIGINT IS NOT NULL
    AND (
      tenant_id IS NULL
      OR tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    )
  );

DROP POLICY IF EXISTS product_module_enable_write_admin ON product_module_enable;
CREATE POLICY product_module_enable_write_admin ON product_module_enable
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin', 'Super Admin')
          AND u.is_active = TRUE
          AND r.is_active = TRUE
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin', 'Super Admin')
          AND u.is_active = TRUE
          AND r.is_active = TRUE
    )
  );

-- ──────────────────────────────────────────────────────────────────────────
-- 4. Audit trigger
-- ──────────────────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS audit_product_module_enable_changes ON product_module_enable;
CREATE TRIGGER audit_product_module_enable_changes
  AFTER INSERT OR UPDATE OR DELETE ON product_module_enable
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ──────────────────────────────────────────────────────────────────────────
-- 5. Register migration
-- ──────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (337, 'cru_v15_product_module_enable_table', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_product_module_enable_changes ON product_module_enable;
-- DROP POLICY  IF EXISTS product_module_enable_write_admin   ON product_module_enable;
-- DROP POLICY  IF EXISTS product_module_enable_select_tenant ON product_module_enable;
-- DROP TABLE   IF EXISTS product_module_enable;
-- DELETE FROM schema_migrations WHERE version = 337;
-- COMMIT;
-- ROLLBACK END
