-- Migration: 263_crl_fn_report_template_functions.sql
-- Module: M20 — CR-L Reports & Briefings
-- CR: CR-L
-- Date: 2026-05-15
-- Description: 5 fn_'s for report_template CRUD.
-- ADAPTATIONS: A1 user.role_id direct FK (no user_role).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- fn_report_template_list
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_template_list(
  p_actor_id    BIGINT,
  p_admin_mode  BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_data        JSONB;
  v_caller_role TEXT;
BEGIN
  IF p_admin_mode THEN
    IF NOT fn_current_user_has_permission('report.template.manage') THEN
      RAISE EXCEPTION 'report.template.manage permission required' USING ERRCODE = '42501';
    END IF;
  ELSE
    IF NOT fn_current_user_has_permission('report.read') THEN
      RAISE EXCEPTION 'report.read permission required' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT r.name INTO v_caller_role
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = p_actor_id;

  IF p_admin_mode THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', t.id,
      'templateId', t.template_id,
      'displayNameEn', t.display_name_en,
      'displayNameAr', t.display_name_ar,
      'description', t.description,
      'reportKind', t.report_kind,
      'dataSource', t.data_source,
      'parameterSchema', t.parameter_schema,
      'assignedRoles', t.assigned_roles,
      'isScheduled', t.is_scheduled,
      'scheduleCron', t.schedule_cron,
      'scheduleRecipients', t.schedule_recipients,
      'enabled', t.enabled,
      'lastRunAt', t.last_run_at,
      'isActive', t.is_active
    ) ORDER BY t.template_id ASC), '[]'::jsonb) INTO v_data
    FROM report_template t
    WHERE t.is_active = TRUE;
  ELSE
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', t.id,
      'templateId', t.template_id,
      'displayNameEn', t.display_name_en,
      'displayNameAr', t.display_name_ar,
      'description', t.description,
      'reportKind', t.report_kind,
      'parameterSchema', t.parameter_schema,
      'assignedRoles', t.assigned_roles,
      'lastRunAt', t.last_run_at
    ) ORDER BY t.template_id ASC), '[]'::jsonb) INTO v_data
    FROM report_template t
    WHERE t.is_active = TRUE
      AND t.enabled = TRUE
      AND (v_caller_role IS NOT NULL AND t.assigned_roles ? v_caller_role);
  END IF;

  RETURN jsonb_build_object('data', v_data);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_template_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_template_list(BIGINT, BOOLEAN) IS 'List report templates. admin_mode=true returns all (requires report.template.manage); else filters by caller role overlap with assigned_roles.';
