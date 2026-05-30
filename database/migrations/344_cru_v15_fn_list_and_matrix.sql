-- Migration: 344_cru_v15_fn_list_and_matrix.sql
-- Module: CR-U — Product Module Toggle (wave v1.5)
-- Description: Three read fn_'s for the admin UI + user-creation form:
--                fn_product_module_list()                → JSONB catalog+enable state
--                fn_role_module_matrix_get()             → JSONB role × module matrix
--                fn_role_filter_for_enabled_modules()    → BIGINT[] roles still useful
--              All DEFINER, STABLE, JSONB shape uses camelCase keys.
--              Permission gates:
--                - product_module_list + role_module_matrix_get → settings.read
--                  (matches existing fn_system_setting_list pattern)
--                - role_filter_for_enabled_modules → any authenticated user
--                  (used by user-creation dropdown rendering)
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- 1. fn_product_module_list — catalog with effective enable state
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_product_module_list()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user_id   BIGINT;
  v_tenant_id UUID;
  v_bundles   JSONB;
  v_modules   JSONB;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_product_module_list: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('settings.read') THEN
    RAISE EXCEPTION 'fn_product_module_list: forbidden — settings.read required'
      USING ERRCODE = '42501';
  END IF;

  BEGIN
    v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  EXCEPTION WHEN OTHERS THEN v_tenant_id := NULL;
  END;

  -- Bundles: is_enabled aggregates over the bundle's modules.
  -- A bundle is "enabled" iff ANY of its modules are enabled.
  -- Platform bundle always reports TRUE (is_core).
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'code',      pb.code,
      'labelKey',  pb.label_key,
      'isCore',    pb.is_core,
      'isEnabled', CASE
        WHEN pb.is_core THEN TRUE
        ELSE EXISTS (
          SELECT 1 FROM product_module pm
          WHERE pm.bundle_code = pb.code
            AND pm.is_active = TRUE
            AND fn_module_enabled(v_tenant_id, pm.key) = TRUE
        )
      END
    ) ORDER BY pb.id
  ), '[]'::jsonb) INTO v_bundles
  FROM product_bundle pb
  WHERE pb.is_active = TRUE;

  -- Modules: full catalog with per-module effective is_enabled.
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'key',              pm.key,
      'bundleCode',       pm.bundle_code,
      'parentKey',        pm.parent_key,
      'labelKey',         pm.label_key,
      'sidebarPath',      pm.sidebar_path,
      'defaultRoleCodes', pm.default_role_codes,
      'isEnabled',        fn_module_enabled(v_tenant_id, pm.key),
      'isCore',           pm.is_core,
      'displayOrder',     pm.display_order
    ) ORDER BY pm.bundle_code, pm.display_order, pm.key
  ), '[]'::jsonb) INTO v_modules
  FROM product_module pm
  WHERE pm.is_active = TRUE;

  RETURN jsonb_build_object('bundles', v_bundles, 'modules', v_modules);
END;
$fn$;

REVOKE ALL ON FUNCTION public.fn_product_module_list() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_product_module_list() TO neondb_owner;
COMMENT ON FUNCTION public.fn_product_module_list() IS
  'CR-U v1.5: Returns { bundles: [...], modules: [...] } with effective is_enabled per current tenant. Drives the /app/admin/product-modules screen. Permission-gated by settings.read.';

