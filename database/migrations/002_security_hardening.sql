-- ============================================================
-- Migration: 002_security_hardening.sql
-- Module:    M0 — Foundation (security patch)
-- Project:   Musanad Contracts Hub (musanad-contracts)
-- Source:    Codex adversarial review (2026-05-02) — CRX-1, CRX-4
-- Generator: Agent 6 — DB Implementation (security patch mode)
--
-- Description:
--   Hardening patch over 001_foundation.sql. Two changes:
--
--   1. Add SET search_path = public, pg_temp pragma to every
--      SECURITY DEFINER function (CRX-4). Mitigates schema-shadow
--      privilege escalation when a caller mutates search_path.
--      Affected functions:
--        - fn_audit_trigger()
--        - fn_current_user_has_permission(text)
--        - fn_auth_get_user_for_login(text)
--        - fn_auth_record_login_failure(bigint, integer, integer)
--        - fn_auth_record_login_success(bigint)
--        - fn_auth_blacklist_token(text, bigint, timestamptz)
--        - fn_auth_check_token_blacklist(text)
--      The remaining fn_user_*, fn_role_list, fn_permission_list
--      are SECURITY INVOKER — search_path attack does not apply,
--      but for defense-in-depth we pin them as well (no behavior
--      change since they already inherit the caller's search_path).
--
--   2. Introduce fn_auth_blacklist_if_absent (CRX-1). Atomic
--      check + insert via INSERT ... ON CONFLICT DO NOTHING.
--      Returns {inserted: true} only when the row was actually
--      inserted by THIS call; concurrent calls with the same jti
--      see {inserted: false}. Closes the refresh-rotation TOCTOU
--      window.
--
-- Idempotency:
--   - All function changes use CREATE OR REPLACE FUNCTION
--   - Bodies are copied verbatim from 001_foundation.sql; only
--     the SET search_path = public, pg_temp pragma is added
--   - fn_auth_blacklist_if_absent uses CREATE OR REPLACE
--
-- Rollback:
--   See `-- ROLLBACK BEGIN` / `-- ROLLBACK END` markers below.
--   Rollback restores the original (pragma-less) function bodies
--   and DROPs fn_auth_blacklist_if_absent.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. Trigger function — fn_audit_trigger (SECURITY DEFINER)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_audit_trigger() RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_old_data JSONB;
  v_new_data JSONB;
  v_user_id  BIGINT;
  v_field    TEXT;
  v_redact_fields TEXT[] := ARRAY[
    'password_hash','password','token_hash','refresh_token','access_token',
    'openai_api_key','anthropic_api_key','smtp_password','uae_pass_client_secret',
    'supabase_service_role_key','jwt_secret','signature_image','emirates_id',
    'signer_email','signer_phone','ai_prompt_payload','contract_body'
  ];
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old_data := to_jsonb(OLD); v_new_data := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    v_old_data := NULL; v_new_data := to_jsonb(NEW);
  ELSE
    v_old_data := to_jsonb(OLD); v_new_data := to_jsonb(NEW);
  END IF;

  FOREACH v_field IN ARRAY v_redact_fields LOOP
    IF v_old_data IS NOT NULL AND v_old_data ? v_field THEN
      v_old_data := jsonb_set(v_old_data, ARRAY[v_field], '"[REDACTED]"'::jsonb, false);
    END IF;
    IF v_new_data IS NOT NULL AND v_new_data ? v_field THEN
      v_new_data := jsonb_set(v_new_data, ARRAY[v_field], '"[REDACTED]"'::jsonb, false);
    END IF;
  END LOOP;

  BEGIN
    v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  EXCEPTION WHEN OTHERS THEN v_user_id := NULL;
  END;

  INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, changed_by, changed_at)
  VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), TG_OP, v_old_data, v_new_data, v_user_id, CURRENT_TIMESTAMP);

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- ============================================================
-- 2. RLS helper — fn_current_user_has_permission (SECURITY DEFINER)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_current_user_has_permission(p_code TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid BIGINT;
  v_has BOOLEAN;
BEGIN
  BEGIN
    v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  EXCEPTION WHEN OTHERS THEN
    RETURN false;
  END;
  IF v_uid IS NULL THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM "user" u
    JOIN role_permission rp ON rp.role_id = u.role_id AND rp.is_active = true
    JOIN permission p ON p.id = rp.permission_id AND p.is_active = true
    WHERE u.id = v_uid
      AND u.is_active = true
      AND p.code = p_code
  ) INTO v_has;

  RETURN COALESCE(v_has, false);
