-- MIGRATION: 539_sidebar_role_order.sql
-- Date: 2026-06-04
-- Description:
--   Per-role sidebar module ordering. A single system_setting row stores a
--   JSONB map { roleName: [moduleKey, moduleKey, ...] } that the FE merges
--   with the auth payload's effectiveModules to render the sidebar in the
--   admin-chosen order.
--
--   Role names match the FE AppRole union (e.g. "executive", "contract_drafter")
--   and the role.name column. Module keys match the FE ModuleKey union
--   (e.g. "insights", "contracts", "dashboards.financeTreasury").
--
--   Empty / missing role entry = fall back to the built-in displayOrder
--   compiled into the FE config/sidebar.ts MODULES record.
--
--   Per HITL Q4 (2026-06-04): platform_admin is intentionally excluded from
--   this feature — its sidebar is the static ["admin"] entry plus a separate
--   ADMIN_SUB_NAV structure that this row does not control.

BEGIN;

-- ============================================================
-- 1. Permission.
-- ============================================================
INSERT INTO permission (code, module, action, description, is_active, created_at)
VALUES ('admin.sidebar.manage', 'admin', 'sidebar.manage',
        'Reorder sidebar modules per role from the platform admin workbench', TRUE, CURRENT_TIMESTAMP)
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permission (role_id, permission_id, is_active, created_at)
SELECT r.id, p.id, TRUE, CURRENT_TIMESTAMP
  FROM role r, permission p
 WHERE r.name IN ('Super Admin', 'platform_admin')
   AND p.code = 'admin.sidebar.manage'
ON CONFLICT DO NOTHING;

-- ============================================================
-- 2. system_setting row — default = no overrides.
-- ============================================================
INSERT INTO system_setting
  (key, value, description, category, is_secret, is_active, created_at, updated_at)
VALUES
  ('sidebar.role_order',
   '{}'::jsonb,
   'Per-role sidebar module ordering. Map of roleName → ordered array of module keys. Empty entry = use built-in displayOrder.',
   'general', FALSE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- 3. fn_sidebar_role_order_get — public (no perm check). Returns the full
--    map. This is loaded by every authenticated sidebar render, so keeping
--    it cheap and uncached on the DB side (the FE caches via react-query).
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_sidebar_role_order_get()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $fn$
  SELECT COALESCE(
    (SELECT value FROM system_setting WHERE key = 'sidebar.role_order' AND is_active = TRUE LIMIT 1),
    '{}'::jsonb
  );
$fn$;

GRANT EXECUTE ON FUNCTION fn_sidebar_role_order_get() TO neondb_owner;

-- ============================================================
-- 4. fn_sidebar_role_order_set — admin write.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_sidebar_role_order_set(p_payload jsonb, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $fn$
DECLARE
  v_role_name text;
  v_arr jsonb;
BEGIN
  IF NOT fn_current_user_has_permission('admin.sidebar.manage') THEN
    RAISE EXCEPTION 'Permission denied: admin.sidebar.manage required' USING ERRCODE = '42501';
  END IF;

  IF jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'payload must be a JSON object keyed by role name' USING ERRCODE = '22023';
  END IF;

  -- Validate every entry: key must be a non-empty string, value must be
  -- an array of strings. Reject silently-malformed payloads up-front.
  FOR v_role_name, v_arr IN SELECT * FROM jsonb_each(p_payload) LOOP
    IF v_role_name IS NULL OR length(v_role_name) = 0 THEN
      RAISE EXCEPTION 'role name must be non-empty' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_arr) <> 'array' THEN
      RAISE EXCEPTION 'value for role "%" must be a JSON array', v_role_name USING ERRCODE = '22023';
    END IF;
  END LOOP;

  UPDATE system_setting
     SET value      = p_payload,
         updated_at = CURRENT_TIMESTAMP,
         updated_by = p_actor_id
   WHERE key = 'sidebar.role_order';

  -- Audit log line — same helper used by other admin settings writes.
  PERFORM fn_audit_log_record_v2(
    p_actor_id,
    'sidebar.role_order',
    'UPDATE',
    NULL,
    p_payload
  );

  RETURN jsonb_build_object(
    'order',     p_payload,
    'updatedBy', p_actor_id
  );
END;
$fn$;

REVOKE EXECUTE ON FUNCTION fn_sidebar_role_order_set(jsonb, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_sidebar_role_order_set(jsonb, bigint) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (539, 'sidebar_role_order', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
