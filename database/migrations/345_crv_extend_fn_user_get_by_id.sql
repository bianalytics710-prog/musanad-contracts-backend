-- Migration: 345_crv_extend_fn_user_get_by_id.sql
-- Module: CR-V — Backend wiring for Product Module Toggle (wave v1.5)
-- Description: Extend fn_user_get_by_id to include effectiveModules (text[] →
--              cast to jsonb array) so the auth middleware gets the module set
--              in a single DB round-trip (no second query needed in auth.middleware.ts).
--
-- CR-V design choice: fold effectiveModules into the existing fn_user_get_by_id
-- rather than a separate query in the middleware. This is the single auth
-- round-trip path specified in the plan (§"Single source of truth").
--
-- SECURITY: fn_user_get_by_id is SECURITY INVOKER. The new sub-call to
-- fn_user_effective_modules is SECURITY DEFINER — that function handles its own
-- tenant resolution from app.current_tenant_id GUC, which is already set by
-- the time this fn is called during authentication.
--
-- Rollback: see ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_user_get_by_id(p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_result JSONB;
BEGIN
  IF p_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'id',           u.id,
    'email',        u.email,
    'firstName',    u.first_name,
    'lastName',     u.last_name,
    'isActive',     u.is_active,
    'lastLoginAt',  u.last_login_at,
    'createdAt',    u.created_at,
    'updatedAt',    u.updated_at,
    'role', jsonb_build_object(
      'id',   r.id,
      'name', r.name
    ),
    'permissions', (
      SELECT COALESCE(jsonb_agg(p.code ORDER BY p.code), '[]'::jsonb)
      FROM role_permission rp
      JOIN permission p ON p.id = rp.permission_id
      WHERE rp.role_id = u.role_id
        AND rp.is_active = true
        AND p.is_active = true
    ),
    'effectiveModules', (
      SELECT COALESCE(
        to_jsonb(fn_user_effective_modules(u.id)),
        '[]'::jsonb
      )
    )
  ) INTO v_result
  FROM "user" u
  JOIN role r ON r.id = u.role_id
  WHERE u.id = p_id;

  RETURN v_result;  -- NULL if not found
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_user_get_by_id: %', SQLERRM;
END;
$fn$;

COMMENT ON FUNCTION public.fn_user_get_by_id(BIGINT) IS
  'Returns full user with role, permissions[] (codes), and effectiveModules[] (module keys). NEVER returns passwordHash. NULL if not found. CR-V: effectiveModules added via fn_user_effective_modules sub-call (single auth round-trip).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (345, 'crv_extend_fn_user_get_by_id_effective_modules', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- -- Restore original fn_user_get_by_id without effectiveModules key.
-- CREATE OR REPLACE FUNCTION public.fn_user_get_by_id(p_id BIGINT)
-- RETURNS JSONB
-- LANGUAGE plpgsql
-- STABLE
-- SECURITY INVOKER
-- SET search_path = public, pg_temp
-- AS $fn$
-- DECLARE
--   v_result JSONB;
-- BEGIN
--   IF p_id IS NULL THEN
--     RETURN NULL;
--   END IF;
--   SELECT jsonb_build_object(
--     'id',           u.id,
--     'email',        u.email,
--     'firstName',    u.first_name,
--     'lastName',     u.last_name,
--     'isActive',     u.is_active,
--     'lastLoginAt',  u.last_login_at,
--     'createdAt',    u.created_at,
--     'updatedAt',    u.updated_at,
--     'role', jsonb_build_object('id', r.id, 'name', r.name),
--     'permissions', (
--       SELECT COALESCE(jsonb_agg(p.code ORDER BY p.code), '[]'::jsonb)
--       FROM role_permission rp
--       JOIN permission p ON p.id = rp.permission_id
--       WHERE rp.role_id = u.role_id
--         AND rp.is_active = true
--         AND p.is_active = true
--     )
--   ) INTO v_result
--   FROM "user" u JOIN role r ON r.id = u.role_id
--   WHERE u.id = p_id;
--   RETURN v_result;
-- EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_user_get_by_id: %', SQLERRM;
-- END;
-- $fn$;
-- DELETE FROM schema_migrations WHERE version = 345;
-- COMMIT;
-- ROLLBACK END
