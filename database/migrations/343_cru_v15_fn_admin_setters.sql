-- Migration: 343_cru_v15_fn_admin_setters.sql
-- Module: CR-U — Product Module Toggle (wave v1.5)
-- Description: SECURITY DEFINER admin-only setter fn_'s:
--                fn_product_bundle_set(code, is_enabled, reason)
--                fn_product_module_set(key, is_enabled, reason)
--                fn_role_module_access_set(role_id, module_key, is_allowed, reason)
--              All three gate access via:
--                (a) settings.write permission, AND
--                (b) role.name IN ('platform_admin','Super Admin')
--              Tenant resolution: uses current_setting('app.current_tenant_id')
--              GUC. NULL tenant_id rows are written when GUC is absent (system
--              default). All writes captured by audit trigger on the underlying
--              tables (records actor via current_setting('app.current_user_id')).
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- 1. fn_product_bundle_set
-- ──────────────────────────────────────────────────────────────────────────
-- Toggles every product_module_enable row whose module belongs to the bundle.
-- 'platform' bundle is_core=TRUE and cannot be disabled (raises 42501).
CREATE OR REPLACE FUNCTION public.fn_product_bundle_set(
  p_code       TEXT,
  p_is_enabled BOOLEAN,
  p_reason     TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user_id     BIGINT;
  v_tenant_id   UUID;
  v_role_name   TEXT;
  v_bundle      product_bundle%ROWTYPE;
  v_updated     INTEGER := 0;
  v_module_key  TEXT;
BEGIN
  -- AuthN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_product_bundle_set: unauthorized' USING ERRCODE = '42501';
  END IF;

  -- AuthZ: role check
  SELECT r.name INTO v_role_name
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role_name NOT IN ('platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_product_bundle_set: forbidden — admin role required'
      USING ERRCODE = '42501';
  END IF;

  -- AuthZ: permission check
  IF NOT fn_current_user_has_permission('settings.write') THEN
    RAISE EXCEPTION 'fn_product_bundle_set: forbidden — settings.write required'
      USING ERRCODE = '42501';
  END IF;

  -- Validation
  IF p_code IS NULL OR p_code NOT IN ('clm', 'ecip', 'platform') THEN
    RAISE EXCEPTION 'fn_product_bundle_set: invalid bundle code "%"', p_code
      USING ERRCODE = '22023';
  END IF;
  IF p_is_enabled IS NULL THEN
    RAISE EXCEPTION 'fn_product_bundle_set: is_enabled is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_bundle FROM product_bundle WHERE code = p_code AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_product_bundle_set: bundle "%" not found', p_code
      USING ERRCODE = 'P0002';
  END IF;

  -- Platform bundle is is_core — cannot be disabled
  IF v_bundle.is_core AND p_is_enabled = FALSE THEN
    RAISE EXCEPTION 'fn_product_bundle_set: cannot disable platform bundle (is_core=TRUE)'
      USING ERRCODE = '42501';
  END IF;

  -- Resolve tenant from GUC (NULL = system default)
  BEGIN
    v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  EXCEPTION WHEN OTHERS THEN
    v_tenant_id := NULL;
  END;

  -- UPSERT one product_module_enable row per module in this bundle.
  FOR v_module_key IN
    SELECT key FROM product_module WHERE bundle_code = p_code AND is_active = TRUE
  LOOP
    INSERT INTO product_module_enable (
      tenant_id, module_key, is_enabled, reason, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_module_key, p_is_enabled,
      COALESCE(p_reason, 'bundle ' || p_code || ' toggled'),
      v_user_id, v_user_id
    )
    ON CONFLICT (tenant_id, module_key) DO UPDATE
      SET is_enabled = EXCLUDED.is_enabled,
          reason     = EXCLUDED.reason,
          updated_by = EXCLUDED.updated_by,
          updated_at = CURRENT_TIMESTAMP,
          is_active  = TRUE;

    v_updated := v_updated + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'bundleCode',     p_code,
    'isEnabled',      p_is_enabled,
    'modulesUpdated', v_updated,
    'tenantId',       v_tenant_id,
    'reason',         p_reason
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.fn_product_bundle_set(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_product_bundle_set(TEXT, BOOLEAN, TEXT) TO neondb_owner;
COMMENT ON FUNCTION public.fn_product_bundle_set(TEXT, BOOLEAN, TEXT) IS
  'CR-U v1.5: Toggle a whole bundle (clm / ecip). UPSERTs product_module_enable rows for every module in the bundle. Rejects toggle-off for the platform bundle (is_core=TRUE).';

-- ──────────────────────────────────────────────────────────────────────────
-- 2. fn_product_module_set
-- ──────────────────────────────────────────────────────────────────────────
-- UPSERTs a single product_module_enable row. When p_is_enabled=FALSE
-- recursively disables all children (modules whose parent_key chains back
-- to p_key). When enabling, only the requested module is set — children stay
-- where they are (admin can re-enable explicitly).
CREATE OR REPLACE FUNCTION public.fn_product_module_set(
  p_key        TEXT,
  p_is_enabled BOOLEAN,
  p_reason     TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user_id    BIGINT;
  v_tenant_id  UUID;
  v_role_name  TEXT;
  v_module     product_module%ROWTYPE;
  v_cascaded   INTEGER := 0;
  v_child_key  TEXT;
BEGIN
  -- AuthN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_product_module_set: unauthorized' USING ERRCODE = '42501';
  END IF;

  -- AuthZ
  SELECT r.name INTO v_role_name
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role_name NOT IN ('platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_product_module_set: forbidden — admin role required'
      USING ERRCODE = '42501';
  END IF;

  IF NOT fn_current_user_has_permission('settings.write') THEN
    RAISE EXCEPTION 'fn_product_module_set: forbidden — settings.write required'
      USING ERRCODE = '42501';
  END IF;

  -- Validation
  IF p_key IS NULL THEN
    RAISE EXCEPTION 'fn_product_module_set: key is required' USING ERRCODE = '22023';
  END IF;
  IF p_is_enabled IS NULL THEN
    RAISE EXCEPTION 'fn_product_module_set: is_enabled is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_module FROM product_module WHERE key = p_key AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_product_module_set: module "%" not found', p_key USING ERRCODE = 'P0002';
  END IF;

  -- Cannot disable is_core modules (platform bundle)
  IF v_module.is_core AND p_is_enabled = FALSE THEN
    RAISE EXCEPTION 'fn_product_module_set: cannot disable is_core module "%"', p_key
      USING ERRCODE = '42501';
  END IF;

  -- Resolve tenant from GUC (NULL = system default)
  BEGIN
    v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  EXCEPTION WHEN OTHERS THEN
    v_tenant_id := NULL;
  END;

  -- UPSERT the target row
  INSERT INTO product_module_enable (
    tenant_id, module_key, is_enabled, reason, created_by, updated_by
  ) VALUES (
    v_tenant_id, p_key, p_is_enabled, p_reason, v_user_id, v_user_id
  )
  ON CONFLICT (tenant_id, module_key) DO UPDATE
    SET is_enabled = EXCLUDED.is_enabled,
        reason     = EXCLUDED.reason,
        updated_by = EXCLUDED.updated_by,
        updated_at = CURRENT_TIMESTAMP,
        is_active  = TRUE;

  -- On disable, cascade disable to all descendants via recursive CTE.
  IF p_is_enabled = FALSE THEN
    FOR v_child_key IN
      WITH RECURSIVE descendants AS (
        SELECT key FROM product_module WHERE parent_key = p_key AND is_active = TRUE
        UNION ALL
        SELECT pm.key
        FROM product_module pm
        JOIN descendants d ON pm.parent_key = d.key
        WHERE pm.is_active = TRUE
      )
      SELECT key FROM descendants
    LOOP
      INSERT INTO product_module_enable (
        tenant_id, module_key, is_enabled, reason, created_by, updated_by
      ) VALUES (
        v_tenant_id, v_child_key, FALSE,
        COALESCE(p_reason, '') || ' (cascade: parent ' || p_key || ' disabled)',
        v_user_id, v_user_id
      )
      ON CONFLICT (tenant_id, module_key) DO UPDATE
        SET is_enabled = FALSE,
            reason     = EXCLUDED.reason,
            updated_by = EXCLUDED.updated_by,
            updated_at = CURRENT_TIMESTAMP,
            is_active  = TRUE;

      v_cascaded := v_cascaded + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'moduleKey',         p_key,
    'isEnabled',         p_is_enabled,
    'cascadedChildren',  v_cascaded,
    'tenantId',          v_tenant_id,
    'reason',            p_reason
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.fn_product_module_set(TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_product_module_set(TEXT, BOOLEAN, TEXT) TO neondb_owner;
COMMENT ON FUNCTION public.fn_product_module_set(TEXT, BOOLEAN, TEXT) IS
  'CR-U v1.5: UPSERT one product_module_enable row. On disable cascades disable to all descendants via parent_key chain. Rejects disabling is_core modules.';

-- ──────────────────────────────────────────────────────────────────────────
-- 3. fn_role_module_access_set
-- ──────────────────────────────────────────────────────────────────────────
-- UPSERTs a single role_module_access row. p_is_allowed NULL clears the
-- override (deletes/soft-deletes the row so the matrix cell falls back to
-- default_role_codes evaluation).
CREATE OR REPLACE FUNCTION public.fn_role_module_access_set(
  p_role_id     BIGINT,
  p_module_key  TEXT,
  p_is_allowed  BOOLEAN,
  p_reason      TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user_id    BIGINT;
  v_tenant_id  UUID;
  v_role_name  TEXT;
  v_cleared    BOOLEAN := FALSE;
BEGIN
  -- AuthN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_role_module_access_set: unauthorized' USING ERRCODE = '42501';
  END IF;

  -- AuthZ
  SELECT r.name INTO v_role_name
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role_name NOT IN ('platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_role_module_access_set: forbidden — admin role required'
      USING ERRCODE = '42501';
  END IF;

  IF NOT fn_current_user_has_permission('settings.write') THEN
    RAISE EXCEPTION 'fn_role_module_access_set: forbidden — settings.write required'
      USING ERRCODE = '42501';
  END IF;

  -- Validation
  IF p_role_id IS NULL THEN
    RAISE EXCEPTION 'fn_role_module_access_set: role_id is required' USING ERRCODE = '22023';
  END IF;
  IF p_module_key IS NULL THEN
    RAISE EXCEPTION 'fn_role_module_access_set: module_key is required' USING ERRCODE = '22023';
  END IF;

  -- FK validation (UPSERT would also catch but error code is nicer)
  IF NOT EXISTS (SELECT 1 FROM role WHERE id = p_role_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_role_module_access_set: role % not found', p_role_id USING ERRCODE = 'P0002';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM product_module WHERE key = p_module_key AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_role_module_access_set: module "%" not found', p_module_key USING ERRCODE = 'P0002';
  END IF;

  -- Resolve tenant from GUC
  BEGIN
    v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  EXCEPTION WHEN OTHERS THEN
    v_tenant_id := NULL;
  END;

  -- Clear-override path: soft-delete the existing row.
  IF p_is_allowed IS NULL THEN
    UPDATE role_module_access
       SET is_active  = FALSE,
           reason     = COALESCE(p_reason, 'override cleared'),
           updated_by = v_user_id,
           updated_at = CURRENT_TIMESTAMP
     WHERE role_id    = p_role_id
       AND module_key = p_module_key
       AND tenant_id  IS NOT DISTINCT FROM v_tenant_id
       AND is_active  = TRUE;
    v_cleared := FOUND;
  ELSE
    INSERT INTO role_module_access (
      tenant_id, role_id, module_key, is_allowed, reason, created_by, updated_by
    ) VALUES (
      v_tenant_id, p_role_id, p_module_key, p_is_allowed, p_reason, v_user_id, v_user_id
    )
    ON CONFLICT (tenant_id, role_id, module_key) DO UPDATE
      SET is_allowed = EXCLUDED.is_allowed,
          reason     = EXCLUDED.reason,
          updated_by = EXCLUDED.updated_by,
          updated_at = CURRENT_TIMESTAMP,
          is_active  = TRUE;
  END IF;

  RETURN jsonb_build_object(
    'roleId',    p_role_id,
    'moduleKey', p_module_key,
    'isAllowed', p_is_allowed,
    'cleared',   v_cleared,
    'tenantId',  v_tenant_id,
    'reason',    p_reason
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.fn_role_module_access_set(BIGINT, TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_role_module_access_set(BIGINT, TEXT, BOOLEAN, TEXT) TO neondb_owner;
COMMENT ON FUNCTION public.fn_role_module_access_set(BIGINT, TEXT, BOOLEAN, TEXT) IS
  'CR-U v1.5: UPSERT one role_module_access row. p_is_allowed NULL clears the override (soft-delete) so the matrix cell falls back to product_module.default_role_codes evaluation.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (343, 'cru_v15_fn_admin_setters', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.fn_role_module_access_set(BIGINT, TEXT, BOOLEAN, TEXT);
-- DROP FUNCTION IF EXISTS public.fn_product_module_set(TEXT, BOOLEAN, TEXT);
-- DROP FUNCTION IF EXISTS public.fn_product_bundle_set(TEXT, BOOLEAN, TEXT);
-- DELETE FROM schema_migrations WHERE version = 343;
-- COMMIT;
-- ROLLBACK END
