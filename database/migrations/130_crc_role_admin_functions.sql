-- ============================================================
-- Migration 130 — CRC role_admin_functions
-- ============================================================
-- Module:      M10 — CR-C
-- Description: Net-new admin/role/template fns + EXTEND fn_system_setting_set/list.
--              All CREATE OR REPLACE re-applies COMMENT + REVOKE/GRANT trio per A4/B14.
-- New:         fn_role_create / fn_role_update / fn_role_delete
--              fn_role_permission_grant / fn_role_permission_revoke
--              fn_tenant_list / fn_tenant_get_by_id
--              fn_notification_template_list / fn_notification_template_get_by_id /
--              fn_notification_template_update / fn_notification_template_render
-- Extend:      fn_system_setting_set (per-key validators + is_secret redaction)
--              fn_system_setting_list (is_secret redaction; updatedByName via concat_ws)
--              fn_system_setting_list(TEXT) — new overload with category filter
-- ============================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────
-- 1. fn_role_create(p_name, p_description) — INVOKER, role.manage
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_role_create(
  p_name        TEXT,
  p_description TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $fn$
DECLARE
  v_uid    BIGINT;
  v_actor  BIGINT;
  v_name   TEXT;
  v_id     BIGINT;
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_role_create: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('role.manage') THEN
    RAISE EXCEPTION 'fn_role_create: forbidden' USING ERRCODE = '42501';
  END IF;

  v_name := trim(COALESCE(p_name, ''));
  IF v_name = '' THEN
    RAISE EXCEPTION 'fn_role_create: name_required' USING ERRCODE = '22023';
  END IF;

  v_actor := v_uid;
  IF v_actor = 0 THEN v_actor := NULL; END IF;

  INSERT INTO role (name, description, created_by, updated_by)
  VALUES (v_name, p_description, v_actor, v_actor)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'name', v_name);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN unique_violation THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_role_create: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_role_create(TEXT, TEXT) IS
  'CR-C role creation. INVOKER, gated by role.manage. Role.name UNIQUE — 23505 bubbles to BE → 409.';