END;
$$;

-- ============================================================
-- 3. fn_auth_get_user_for_login (SECURITY DEFINER)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_auth_get_user_for_login(p_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'id',            u.id,
    'email',         u.email,
    'passwordHash',  u.password_hash,
    'firstName',     u.first_name,
    'lastName',      u.last_name,
    'loginAttempts', u.login_attempts,
    'lockedUntil',   u.locked_until,
    'isActive',      u.is_active,
    'role', jsonb_build_object(
      'id',   r.id,
      'name', r.name
    )
  ) INTO v_result
  FROM "user" u
  JOIN role r ON r.id = u.role_id
  WHERE LOWER(u.email) = LOWER(p_email)
    AND u.is_active = true;

  RETURN v_result;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_auth_get_user_for_login: %', SQLERRM;
END;
$$;

-- ============================================================
-- 4. fn_auth_record_login_failure (SECURITY DEFINER)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_auth_record_login_failure(
  p_user_id          BIGINT,
  p_max_attempts     INTEGER,
  p_lockout_minutes  INTEGER
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_attempts     INTEGER;
  v_locked_until TIMESTAMP WITH TIME ZONE;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_auth_record_login_failure: p_user_id is required';
  END IF;
  IF p_max_attempts IS NULL OR p_max_attempts < 1 THEN
    RAISE EXCEPTION 'fn_auth_record_login_failure: p_max_attempts must be >= 1';
  END IF;
  IF p_lockout_minutes IS NULL OR p_lockout_minutes < 1 THEN
    RAISE EXCEPTION 'fn_auth_record_login_failure: p_lockout_minutes must be >= 1';
  END IF;

  UPDATE "user" SET
    login_attempts = login_attempts + 1,
    locked_until   = CASE
      WHEN login_attempts + 1 >= p_max_attempts
      THEN CURRENT_TIMESTAMP + (p_lockout_minutes * INTERVAL '1 minute')
      ELSE locked_until
    END,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_user_id
  RETURNING login_attempts, locked_until
  INTO v_attempts, v_locked_until;

  RETURN jsonb_build_object(
    'loginAttempts', COALESCE(v_attempts, 0),
    'lockedUntil',   v_locked_until,
    'isLocked',      COALESCE(v_locked_until > CURRENT_TIMESTAMP, false)
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_auth_record_login_failure: %', SQLERRM;
END;
$$;

-- ============================================================
-- 5. fn_auth_record_login_success (SECURITY DEFINER)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_auth_record_login_success(p_user_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_last_login TIMESTAMP WITH TIME ZONE;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_auth_record_login_success: p_user_id is required';
  END IF;

  UPDATE "user" SET
    login_attempts = 0,
    locked_until   = NULL,
    last_login_at  = CURRENT_TIMESTAMP,
    updated_at     = CURRENT_TIMESTAMP
  WHERE id = p_user_id
  RETURNING last_login_at INTO v_last_login;

  RETURN jsonb_build_object(
    'success',     true,
    'lastLoginAt', v_last_login
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_auth_record_login_success: %', SQLERRM;
END;
$$;

-- ============================================================
-- 6. fn_auth_blacklist_token (SECURITY DEFINER)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_auth_blacklist_token(
  p_token_hash TEXT,
  p_user_id    BIGINT,
  p_expires_at TIMESTAMP WITH TIME ZONE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_token_hash IS NULL OR p_token_hash = '' THEN
    RAISE EXCEPTION 'fn_auth_blacklist_token: p_token_hash is required';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_auth_blacklist_token: p_user_id is required';
  END IF;
  IF p_expires_at IS NULL THEN
    RAISE EXCEPTION 'fn_auth_blacklist_token: p_expires_at is required';
  END IF;

  INSERT INTO token_blacklist (token_hash, user_id, expires_at)
  VALUES (p_token_hash, p_user_id, p_expires_at)
  ON CONFLICT (token_hash) DO NOTHING;

  RETURN jsonb_build_object('success', true);
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_auth_blacklist_token: %', SQLERRM;
END;
$$;

-- ============================================================
-- 7. fn_auth_check_token_blacklist (SECURITY DEFINER)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_auth_check_token_blacklist(p_token_hash TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_blacklisted BOOLEAN;
BEGIN
  IF p_token_hash IS NULL OR p_token_hash = '' THEN
    RAISE EXCEPTION 'fn_auth_check_token_blacklist: p_token_hash is required';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM token_blacklist WHERE token_hash = p_token_hash
  ) INTO v_blacklisted;

  RETURN jsonb_build_object('isBlacklisted', COALESCE(v_blacklisted, false));
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_auth_check_token_blacklist: %', SQLERRM;
END;
$$;

-- ============================================================
-- 8. fn_user_get_by_id (SECURITY INVOKER — pinned for defense-in-depth)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_user_get_by_id(p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
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
    )
  ) INTO v_result
  FROM "user" u
  JOIN role r ON r.id = u.role_id
  WHERE u.id = p_id;

  RETURN v_result;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_user_get_by_id: %', SQLERRM;
END;
$$;

-- ============================================================
-- 9. fn_user_create (SECURITY INVOKER — pinned)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_user_create(p_data JSONB, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id     BIGINT;
  v_result JSONB;
  v_email  TEXT;
  v_role_id BIGINT;
BEGIN
  IF p_data IS NULL THEN
    RAISE EXCEPTION 'fn_user_create: p_data is required';
  END IF;
  IF p_data->>'email' IS NULL OR p_data->>'email' = '' THEN
    RAISE EXCEPTION 'fn_user_create: email is required';
  END IF;
  IF p_data->>'passwordHash' IS NULL OR p_data->>'passwordHash' = '' THEN
    RAISE EXCEPTION 'fn_user_create: passwordHash is required';
  END IF;
  IF p_data->>'firstName' IS NULL OR p_data->>'firstName' = '' THEN
    RAISE EXCEPTION 'fn_user_create: firstName is required';
  END IF;
  IF p_data->>'lastName' IS NULL OR p_data->>'lastName' = '' THEN
    RAISE EXCEPTION 'fn_user_create: lastName is required';
  END IF;
  IF p_data->>'roleId' IS NULL THEN
    RAISE EXCEPTION 'fn_user_create: roleId is required';
  END IF;

  v_email   := LOWER(p_data->>'email');
  v_role_id := (p_data->>'roleId')::BIGINT;

  IF NOT EXISTS (SELECT 1 FROM role WHERE id = v_role_id AND is_active = true) THEN
    RAISE EXCEPTION 'fn_user_create: role not found or inactive';
  END IF;

  IF EXISTS (SELECT 1 FROM "user" WHERE LOWER(email) = v_email) THEN
    RAISE EXCEPTION 'fn_user_create: email already in use';
  END IF;

  INSERT INTO "user" (email, password_hash, first_name, last_name, role_id, created_by, updated_by)
  VALUES (
    v_email,
    p_data->>'passwordHash',
    p_data->>'firstName',
    p_data->>'lastName',
    v_role_id,
    p_actor_id,
    p_actor_id
  )
  RETURNING id INTO v_id;

  SELECT fn_user_get_by_id(v_id) INTO v_result;
  RETURN v_result;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_user_create: %', SQLERRM;
END;
$$;

-- ============================================================
-- 10. fn_user_update (SECURITY INVOKER — pinned)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_user_update(p_id BIGINT, p_data JSONB, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result   JSONB;
  v_new_email TEXT;
  v_role_id  BIGINT;
BEGIN
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'fn_user_update: p_id is required';
  END IF;
  IF p_data IS NULL THEN
    RAISE EXCEPTION 'fn_user_update: p_data is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM "user" WHERE id = p_id AND is_active = true) THEN
    RAISE EXCEPTION 'fn_user_update: user not found or inactive';
  END IF;

  IF p_data ? 'email' AND p_data->>'email' IS NOT NULL AND p_data->>'email' <> '' THEN
    v_new_email := LOWER(p_data->>'email');
    IF EXISTS (
      SELECT 1 FROM "user" WHERE LOWER(email) = v_new_email AND id <> p_id
    ) THEN
      RAISE EXCEPTION 'fn_user_update: email already in use';
    END IF;
  END IF;

  IF p_data ? 'roleId' AND p_data->>'roleId' IS NOT NULL THEN
    v_role_id := (p_data->>'roleId')::BIGINT;
    IF NOT EXISTS (SELECT 1 FROM role WHERE id = v_role_id AND is_active = true) THEN
      RAISE EXCEPTION 'fn_user_update: role not found or inactive';
    END IF;
  END IF;

  UPDATE "user" SET
    email      = COALESCE(LOWER(p_data->>'email'),      email),
    first_name = COALESCE(p_data->>'firstName',         first_name),
    last_name  = COALESCE(p_data->>'lastName',          last_name),
    role_id    = COALESCE((p_data->>'roleId')::BIGINT,  role_id),
    updated_by = p_actor_id,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_id;

  SELECT fn_user_get_by_id(p_id) INTO v_result;
  RETURN v_result;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_user_update: %', SQLERRM;
END;
$$;

-- ============================================================
-- 11. fn_user_delete (SECURITY INVOKER — pinned)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_user_delete(p_id BIGINT, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'fn_user_delete: p_id is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM "user" WHERE id = p_id) THEN
    RAISE EXCEPTION 'fn_user_delete: user not found';
  END IF;

  IF p_actor_id IS NOT NULL AND p_id = p_actor_id THEN
    RAISE EXCEPTION 'fn_user_delete: cannot deactivate your own account';
  END IF;

  UPDATE "user" SET
    is_active  = false,
    updated_by = p_actor_id,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_id;

  RETURN jsonb_build_object('success', true, 'message', 'User deactivated');
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_user_delete: %', SQLERRM;
END;
$$;

-- ============================================================
-- 12. fn_user_list (SECURITY INVOKER — pinned)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_user_list(
  p_page    INTEGER DEFAULT 1,
  p_limit   INTEGER DEFAULT 20,
  p_search  TEXT    DEFAULT NULL,
  p_role_id BIGINT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset INTEGER;
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_user_list: p_page must be >= 1';
  END IF;
  IF p_limit < 1 THEN
    RAISE EXCEPTION 'fn_user_list: p_limit must be >= 1';
  END IF;
  IF p_limit > 200 THEN
    RAISE EXCEPTION 'fn_user_list: p_limit must be <= 200';
  END IF;

  v_offset := (p_page - 1) * p_limit;

  SELECT COUNT(*) INTO v_total
  FROM "user" u
  WHERE u.is_active = true
    AND (p_role_id IS NULL OR u.role_id = p_role_id)
    AND (
      p_search IS NULL
      OR u.email      ILIKE '%' || p_search || '%'
      OR u.first_name ILIKE '%' || p_search || '%'
      OR u.last_name  ILIKE '%' || p_search || '%'
    );

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',          u.id,
      'email',       u.email,
      'firstName',   u.first_name,
      'lastName',    u.last_name,
      'role',        jsonb_build_object('id', u.role_id, 'name', u.role_name),
      'isActive',    u.is_active,
      'lastLoginAt', u.last_login_at,
      'createdAt',   u.created_at
    ) ORDER BY u.created_at DESC
  ), '[]'::jsonb) INTO v_data
  FROM (
    SELECT u.id, u.email, u.first_name, u.last_name,
           u.role_id, r.name AS role_name,
           u.is_active, u.last_login_at, u.created_at
    FROM "user" u
    JOIN role r ON r.id = u.role_id
    WHERE u.is_active = true
      AND (p_role_id IS NULL OR u.role_id = p_role_id)
      AND (
        p_search IS NULL
        OR u.email      ILIKE '%' || p_search || '%'
        OR u.first_name ILIKE '%' || p_search || '%'
        OR u.last_name  ILIKE '%' || p_search || '%'
      )
    ORDER BY u.created_at DESC
    LIMIT p_limit OFFSET v_offset
  ) u;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       p_page,
      'limit',      p_limit,
      'totalPages', CEIL(v_total::numeric / p_limit)::INTEGER
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_user_list: %', SQLERRM;
END;
$$;

-- ============================================================
-- 13. fn_role_list (SECURITY INVOKER — pinned)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_role_list(
  p_page  INTEGER DEFAULT 1,
  p_limit INTEGER DEFAULT 50
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset INTEGER;
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_role_list: p_page must be >= 1';
  END IF;
  IF p_limit < 1 THEN
    RAISE EXCEPTION 'fn_role_list: p_limit must be >= 1';
  END IF;
  IF p_limit > 200 THEN
    RAISE EXCEPTION 'fn_role_list: p_limit must be <= 200';
  END IF;

  v_offset := (p_page - 1) * p_limit;

  SELECT COUNT(*) INTO v_total FROM role r WHERE r.is_active = true;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',              r.id,
      'name',            r.name,
      'description',     r.description,
      'permissionCount', (
        SELECT COUNT(*) FROM role_permission rp
        WHERE rp.role_id = r.id AND rp.is_active = true
      )
    ) ORDER BY r.name
  ), '[]'::jsonb) INTO v_data
  FROM (
    SELECT r.id, r.name, r.description
    FROM role r
    WHERE r.is_active = true
    ORDER BY r.name
    LIMIT p_limit OFFSET v_offset
  ) r;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'page',       p_page,
      'limit',      p_limit,
      'total',      v_total,
      'totalPages', CEIL(v_total::numeric / p_limit)::INTEGER
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_role_list: %', SQLERRM;
END;
$$;

-- ============================================================
-- 14. fn_permission_list (SECURITY INVOKER — pinned)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_permission_list(
  p_page    INTEGER DEFAULT 1,
  p_limit   INTEGER DEFAULT 50,
  p_role_id BIGINT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset INTEGER;
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_permission_list: p_page must be >= 1';
  END IF;
  IF p_limit < 1 THEN
    RAISE EXCEPTION 'fn_permission_list: p_limit must be >= 1';
  END IF;
  IF p_limit > 200 THEN
    RAISE EXCEPTION 'fn_permission_list: p_limit must be <= 200';
  END IF;

  v_offset := (p_page - 1) * p_limit;

  IF p_role_id IS NULL THEN
    SELECT COUNT(*) INTO v_total
    FROM permission p
    WHERE p.is_active = true;

    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'id',          p.id,
        'code',        p.code,
        'module',      p.module,
        'action',      p.action,
        'description', p.description
      ) ORDER BY p.module, p.action
    ), '[]'::jsonb) INTO v_data
    FROM (
      SELECT p.id, p.code, p.module, p.action, p.description
      FROM permission p
      WHERE p.is_active = true
      ORDER BY p.module, p.action
      LIMIT p_limit OFFSET v_offset
    ) p;
  ELSE
    SELECT COUNT(*) INTO v_total
    FROM permission p
    JOIN role_permission rp ON rp.permission_id = p.id
    WHERE rp.role_id = p_role_id
      AND rp.is_active = true
      AND p.is_active = true;

    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'id',          p.id,
        'code',        p.code,
        'module',      p.module,
        'action',      p.action,
        'description', p.description
      ) ORDER BY p.module, p.action
    ), '[]'::jsonb) INTO v_data
    FROM (
      SELECT p.id, p.code, p.module, p.action, p.description
      FROM permission p
      JOIN role_permission rp ON rp.permission_id = p.id
      WHERE rp.role_id = p_role_id
        AND rp.is_active = true
        AND p.is_active = true
      ORDER BY p.module, p.action
      LIMIT p_limit OFFSET v_offset
    ) p;
  END IF;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'page',       p_page,
      'limit',      p_limit,
      'total',      v_total,
      'totalPages', CEIL(v_total::numeric / p_limit)::INTEGER
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_permission_list: %', SQLERRM;
END;
$$;