-- ──────────────────────────────────────────────────────────────────────────
-- 2. fn_role_module_matrix_get — full role × module matrix
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_role_module_matrix_get()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user_id   BIGINT;
  v_tenant_id UUID;
  v_roles     JSONB;
  v_modules   JSONB;
  v_matrix    JSONB;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_role_module_matrix_get: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('settings.read') THEN
    RAISE EXCEPTION 'fn_role_module_matrix_get: forbidden — settings.read required'
      USING ERRCODE = '42501';
  END IF;

  BEGIN
    v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  EXCEPTION WHEN OTHERS THEN v_tenant_id := NULL;
  END;

  -- Active roles. label = name (no separate display column in schema).
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object('id', r.id, 'code', r.name, 'label', r.name)
    ORDER BY r.id
  ), '[]'::jsonb) INTO v_roles
  FROM role r
  WHERE r.is_active = TRUE;

  -- Modules + app-level effective state.
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'key',            pm.key,
      'bundleCode',     pm.bundle_code,
      'labelKey',       pm.label_key,
      'isEnabledAtApp', fn_module_enabled(v_tenant_id, pm.key)
    ) ORDER BY pm.bundle_code, pm.display_order, pm.key
  ), '[]'::jsonb) INTO v_modules
  FROM product_module pm
  WHERE pm.is_active = TRUE;

  -- Matrix cell per (role, module). effective_state:
  --   'allow'   when explicit allow OR no explicit deny + role in default
  --   'deny'    when explicit deny OR no override + role NOT in default
  --   (source = 'explicit' iff a row exists)
  WITH cells AS (
    SELECT
      r.id   AS role_id,
      r.name AS role_name,
      pm.key AS module_key,
      pm.default_role_codes AS default_role_codes,
      (
        SELECT rma.is_allowed
        FROM role_module_access rma
        WHERE rma.role_id    = r.id
          AND rma.module_key = pm.key
          AND rma.is_active  = TRUE
          AND rma.tenant_id  = v_tenant_id
        LIMIT 1
      ) AS tenant_override,
      (
        SELECT rma.is_allowed
        FROM role_module_access rma
        WHERE rma.role_id    = r.id
          AND rma.module_key = pm.key
          AND rma.is_active  = TRUE
          AND rma.tenant_id  IS NULL
        LIMIT 1
      ) AS default_override
    FROM role r
    CROSS JOIN product_module pm
    WHERE r.is_active = TRUE AND pm.is_active = TRUE
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'roleId',         c.role_id,
      'moduleKey',      c.module_key,
      'effectiveState', CASE
        WHEN c.tenant_override IS NOT NULL AND c.tenant_override = TRUE THEN 'allow'
        WHEN c.tenant_override IS NOT NULL AND c.tenant_override = FALSE THEN 'deny'
        WHEN c.default_override IS NOT NULL AND c.default_override = TRUE THEN 'allow'
        WHEN c.default_override IS NOT NULL AND c.default_override = FALSE THEN 'deny'
        WHEN c.default_role_codes ? c.role_name THEN 'allow'
        ELSE 'deny'
      END,
      'source', CASE
        WHEN c.tenant_override IS NOT NULL OR c.default_override IS NOT NULL THEN 'explicit'
        ELSE 'default'
      END
    )
  ), '[]'::jsonb) INTO v_matrix
  FROM cells c;

  RETURN jsonb_build_object(
    'roles',   v_roles,
    'modules', v_modules,
    'matrix',  v_matrix
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.fn_role_module_matrix_get() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_role_module_matrix_get() TO neondb_owner;
COMMENT ON FUNCTION public.fn_role_module_matrix_get() IS
  'CR-U v1.5: Returns { roles, modules, matrix } for the role × module admin screen. Each matrix cell carries effectiveState (allow/deny) and source (explicit/default). Permission-gated by settings.read.';

-- ──────────────────────────────────────────────────────────────────────────
-- 3. fn_role_filter_for_enabled_modules — BIGINT[] of "still-useful" roles
-- ──────────────────────────────────────────────────────────────────────────
-- Used by the FE user-creation form + login persona chips to hide roles
-- whose default modules are entirely disabled at the app level.
CREATE OR REPLACE FUNCTION public.fn_role_filter_for_enabled_modules()
RETURNS BIGINT[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user_id   BIGINT;
  v_tenant_id UUID;
  v_result    BIGINT[];
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_role_filter_for_enabled_modules: unauthorized' USING ERRCODE = '42501';
  END IF;

  BEGIN
    v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  EXCEPTION WHEN OTHERS THEN v_tenant_id := NULL;
  END;

  -- A role is "useful" iff at least one enabled module lists it in
  -- default_role_codes OR an explicit allow exists for that role.
  SELECT COALESCE(array_agg(r.id ORDER BY r.id), ARRAY[]::BIGINT[])
    INTO v_result
  FROM role r
  WHERE r.is_active = TRUE
    AND EXISTS (
      SELECT 1
      FROM product_module pm
      WHERE pm.is_active = TRUE
        AND fn_module_enabled(v_tenant_id, pm.key) = TRUE
        AND (
          pm.default_role_codes ? r.name
          OR EXISTS (
            SELECT 1 FROM role_module_access rma
            WHERE rma.role_id    = r.id
              AND rma.module_key = pm.key
              AND rma.is_active  = TRUE
              AND rma.is_allowed = TRUE
              AND (rma.tenant_id = v_tenant_id OR rma.tenant_id IS NULL)
          )
        )
    );

  RETURN COALESCE(v_result, ARRAY[]::BIGINT[]);
END;
$fn$;

REVOKE ALL ON FUNCTION public.fn_role_filter_for_enabled_modules() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_role_filter_for_enabled_modules() TO neondb_owner;
COMMENT ON FUNCTION public.fn_role_filter_for_enabled_modules() IS
  'CR-U v1.5: Returns BIGINT[] of role ids whose intersection of (default-allowed modules + explicit allow modules) ∩ (currently-enabled modules) is non-empty. Used by FE user-creation dropdown + login persona chip filter (CR-W).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (344, 'cru_v15_fn_list_and_matrix', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.fn_role_filter_for_enabled_modules();
-- DROP FUNCTION IF EXISTS public.fn_role_module_matrix_get();
-- DROP FUNCTION IF EXISTS public.fn_product_module_list();
-- DELETE FROM schema_migrations WHERE version = 344;
-- COMMIT;
-- ROLLBACK END