REVOKE EXECUTE ON FUNCTION fn_role_create(TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_role_create(TEXT, TEXT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 2. fn_role_update(p_id, p_name, p_description) — INVOKER, role.manage
--    Built-in 8-name array immutable for rename (OPEN-DECISION-E).
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_role_update(
  p_id          BIGINT,
  p_name        TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $fn$
DECLARE
  v_uid       BIGINT;
  v_actor     BIGINT;
  v_row       role%ROWTYPE;
  v_builtin   BOOLEAN;
  v_new_name  TEXT;
  v_builtins  TEXT[] := ARRAY['Super Admin','Admin','User','platform_admin',
                              'executive','legal_counsel','contract_drafter','contract_approver'];
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_role_update: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('role.manage') THEN
    RAISE EXCEPTION 'fn_role_update: forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'fn_role_update: id_required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM role WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_role_update: role_not_found' USING ERRCODE = 'P0002';
  END IF;

  v_builtin := v_row.name = ANY (v_builtins);

  IF p_name IS NOT NULL AND trim(p_name) <> v_row.name THEN
    IF v_builtin THEN
      RAISE EXCEPTION 'fn_role_update: cannot_rename_system_role (%)', v_row.name USING ERRCODE = 'P0001';
    END IF;
    v_new_name := trim(p_name);
    IF v_new_name = '' THEN
      RAISE EXCEPTION 'fn_role_update: name_required' USING ERRCODE = '22023';
    END IF;
  ELSE
    v_new_name := v_row.name;
  END IF;

  v_actor := v_uid;
  IF v_actor = 0 THEN v_actor := NULL; END IF;

  UPDATE role SET
    name        = v_new_name,
    description = COALESCE(p_description, description),
    updated_by  = v_actor,
    updated_at  = CURRENT_TIMESTAMP
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id',          v_row.id,
    'name',        v_row.name,
    'description', v_row.description,
    'isActive',    v_row.is_active
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN unique_violation THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_role_update: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_role_update(BIGINT, TEXT, TEXT) IS
  'CR-C role rename / description-update. Blocks rename on 8 built-in roles (OPEN-DECISION-E hard-coded array). Description editable on all roles.';
REVOKE EXECUTE ON FUNCTION fn_role_update(BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_role_update(BIGINT, TEXT, TEXT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 3. fn_role_delete(p_id) — INVOKER, role.manage. Soft-delete; blocks built-in / in-use.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_role_delete(p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $fn$
DECLARE
  v_uid       BIGINT;
  v_actor     BIGINT;
  v_row       role%ROWTYPE;
  v_builtin   BOOLEAN;
  v_user_count BIGINT;
  v_builtins  TEXT[] := ARRAY['Super Admin','Admin','User','platform_admin',
                              'executive','legal_counsel','contract_drafter','contract_approver'];
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_role_delete: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('role.manage') THEN
    RAISE EXCEPTION 'fn_role_delete: forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'fn_role_delete: id_required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM role WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_role_delete: role_not_found' USING ERRCODE = 'P0002';
  END IF;

  v_builtin := v_row.name = ANY (v_builtins);
  IF v_builtin THEN
    RAISE EXCEPTION 'fn_role_delete: cannot_delete_system_role (%)', v_row.name USING ERRCODE = 'P0001';
  END IF;

  SELECT COUNT(*) INTO v_user_count
  FROM "user"
  WHERE role_id = p_id AND is_active = TRUE;

  IF v_user_count > 0 THEN
    RAISE EXCEPTION 'fn_role_delete: role_in_use (% users assigned)', v_user_count
      USING ERRCODE = 'P0001';
  END IF;

  v_actor := v_uid;
  IF v_actor = 0 THEN v_actor := NULL; END IF;

  UPDATE role SET
    is_active  = FALSE,
    updated_by = v_actor,
    updated_at = CURRENT_TIMESTAMP
  WHERE id = p_id;

  RETURN jsonb_build_object('success', TRUE, 'id', p_id);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_role_delete: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_role_delete(BIGINT) IS
  'CR-C role soft-delete. Blocks if any of 8 built-in roles OR if active users assigned (P0001 with userCount).';
REVOKE EXECUTE ON FUNCTION fn_role_delete(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_role_delete(BIGINT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 4. fn_role_permission_grant(p_role_id, p_permission_id) — DEFINER. Strict allowlist.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_role_permission_grant(
  p_role_id       BIGINT,
  p_permission_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid             BIGINT;
  v_actor           BIGINT;
  v_already_exists  BOOLEAN;
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_role_permission_grant: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('role.manage') THEN
    RAISE EXCEPTION 'fn_role_permission_grant: forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_role_id IS NULL OR p_permission_id IS NULL THEN
    RAISE EXCEPTION 'fn_role_permission_grant: role_id and permission_id required' USING ERRCODE = '22023';
  END IF;

  -- S2-23 — FK pre-validation parity (BOTH IDs validated before INSERT)
  IF NOT EXISTS (SELECT 1 FROM role WHERE id = p_role_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_role_permission_grant: role_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM permission WHERE id = p_permission_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_role_permission_grant: permission_not_found' USING ERRCODE = 'P0002';
  END IF;

  v_actor := v_uid;
  IF v_actor = 0 THEN v_actor := NULL; END IF;

  v_already_exists := EXISTS (
    SELECT 1 FROM role_permission
     WHERE role_id = p_role_id AND permission_id = p_permission_id
  );

  INSERT INTO role_permission (role_id, permission_id, created_by)
  VALUES (p_role_id, p_permission_id, v_actor)
  ON CONFLICT (role_id, permission_id) DO NOTHING;

  RETURN jsonb_build_object('granted', TRUE, 'alreadyExists', v_already_exists);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_role_permission_grant: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_role_permission_grant(BIGINT, BIGINT) IS
  'CR-C grant permission to role. DEFINER. Strict allowlist (permission must exist + is_active). Idempotent via UNIQUE(role_id, permission_id).';
REVOKE EXECUTE ON FUNCTION fn_role_permission_grant(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_role_permission_grant(BIGINT, BIGINT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 5. fn_role_permission_revoke(p_role_id, p_permission_id) — DEFINER.
--    Protects 8 Super Admin essential grants.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_role_permission_revoke(
  p_role_id       BIGINT,
  p_permission_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid             BIGINT;
  v_role_name       TEXT;
  v_perm_code       TEXT;
  v_essential       TEXT[] := ARRAY['role.manage','user.manage','user.read.all',
                                    'audit.read','audit.verify','demo.purge',
                                    'settings.read','settings.write'];
  v_already_absent  BOOLEAN;
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_role_permission_revoke: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('role.manage') THEN
    RAISE EXCEPTION 'fn_role_permission_revoke: forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_role_id IS NULL OR p_permission_id IS NULL THEN
    RAISE EXCEPTION 'fn_role_permission_revoke: role_id and permission_id required' USING ERRCODE = '22023';
  END IF;

  SELECT r.name INTO v_role_name FROM role r WHERE r.id = p_role_id AND r.is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_role_permission_revoke: role_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT p.code INTO v_perm_code FROM permission p WHERE p.id = p_permission_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_role_permission_revoke: permission_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF v_role_name = 'Super Admin' AND v_perm_code = ANY (v_essential) THEN
    RAISE EXCEPTION 'fn_role_permission_revoke: cannot_revoke_system_grant (% on %)', v_perm_code, v_role_name
      USING ERRCODE = 'P0001';
  END IF;

  v_already_absent := NOT EXISTS (
    SELECT 1 FROM role_permission
     WHERE role_id = p_role_id AND permission_id = p_permission_id
  );

  DELETE FROM role_permission
   WHERE role_id = p_role_id AND permission_id = p_permission_id;

  RETURN jsonb_build_object('revoked', TRUE, 'alreadyAbsent', v_already_absent);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_role_permission_revoke: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_role_permission_revoke(BIGINT, BIGINT) IS
  'CR-C revoke permission from role. DEFINER. Idempotent. Blocks Super Admin essential grants (8-permission allowlist hard-coded).';
REVOKE EXECUTE ON FUNCTION fn_role_permission_revoke(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_role_permission_revoke(BIGINT, BIGINT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 6. fn_tenant_list(p_page, p_limit, p_search) — INVOKER STABLE, tenant.read
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_tenant_list(
  p_page   INTEGER DEFAULT 1,
  p_limit  INTEGER DEFAULT 20,
  p_search TEXT    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_uid    BIGINT;
  v_page   INTEGER := GREATEST(COALESCE(p_page, 1), 1);
  v_limit  INTEGER := GREATEST(COALESCE(p_limit, 20), 1);
  v_offset INTEGER;
  v_total  BIGINT;
  v_data   JSONB;
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_tenant_list: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('tenant.read') THEN
    RAISE EXCEPTION 'fn_tenant_list: forbidden' USING ERRCODE = '42501';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  SELECT COUNT(*) INTO v_total
    FROM tenant t
   WHERE t.is_active = TRUE
     AND (p_search IS NULL OR t.name ILIKE '%' || p_search || '%' OR t.slug ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(row_data ORDER BY name_for_sort), '[]'::jsonb) INTO v_data
  FROM (
    SELECT t.name AS name_for_sort,
           jsonb_build_object(
             'id',           t.id,
             'name',         t.name,
             'slug',         t.slug,
             'displayName',  t.display_name,
             'industry',     t.industry,
             'riskAppetite', t.risk_appetite,
             'dataRegion',   t.data_region,
             'configPack',   t.config_pack,
             'isActive',     t.is_active,
             'createdAt',    t.created_at
           ) AS row_data
      FROM tenant t
     WHERE t.is_active = TRUE
       AND (p_search IS NULL OR t.name ILIKE '%' || p_search || '%' OR t.slug ILIKE '%' || p_search || '%')
     ORDER BY t.name ASC
     LIMIT v_limit OFFSET v_offset
  ) page;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_limit)::INTEGER END
    )
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_tenant_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_tenant_list(INTEGER, INTEGER, TEXT) IS
  'CR-C tenant list. INVOKER STABLE, gated by tenant.read. ILIKE search on name + slug. Sorted by name ASC.';
REVOKE EXECUTE ON FUNCTION fn_tenant_list(INTEGER, INTEGER, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tenant_list(INTEGER, INTEGER, TEXT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 7. fn_tenant_get_by_id(p_id UUID) — INVOKER STABLE, tenant.read
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_tenant_get_by_id(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_uid BIGINT;
  v_row JSONB;
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_tenant_get_by_id: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('tenant.read') THEN
    RAISE EXCEPTION 'fn_tenant_get_by_id: forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',           t.id,
    'name',         t.name,
    'slug',         t.slug,
    'displayName',  t.display_name,
    'industry',     t.industry,
    'riskAppetite', t.risk_appetite,
    'dataRegion',   t.data_region,
    'configPack',   t.config_pack,
    'isActive',     t.is_active,
    'createdAt',    t.created_at,
    'updatedAt',    t.updated_at,
    'createdBy',    t.created_by,
    'updatedBy',    t.updated_by
  ) INTO v_row
  FROM tenant t
  WHERE t.id = p_id AND t.is_active = TRUE;

  RETURN v_row;
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_tenant_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_tenant_get_by_id(UUID) IS
  'CR-C tenant detail. INVOKER STABLE, gated by tenant.read. Returns NULL on not-found (BE → 404).';
REVOKE EXECUTE ON FUNCTION fn_tenant_get_by_id(UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tenant_get_by_id(UUID) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 8. fn_notification_template_list(p_page, p_limit, p_channel, p_search)
--    INVOKER STABLE, notification.template.manage. Tenant-scoped.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_notification_template_list(
  p_page    INTEGER DEFAULT 1,
  p_limit   INTEGER DEFAULT 20,
  p_channel TEXT    DEFAULT NULL,
  p_search  TEXT    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_uid       BIGINT;
  v_tenant_id UUID;
  v_page      INTEGER := GREATEST(COALESCE(p_page, 1), 1);
  v_limit     INTEGER := GREATEST(COALESCE(p_limit, 20), 1);
  v_offset    INTEGER;
  v_total     BIGINT;
  v_data      JSONB;
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_notification_template_list: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('notification.template.manage') THEN
    RAISE EXCEPTION 'fn_notification_template_list: forbidden' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_notification_template_list: tenant_context_missing' USING ERRCODE = '42501';
  END IF;

  IF p_channel IS NOT NULL AND p_channel NOT IN ('email','in_app','teams_capture','slack_capture') THEN
    RAISE EXCEPTION 'fn_notification_template_list: invalid_channel' USING ERRCODE = '22023';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  SELECT COUNT(*) INTO v_total
    FROM notification_template nt
   WHERE nt.tenant_id = v_tenant_id
     AND nt.is_active = TRUE
     AND (p_channel IS NULL OR nt.channel = p_channel)
     AND (p_search  IS NULL
          OR nt.template_id ILIKE '%' || p_search || '%'
          OR nt.subject_en  ILIKE '%' || p_search || '%'
          OR nt.subject_ar  ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(row_data ORDER BY template_id_sort), '[]'::jsonb) INTO v_data
  FROM (
    SELECT nt.template_id AS template_id_sort,
           jsonb_build_object(
             'id',                  nt.id,
             'templateId',          nt.template_id,
             'channel',             nt.channel,
             'subjectEn',           nt.subject_en,
             'subjectAr',           nt.subject_ar,
             'lastModifiedByName',  NULLIF(concat_ws(' ', u.first_name, u.last_name), ''),
             'dataClassification',  nt.data_classification,
             'isActive',            nt.is_active,
             'updatedAt',           nt.updated_at
           ) AS row_data
      FROM notification_template nt
      LEFT JOIN "user" u ON u.id = nt.last_modified_by
     WHERE nt.tenant_id = v_tenant_id
       AND nt.is_active = TRUE
       AND (p_channel IS NULL OR nt.channel = p_channel)
       AND (p_search  IS NULL
            OR nt.template_id ILIKE '%' || p_search || '%'
            OR nt.subject_en  ILIKE '%' || p_search || '%'
            OR nt.subject_ar  ILIKE '%' || p_search || '%')
     ORDER BY nt.template_id ASC
     LIMIT v_limit OFFSET v_offset
  ) page;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_limit)::INTEGER END
    )
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_template_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_notification_template_list(INTEGER, INTEGER, TEXT, TEXT) IS
  'CR-C notification template list. INVOKER STABLE, gated by notification.template.manage. Tenant-scoped via app.current_tenant_id GUC. Optional channel filter; ILIKE search on template_id + subject_en + subject_ar.';
REVOKE EXECUTE ON FUNCTION fn_notification_template_list(INTEGER, INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_template_list(INTEGER, INTEGER, TEXT, TEXT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 9. fn_notification_template_get_by_id(p_id BIGINT) — INVOKER STABLE
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_notification_template_get_by_id(p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_uid       BIGINT;
  v_tenant_id UUID;
  v_row       JSONB;
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_notification_template_get_by_id: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('notification.template.manage') THEN
    RAISE EXCEPTION 'fn_notification_template_get_by_id: forbidden' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_notification_template_get_by_id: tenant_context_missing' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',                  nt.id,
    'tenantId',            nt.tenant_id,
    'templateId',          nt.template_id,
    'channel',             nt.channel,
    'subjectEn',           nt.subject_en,
    'subjectAr',           nt.subject_ar,
    'bodyEn',              nt.body_en,
    'bodyAr',              nt.body_ar,
    'parameterSchema',     nt.parameter_schema,
    'lastModifiedByName',  NULLIF(concat_ws(' ', u.first_name, u.last_name), ''),
    'dataClassification',  nt.data_classification,
    'isActive',            nt.is_active,
    'createdAt',           nt.created_at,
    'updatedAt',           nt.updated_at
  ) INTO v_row
  FROM notification_template nt
  LEFT JOIN "user" u ON u.id = nt.last_modified_by
  WHERE nt.id = p_id
    AND nt.tenant_id = v_tenant_id
    AND nt.is_active = TRUE;

  RETURN v_row;
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_template_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_notification_template_get_by_id(BIGINT) IS
  'CR-C notification template detail. INVOKER STABLE, gated by notification.template.manage. Tenant-scoped. Returns NULL on not-found (BE → 404).';
REVOKE EXECUTE ON FUNCTION fn_notification_template_get_by_id(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_template_get_by_id(BIGINT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 10. fn_notification_template_update — INVOKER, notification.template.manage
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_notification_template_update(
  p_id               BIGINT,
  p_subject_en       TEXT,
  p_subject_ar       TEXT,
  p_body_en          TEXT,
  p_body_ar          TEXT,
  p_parameter_schema JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $fn$
DECLARE
  v_uid       BIGINT;
  v_actor     BIGINT;
  v_tenant_id UUID;
  v_row       notification_template%ROWTYPE;
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_notification_template_update: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('notification.template.manage') THEN
    RAISE EXCEPTION 'fn_notification_template_update: forbidden' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_notification_template_update: tenant_context_missing' USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'fn_notification_template_update: id_required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row
    FROM notification_template
   WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_notification_template_update: template_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF p_body_en IS NOT NULL AND length(trim(p_body_en)) = 0 THEN
    RAISE EXCEPTION 'fn_notification_template_update: body_en_required' USING ERRCODE = '22023';
  END IF;
  IF p_body_ar IS NOT NULL AND length(trim(p_body_ar)) = 0 THEN
    RAISE EXCEPTION 'fn_notification_template_update: body_ar_required' USING ERRCODE = '22023';
  END IF;
  IF p_parameter_schema IS NOT NULL AND jsonb_typeof(p_parameter_schema) <> 'object' THEN
    RAISE EXCEPTION 'fn_notification_template_update: parameter_schema_must_be_object' USING ERRCODE = '22023';
  END IF;

  v_actor := v_uid;
  IF v_actor = 0 THEN v_actor := NULL; END IF;

  UPDATE notification_template SET
    subject_en       = COALESCE(p_subject_en, subject_en),
    subject_ar       = COALESCE(p_subject_ar, subject_ar),
    body_en          = COALESCE(p_body_en, body_en),
    body_ar          = COALESCE(p_body_ar, body_ar),
    parameter_schema = COALESCE(p_parameter_schema, parameter_schema),
    last_modified_by = v_actor,
    updated_by       = v_actor,
    updated_at       = CURRENT_TIMESTAMP
  WHERE id = p_id AND tenant_id = v_tenant_id;

  RETURN fn_notification_template_get_by_id(p_id);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_template_update: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_notification_template_update(BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB) IS
  'CR-C template edit. INVOKER, gated by notification.template.manage. Tenant-scoped via app.current_tenant_id GUC. template_id + channel immutable (not in signature).';
REVOKE EXECUTE ON FUNCTION fn_notification_template_update(BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_template_update(BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 11. fn_notification_template_render(p_template_id, p_channel, p_locale, p_parameters)
--     INVOKER STABLE. notification.template.manage OR system actor.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_notification_template_render(
  p_template_id TEXT,
  p_channel     TEXT,
  p_locale      TEXT,
  p_parameters  JSONB
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_uid           BIGINT;
  v_tenant_id     UUID;
  v_row           notification_template%ROWTYPE;
  v_subject_raw   TEXT;
  v_body_raw      TEXT;
  v_key           TEXT;
  v_value         TEXT;
  v_escaped       TEXT;
  v_missing       TEXT[];
  v_extra         TEXT[];
  v_params        JSONB := COALESCE(p_parameters, '{}'::jsonb);
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;

  -- System actor (NULL or 0) is allowed; otherwise must hold the perm.
  IF v_uid IS NOT NULL AND v_uid <> 0 THEN
    IF NOT fn_current_user_has_permission('notification.template.manage') THEN
      RAISE EXCEPTION 'fn_notification_template_render: forbidden' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_locale NOT IN ('en','ar') THEN
    RAISE EXCEPTION 'fn_notification_template_render: invalid_locale' USING ERRCODE = '22023';
  END IF;
  IF p_channel IS NULL OR p_channel NOT IN ('email','in_app','teams_capture','slack_capture') THEN
    RAISE EXCEPTION 'fn_notification_template_render: invalid_channel' USING ERRCODE = '22023';
  END IF;
  IF p_template_id IS NULL OR length(trim(p_template_id)) = 0 THEN
    RAISE EXCEPTION 'fn_notification_template_render: template_id_required' USING ERRCODE = '22023';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_notification_template_render: tenant_context_missing' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
    FROM notification_template
   WHERE template_id = p_template_id
     AND channel = p_channel
     AND tenant_id = v_tenant_id
     AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_notification_template_render: template_not_found' USING ERRCODE = 'P0002';
  END IF;

  v_subject_raw := CASE p_locale WHEN 'en' THEN v_row.subject_en ELSE v_row.subject_ar END;
  v_body_raw    := CASE p_locale WHEN 'en' THEN v_row.body_en    ELSE v_row.body_ar    END;

  -- Substitution loop (HTML-escape value first to prevent XSS — AC-S13-07)
  FOR v_key, v_value IN
    SELECT k, vt FROM jsonb_each_text(v_params) AS j(k, vt)
  LOOP
    -- Apply ampersand FIRST (otherwise &lt; → &amp;lt;)
    v_escaped := replace(replace(replace(replace(replace(
      COALESCE(v_value, ''),
      '&',  '&amp;'),
      '<',  '&lt;'),
      '>',  '&gt;'),
      '"', '&quot;'),
      '''','&#39;');
    IF v_subject_raw IS NOT NULL THEN
      v_subject_raw := regexp_replace(v_subject_raw, format('\{\{\s*%s\s*\}\}', v_key), v_escaped, 'g');
    END IF;
    IF v_body_raw IS NOT NULL THEN
      v_body_raw := regexp_replace(v_body_raw,    format('\{\{\s*%s\s*\}\}', v_key), v_escaped, 'g');
    END IF;
  END LOOP;

  v_missing := ARRAY(
    SELECT k FROM jsonb_object_keys(v_row.parameter_schema) k
     WHERE NOT (v_params ? k)
  );
  v_extra := ARRAY(
    SELECT k FROM jsonb_object_keys(v_params) k
     WHERE NOT (v_row.parameter_schema ? k)
  );

  RETURN jsonb_build_object(
    'subject',           v_subject_raw,
    'body',              v_body_raw,
    'missingParameters', to_jsonb(v_missing),
    'extraParameters',   to_jsonb(v_extra)
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_template_render: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_notification_template_render(TEXT, TEXT, TEXT, JSONB) IS
  'CR-C render template with locale + parameter substitution. INVOKER STABLE. Mustache {{paramName}} regex syntax matches BE nodemailer regex (INFO-C). HTML-escapes parameter values to prevent XSS injection (AC-S13-07). Missing parameters do NOT raise — leave placeholder + report in missingParameters[]. System actor (NULL/0) may render without notification.template.manage.';
REVOKE EXECUTE ON FUNCTION fn_notification_template_render(TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_template_render(TEXT, TEXT, TEXT, JSONB) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 12. EXTEND fn_system_setting_set — per-key validators + is_secret response redaction.
--     Trio re-applied per A4. Compensating audit insert preserved (R-PA7 099) but routed
--     via fn_audit_log_record_v2 chain (post-128).
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_system_setting_set(
  p_key   TEXT,
  p_value JSONB,
  p_actor BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id     BIGINT;
  v_old_row     system_setting%ROWTYPE;
  v_row         system_setting%ROWTYPE;
  v_text        TEXT;
  v_int         INTEGER;
  v_bool        BOOLEAN;
  v_arr_typ     TEXT;
  v_elem        JSONB;
  v_returned_v  JSONB;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_system_setting_set: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('settings.write') THEN
    RAISE EXCEPTION 'fn_system_setting_set: forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_key IS NULL OR length(p_key) = 0 THEN
    RAISE EXCEPTION 'fn_system_setting_set: key is required' USING ERRCODE = '22023';
  END IF;
  IF p_value IS NULL THEN
    RAISE EXCEPTION 'fn_system_setting_set: value is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_old_row
    FROM system_setting
   WHERE key = p_key AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_system_setting_set: setting "%" does not exist', p_key USING ERRCODE = 'P0002';
  END IF;

  -- Per-key value-shape validators (per db-design.md §2.10)
  IF p_key = 'email.smtp.port' THEN
    IF jsonb_typeof(p_value) <> 'number' THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (port must be integer 1..65535)' USING ERRCODE = '22023';
    END IF;
    v_int := (p_value)::INTEGER;
    IF v_int < 1 OR v_int > 65535 THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (port must be integer 1..65535)' USING ERRCODE = '22023';
    END IF;
  ELSIF p_key = 'email.smtp.encryption' THEN
    IF jsonb_typeof(p_value) <> 'string' OR (p_value #>> '{}') NOT IN ('none','tls','ssl','starttls') THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (encryption must be one of none/tls/ssl/starttls)' USING ERRCODE = '22023';
    END IF;
  ELSIF p_key IN ('branding.color_primary','branding.color_accent') THEN
    IF jsonb_typeof(p_value) <> 'string' OR NOT ((p_value #>> '{}') ~ '^#[0-9A-Fa-f]{6}$') THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (must be a valid hex color #RRGGBB)' USING ERRCODE = '22023';
    END IF;
  ELSIF p_key = 'calendar.weekend_days' THEN
    IF jsonb_typeof(p_value) <> 'array' THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (weekend_days must be an array)' USING ERRCODE = '22023';
    END IF;
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_value) LOOP
      IF jsonb_typeof(v_elem) <> 'string' OR (v_elem #>> '{}') NOT IN ('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday') THEN
        RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (unknown weekday: %)', (v_elem #>> '{}') USING ERRCODE = '22023';
      END IF;
    END LOOP;
  ELSIF p_key IN ('calendar.working_hours_start','calendar.working_hours_end') THEN
    IF jsonb_typeof(p_value) <> 'string' OR NOT ((p_value #>> '{}') ~ '^[0-2][0-9]:[0-5][0-9]$') THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (must be HH:MM)' USING ERRCODE = '22023';
    END IF;
  ELSIF p_key = 'calendar.holidays' THEN
    IF jsonb_typeof(p_value) <> 'array' THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (holidays must be an array)' USING ERRCODE = '22023';
    END IF;
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_value) LOOP
      IF jsonb_typeof(v_elem) <> 'string' OR NOT ((v_elem #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$') THEN
        RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (holiday date must be YYYY-MM-DD)' USING ERRCODE = '22023';
      END IF;
    END LOOP;
  ELSIF p_key = 'audit.retention_days' THEN
    IF jsonb_typeof(p_value) <> 'number' THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (retention_days must be integer 1..3650)' USING ERRCODE = '22023';
    END IF;
    v_int := (p_value)::INTEGER;
    IF v_int < 1 OR v_int > 3650 THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (retention_days must be 1..3650)' USING ERRCODE = '22023';
    END IF;
  ELSIF p_key = 'email.daily_send_limit' THEN
    IF jsonb_typeof(p_value) <> 'number' THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (daily_send_limit must be integer 1..1000000)' USING ERRCODE = '22023';
    END IF;
    v_int := (p_value)::INTEGER;
    IF v_int < 1 OR v_int > 1000000 THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (daily_send_limit must be 1..1000000)' USING ERRCODE = '22023';
    END IF;
  ELSIF p_key IN ('email.from_address','email.reply_to') THEN
    IF jsonb_typeof(p_value) <> 'string' THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (must be a string)' USING ERRCODE = '22023';
    END IF;
    v_text := (p_value #>> '{}');
    IF length(v_text) > 0 AND NOT (v_text ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (must be a valid email or empty string)' USING ERRCODE = '22023';
    END IF;
  ELSIF p_key = 'security.session_timeout_min' THEN
    IF jsonb_typeof(p_value) <> 'number' THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (session_timeout_min must be integer 1..1440)' USING ERRCODE = '22023';
    END IF;
    v_int := (p_value)::INTEGER;
    IF v_int < 1 OR v_int > 1440 THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (session_timeout_min must be 1..1440)' USING ERRCODE = '22023';
    END IF;
  ELSIF p_key = 'security.password_policy_min_length' THEN
    IF jsonb_typeof(p_value) <> 'number' THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (password_policy_min_length must be integer 8..128)' USING ERRCODE = '22023';
    END IF;
    v_int := (p_value)::INTEGER;
    IF v_int < 8 OR v_int > 128 THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (password_policy_min_length must be 8..128)' USING ERRCODE = '22023';
    END IF;
  ELSIF p_key IN ('security.password_policy_require_special','security.mfa_required','email.enabled') THEN
    IF jsonb_typeof(p_value) <> 'boolean' THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (% must be boolean)', p_key USING ERRCODE = '22023';
    END IF;
  ELSIF p_key = 'security.ip_allowlist' THEN
    IF jsonb_typeof(p_value) <> 'array' THEN
      RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (ip_allowlist must be an array)' USING ERRCODE = '22023';
    END IF;
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_value) LOOP
      IF jsonb_typeof(v_elem) <> 'string' OR length(v_elem #>> '{}') = 0 THEN
        RAISE EXCEPTION 'fn_system_setting_set: invalid_setting_value (ip_allowlist entries must be non-empty strings)' USING ERRCODE = '22023';
      END IF;
    END LOOP;
  END IF;

  UPDATE system_setting
    SET value      = p_value,
        updated_by = COALESCE(p_actor, v_user_id),
        updated_at = CURRENT_TIMESTAMP
   WHERE key = p_key
   RETURNING * INTO v_row;

  -- Compensating audit insert (system_setting has no `id` column → fn_audit_trigger
  -- can't fire). Routes through fn_audit_log_record_v2 to stay on the hash chain.
  PERFORM fn_audit_log_record_v2(
    'system_setting',
    NULL,
    'UPDATE',
    jsonb_build_object('key', v_old_row.key, 'value', v_old_row.value, 'category', v_old_row.category),
    jsonb_build_object('key', v_row.key,     'value', v_row.value,     'category', v_row.category),
    COALESCE(p_actor, v_user_id)
  );

  -- Redact value in response when is_secret
  v_returned_v := CASE WHEN v_row.is_secret THEN '"***REDACTED***"'::jsonb ELSE v_row.value END;

  RETURN jsonb_build_object(
    'key',       v_row.key,
    'value',     v_returned_v,
    'category',  v_row.category,
    'isSecret',  v_row.is_secret,
    'updatedAt', v_row.updated_at
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_system_setting_set: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_system_setting_set(TEXT, JSONB, BIGINT) IS
  'CR-C extended (R-PA0 097 + R-PA7 099 + CR-C 130): per-key value-shape validators (port range, hex color, weekday allowlist, time HH:MM, date YYYY-MM-DD, email regex, integer ranges, boolean checks). Permission gate stays settings.write (NAMING-CONFLICT-2). is_secret value redacted in response. Compensating audit_log INSERT routes through fn_audit_log_record_v2 chain.';
REVOKE EXECUTE ON FUNCTION fn_system_setting_set(TEXT, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_system_setting_set(TEXT, JSONB, BIGINT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 13. EXTEND fn_system_setting_list() — is_secret redaction + updatedByName concat_ws
-- ─────────────────────────────────────────────────────────────
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
      'key',           s.key,
      'value',         CASE WHEN s.is_secret THEN '"***REDACTED***"'::jsonb ELSE s.value END,
      'description',   s.description,
      'category',      s.category,
      'isSecret',      s.is_secret,
      'updatedAt',     s.updated_at,
      'updatedByName', NULLIF(concat_ws(' ', u.first_name, u.last_name), '')
    ) ORDER BY s.category, s.key
  ), '[]'::jsonb) INTO v_result
  FROM system_setting s
  LEFT JOIN "user" u ON u.id = s.updated_by
  WHERE s.is_active = TRUE;

  RETURN jsonb_build_object('settings', v_result);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_system_setting_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_system_setting_list() IS
  'CR-C extended (R-PA0 097 baseline): adds is_secret value redaction in projection + updatedByName via LEFT JOIN "user" with concat_ws (W3 lesson). Returns all keys.';
REVOKE EXECUTE ON FUNCTION fn_system_setting_list() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_system_setting_list() TO neondb_owner;

-- 13b. New overload: fn_system_setting_list(p_category)
CREATE OR REPLACE FUNCTION fn_system_setting_list(p_category TEXT)
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

  IF p_category IS NOT NULL AND p_category NOT IN
     ('general','uae_pass','branding','security','email','calendar','audit_retention') THEN
    RAISE EXCEPTION 'fn_system_setting_list: invalid_category' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'key',           s.key,
      'value',         CASE WHEN s.is_secret THEN '"***REDACTED***"'::jsonb ELSE s.value END,
      'description',   s.description,
      'category',      s.category,
      'isSecret',      s.is_secret,
      'updatedAt',     s.updated_at,
      'updatedByName', NULLIF(concat_ws(' ', u.first_name, u.last_name), '')
    ) ORDER BY s.category, s.key
  ), '[]'::jsonb) INTO v_result
  FROM system_setting s
  LEFT JOIN "user" u ON u.id = s.updated_by
  WHERE s.is_active = TRUE
    AND (p_category IS NULL OR s.category = p_category);

  RETURN jsonb_build_object('settings', v_result);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_system_setting_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_system_setting_list(TEXT) IS
  'CR-C overload: optional p_category filter (NULL → all). is_secret value redaction + updatedByName via concat_ws. Permission gate settings.read.';
REVOKE EXECUTE ON FUNCTION fn_system_setting_list(TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_system_setting_list(TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (130, 'crc_role_admin_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_system_setting_list(TEXT);
-- -- Restore fn_system_setting_list() body from migration 097 manually.
-- -- Restore fn_system_setting_set body from migration 099 manually.
-- DROP FUNCTION IF EXISTS fn_notification_template_render(TEXT, TEXT, TEXT, JSONB);
-- DROP FUNCTION IF EXISTS fn_notification_template_update(BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB);
-- DROP FUNCTION IF EXISTS fn_notification_template_get_by_id(BIGINT);
-- DROP FUNCTION IF EXISTS fn_notification_template_list(INTEGER, INTEGER, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_tenant_get_by_id(UUID);
-- DROP FUNCTION IF EXISTS fn_tenant_list(INTEGER, INTEGER, TEXT);
-- DROP FUNCTION IF EXISTS fn_role_permission_revoke(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_role_permission_grant(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_role_delete(BIGINT);
-- DROP FUNCTION IF EXISTS fn_role_update(BIGINT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_role_create(TEXT, TEXT);
-- DELETE FROM schema_migrations WHERE version = 130;
-- COMMIT;
-- ROLLBACK END
