-- Migration: 573_fn_tenant_create.sql
-- Module: R-IL Phase G — tenant creation from Platform Admin Industry catalogs.
-- Date: 2026-06-05
--
-- Goal: introduce fn_tenant_create + tenant.manage permission so Platform
-- Admin can onboard new tenants directly from the /app/admin/industry-catalogs
-- workflow. Tenant is created with an industry tag (must be set so the new
-- tenant's Index-Linked Contracts module renders with a valid catalog).
--
-- Permission gate: tenant.manage (new; granted to Super Admin + platform_admin).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. Seed permission ───────────────────────────────────────
INSERT INTO permission (code, module, action, description)
VALUES (
  'tenant.manage',
  'tenant',
  'manage',
  'Create new tenants (Platform Admin only). Read access remains gated by tenant.read.'
)
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM role r, permission p
WHERE r.name IN ('Super Admin', 'platform_admin')
  AND p.code = 'tenant.manage'
ON CONFLICT DO NOTHING;

-- ── 2. fn_tenant_create ──────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_tenant_create(
  p_slug          TEXT,
  p_display_name  TEXT,
  p_name          TEXT,
  p_industry_id   BIGINT,
  p_config_pack   TEXT DEFAULT 'default',
  p_risk_appetite TEXT DEFAULT 'standard',
  p_data_region   TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id UUID;
  v_industry_code TEXT;
BEGIN
  IF NOT fn_current_user_has_permission('tenant.manage') THEN
    RAISE EXCEPTION 'forbidden: tenant.manage required' USING ERRCODE = '42501';
  END IF;

  IF p_slug IS NULL OR LENGTH(TRIM(p_slug)) = 0 THEN
    RAISE EXCEPTION 'slug is required' USING ERRCODE = '22023';
  END IF;
  IF p_slug !~ '^[a-z][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'slug must be lowercase, alphanumeric, with hyphens or underscores (start with a letter)' USING ERRCODE = '22023';
  END IF;
  IF p_display_name IS NULL OR LENGTH(TRIM(p_display_name)) = 0 THEN
    RAISE EXCEPTION 'displayName is required' USING ERRCODE = '22023';
  END IF;
  IF p_name IS NULL OR LENGTH(TRIM(p_name)) = 0 THEN
    RAISE EXCEPTION 'name is required' USING ERRCODE = '22023';
  END IF;
  IF p_industry_id IS NULL THEN
    RAISE EXCEPTION 'industryId is required' USING ERRCODE = '22023';
  END IF;

  -- Validate industry exists + is active.
  SELECT code INTO v_industry_code
  FROM industry
  WHERE id = p_industry_id AND is_active = TRUE;
  IF v_industry_code IS NULL THEN
    RAISE EXCEPTION 'industry % not found or inactive', p_industry_id USING ERRCODE = 'P0002';
  END IF;

  BEGIN
    INSERT INTO tenant (
      slug, display_name, name, industry_id,
      config_pack, risk_appetite, data_region
    ) VALUES (
      LOWER(TRIM(p_slug)),
      TRIM(p_display_name),
      TRIM(p_name),
      p_industry_id,
      COALESCE(p_config_pack, 'default'),
      COALESCE(p_risk_appetite, 'standard'),
      p_data_region
    )
    RETURNING id INTO v_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'tenant slug already exists' USING ERRCODE = '23505';
  END;

  RETURN jsonb_build_object(
    'id', v_id,
    'slug', LOWER(TRIM(p_slug)),
    'displayName', TRIM(p_display_name),
    'name', TRIM(p_name),
    'industryId', p_industry_id,
    'industryCode', v_industry_code
  );
END $$;

REVOKE EXECUTE ON FUNCTION fn_tenant_create(TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tenant_create(TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_tenant_create(TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT) IS
  'R-IL Platform Admin — onboard a new tenant tagged to an industry. Industry FK is mandatory so the tenant''s Index-Linked Contracts module has a catalog to render with.';

-- ── 3. Record migration ─────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (573, '573_fn_tenant_create', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_tenant_create(TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT);
-- DELETE FROM role_permission WHERE permission_id = (SELECT id FROM permission WHERE code = 'tenant.manage');
-- DELETE FROM permission WHERE code = 'tenant.manage';
-- DELETE FROM schema_migrations WHERE version = 573;
-- COMMIT;
-- ============================================================
