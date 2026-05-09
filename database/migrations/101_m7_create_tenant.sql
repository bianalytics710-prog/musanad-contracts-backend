-- Migration: 101_m7_create_tenant.sql
-- Module: M7 — OSINT Source Framework + Adapter Protocol (CR-A)
-- Description: Bootstrap multi-tenancy with the `tenant` table + ADNOC seed row + fn_tenant_get_current.
--              NO audit trigger (CC1 / OQ-8 carve-out — tenant.id is UUID; audit_log.record_id is BIGINT.
--              Defer comprehensive tenant audit to CR-C hash-chained replacement).
--              FORCE RLS + 2 policies (self-row read + platform_admin manage).
-- Rollback: DROP TABLE tenant CASCADE; DROP FUNCTION fn_tenant_get_current.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ----------------------------------------------------------------
-- 1. CREATE TABLE tenant
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tenant (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          VARCHAR(50)  NOT NULL UNIQUE,
  display_name  VARCHAR(200) NOT NULL,
  config_pack   VARCHAR(50)  NOT NULL DEFAULT 'default',
  is_active     BOOLEAN      NOT NULL DEFAULT TRUE,

  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by    BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by    BIGINT REFERENCES "user"(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_tenant_active ON tenant(id) WHERE is_active = TRUE;

COMMENT ON TABLE tenant IS
  'M7 minimal multi-tenancy bootstrap (Q2 lock). Single ADNOC row in CR-A; CR-C extends with branding, hierarchy, hash-chained audit. NO audit trigger in CR-A: tenant.id is UUID and audit_log.record_id is BIGINT — direct INSERT would fail (CC1 carve-out, OQ-8). Tenant audit is deferred to CR-C hash-chained audit_log replacement which natively accepts TEXT record_id.';
COMMENT ON COLUMN tenant.id IS 'UUID PK. ADNOC seed = 00000000-0000-0000-0000-000000000001.';
COMMENT ON COLUMN tenant.slug IS 'Stable string handle. ADNOC slug = adnoc.';
COMMENT ON COLUMN tenant.config_pack IS 'Drives seed selection. ADNOC tenant uses config_pack=adnoc.';

-- ----------------------------------------------------------------
-- 2. ADNOC seed row (idempotent)
-- ----------------------------------------------------------------
INSERT INTO tenant (id, slug, display_name, config_pack)
VALUES ('00000000-0000-0000-0000-000000000001', 'adnoc', 'ADNOC', 'adnoc')
ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------
-- 3. FORCE RLS + 2 policies
-- ----------------------------------------------------------------
ALTER TABLE tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_self_row_select ON tenant;
CREATE POLICY tenant_self_row_select ON tenant
  FOR SELECT
  USING (
    id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
  );

DROP POLICY IF EXISTS tenant_platform_admin_all ON tenant;
CREATE POLICY tenant_platform_admin_all ON tenant
  FOR ALL
  USING (fn_current_user_has_permission('source.manage'))
  WITH CHECK (fn_current_user_has_permission('source.manage'));

-- ----------------------------------------------------------------
-- 4. fn_tenant_get_current — read-only, returns current-tenant row
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_tenant_get_current(p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_row       JSONB;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'id',          t.id,
    'slug',        t.slug,
    'displayName', t.display_name,
    'configPack',  t.config_pack
  ) INTO v_row
  FROM tenant t
  WHERE t.id = v_tenant_id AND t.is_active = TRUE;

  RETURN v_row;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_tenant_get_current: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_tenant_get_current(BIGINT) IS
  'M7 — returns the tenant row matching app.current_tenant_id GUC. NULL if unset.';
REVOKE EXECUTE ON FUNCTION fn_tenant_get_current(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tenant_get_current(BIGINT) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (101, 'm7_create_tenant', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_tenant_get_current(BIGINT);
-- DROP TABLE IF EXISTS tenant CASCADE;
-- DELETE FROM schema_migrations WHERE version = 101;
-- COMMIT;
-- ============================================================
