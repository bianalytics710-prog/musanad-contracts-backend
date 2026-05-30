-- Migration: 342_cru_v15_fn_user_effective_modules_and_module_enabled.sql
-- Module: CR-U — Product Module Toggle (wave v1.5)
-- Description: Two STABLE / SECURITY DEFINER fn_'s — the runtime read paths.
--                fn_module_enabled(tenant, module_key) → BOOLEAN
--                fn_user_effective_modules(user_id)    → TEXT[]
--              fn_module_enabled cascade rules (evaluated in this order):
--                1. If module is in 'platform' bundle → TRUE (always-on).
--                2. If product_module_enable row exists for (tenant, module)
--                   → return its is_enabled (tenant-specific wins).
--                3. Else if product_module_enable row exists for (NULL, module)
--                   → return its is_enabled (system default fallback).
--                4. Else → return product_module.default_enabled.
--                5. AND if the module has a parent_key, recurse on the parent
--                   with the same tenant. Returns TRUE only when self AND
--                   every ancestor is TRUE.
--              fn_user_effective_modules logic:
--                For each active module M:
--                  - skip if fn_module_enabled(user.tenant_id, M.key) is FALSE.
--                  - include M.key if:
--                      EXISTS active role_module_access row for (tenant, role, M)
--                        with is_allowed=TRUE   → explicit allow
--                      OR (
--                        NOT EXISTS active role_module_access row for
--                          (tenant, role, M) with is_allowed=FALSE
--                        AND role.name appears in M.default_role_codes JSONB
--                      ) → no explicit deny + default-allowed
--              Tenant resolution: uses current_setting('app.current_tenant_id')
--              when set, else NULL → fn_module_enabled treats absent override
--              rows as default_enabled. fn_user_effective_modules looks up the
--              tenant from the GUC because no tenant_id column exists on "user"
--              today (multi-tenant ready: per the v1.5 reference doc §11).
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- 1. fn_module_enabled — cheap predicate with parent cascade
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_module_enabled(
  p_tenant_id UUID,
  p_module_key TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_bundle_code   TEXT;
  v_parent_key    TEXT;
  v_default       BOOLEAN;
  v_self_enabled  BOOLEAN;
  v_parent_ok     BOOLEAN;
BEGIN
  -- Catalog lookup
  SELECT pm.bundle_code, pm.parent_key, pm.default_enabled
    INTO v_bundle_code, v_parent_key, v_default
  FROM product_module pm
  WHERE pm.key = p_module_key
    AND pm.is_active = TRUE;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  -- Platform bundle modules are always on (matches brief: platform is_core)
  IF v_bundle_code = 'platform' THEN
    -- Still respect parent cascade (e.g. profile has no parent; users_roles → admin)
    IF v_parent_key IS NOT NULL THEN
      RETURN fn_module_enabled(p_tenant_id, v_parent_key);
    END IF;
    RETURN TRUE;
  END IF;

  -- Tenant-specific override (highest priority)
  SELECT pme.is_enabled INTO v_self_enabled
  FROM product_module_enable pme
  WHERE pme.module_key = p_module_key
    AND pme.tenant_id  = p_tenant_id
    AND pme.is_active  = TRUE
    AND p_tenant_id IS NOT NULL;

  -- System default (NULL tenant fallback)
  IF v_self_enabled IS NULL THEN
    SELECT pme.is_enabled INTO v_self_enabled
    FROM product_module_enable pme
    WHERE pme.module_key = p_module_key
      AND pme.tenant_id IS NULL
      AND pme.is_active = TRUE;
  END IF;

  -- Catalog default
  IF v_self_enabled IS NULL THEN
    v_self_enabled := v_default;
  END IF;

  -- Short-circuit: self disabled → cascade disabled
  IF v_self_enabled IS NOT TRUE THEN
    RETURN FALSE;
  END IF;

  -- Parent cascade: child enabled iff parent also enabled
  IF v_parent_key IS NOT NULL THEN
    v_parent_ok := fn_module_enabled(p_tenant_id, v_parent_key);
    RETURN COALESCE(v_parent_ok, FALSE);
  END IF;

  RETURN TRUE;
END;
$fn$;

REVOKE ALL ON FUNCTION public.fn_module_enabled(UUID, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_module_enabled(UUID, TEXT) TO neondb_owner;
COMMENT ON FUNCTION public.fn_module_enabled(UUID, TEXT) IS
  'CR-U v1.5: STABLE predicate — TRUE iff the module (and all ancestors via parent_key) is enabled for the given tenant. Platform bundle modules are always TRUE. Used by 11 worker top-of-loop guards + fn_demo_scenario_trigger + the requireModuleEnabled middleware path (via fn_user_effective_modules).';

-- ──────────────────────────────────────────────────────────────────────────
-- 2. fn_user_effective_modules — set intersection per actor
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_user_effective_modules(
  p_user_id BIGINT
)
RETURNS TEXT[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_role_id    BIGINT;
  v_role_name  TEXT;
  v_tenant_id  UUID;
  v_result     TEXT[];
BEGIN
  IF p_user_id IS NULL THEN
    RETURN ARRAY[]::TEXT[];
  END IF;

  -- Look up the user's role
  SELECT u.role_id, r.name
    INTO v_role_id, v_role_name
  FROM "user" u
  JOIN role r ON r.id = u.role_id
  WHERE u.id = p_user_id
    AND u.is_active = TRUE
    AND r.is_active = TRUE;

  IF NOT FOUND THEN
    RETURN ARRAY[]::TEXT[];
  END IF;

  -- Resolve tenant from GUC (set by BE middleware per request).
  -- The "user" table currently has no tenant_id column; the GUC is the
  -- authoritative source today and the multi-tenant migration target.
  BEGIN
    v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  EXCEPTION WHEN OTHERS THEN
    v_tenant_id := NULL;
  END;

  -- Compute the effective set in one pass.
  SELECT COALESCE(array_agg(pm.key ORDER BY pm.bundle_code, pm.display_order), ARRAY[]::TEXT[])
    INTO v_result
  FROM product_module pm
  WHERE pm.is_active = TRUE
    AND fn_module_enabled(v_tenant_id, pm.key) = TRUE
    AND (
      -- Explicit allow (tenant-specific row wins over system default)
      EXISTS (
        SELECT 1 FROM role_module_access rma
        WHERE rma.module_key = pm.key
          AND rma.role_id    = v_role_id
          AND rma.is_active  = TRUE
          AND rma.is_allowed = TRUE
          AND (
            rma.tenant_id = v_tenant_id
            OR (rma.tenant_id IS NULL AND NOT EXISTS (
              SELECT 1 FROM role_module_access rma2
              WHERE rma2.module_key = pm.key
                AND rma2.role_id    = v_role_id
                AND rma2.is_active  = TRUE
                AND rma2.tenant_id  = v_tenant_id
            ))
          )
      )
      OR (
        -- No explicit deny AND role.name appears in default_role_codes
        NOT EXISTS (
          SELECT 1 FROM role_module_access rma
          WHERE rma.module_key = pm.key
            AND rma.role_id    = v_role_id
            AND rma.is_active  = TRUE
            AND rma.is_allowed = FALSE
            AND (
              rma.tenant_id = v_tenant_id
              OR (rma.tenant_id IS NULL AND NOT EXISTS (
                SELECT 1 FROM role_module_access rma2
                WHERE rma2.module_key = pm.key
                  AND rma2.role_id    = v_role_id
                  AND rma2.is_active  = TRUE
                  AND rma2.tenant_id  = v_tenant_id
              ))
            )
        )
        AND pm.default_role_codes ? v_role_name
      )
    );

  RETURN COALESCE(v_result, ARRAY[]::TEXT[]);
END;
$fn$;

REVOKE ALL ON FUNCTION public.fn_user_effective_modules(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_user_effective_modules(BIGINT) TO neondb_owner;
COMMENT ON FUNCTION public.fn_user_effective_modules(BIGINT) IS
  'CR-U v1.5: Returns the TEXT[] of module keys accessible to the given user — the intersection of (bundle on) × (module on, with parent cascade) × (role allow override OR no explicit deny + role.name in default_role_codes). Folded into fn_user_get_by_id by CR-V. Tenant resolved from app.current_tenant_id GUC.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (342, 'cru_v15_fn_user_effective_modules_and_module_enabled', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.fn_user_effective_modules(BIGINT);
-- DROP FUNCTION IF EXISTS public.fn_module_enabled(UUID, TEXT);
-- DELETE FROM schema_migrations WHERE version = 342;
-- COMMIT;
-- ROLLBACK END
