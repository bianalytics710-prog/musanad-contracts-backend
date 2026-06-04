-- MIGRATION: 538_dev_login_personas_visibility.sql
-- Date: 2026-06-03
-- Description:
--   Platform admin can hide personas from the dev one-click login panel on
--   /auth/login. Backed by a single system_setting row holding an array of
--   persona keys to hide. Empty array = all 11 personas visible (default).
--
--   Persona keys are the FE-side identifiers in LoginForm.tsx:
--     super, platform, legal, drafter, approver, recipient, executive,
--     operations, finance, compliance, procurement
--
--   The GET fn is callable by anyone (no permission check) because the
--   login page must reach it before the user has authenticated. The SET
--   fn requires the new dev.login_personas.manage permission.

BEGIN;

-- ============================================================
-- 1. Permission.
-- ============================================================
INSERT INTO permission (code, module, action, description, is_active, created_at)
VALUES ('dev.login_personas.manage', 'dev', 'login_personas.manage',
        'Toggle which dev personas appear on the one-click login panel', TRUE, CURRENT_TIMESTAMP)
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permission (role_id, permission_id, is_active, created_at)
SELECT r.id, p.id, TRUE, CURRENT_TIMESTAMP
  FROM role r, permission p
 WHERE r.name IN ('Super Admin', 'platform_admin')
   AND p.code = 'dev.login_personas.manage'
ON CONFLICT DO NOTHING;

-- ============================================================
-- 2. system_setting row — default = nothing hidden.
-- ============================================================
INSERT INTO system_setting
  (key, value, description, category, is_secret, is_active, created_at, updated_at)
VALUES
  ('dev.login_personas_hidden',
   '[]'::jsonb,
   'Array of persona keys to hide from the dev one-click login panel. Empty = all visible.',
   'general', FALSE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- 3. fn_dev_login_personas_get — readable without auth (login page calls
--    before the user is signed in). Returns just the array.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_dev_login_personas_get()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $fn$
  SELECT COALESCE(
    (SELECT value FROM system_setting WHERE key = 'dev.login_personas_hidden' AND is_active = TRUE LIMIT 1),
    '[]'::jsonb
  );
$fn$;

-- Public-readable by design — the login page is pre-auth.
GRANT EXECUTE ON FUNCTION fn_dev_login_personas_get() TO PUBLIC;

-- ============================================================
-- 4. fn_dev_login_personas_set — admin write.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_dev_login_personas_set(p_hidden jsonb, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $fn$
BEGIN
  IF NOT fn_current_user_has_permission('dev.login_personas.manage') THEN
    RAISE EXCEPTION 'Permission denied: dev.login_personas.manage required' USING ERRCODE = '42501';
  END IF;

  IF jsonb_typeof(p_hidden) <> 'array' THEN
    RAISE EXCEPTION 'hidden must be a JSON array' USING ERRCODE = '22023';
  END IF;

  UPDATE system_setting
     SET value      = p_hidden,
         updated_at = CURRENT_TIMESTAMP,
         updated_by = p_actor_id
   WHERE key = 'dev.login_personas_hidden';

  RETURN jsonb_build_object(
    'hidden',  p_hidden,
    'updatedBy', p_actor_id
  );
END;
$fn$;

REVOKE EXECUTE ON FUNCTION fn_dev_login_personas_set(jsonb, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dev_login_personas_set(jsonb, bigint) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (538, 'dev_login_personas_visibility', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
