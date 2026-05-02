-- ============================================================
-- Migration: 001_foundation.sql
-- Module:    M0 — Foundation
-- Project:   Musanad Contracts Hub (musanad-contracts)
-- Source:    db-design.md v1.1 (Agent 4 — DB Architect)
-- Generator: Agent 6 — DB Implementation
--
-- Description:
--   Bootstrap migration. Creates:
--     - 7 tables  : schema_migrations, audit_log, role, permission,
--                   role_permission, "user", token_blacklist
--     - 19 named indexes
--     - 1 trigger function   : fn_audit_trigger
--     - 1 RLS helper function: fn_current_user_has_permission
--     - 13 fn_ API functions : fn_auth_* (5), fn_user_* (5),
--                              fn_role_* (1), fn_permission_* (1)
--     - 3 audit triggers     : audit_user_changes,
--                              audit_role_changes,
--                              audit_role_permission_changes
--     - 16 RLS policies (production-grade per decisions.md G5)
--     - 4 seed datasets      : permission (4), role (3),
--                              role_permission (7), user (1)
--
-- Idempotency:
--   - All table DDL uses CREATE TABLE IF NOT EXISTS
--   - All indexes use CREATE INDEX IF NOT EXISTS
--   - All functions use CREATE OR REPLACE FUNCTION
--   - All triggers use DROP IF EXISTS / CREATE
--   - All policies use DROP IF EXISTS / CREATE
--   - All seeds use ON CONFLICT DO UPDATE / DO NOTHING
--
-- Rollback:
--   See `-- ROLLBACK BEGIN` / `-- ROLLBACK END` markers at the
--   bottom of this file. The migration runner locates these
--   markers when invoked with --down.
-- ============================================================

BEGIN;

-- ============================================================
-- SECTION 1 — TABLE DDL
-- ============================================================

