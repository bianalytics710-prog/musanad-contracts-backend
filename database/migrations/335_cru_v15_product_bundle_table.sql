-- Migration: 335_cru_v15_product_bundle_table.sql
-- Module: CR-U — Product Module Toggle (wave v1.5)
-- Description: Creates product_bundle catalog table. Three rows seeded later in 339:
--                'clm'      (Contract Lifecycle Management)
--                'ecip'     (Enterprise Contract Intelligence Platform — CRIP/ECIP)
--                'platform' (Platform infrastructure — always-on, is_core=TRUE)
--              Layer-1 of the three-layer product-module architecture.
--              Pattern mirrors 097_pa_system_settings.sql:
--                FORCE RLS, role-name policy via "user"+role join (not GUC),
--                fn_audit_trigger attached, full COMMENTs.
--              Role identifier column confirmed: role.name (not role.code).
--              BIGSERIAL PK is required because fn_audit_trigger references
--              COALESCE(NEW.id, OLD.id) (002_security_hardening.sql:91).
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- 1. product_bundle table
-- ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS product_bundle (
  id          BIGSERIAL PRIMARY KEY,
  code        TEXT NOT NULL UNIQUE CHECK (code IN ('clm', 'ecip', 'platform')),
  label_key   TEXT NOT NULL,
  is_core     BOOLEAN NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE  product_bundle           IS 'CR-U v1.5: Layer-1 product bundle catalog. Three rows: clm / ecip / platform. is_core=TRUE marks always-on bundles (only platform). Used by fn_product_bundle_set + the admin Product Modules screen.';
COMMENT ON COLUMN product_bundle.id        IS 'Surrogate PK. BIGSERIAL required for fn_audit_trigger (COALESCE(NEW.id, OLD.id)).';
COMMENT ON COLUMN product_bundle.code      IS 'Stable identifier referenced by product_module.bundle_code. Constrained to (clm, ecip, platform).';
COMMENT ON COLUMN product_bundle.label_key IS 'i18n key resolved client-side (admin.modules.bundle.<code>.label).';
COMMENT ON COLUMN product_bundle.is_core   IS 'TRUE for bundles that cannot be disabled (platform). UI locks the master toggle.';
COMMENT ON COLUMN product_bundle.is_active IS 'Soft-delete flag. is_active=FALSE removes from catalog without violating FKs.';

-- ──────────────────────────────────────────────────────────────────────────
-- 2. Indexes
-- ──────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_product_bundle_code_active
  ON product_bundle (code) WHERE is_active = TRUE;

-- ──────────────────────────────────────────────────────────────────────────
-- 3. RLS — read-all-authenticated, write platform_admin + Super Admin
-- ──────────────────────────────────────────────────────────────────────────
ALTER TABLE product_bundle ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_bundle FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS product_bundle_select_all ON product_bundle;
CREATE POLICY product_bundle_select_all ON product_bundle
  FOR SELECT
  USING (
    NULLIF(current_setting('app.current_user_id', true), '')::BIGINT IS NOT NULL
  );

DROP POLICY IF EXISTS product_bundle_write_admin ON product_bundle;
CREATE POLICY product_bundle_write_admin ON product_bundle
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
-- 4. Audit trigger (BIGSERIAL id satisfies fn_audit_trigger NEW.id contract)
-- ──────────────────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS audit_product_bundle_changes ON product_bundle;
CREATE TRIGGER audit_product_bundle_changes
  AFTER INSERT OR UPDATE OR DELETE ON product_bundle
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ──────────────────────────────────────────────────────────────────────────
-- 5. Register migration
-- ──────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (335, 'cru_v15_product_bundle_table', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP TRIGGER  IF EXISTS audit_product_bundle_changes ON product_bundle;
-- DROP POLICY   IF EXISTS product_bundle_write_admin   ON product_bundle;
-- DROP POLICY   IF EXISTS product_bundle_select_all    ON product_bundle;
-- DROP TABLE    IF EXISTS product_bundle;
-- DELETE FROM schema_migrations WHERE version = 335;
-- COMMIT;
-- ROLLBACK END
