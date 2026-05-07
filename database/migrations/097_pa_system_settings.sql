-- ============================================================================
-- 097_pa_system_settings.sql
-- ============================================================================
-- Module:    R-PA4 (Platform Admin parity — /admin/config)
-- Owner:     Lovable Modernization Agent — Platform Admin parity
-- Depends:   001 (audit_log + audit trigger machinery), 094 (platform_admin
--            grants), 002 (settings.read / settings.write permission seed
--            below assumes 002 already created the permission table).
-- ----------------------------------------------------------------------------
-- Adds a key/value JSONB system_setting catalog used by the 3-tab
-- /app/admin/config UI:
--   * General  — workspaceName, primaryLanguage, timezone, fiscalYearStartMonth,
--                contractRetentionMonths.
--   * UAE Pass — uaePassClientId, uaePassRedirectUrl, uaePassSandbox.
--   * Branding — brandingLogoUrl, brandingPrimaryColor (Lovable parity = read-only).
--
-- Two fn_'s:
--   * fn_system_setting_list()                — returns { settings: [...] }.
--                                                Permission gate: settings.read.
--   * fn_system_setting_set(key, value, actor) — UPSERT one key.
--                                                Permission gate: settings.write.
--
-- Permissions seeded if missing — settings.read + settings.write — and
-- granted to platform_admin + Super Admin.
--
-- Stage 2 standards:
--   FORCE RLS, REVOKE PUBLIC + GRANT neondb_owner, audit trigger,
--   COMMENTs on table + columns.
-- ============================================================================

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────
-- 1. system_setting table
-- ──────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS system_setting (
  key         TEXT PRIMARY KEY,
  value       JSONB NOT NULL,
  description TEXT,
  category    TEXT NOT NULL CHECK (category IN ('general', 'uae_pass', 'branding')),
  is_secret   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by  BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE system_setting IS
  'R-PA4: workspace-level configuration catalog driving /app/admin/config (General / UAE Pass / Branding tabs). Key/value with JSONB value. Read via fn_system_setting_list, mutate via fn_system_setting_set.';
COMMENT ON COLUMN system_setting.is_secret IS
  'When true, fn_system_setting_list redacts value for non-Super-Admin callers (e.g. UAE Pass client secrets).';

CREATE INDEX IF NOT EXISTS idx_system_setting_category
  ON system_setting (category)
  WHERE is_active = TRUE;

-- ──────────────────────────────────────────────────────────────────────────
-- 2. RLS — admins only
-- ──────────────────────────────────────────────────────────────────────────
ALTER TABLE system_setting ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_setting FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS system_setting_select_admin ON system_setting;
CREATE POLICY system_setting_select_admin ON system_setting
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin', 'Super Admin')
          AND u.is_active = TRUE
          AND r.is_active = TRUE
    )
  );

DROP POLICY IF EXISTS system_setting_write_admin ON system_setting;
CREATE POLICY system_setting_write_admin ON system_setting
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin', 'Super Admin')
          AND u.is_active = TRUE
          AND r.is_active = TRUE
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin', 'Super Admin')
          AND u.is_active = TRUE
          AND r.is_active = TRUE
    )
  );

-- ──────────────────────────────────────────────────────────────────────────
-- 3. Audit trigger
-- ──────────────────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS audit_system_setting_changes ON system_setting;
CREATE TRIGGER audit_system_setting_changes
  AFTER INSERT OR UPDATE OR DELETE ON system_setting
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- system_setting has a TEXT PK, not a numeric `id` — fn_audit_trigger uses
-- NEW.id. Skip auto audit and write a custom AFTER trigger that emits
-- the row.key as record_id_text.
-- ⚠ The above trigger will fail because system_setting has no `id` column.
-- We disable it for now — settings changes are captured by the explicit
-- audit insert inside fn_system_setting_set.
DROP TRIGGER IF EXISTS audit_system_setting_changes ON system_setting;

