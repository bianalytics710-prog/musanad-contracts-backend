-- Migration: 338_cru_v15_role_module_access_table.sql
-- Module: CR-U — Product Module Toggle (wave v1.5)
-- Description: Runtime per-tenant role × module RBAC override table (Layer-3).
--              When NO row exists for a (tenant, role, module) triple, the
--              module's default_role_codes catalog field decides access.
--              When a row exists, is_allowed wins (explicit override).
--              CR-U starts with this table EMPTY for ADNOC — all access flows
--              through defaults — and admins populate it via fn_role_module_access_set.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- 1. role_module_access table
-- ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS role_module_access (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID,
  role_id     BIGINT NOT NULL REFERENCES role(id) ON DELETE CASCADE,
  module_key  TEXT   NOT NULL REFERENCES product_module(key) ON UPDATE CASCADE,
  is_allowed  BOOLEAN NOT NULL,
  reason      TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  UNIQUE (tenant_id, role_id, module_key)
);

COMMENT ON TABLE  role_module_access             IS 'CR-U v1.5: Per-tenant role × module RBAC override matrix. Empty by default — every role uses product_module.default_role_codes. Populated only when an admin overrides a cell via fn_role_module_access_set.';
COMMENT ON COLUMN role_module_access.id          IS 'Surrogate PK. BIGSERIAL required by fn_audit_trigger.';
COMMENT ON COLUMN role_module_access.tenant_id   IS 'NULL = system default. Tenant-specific overrides take precedence.';
COMMENT ON COLUMN role_module_access.role_id     IS 'Role being granted/denied. References role(id).';
COMMENT ON COLUMN role_module_access.module_key  IS 'Module being toggled. References product_module(key).';
COMMENT ON COLUMN role_module_access.is_allowed  IS 'TRUE = explicit allow; FALSE = explicit deny. Absence of row = use default_role_codes.';
COMMENT ON COLUMN role_module_access.reason      IS 'Free-text justification (audit aid).';
COMMENT ON COLUMN role_module_access.is_active   IS 'Soft-delete flag. is_active=FALSE acts as "clear override" → fall back to default_role_codes.';

-- ──────────────────────────────────────────────────────────────────────────
-- 2. Indexes
-- ──────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_role_module_access_lookup
  ON role_module_access (role_id, module_key, tenant_id) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_role_module_access_module
  ON role_module_access (module_key) WHERE is_active = TRUE;

-- ──────────────────────────────────────────────────────────────────────────
-- 3. RLS — tenant-scoped reads, admin-only writes
-- ──────────────────────────────────────────────────────────────────────────
ALTER TABLE role_module_access ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_module_access FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_module_access_select_tenant ON role_module_access;
CREATE POLICY role_module_access_select_tenant ON role_module_access
  FOR SELECT
  USING (
    NULLIF(current_setting('app.current_user_id', true), '')::BIGINT IS NOT NULL
    AND (
      tenant_id IS NULL
      OR tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    )
  );

DROP POLICY IF EXISTS role_module_access_write_admin ON role_module_access;
CREATE POLICY role_module_access_write_admin ON role_module_access
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
DROP TRIGGER IF EXISTS audit_role_module_access_changes ON role_module_access;
CREATE TRIGGER audit_role_module_access_changes
  AFTER INSERT OR UPDATE OR DELETE ON role_module_access
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ──────────────────────────────────────────────────────────────────────────
-- 5. Register migration
-- ──────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (338, 'cru_v15_role_module_access_table', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_role_module_access_changes ON role_module_access;
-- DROP POLICY  IF EXISTS role_module_access_write_admin   ON role_module_access;
-- DROP POLICY  IF EXISTS role_module_access_select_tenant ON role_module_access;
-- DROP TABLE   IF EXISTS role_module_access;
-- DELETE FROM schema_migrations WHERE version = 338;
-- COMMIT;
-- ROLLBACK END