REVOKE EXECUTE ON FUNCTION fn_report_template_list(BIGINT, BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_list(BIGINT, BOOLEAN) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- fn_report_template_get_by_id
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_template_get_by_id(
  p_actor_id BIGINT,
  p_id       BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_t           RECORD;
  v_caller_role TEXT;
  v_can_see     BOOLEAN := FALSE;
BEGIN
  SELECT * INTO v_t FROM report_template WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Template not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT r.name INTO v_caller_role
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = p_actor_id;

  v_can_see := fn_current_user_has_permission('report.template.manage')
            OR (v_caller_role IS NOT NULL AND v_t.assigned_roles ? v_caller_role);
  IF NOT v_can_see THEN
    RAISE EXCEPTION 'Template not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'id', v_t.id,
    'tenantId', v_t.tenant_id,
    'templateId', v_t.template_id,
    'displayNameEn', v_t.display_name_en,
    'displayNameAr', v_t.display_name_ar,
    'description', v_t.description,
    'reportKind', v_t.report_kind,
    'dataSource', v_t.data_source,
    'parameterSchema', v_t.parameter_schema,
    'assignedRoles', v_t.assigned_roles,
    'isScheduled', v_t.is_scheduled,
    'scheduleCron', v_t.schedule_cron,
    'scheduleRecipients', v_t.schedule_recipients,
    'enabled', v_t.enabled,
    'lastRunAt', v_t.last_run_at,
    'dataClassification', v_t.data_classification,
    'createdAt', v_t.created_at,
    'updatedAt', v_t.updated_at,
    'createdBy', v_t.created_by,
    'updatedBy', v_t.updated_by,
    'isActive', v_t.is_active
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_template_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_template_get_by_id(BIGINT, BIGINT) IS 'Get report template by id. Visibility: report.template.manage OR roles-overlap.';
REVOKE EXECUTE ON FUNCTION fn_report_template_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_get_by_id(BIGINT, BIGINT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- fn_report_template_create
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_template_create(
  p_actor_id            BIGINT,
  p_template_id         TEXT,
  p_display_name_en     TEXT,
  p_report_kind         TEXT,
  p_data_source         TEXT,
  p_assigned_roles      JSONB,
  p_display_name_ar     TEXT DEFAULT NULL,
  p_description         TEXT DEFAULT NULL,
  p_parameter_schema    JSONB DEFAULT '{}',
  p_is_scheduled        BOOLEAN DEFAULT FALSE,
  p_schedule_cron       TEXT DEFAULT NULL,
  p_schedule_recipients JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_id        BIGINT;
  v_invalid   TEXT;
BEGIN
  IF NOT fn_current_user_has_permission('report.template.manage') THEN
    RAISE EXCEPTION 'report.template.manage permission required' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;

  IF p_template_id IS NULL OR length(trim(p_template_id)) = 0 THEN
    RAISE EXCEPTION 'templateId is required' USING ERRCODE = '22023';
  END IF;
  IF p_report_kind NOT IN ('excel','pdf','both') THEN
    RAISE EXCEPTION 'reportKind must be excel | pdf | both' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_assigned_roles) <> 'array' OR jsonb_array_length(p_assigned_roles) = 0 THEN
    RAISE EXCEPTION 'assignedRoles must be a non-empty array' USING ERRCODE = '22023';
  END IF;

  -- Validate every role in assignedRoles exists
  SELECT e INTO v_invalid
    FROM jsonb_array_elements_text(p_assigned_roles) e
   WHERE NOT EXISTS (SELECT 1 FROM role r WHERE r.name = e AND r.is_active = TRUE)
   LIMIT 1;
  IF v_invalid IS NOT NULL THEN
    RAISE EXCEPTION 'invalid role in assignedRoles: %', v_invalid USING ERRCODE = '22023';
  END IF;

  -- Validate data_source exists (fn_report_data_<slug>)
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_report_data_' || p_data_source AND pronamespace = 'public'::regnamespace) THEN
    RAISE EXCEPTION 'Unknown data_source — must match a fn_report_data_* in the worker registry' USING ERRCODE = '22023';
  END IF;

  IF p_is_scheduled THEN
    IF p_schedule_cron IS NULL OR length(trim(p_schedule_cron)) = 0 THEN
      RAISE EXCEPTION 'scheduleCron is required when isScheduled=true' USING ERRCODE = '22023';
    END IF;
    IF p_schedule_recipients IS NULL OR jsonb_typeof(p_schedule_recipients) <> 'array' OR jsonb_array_length(p_schedule_recipients) = 0 THEN
      RAISE EXCEPTION 'scheduleRecipients is required when isScheduled=true' USING ERRCODE = '22023';
    END IF;
  END IF;

  BEGIN
    INSERT INTO report_template (
      tenant_id, template_id, display_name_en, display_name_ar, description,
      report_kind, data_source, parameter_schema, assigned_roles,
      is_scheduled, schedule_cron, schedule_recipients, enabled,
      created_by, updated_by
    ) VALUES (
      v_tenant_id, trim(p_template_id), trim(p_display_name_en), p_display_name_ar, p_description,
      p_report_kind, trim(p_data_source), COALESCE(p_parameter_schema, '{}'::jsonb), p_assigned_roles,
      p_is_scheduled, p_schedule_cron, p_schedule_recipients, TRUE,
      NULLIF(p_actor_id, 0), NULLIF(p_actor_id, 0)
    ) RETURNING id INTO v_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'Template id already exists for this tenant' USING ERRCODE = '23505';
  END;

  RETURN fn_report_template_get_by_id(p_actor_id, v_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_template_create: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, JSONB, BOOLEAN, TEXT, JSONB) IS 'Create a report template. data_source validated against pg_proc fn_report_data_<slug>.';
REVOKE EXECUTE ON FUNCTION fn_report_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, JSONB, BOOLEAN, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, JSONB, BOOLEAN, TEXT, JSONB) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- fn_report_template_update
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_template_update(
  p_actor_id            BIGINT,
  p_id                  BIGINT,
  p_display_name_en     TEXT DEFAULT NULL,
  p_display_name_ar     TEXT DEFAULT NULL,
  p_description         TEXT DEFAULT NULL,
  p_data_source         TEXT DEFAULT NULL,
  p_parameter_schema    JSONB DEFAULT NULL,
  p_assigned_roles      JSONB DEFAULT NULL,
  p_is_scheduled        BOOLEAN DEFAULT NULL,
  p_schedule_cron       TEXT DEFAULT NULL,
  p_schedule_recipients JSONB DEFAULT NULL,
  p_enabled             BOOLEAN DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_t       RECORD;
  v_invalid TEXT;
BEGIN
  IF NOT fn_current_user_has_permission('report.template.manage') THEN
    RAISE EXCEPTION 'report.template.manage permission required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_t FROM report_template WHERE id = p_id AND is_active = TRUE FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Template not found' USING ERRCODE = 'P0002';
  END IF;

  -- assigned_roles validation
  IF p_assigned_roles IS NOT NULL THEN
    IF jsonb_typeof(p_assigned_roles) <> 'array' OR jsonb_array_length(p_assigned_roles) = 0 THEN
      RAISE EXCEPTION 'assignedRoles must be a non-empty array' USING ERRCODE = '22023';
    END IF;
    SELECT e INTO v_invalid
      FROM jsonb_array_elements_text(p_assigned_roles) e
     WHERE NOT EXISTS (SELECT 1 FROM role r WHERE r.name = e AND r.is_active = TRUE)
     LIMIT 1;
    IF v_invalid IS NOT NULL THEN
      RAISE EXCEPTION 'invalid role in assignedRoles: %', v_invalid USING ERRCODE = '22023';
    END IF;
  END IF;

  -- data_source validation
  IF p_data_source IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_report_data_' || p_data_source AND pronamespace = 'public'::regnamespace) THEN
    RAISE EXCEPTION 'Unknown data_source' USING ERRCODE = '22023';
  END IF;

  -- schedule validation
  IF (COALESCE(p_is_scheduled, v_t.is_scheduled)) = TRUE THEN
    IF COALESCE(p_schedule_cron, v_t.schedule_cron) IS NULL THEN
      RAISE EXCEPTION 'scheduleCron is required when isScheduled=true' USING ERRCODE = '22023';
    END IF;
    IF COALESCE(p_schedule_recipients, v_t.schedule_recipients) IS NULL THEN
      RAISE EXCEPTION 'scheduleRecipients is required when isScheduled=true' USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE report_template SET
    display_name_en     = COALESCE(p_display_name_en, display_name_en),
    display_name_ar     = COALESCE(p_display_name_ar, display_name_ar),
    description         = COALESCE(p_description, description),
    data_source         = COALESCE(p_data_source, data_source),
    parameter_schema    = COALESCE(p_parameter_schema, parameter_schema),
    assigned_roles      = COALESCE(p_assigned_roles, assigned_roles),
    is_scheduled        = COALESCE(p_is_scheduled, is_scheduled),
    schedule_cron       = COALESCE(p_schedule_cron, schedule_cron),
    schedule_recipients = COALESCE(p_schedule_recipients, schedule_recipients),
    enabled             = COALESCE(p_enabled, enabled),
    updated_at          = fn_demo_now(),
    updated_by          = NULLIF(p_actor_id, 0)
  WHERE id = p_id;

  RETURN fn_report_template_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_template_update: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, BOOLEAN, TEXT, JSONB, BOOLEAN) IS 'Partial update of report template; templateId/tenantId/reportKind are immutable.';
REVOKE EXECUTE ON FUNCTION fn_report_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, BOOLEAN, TEXT, JSONB, BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, BOOLEAN, TEXT, JSONB, BOOLEAN) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- fn_report_template_delete (soft)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_template_delete(
  p_actor_id BIGINT,
  p_id       BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_rows INTEGER;
BEGIN
  IF NOT fn_current_user_has_permission('report.template.manage') THEN
    RAISE EXCEPTION 'report.template.manage permission required' USING ERRCODE = '42501';
  END IF;

  UPDATE report_template
     SET is_active = FALSE, enabled = FALSE,
         updated_at = fn_demo_now(), updated_by = NULLIF(p_actor_id, 0)
   WHERE id = p_id AND is_active = TRUE;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Template not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('deletedId', p_id, 'success', TRUE);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_template_delete: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_template_delete(BIGINT, BIGINT) IS 'Soft-delete report template (is_active=false, enabled=false). report_run history preserved.';
REVOKE EXECUTE ON FUNCTION fn_report_template_delete(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_delete(BIGINT, BIGINT) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (263, '263_crl_fn_report_template_functions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_report_template_list(BIGINT, BOOLEAN);
-- DROP FUNCTION IF EXISTS fn_report_template_get_by_id(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_report_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, JSONB, BOOLEAN, TEXT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, BOOLEAN, TEXT, JSONB, BOOLEAN);
-- DROP FUNCTION IF EXISTS fn_report_template_delete(BIGINT, BIGINT);
-- DELETE FROM schema_migrations WHERE version = 263;
-- ============================================================