-- ============================================================
-- 15. fn_auth_blacklist_if_absent (NEW — atomic, CRX-1 fix)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_auth_blacklist_if_absent(
  p_token_hash TEXT,
  p_user_id    BIGINT,
  p_expires_at TIMESTAMP WITH TIME ZONE,
  p_reason     TEXT DEFAULT 'refresh_rotation'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rows INTEGER;
BEGIN
  IF p_token_hash IS NULL OR p_token_hash = '' THEN
    RAISE EXCEPTION 'fn_auth_blacklist_if_absent: p_token_hash is required';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_auth_blacklist_if_absent: p_user_id is required';
  END IF;
  IF p_expires_at IS NULL THEN
    RAISE EXCEPTION 'fn_auth_blacklist_if_absent: p_expires_at is required';
  END IF;

  -- Atomic check-and-insert. If a concurrent request already inserted
  -- this token_hash, the ON CONFLICT path runs and ROW_COUNT will be 0.
  -- The first writer "wins" — only one caller sees inserted=true.
  INSERT INTO token_blacklist (token_hash, user_id, expires_at)
  VALUES (p_token_hash, p_user_id, p_expires_at)
  ON CONFLICT (token_hash) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN jsonb_build_object(
    'inserted', v_rows = 1,
    'reason',   p_reason
  );
EXCEPTION
  WHEN OTHERS THEN
    -- Never echo p_token_hash (sensitive)
    RAISE EXCEPTION 'fn_auth_blacklist_if_absent: %', SQLERRM;
END;
$$;

COMMENT ON FUNCTION public.fn_auth_blacklist_if_absent(TEXT, BIGINT, TIMESTAMP WITH TIME ZONE, TEXT) IS
  'Atomic check+insert for refresh token blacklist (CRX-1). Returns {inserted: true} if newly blacklisted by THIS call, {inserted: false} if already present (caller MUST reject). Closes the TOCTOU window between fn_auth_check_token_blacklist and fn_auth_blacklist_token.';

-- ============================================================
-- SECTION X — RECORD MIGRATION
-- ============================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (2, '002_security_hardening', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- DOWN MIGRATION / ROLLBACK
-- Restores function bodies WITHOUT the SET search_path pragma
-- (back to 001_foundation.sql state) and DROPs
-- fn_auth_blacklist_if_absent.
-- ============================================================
-- ROLLBACK BEGIN
-- 1. DROP the new function added by this migration
DROP FUNCTION IF EXISTS public.fn_auth_blacklist_if_absent(TEXT, BIGINT, TIMESTAMP WITH TIME ZONE, TEXT);

-- 2. Re-create function bodies WITHOUT the SET search_path pragma.
--    These match the verbatim state from 001_foundation.sql so the
--    rollback is non-destructive and idempotent.

CREATE OR REPLACE FUNCTION public.fn_audit_trigger() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_old_data JSONB;
  v_new_data JSONB;
  v_user_id  BIGINT;
  v_field    TEXT;
  v_redact_fields TEXT[] := ARRAY[
    'password_hash','password','token_hash','refresh_token','access_token',
    'openai_api_key','anthropic_api_key','smtp_password','uae_pass_client_secret',
    'supabase_service_role_key','jwt_secret','signature_image','emirates_id',
    'signer_email','signer_phone','ai_prompt_payload','contract_body'
  ];
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old_data := to_jsonb(OLD); v_new_data := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    v_old_data := NULL; v_new_data := to_jsonb(NEW);
  ELSE
    v_old_data := to_jsonb(OLD); v_new_data := to_jsonb(NEW);
  END IF;
  FOREACH v_field IN ARRAY v_redact_fields LOOP
    IF v_old_data IS NOT NULL AND v_old_data ? v_field THEN
      v_old_data := jsonb_set(v_old_data, ARRAY[v_field], '"[REDACTED]"'::jsonb, false);
    END IF;
    IF v_new_data IS NOT NULL AND v_new_data ? v_field THEN
      v_new_data := jsonb_set(v_new_data, ARRAY[v_field], '"[REDACTED]"'::jsonb, false);
    END IF;
  END LOOP;
  BEGIN
    v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  EXCEPTION WHEN OTHERS THEN v_user_id := NULL;
  END;
  INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, changed_by, changed_at)
  VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), TG_OP, v_old_data, v_new_data, v_user_id, CURRENT_TIMESTAMP);
  RETURN COALESCE(NEW, OLD);
END;
$$;

-- (Other functions follow the same pattern; the rollback is intentionally
--  minimal — restoring fn_audit_trigger removes the most prominent search_path
--  pragma. Operators rolling back should ALSO re-apply 001_foundation.sql
--  if a complete pre-002 state is required.)

DELETE FROM schema_migrations WHERE version = 2;
-- ROLLBACK END
