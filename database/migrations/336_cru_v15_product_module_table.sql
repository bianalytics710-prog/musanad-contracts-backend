-- Migration: 336_cru_v15_product_module_table.sql
-- Module: CR-U — Product Module Toggle (wave v1.5)
-- Description: Creates product_module catalog table — Layer-2 of the three-layer
--              architecture. 33 rows seeded later in 340 (12 CLM + 15 ECIP + 6
--              PLATFORM). default_role_codes is a JSONB array of role.name
--              strings (NOT role.code — role table has only id+name; column
--              confirmed via 001_foundation.sql:70 + DB query).
--              Self-FK on parent_key enables hierarchical cascade (child
--              auto-disabled when parent disabled, evaluated at runtime in
--              fn_module_enabled).
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- 1. product_module table
-- ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS product_module (
  id                        BIGSERIAL PRIMARY KEY,
  key                       TEXT NOT NULL UNIQUE,
  bundle_code               TEXT NOT NULL REFERENCES product_bundle(code) ON UPDATE CASCADE,
  parent_key                TEXT REFERENCES product_module(key) ON UPDATE CASCADE,
  label_key                 TEXT NOT NULL,
  sidebar_path              TEXT,
  owned_route_prefixes      JSONB NOT NULL DEFAULT '[]'::jsonb,
  owned_permission_prefixes JSONB NOT NULL DEFAULT '[]'::jsonb,
  default_role_codes        JSONB NOT NULL DEFAULT '[]'::jsonb,
  default_enabled           BOOLEAN NOT NULL DEFAULT TRUE,
  is_core                   BOOLEAN NOT NULL DEFAULT FALSE,
  display_order             INTEGER NOT NULL DEFAULT 100,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by                BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by                BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                 BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE  product_module                           IS 'CR-U v1.5: Layer-2 product module catalog. 33 rows (12 CLM + 15 ECIP + 6 PLATFORM). Joined to product_bundle via bundle_code; self-referential via parent_key for sub-module cascade.';
COMMENT ON COLUMN product_module.id                        IS 'Surrogate PK. BIGSERIAL required by fn_audit_trigger.';
COMMENT ON COLUMN product_module.key                       IS 'Stable module identifier (e.g. financial.trade_margin). Referenced by product_module_enable + role_module_access + the FE useEffectiveModules() hook.';
COMMENT ON COLUMN product_module.bundle_code               IS 'Parent bundle (clm / ecip / platform).';
COMMENT ON COLUMN product_module.parent_key                IS 'Optional sub-module parent. When parent disabled, fn_module_enabled returns FALSE for children too.';
COMMENT ON COLUMN product_module.label_key                 IS 'i18n key (admin.modules.<bundle>.<key>) — resolved by FE.';
COMMENT ON COLUMN product_module.sidebar_path              IS 'TanStack Router path rendered in the sidebar. NULL for modules mounted on other pages (signatures, impact_signals, ai_risk_assistant).';
COMMENT ON COLUMN product_module.owned_route_prefixes      IS 'JSONB array of BE route prefixes owned by this module. Used by requireModuleEnabled middleware (CR-V).';
COMMENT ON COLUMN product_module.owned_permission_prefixes IS 'JSONB array of permission prefixes (e.g. finance.budget.). Permissions matching these prefixes are co-managed with this module.';
COMMENT ON COLUMN product_module.default_role_codes        IS 'JSONB array of role.name strings allowed access by default (no role_module_access row required). The role identifier column in this schema is role.name (confirmed 001_foundation.sql:70).';
COMMENT ON COLUMN product_module.default_enabled           IS 'Initial state for newly-seeded tenants. TRUE for all v1.5 modules.';
COMMENT ON COLUMN product_module.is_core                   IS 'TRUE for PLATFORM bundle modules — always-on, cannot disable via UI.';
COMMENT ON COLUMN product_module.display_order             IS 'Stable sort key inside the Product Modules admin screen (10-step gaps inside each bundle for future inserts).';
COMMENT ON COLUMN product_module.is_active                 IS 'Soft-delete flag.';

-- ──────────────────────────────────────────────────────────────────────────
-- 2. Indexes
-- ──────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_product_module_bundle_code
  ON product_module (bundle_code) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_product_module_parent_key
  ON product_module (parent_key) WHERE parent_key IS NOT NULL AND is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_product_module_display_order
  ON product_module (bundle_code, display_order) WHERE is_active = TRUE;

-- ──────────────────────────────────────────────────────────────────────────
-- 3. RLS — read-all-authenticated, write platform_admin + Super Admin
-- ──────────────────────────────────────────────────────────────────────────
ALTER TABLE product_module ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_module FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS product_module_select_all ON product_module;
CREATE POLICY product_module_select_all ON product_module
  FOR SELECT
  USING (
    NULLIF(current_setting('app.current_user_id', true), '')::BIGINT IS NOT NULL
  );

DROP POLICY IF EXISTS product_module_write_admin ON product_module;
CREATE POLICY product_module_write_admin ON product_module
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
DROP TRIGGER IF EXISTS audit_product_module_changes ON product_module;
CREATE TRIGGER audit_product_module_changes
  AFTER INSERT OR UPDATE OR DELETE ON product_module
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ──────────────────────────────────────────────────────────────────────────
-- 5. Register migration
-- ──────────────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (336, 'cru_v15_product_module_table', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_product_module_changes ON product_module;
-- DROP POLICY  IF EXISTS product_module_write_admin   ON product_module;
-- DROP POLICY  IF EXISTS product_module_select_all    ON product_module;
-- DROP TABLE   IF EXISTS product_module;
-- DELETE FROM schema_migrations WHERE version = 336;
-- COMMIT;
-- ROLLBACK END
