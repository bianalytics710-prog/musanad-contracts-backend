-- MIGRATION: 540_sidebar_role_order_audit_fix.sql
-- Date: 2026-06-04
-- Description:
--   Hotfix for mig 539: fn_sidebar_role_order_set was calling
--   fn_audit_log_record_v2 with the wrong argument order — 5 positional
--   args matching no overload (the real signature is 6 args:
--   table_name, record_id, action, old_values, new_values, changed_by).
--
--   The bad call produced PG 42883 ("function ... does not exist") which
--   the BE translated to "function not deployed" — masking the real cause.
--   Replacing with the canonical call pattern used by fn_system_setting_set
--   (mig 130).

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_sidebar_role_order_set(p_payload jsonb, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $fn$
DECLARE
  v_role_name text;
  v_arr jsonb;
  v_old_value jsonb;
BEGIN
  IF NOT fn_current_user_has_permission('admin.sidebar.manage') THEN
    RAISE EXCEPTION 'Permission denied: admin.sidebar.manage required' USING ERRCODE = '42501';
  END IF;

  IF jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'payload must be a JSON object keyed by role name' USING ERRCODE = '22023';
  END IF;

  FOR v_role_name, v_arr IN SELECT * FROM jsonb_each(p_payload) LOOP
    IF v_role_name IS NULL OR length(v_role_name) = 0 THEN
      RAISE EXCEPTION 'role name must be non-empty' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_arr) <> 'array' THEN
      RAISE EXCEPTION 'value for role "%" must be a JSON array', v_role_name USING ERRCODE = '22023';
    END IF;
  END LOOP;

  SELECT value INTO v_old_value
    FROM system_setting
   WHERE key = 'sidebar.role_order' AND is_active = TRUE
   LIMIT 1;

  UPDATE system_setting
     SET value      = p_payload,
         updated_at = CURRENT_TIMESTAMP,
         updated_by = p_actor_id
   WHERE key = 'sidebar.role_order';

  -- Canonical 6-arg signature: (table_name, record_id, action, old_values, new_values, changed_by).
  PERFORM fn_audit_log_record_v2(
    'system_setting',
    NULL::bigint,
    'UPDATE',
    jsonb_build_object('key', 'sidebar.role_order', 'value', COALESCE(v_old_value, '{}'::jsonb)),
    jsonb_build_object('key', 'sidebar.role_order', 'value', p_payload),
    p_actor_id
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
VALUES (540, 'sidebar_role_order_audit_fix', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
