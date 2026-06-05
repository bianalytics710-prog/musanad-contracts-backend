-- Migration: 574_fn_industry_upsert.sql
-- Module: R-IL Phase H — Industry create/update/deactivate from Platform Admin.
-- Date: 2026-06-05
--
-- Goal: extend the catalog admin surface so Platform Admin can create new
-- industries (e.g. "Construction", "FMCG Distribution") right from
-- /app/admin/industry-catalogs. After creating an industry, the existing
-- benchmark + cost-component upsert fns (mig 571) can be used to seed its
-- catalog, and fn_tenant_create (mig 573) can register tenants under it.
--
-- Permission: reuses platform.catalog.manage (mig 571) — same Platform
-- Admin role already curates the industry-level catalogs.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── fn_industry_upsert ───────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_industry_upsert(
  p_id                BIGINT,          -- NULL = create, non-null = update
  p_code              TEXT,
  p_display_label_en  TEXT,
  p_display_label_ar  TEXT,
  p_description       TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.catalog.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.catalog.manage required' USING ERRCODE = '42501';
  END IF;

  IF p_code IS NULL OR LENGTH(TRIM(p_code)) = 0 THEN
    RAISE EXCEPTION 'code is required' USING ERRCODE = '22023';
  END IF;
  IF p_code !~ '^[a-z][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'code must be lowercase, alphanumeric with underscores (start with a letter)' USING ERRCODE = '22023';
  END IF;
  IF p_display_label_en IS NULL OR LENGTH(TRIM(p_display_label_en)) = 0 THEN
    RAISE EXCEPTION 'displayLabelEn is required' USING ERRCODE = '22023';
  END IF;

  IF p_id IS NULL THEN
    -- Create
    BEGIN
      INSERT INTO industry (code, display_label_en, display_label_ar, description)
      VALUES (
        LOWER(TRIM(p_code)),
        TRIM(p_display_label_en),
        NULLIF(TRIM(COALESCE(p_display_label_ar, '')), ''),
        NULLIF(TRIM(COALESCE(p_description, '')), '')
      )
      RETURNING id INTO v_id;
    EXCEPTION
      WHEN unique_violation THEN
        RAISE EXCEPTION 'industry code already exists' USING ERRCODE = '23505';
    END;
  ELSE
    -- Update (code is immutable to keep FKs stable)
    UPDATE industry
    SET
      display_label_en = TRIM(p_display_label_en),
      display_label_ar = NULLIF(TRIM(COALESCE(p_display_label_ar, '')), ''),
      description      = NULLIF(TRIM(COALESCE(p_description, '')), ''),
      updated_at       = NOW()
    WHERE id = p_id
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'industry % not found', p_id USING ERRCODE = 'P0002';
    END IF;
  END IF;

  RETURN jsonb_build_object('id', v_id);
END $$;

REVOKE EXECUTE ON FUNCTION fn_industry_upsert(BIGINT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_industry_upsert(BIGINT, TEXT, TEXT, TEXT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_industry_upsert(BIGINT, TEXT, TEXT, TEXT, TEXT) IS
  'R-IL Platform Admin — create (p_id NULL) or update (p_id set) an industry. Code is immutable on update to keep tenant.industry_id + catalog.industry_id FKs stable.';

-- ── fn_industry_deactivate ───────────────────────────────────
CREATE OR REPLACE FUNCTION fn_industry_deactivate(p_id BIGINT)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
  v_tenant_count INTEGER;
BEGIN
  IF NOT fn_current_user_has_permission('platform.catalog.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.catalog.manage required' USING ERRCODE = '42501';
  END IF;

  -- Block deactivation if any active tenant still references this industry.
  -- Otherwise tenants would lose their catalog resolution.
  SELECT COUNT(*) INTO v_tenant_count
  FROM tenant WHERE industry_id = p_id AND is_active = TRUE;
  IF v_tenant_count > 0 THEN
    RAISE EXCEPTION 'industry has % active tenant(s); reassign or deactivate them first', v_tenant_count
      USING ERRCODE = '23503';
  END IF;

  UPDATE industry
  SET is_active = FALSE, updated_at = NOW()
  WHERE id = p_id
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'industry % not found', p_id USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('id', v_id, 'isActive', FALSE);
END $$;

REVOKE EXECUTE ON FUNCTION fn_industry_deactivate(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_industry_deactivate(BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_industry_deactivate(BIGINT) IS
  'R-IL Platform Admin — soft-delete an industry (is_active=false). Blocked when active tenants still reference the industry; reassign tenants first.';

-- Record migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (574, '574_fn_industry_upsert', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_industry_deactivate(BIGINT);
-- DROP FUNCTION IF EXISTS fn_industry_upsert(BIGINT, TEXT, TEXT, TEXT, TEXT);
-- DELETE FROM schema_migrations WHERE version = 574;
-- COMMIT;
-- ============================================================