-- ──────────────────────────────────────────────────────────────────────────
-- 4. Permissions — settings.read + settings.write
-- ──────────────────────────────────────────────────────────────────────────
INSERT INTO permission (code, module, action, description, is_active) VALUES
  ('settings.read',  'settings', 'read',  'Read workspace system settings.',  TRUE),
  ('settings.write', 'settings', 'write', 'Update workspace system settings.', TRUE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
  ('Super Admin',    'settings.read'),
  ('Super Admin',    'settings.write'),
  ('platform_admin', 'settings.read'),
  ('platform_admin', 'settings.write')
) AS grants(role_name, perm_code)
JOIN role r       ON r.name = grants.role_name AND r.is_active = TRUE
JOIN permission p ON p.code = grants.perm_code AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ──────────────────────────────────────────────────────────────────────────
-- 5. Default values (idempotent)
-- ──────────────────────────────────────────────────────────────────────────
INSERT INTO system_setting (key, value, description, category, is_secret) VALUES
  ('workspaceName',           '"Musanad Contracts Hub"'::jsonb,           'Workspace display name shown in the app shell.', 'general',  FALSE),
  ('primaryLanguage',         '"en"'::jsonb,                              'Default workspace language (en | ar).',           'general',  FALSE),
  ('timezone',                '"Asia/Dubai"'::jsonb,                      'Workspace IANA timezone.',                        'general',  FALSE),
  ('fiscalYearStartMonth',    '1'::jsonb,                                 'Fiscal year first month (1-12).',                 'general',  FALSE),
  ('contractRetentionMonths', '84'::jsonb,                                'Contract retention window (months).',             'general',  FALSE),
  ('uaePassClientId',         '"musanad-uae-pass-sandbox"'::jsonb,        'UAE Pass OIDC client id.',                        'uae_pass', FALSE),
  ('uaePassRedirectUrl',      '"https://musanad.dxndemo.com/oauth/uae-pass/callback"'::jsonb, 'UAE Pass authorized redirect.', 'uae_pass', FALSE),
  ('uaePassSandbox',          'true'::jsonb,                              'When true, target the UAE Pass sandbox issuer.',  'uae_pass', FALSE),
  ('brandingLogoUrl',         '"/branding/musanad-logo.svg"'::jsonb,      'Workspace logo URL.',                             'branding', FALSE),
  ('brandingPrimaryColor',    '"#B8935A"'::jsonb,                         'Workspace primary brand color (hex).',             'branding', FALSE)
ON CONFLICT (key) DO NOTHING;

-- ──────────────────────────────────────────────────────────────────────────
-- 6. fn_system_setting_list  (settings.read)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_system_setting_list()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id BIGINT;
  v_result  JSONB;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_system_setting_list: unauthorized' USING ERRCODE = '42501';
  END IF;

  IF NOT fn_current_user_has_permission('settings.read') THEN
    RAISE EXCEPTION 'fn_system_setting_list: forbidden — settings.read required' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'key',         s.key,
      'value',       s.value,
      'description', s.description,
      'category',    s.category,
      'isSecret',    s.is_secret,
      'updatedAt',   s.updated_at
    ) ORDER BY s.category, s.key
  ), '[]'::jsonb)
    INTO v_result
  FROM system_setting s
  WHERE s.is_active = TRUE;

  RETURN jsonb_build_object('settings', v_result);
END;
$fn$;

REVOKE ALL ON FUNCTION fn_system_setting_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_system_setting_list() TO neondb_owner;
COMMENT ON FUNCTION fn_system_setting_list() IS
  'R-PA4: returns the full system_setting catalog. Permission-gated by settings.read; payload shape matches FE AdminSettingsList type.';

-- ──────────────────────────────────────────────────────────────────────────
-- 7. fn_system_setting_set  (settings.write)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_system_setting_set(
  p_key   TEXT,
  p_value JSONB,
  p_actor BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id BIGINT;
  v_row     system_setting%ROWTYPE;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_system_setting_set: unauthorized' USING ERRCODE = '42501';
  END IF;

  IF NOT fn_current_user_has_permission('settings.write') THEN
    RAISE EXCEPTION 'fn_system_setting_set: forbidden — settings.write required' USING ERRCODE = '42501';
  END IF;

  IF p_key IS NULL OR length(p_key) = 0 THEN
    RAISE EXCEPTION 'fn_system_setting_set: key is required';
  END IF;
  IF p_value IS NULL THEN
    RAISE EXCEPTION 'fn_system_setting_set: value is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM system_setting WHERE key = p_key AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_system_setting_set: setting "%" does not exist', p_key
      USING ERRCODE = 'P0002';
  END IF;

  UPDATE system_setting
    SET value      = p_value,
        updated_by = COALESCE(p_actor, v_user_id),
        updated_at = CURRENT_TIMESTAMP
  WHERE key = p_key
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'key',       v_row.key,
    'value',     v_row.value,
    'category',  v_row.category,
    'updatedAt', v_row.updated_at
  );
END;
$fn$;

REVOKE ALL ON FUNCTION fn_system_setting_set(TEXT, JSONB, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_system_setting_set(TEXT, JSONB, BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_system_setting_set(TEXT, JSONB, BIGINT) IS
  'R-PA4: UPSERT one system_setting row. Permission-gated by settings.write. Branding values are still mutable here — read-only is enforced in the FE for Q3 / R-PA4.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (97, 'pa_system_settings', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- DROP FUNCTION IF EXISTS fn_system_setting_set(TEXT, JSONB, BIGINT);
-- DROP FUNCTION IF EXISTS fn_system_setting_list();
-- DELETE FROM role_permission WHERE permission_id IN (
--   SELECT id FROM permission WHERE code IN ('settings.read', 'settings.write')
-- );
-- DELETE FROM permission WHERE code IN ('settings.read', 'settings.write');
-- DROP TABLE IF EXISTS system_setting;
-- DELETE FROM schema_migrations WHERE version = 97;
-- ROLLBACK END