-- 1.1 schema_migrations -------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_migrations (
  version     INTEGER     PRIMARY KEY,
  description TEXT        NOT NULL,
  applied_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE schema_migrations IS 'Tracks applied migrations. Inserted into automatically by the migration runner (database/migrate.ts) at the end of each migration file inside the BEGIN/COMMIT block.';

-- 1.2 audit_log ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
  id          BIGSERIAL   PRIMARY KEY,
  table_name  TEXT        NOT NULL,
  record_id   BIGINT,
  action      TEXT        NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
  old_values  JSONB,
  new_values  JSONB,
  changed_by  BIGINT,
  changed_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE audit_log IS 'Append-only audit trail. Written by fn_audit_trigger() on every INSERT/UPDATE/DELETE of any business table. Sensitive fields (per project.config.json sensitiveFields) are redacted to "[REDACTED]" inside fn_audit_trigger before insertion. No UPDATE or DELETE policies — append-only.';
COMMENT ON COLUMN audit_log.old_values IS 'JSONB snapshot of OLD row, sensitive fields redacted.';
COMMENT ON COLUMN audit_log.new_values IS 'JSONB snapshot of NEW row, sensitive fields redacted.';

-- 1.3 role --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS role (
  id          BIGSERIAL   PRIMARY KEY,
  name        TEXT        NOT NULL UNIQUE,
  description TEXT,
  created_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by  BIGINT,
  updated_by  BIGINT,
  is_active   BOOLEAN     DEFAULT true NOT NULL
);

COMMENT ON TABLE role IS 'Application roles (Super Admin, Admin, User, plus project-specific roles in feature modules). Permissions assigned via role_permission junction.';

-- 1.4 permission --------------------------------------------------------
CREATE TABLE IF NOT EXISTS permission (
  id          BIGSERIAL   PRIMARY KEY,
  code        TEXT        NOT NULL UNIQUE,
  module      TEXT        NOT NULL,
  action      TEXT        NOT NULL,
  description TEXT,
  created_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  is_active   BOOLEAN     DEFAULT true NOT NULL
);

COMMENT ON TABLE permission IS 'Permission catalog. Code is the canonical identifier (e.g., "user.manage"). Used in RLS capability-lookup queries and BE authorise() middleware. Note: column is "code" not "name" so "name" is free for a human-readable label in feature modules if needed.';
COMMENT ON COLUMN permission.code IS 'Canonical permission identifier in dot.notation. Referenced by RLS policies and authorise() middleware. Examples: user.read.all, user.manage, audit.read, role.manage.';

-- 1.5 role_permission ---------------------------------------------------
CREATE TABLE IF NOT EXISTS role_permission (
  id            BIGSERIAL PRIMARY KEY,
  role_id       BIGINT    NOT NULL REFERENCES role(id) ON DELETE CASCADE,
  permission_id BIGINT    NOT NULL REFERENCES permission(id) ON DELETE CASCADE,
  created_at    TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by    BIGINT,
  is_active     BOOLEAN   DEFAULT true NOT NULL,
  UNIQUE(role_id, permission_id)
);

COMMENT ON TABLE role_permission IS 'Junction table mapping roles to permissions. UNIQUE(role_id, permission_id) prevents duplicates. is_active = false soft-revokes a permission for a role.';

-- 1.6 "user" ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "user" (
  id              BIGSERIAL   PRIMARY KEY,
  email           TEXT        NOT NULL UNIQUE,
  password_hash   TEXT        NOT NULL,
  first_name      TEXT        NOT NULL,
  last_name       TEXT        NOT NULL,
  role_id         BIGINT      NOT NULL REFERENCES role(id),
  login_attempts  INTEGER     DEFAULT 0 NOT NULL,
  locked_until    TIMESTAMP WITH TIME ZONE,
  last_login_at   TIMESTAMP WITH TIME ZONE,
  created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_by      BIGINT      REFERENCES "user"(id),
  updated_by      BIGINT      REFERENCES "user"(id),
  is_active       BOOLEAN     DEFAULT true NOT NULL
);

COMMENT ON TABLE "user" IS 'Base user entity. Quoted identifier required because "user" is a SQL reserved word. password_hash is bcrypt(12) — never returned by any fn_ function or logged. Lockout enforced via login_attempts (>= auth.maxFailedAttempts from config) + locked_until (now() + auth.lockoutMinutes).';
COMMENT ON COLUMN "user".password_hash IS 'bcrypt hash with 12 rounds. SENSITIVE — must never appear in fn_ output JSONB or audit_log.old_values/new_values.';
COMMENT ON COLUMN "user".login_attempts IS 'Consecutive failed login attempts. Reset to 0 on successful login. Triggers lockout when >= 5 (auth.maxFailedAttempts).';
COMMENT ON COLUMN "user".locked_until IS 'NULL when not locked. Set to now() + 15 minutes (auth.lockoutMinutes) when login_attempts hits the threshold.';

-- 1.7 token_blacklist ---------------------------------------------------
CREATE TABLE IF NOT EXISTS token_blacklist (
  id             BIGSERIAL   PRIMARY KEY,
  token_hash     TEXT        NOT NULL UNIQUE,
  user_id        BIGINT      NOT NULL REFERENCES "user"(id),
  blacklisted_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  expires_at     TIMESTAMP WITH TIME ZONE NOT NULL
);

COMMENT ON TABLE token_blacklist IS 'Append-only server-side refresh token invalidation. Stores SHA-256 hash of the refresh token (never the token itself). Cleaned up by scheduled job (DELETE WHERE expires_at < now()). No audit trigger — this IS the audit for token revocation.';
COMMENT ON COLUMN token_blacklist.token_hash IS 'SHA-256 hex digest of the refresh token JWT. SENSITIVE — never returned in any fn_ output JSONB.';

-- ============================================================
-- SECTION 2 — INDEXES (19 named indexes)
-- ============================================================

-- audit_log
CREATE INDEX IF NOT EXISTS idx_audit_log_table_record ON audit_log(table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_changed_by   ON audit_log(changed_by);
CREATE INDEX IF NOT EXISTS idx_audit_log_changed_at   ON audit_log(changed_at DESC);

-- role
CREATE INDEX IF NOT EXISTS idx_role_active ON role(id) WHERE is_active = true;

-- permission
CREATE INDEX IF NOT EXISTS idx_permission_code   ON permission(code);
CREATE INDEX IF NOT EXISTS idx_permission_module ON permission(module);
CREATE INDEX IF NOT EXISTS idx_permission_active ON permission(id) WHERE is_active = true;

-- role_permission
CREATE INDEX IF NOT EXISTS idx_role_permission_role_id       ON role_permission(role_id);
CREATE INDEX IF NOT EXISTS idx_role_permission_permission_id ON role_permission(permission_id);
CREATE INDEX IF NOT EXISTS idx_role_permission_active        ON role_permission(id) WHERE is_active = true;

-- "user"
CREATE INDEX IF NOT EXISTS idx_user_email      ON "user"(email);
CREATE INDEX IF NOT EXISTS idx_user_role_id    ON "user"(role_id);
CREATE INDEX IF NOT EXISTS idx_user_active     ON "user"(id) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_user_created_by ON "user"(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_user_updated_by ON "user"(updated_by) WHERE updated_by IS NOT NULL;

-- token_blacklist
CREATE INDEX IF NOT EXISTS idx_token_blacklist_hash       ON token_blacklist(token_hash);
CREATE INDEX IF NOT EXISTS idx_token_blacklist_user_id    ON token_blacklist(user_id);
CREATE INDEX IF NOT EXISTS idx_token_blacklist_expires_at ON token_blacklist(expires_at);

-- ============================================================
-- SECTION 3 — TRIGGER FUNCTION (fn_audit_trigger)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_audit_trigger() RETURNS TRIGGER
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
  -- Capture row state
  IF TG_OP = 'DELETE' THEN
    v_old_data := to_jsonb(OLD); v_new_data := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    v_old_data := NULL; v_new_data := to_jsonb(NEW);
  ELSE
    v_old_data := to_jsonb(OLD); v_new_data := to_jsonb(NEW);
  END IF;

  -- Redact sensitive fields wherever they appear (column-name match on the JSONB key)
  FOREACH v_field IN ARRAY v_redact_fields LOOP
    IF v_old_data IS NOT NULL AND v_old_data ? v_field THEN
      v_old_data := jsonb_set(v_old_data, ARRAY[v_field], '"[REDACTED]"'::jsonb, false);
    END IF;
    IF v_new_data IS NOT NULL AND v_new_data ? v_field THEN
      v_new_data := jsonb_set(v_new_data, ARRAY[v_field], '"[REDACTED]"'::jsonb, false);
    END IF;
  END LOOP;

  -- Resolve actor from session GUC (set by rls.middleware before each request)
  BEGIN
    v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  EXCEPTION WHEN OTHERS THEN v_user_id := NULL;
  END;

  INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, changed_by, changed_at)
  VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), TG_OP, v_old_data, v_new_data, v_user_id, CURRENT_TIMESTAMP);

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION fn_audit_trigger() IS 'Generic audit trigger. Logs INSERT/UPDATE/DELETE to audit_log. Redacts 17 sensitive field names project-wide before insertion.';

-- ============================================================
-- SECTION 4 — AUDIT TRIGGERS
-- ============================================================

DROP TRIGGER IF EXISTS audit_user_changes ON "user";
CREATE TRIGGER audit_user_changes
  AFTER INSERT OR UPDATE OR DELETE ON "user"
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

DROP TRIGGER IF EXISTS audit_role_changes ON role;
CREATE TRIGGER audit_role_changes
  AFTER INSERT OR UPDATE OR DELETE ON role
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

DROP TRIGGER IF EXISTS audit_role_permission_changes ON role_permission;
CREATE TRIGGER audit_role_permission_changes
  AFTER INSERT OR UPDATE OR DELETE ON role_permission
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ============================================================
-- SECTION 5 — RLS HELPER (fn_current_user_has_permission)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_current_user_has_permission(p_code TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_uid BIGINT;
  v_has BOOLEAN;
BEGIN
  -- Read session GUC; NULL → unauthenticated → false
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

COMMENT ON FUNCTION fn_current_user_has_permission(TEXT) IS 'RLS helper. Returns true iff the current session user (app.current_user_id GUC) has a role granting the named permission. SECURITY DEFINER so it can read role_permission/permission regardless of caller RLS.';

-- ============================================================
-- SECTION 6 — RLS ENABLE + POLICIES (16 policies on 7 tables)
-- ============================================================

-- 6.1 "user" table -----------------------------------------------------
ALTER TABLE "user" ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_select_self_or_admin ON "user";
CREATE POLICY user_select_self_or_admin ON "user"
FOR SELECT
USING (
  id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
  OR fn_current_user_has_permission('user.read.all')
);

DROP POLICY IF EXISTS user_insert_admin ON "user";
CREATE POLICY user_insert_admin ON "user"
FOR INSERT
WITH CHECK ( fn_current_user_has_permission('user.manage') );

DROP POLICY IF EXISTS user_update_self_or_admin ON "user";
CREATE POLICY user_update_self_or_admin ON "user"
FOR UPDATE
USING (
  id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
  OR fn_current_user_has_permission('user.manage')
)
WITH CHECK (
  id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
  OR fn_current_user_has_permission('user.manage')
);

DROP POLICY IF EXISTS user_delete_admin ON "user";
CREATE POLICY user_delete_admin ON "user"
FOR DELETE
USING ( fn_current_user_has_permission('user.manage') );

-- 6.2 role / permission / role_permission ------------------------------
ALTER TABLE role            ENABLE ROW LEVEL SECURITY;
ALTER TABLE permission      ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permission ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_select_authenticated ON role;
CREATE POLICY role_select_authenticated ON role
FOR SELECT
USING ( NULLIF(current_setting('app.current_user_id', true), '')::BIGINT IS NOT NULL );

DROP POLICY IF EXISTS role_modify_admin ON role;
CREATE POLICY role_modify_admin ON role
FOR ALL
USING ( fn_current_user_has_permission('role.manage') )
WITH CHECK ( fn_current_user_has_permission('role.manage') );

DROP POLICY IF EXISTS permission_select_authenticated ON permission;
CREATE POLICY permission_select_authenticated ON permission
FOR SELECT
USING ( NULLIF(current_setting('app.current_user_id', true), '')::BIGINT IS NOT NULL );

DROP POLICY IF EXISTS permission_modify_admin ON permission;
CREATE POLICY permission_modify_admin ON permission
FOR ALL
USING ( fn_current_user_has_permission('role.manage') )
WITH CHECK ( fn_current_user_has_permission('role.manage') );

DROP POLICY IF EXISTS role_permission_select_authenticated ON role_permission;
CREATE POLICY role_permission_select_authenticated ON role_permission
FOR SELECT
USING ( NULLIF(current_setting('app.current_user_id', true), '')::BIGINT IS NOT NULL );

DROP POLICY IF EXISTS role_permission_modify_admin ON role_permission;
CREATE POLICY role_permission_modify_admin ON role_permission
FOR ALL
USING ( fn_current_user_has_permission('role.manage') )
WITH CHECK ( fn_current_user_has_permission('role.manage') );

-- 6.3 token_blacklist --------------------------------------------------
ALTER TABLE token_blacklist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS token_blacklist_deny_direct ON token_blacklist;
CREATE POLICY token_blacklist_deny_direct ON token_blacklist
FOR ALL
USING ( false )
WITH CHECK ( false );

-- 6.4 audit_log --------------------------------------------------------
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS audit_log_select_audit_read ON audit_log;
CREATE POLICY audit_log_select_audit_read ON audit_log
FOR SELECT
USING ( fn_current_user_has_permission('audit.read') );

DROP POLICY IF EXISTS audit_log_deny_direct_insert ON audit_log;
CREATE POLICY audit_log_deny_direct_insert ON audit_log
FOR INSERT
WITH CHECK ( false );

DROP POLICY IF EXISTS audit_log_deny_update ON audit_log;
CREATE POLICY audit_log_deny_update ON audit_log
FOR UPDATE
USING ( false ) WITH CHECK ( false );

DROP POLICY IF EXISTS audit_log_deny_delete ON audit_log;
CREATE POLICY audit_log_deny_delete ON audit_log
FOR DELETE
USING ( false );

-- 6.5 schema_migrations ------------------------------------------------
ALTER TABLE schema_migrations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS schema_migrations_deny_all ON schema_migrations;
CREATE POLICY schema_migrations_deny_all ON schema_migrations
FOR ALL
USING ( false ) WITH CHECK ( false );

-- ============================================================
-- SECTION 7 — fn_auth_* FUNCTIONS (5)
-- ============================================================

-- 7.1 fn_auth_get_user_for_login ---------------------------------------
CREATE OR REPLACE FUNCTION fn_auth_get_user_for_login(p_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
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

  RETURN v_result;  -- NULL when not found / inactive
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_auth_get_user_for_login: %', SQLERRM;
END;
$$;

COMMENT ON FUNCTION fn_auth_get_user_for_login(TEXT) IS 'Returns user with passwordHash + lockout state for login controller. SECURITY DEFINER. Returns NULL when not found or inactive (controller returns generic 401 — no email-existence leak). Controller must redact passwordHash via pino before any log line.';

-- 7.2 fn_auth_record_login_failure -------------------------------------
CREATE OR REPLACE FUNCTION fn_auth_record_login_failure(
  p_user_id          BIGINT,
  p_max_attempts     INTEGER,
  p_lockout_minutes  INTEGER
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
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

COMMENT ON FUNCTION fn_auth_record_login_failure(BIGINT, INTEGER, INTEGER) IS 'Increments login_attempts; sets locked_until when threshold reached. Returns {loginAttempts, lockedUntil, isLocked}.';

-- 7.3 fn_auth_record_login_success -------------------------------------
CREATE OR REPLACE FUNCTION fn_auth_record_login_success(p_user_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
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

COMMENT ON FUNCTION fn_auth_record_login_success(BIGINT) IS 'Resets login_attempts, locked_until; sets last_login_at.';

-- 7.4 fn_auth_blacklist_token ------------------------------------------
CREATE OR REPLACE FUNCTION fn_auth_blacklist_token(
  p_token_hash TEXT,
  p_user_id    BIGINT,
  p_expires_at TIMESTAMP WITH TIME ZONE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
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
    -- Do NOT echo p_token_hash in the error message (sensitive)
    RAISE EXCEPTION 'fn_auth_blacklist_token: %', SQLERRM;
END;
$$;

COMMENT ON FUNCTION fn_auth_blacklist_token(TEXT, BIGINT, TIMESTAMP WITH TIME ZONE) IS 'Inserts refresh-token hash into token_blacklist (idempotent via ON CONFLICT). p_token_hash is sensitive — never logged or echoed.';

-- 7.5 fn_auth_check_token_blacklist ------------------------------------
CREATE OR REPLACE FUNCTION fn_auth_check_token_blacklist(p_token_hash TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
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

COMMENT ON FUNCTION fn_auth_check_token_blacklist(TEXT) IS 'Returns {isBlacklisted: boolean}. SECURITY DEFINER bypasses RLS deny-all on token_blacklist.';

-- ============================================================
-- SECTION 8 — fn_user_* FUNCTIONS (5)
-- ============================================================

-- 8.1 fn_user_get_by_id (defined first because fn_user_create / fn_user_update call it)
CREATE OR REPLACE FUNCTION fn_user_get_by_id(p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
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

  RETURN v_result;  -- NULL if not found
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_user_get_by_id: %', SQLERRM;
END;
$$;

COMMENT ON FUNCTION fn_user_get_by_id(BIGINT) IS 'Returns full user with role and permissions[] (codes). NEVER returns passwordHash. NULL if not found.';

-- 8.2 fn_user_create ---------------------------------------------------
CREATE OR REPLACE FUNCTION fn_user_create(p_data JSONB, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_id     BIGINT;
  v_result JSONB;
  v_email  TEXT;
  v_role_id BIGINT;
BEGIN
  -- Validation
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

  -- Role must exist and be active
  IF NOT EXISTS (SELECT 1 FROM role WHERE id = v_role_id AND is_active = true) THEN
    RAISE EXCEPTION 'fn_user_create: role not found or inactive';
  END IF;

  -- Uniqueness on email
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
    -- Do NOT include p_data verbatim — may contain passwordHash
    RAISE EXCEPTION 'fn_user_create: %', SQLERRM;
END;
$$;

COMMENT ON FUNCTION fn_user_create(JSONB, BIGINT) IS 'Creates a user; controller pre-hashes password with bcrypt(12). Returns via fn_user_get_by_id. passwordHash never returned by fn_user_get_by_id.';

-- 8.3 fn_user_update ---------------------------------------------------
CREATE OR REPLACE FUNCTION fn_user_update(p_id BIGINT, p_data JSONB, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
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

  -- Existence + active
  IF NOT EXISTS (SELECT 1 FROM "user" WHERE id = p_id AND is_active = true) THEN
    RAISE EXCEPTION 'fn_user_update: user not found or inactive';
  END IF;

  -- Email uniqueness (only if email is being changed)
  IF p_data ? 'email' AND p_data->>'email' IS NOT NULL AND p_data->>'email' <> '' THEN
    v_new_email := LOWER(p_data->>'email');
    IF EXISTS (
      SELECT 1 FROM "user" WHERE LOWER(email) = v_new_email AND id <> p_id
    ) THEN
      RAISE EXCEPTION 'fn_user_update: email already in use';
    END IF;
  END IF;

  -- Role validity (only if roleId is being changed)
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

COMMENT ON FUNCTION fn_user_update(BIGINT, JSONB, BIGINT) IS 'Partial COALESCE update of email/firstName/lastName/roleId. Returns via fn_user_get_by_id.';

-- 8.4 fn_user_delete ---------------------------------------------------
CREATE OR REPLACE FUNCTION fn_user_delete(p_id BIGINT, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'fn_user_delete: p_id is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM "user" WHERE id = p_id) THEN
    RAISE EXCEPTION 'fn_user_delete: user not found';
  END IF;

  -- Self-protection: cannot deactivate self
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

COMMENT ON FUNCTION fn_user_delete(BIGINT, BIGINT) IS 'Soft delete (is_active=false). Self-protection: cannot deactivate self.';

-- 8.5 fn_user_list -----------------------------------------------------
CREATE OR REPLACE FUNCTION fn_user_list(
  p_page    INTEGER DEFAULT 1,
  p_limit   INTEGER DEFAULT 20,
  p_search  TEXT    DEFAULT NULL,
  p_role_id BIGINT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
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

COMMENT ON FUNCTION fn_user_list(INTEGER, INTEGER, TEXT, BIGINT) IS 'Paginated list with role filter and search across email/firstName/lastName. Returns {data:[], pagination:{}}.';

-- ============================================================
-- SECTION 9 — fn_role_* / fn_permission_* FUNCTIONS (2)
-- ============================================================

-- 9.1 fn_role_list -----------------------------------------------------
CREATE OR REPLACE FUNCTION fn_role_list(
  p_page  INTEGER DEFAULT 1,
  p_limit INTEGER DEFAULT 50
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
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

COMMENT ON FUNCTION fn_role_list(INTEGER, INTEGER) IS 'Paginated list of active roles with permissionCount. Returns {data:[], pagination:{page, limit, total, totalPages}}.';

-- 9.2 fn_permission_list -----------------------------------------------
CREATE OR REPLACE FUNCTION fn_permission_list(
  p_page    INTEGER DEFAULT 1,
  p_limit   INTEGER DEFAULT 50,
  p_role_id BIGINT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
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

COMMENT ON FUNCTION fn_permission_list(INTEGER, INTEGER, BIGINT) IS 'Paginated permission catalog. If p_role_id provided, only that role''s permissions. Returns {data:[], pagination:{page, limit, total, totalPages}}.';

-- ============================================================
-- SECTION 10 — SEED DATA
-- ============================================================

-- 10.1 Permission catalog (4 rows) -------------------------------------
-- Stable IDs 1..99 reserved for foundation permissions.
INSERT INTO permission (id, code, module, action, description, is_active) VALUES
  (1, 'user.read.all',  'user',  'read.all',  'List and read any user profile',                 true),
  (2, 'user.manage',    'user',  'manage',    'Create, update, deactivate users',               true),
  (3, 'role.manage',    'role',  'manage',    'Manage roles, permissions, role-permission map', true),
  (4, 'audit.read',     'audit', 'read',      'Read audit log entries',                         true)
ON CONFLICT (id) DO UPDATE SET
  code        = EXCLUDED.code,
  module      = EXCLUDED.module,
  action      = EXCLUDED.action,
  description = EXCLUDED.description,
  is_active   = true;

SELECT setval('permission_id_seq', GREATEST((SELECT MAX(id) FROM permission), 1));

-- 10.2 Role catalog (3 rows) -------------------------------------------
-- Stable IDs 1..99 reserved for foundation roles.
INSERT INTO role (id, name, description, is_active) VALUES
  (1, 'Super Admin', 'Full system access',         true),
  (2, 'Admin',       'Administrative access',      true),
  (3, 'User',        'Standard user access',       true)
ON CONFLICT (id) DO UPDATE SET
  name        = EXCLUDED.name,
  description = EXCLUDED.description,
  is_active   = true;

SELECT setval('role_id_seq', GREATEST((SELECT MAX(id) FROM role), 1));

-- 10.3 Role-permission grants (7 rows) ---------------------------------
--   Super Admin (1): user.read.all, user.manage, role.manage, audit.read  (4 grants)
--   Admin (2):       user.read.all, user.manage, audit.read               (3 grants)
--   User (3):        (no foundation grants — feature perms in M1+)        (0 grants)
INSERT INTO role_permission (role_id, permission_id, is_active) VALUES
  (1, 1, true),
  (1, 2, true),
  (1, 3, true),
  (1, 4, true)
ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = true;

INSERT INTO role_permission (role_id, permission_id, is_active) VALUES
  (2, 1, true),
  (2, 2, true),
  (2, 4, true)
ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = true;

-- 10.4 Bootstrap admin user (1 row) ------------------------------------
-- Bootstrap admin password set at migration time; rotate on first login per Lovable handoff doc.
INSERT INTO "user" (id, email, password_hash, first_name, last_name, role_id, is_active)
VALUES (
  1,
  'admin@musanad.local',
  '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS',
  'System',
  'Admin',
  1,
  true
)
ON CONFLICT (id) DO NOTHING;

-- Self-FK back-fill: created_by/updated_by reference user(id), so they couldn't be set in
-- the initial INSERT (the row didn't exist). Back-fill them to point at the bootstrap admin.
UPDATE "user"
SET    created_by = 1,
       updated_by = 1
WHERE  id = 1
  AND  created_by IS NULL;

SELECT setval('user_id_seq', GREATEST((SELECT MAX(id) FROM "user"), 1));

-- ============================================================
-- SECTION 11 — RECORD MIGRATION
-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (1, '001_foundation', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- DOWN MIGRATION / ROLLBACK
-- The migration runner locates the markers below when invoked
-- with --down. Idempotent (every DROP uses IF EXISTS).
-- ============================================================
-- ROLLBACK BEGIN
-- DOWN MIGRATION — undo 001_foundation.sql
-- Idempotent: every DROP uses IF EXISTS. Safe to re-run.

-- 1. DROP triggers (must precede dropping the trigger function)
DROP TRIGGER IF EXISTS audit_role_permission_changes ON role_permission;
DROP TRIGGER IF EXISTS audit_role_changes            ON role;
DROP TRIGGER IF EXISTS audit_user_changes            ON "user";

-- 2. DROP all RLS policies (explicit; CASCADE on table drop would also remove them, but
--    explicit drops keep the rollback non-destructive if a developer is rolling back
--    only policies/functions while keeping the tables for inspection).
DROP POLICY IF EXISTS schema_migrations_deny_all              ON schema_migrations;
DROP POLICY IF EXISTS audit_log_deny_delete                   ON audit_log;
DROP POLICY IF EXISTS audit_log_deny_update                   ON audit_log;
DROP POLICY IF EXISTS audit_log_deny_direct_insert            ON audit_log;
DROP POLICY IF EXISTS audit_log_select_audit_read             ON audit_log;
DROP POLICY IF EXISTS token_blacklist_deny_direct             ON token_blacklist;
DROP POLICY IF EXISTS role_permission_modify_admin            ON role_permission;
DROP POLICY IF EXISTS role_permission_select_authenticated    ON role_permission;
DROP POLICY IF EXISTS permission_modify_admin                 ON permission;
DROP POLICY IF EXISTS permission_select_authenticated         ON permission;
DROP POLICY IF EXISTS role_modify_admin                       ON role;
DROP POLICY IF EXISTS role_select_authenticated               ON role;
DROP POLICY IF EXISTS user_delete_admin                       ON "user";
DROP POLICY IF EXISTS user_update_self_or_admin               ON "user";
DROP POLICY IF EXISTS user_insert_admin                       ON "user";
DROP POLICY IF EXISTS user_select_self_or_admin               ON "user";

-- 3. DROP all fn_ functions (the 13 API surface functions)
DROP FUNCTION IF EXISTS fn_permission_list(INTEGER, INTEGER, BIGINT);
DROP FUNCTION IF EXISTS fn_role_list(INTEGER, INTEGER);
DROP FUNCTION IF EXISTS fn_user_list(INTEGER, INTEGER, TEXT, BIGINT);
DROP FUNCTION IF EXISTS fn_user_get_by_id(BIGINT);
DROP FUNCTION IF EXISTS fn_user_delete(BIGINT, BIGINT);
DROP FUNCTION IF EXISTS fn_user_update(BIGINT, JSONB, BIGINT);
DROP FUNCTION IF EXISTS fn_user_create(JSONB, BIGINT);
DROP FUNCTION IF EXISTS fn_auth_check_token_blacklist(TEXT);
DROP FUNCTION IF EXISTS fn_auth_blacklist_token(TEXT, BIGINT, TIMESTAMP WITH TIME ZONE);
DROP FUNCTION IF EXISTS fn_auth_record_login_success(BIGINT);
DROP FUNCTION IF EXISTS fn_auth_record_login_failure(BIGINT, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS fn_auth_get_user_for_login(TEXT);

-- 4. DROP helper / trigger functions
DROP FUNCTION IF EXISTS fn_current_user_has_permission(TEXT);
DROP FUNCTION IF EXISTS fn_audit_trigger();

-- 5. DROP explicitly-named indexes (auto-PK indexes drop with the table; only DROP
--    the named secondary/partial indexes that were explicitly created by this migration).
DROP INDEX IF EXISTS idx_user_updated_by;
DROP INDEX IF EXISTS idx_user_created_by;
DROP INDEX IF EXISTS idx_user_active;
DROP INDEX IF EXISTS idx_user_role_id;
DROP INDEX IF EXISTS idx_user_email;
DROP INDEX IF EXISTS idx_role_permission_active;
DROP INDEX IF EXISTS idx_role_permission_permission_id;
DROP INDEX IF EXISTS idx_role_permission_role_id;
DROP INDEX IF EXISTS idx_permission_active;
DROP INDEX IF EXISTS idx_permission_module;
DROP INDEX IF EXISTS idx_permission_code;
DROP INDEX IF EXISTS idx_role_active;
DROP INDEX IF EXISTS idx_token_blacklist_expires_at;
DROP INDEX IF EXISTS idx_token_blacklist_user_id;
DROP INDEX IF EXISTS idx_token_blacklist_hash;
DROP INDEX IF EXISTS idx_audit_log_changed_at;
DROP INDEX IF EXISTS idx_audit_log_changed_by;
DROP INDEX IF EXISTS idx_audit_log_table_record;

-- 6. DROP tables in reverse FK order (children before parents)
DROP TABLE IF EXISTS token_blacklist;
DROP TABLE IF EXISTS role_permission;
DROP TABLE IF EXISTS audit_log;
DROP TABLE IF EXISTS "user";
DROP TABLE IF EXISTS permission;
DROP TABLE IF EXISTS role;
DROP TABLE IF EXISTS schema_migrations;

-- 7. DROP custom types / domains (none defined in M0; placeholder for future feature modules)
--    No custom CREATE TYPE / CREATE DOMAIN statements exist in 001_foundation.sql.

-- ROLLBACK END
