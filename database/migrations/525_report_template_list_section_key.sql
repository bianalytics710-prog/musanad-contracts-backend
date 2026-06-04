-- MIGRATION: 525_report_template_list_section_key.sql
-- Date: 2026-06-03
-- Description:
--   Extend fn_report_template_list to surface the new section_key column
--   added in mig 523. FE Reports library groups cards by sectionKey.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_report_template_list(p_actor_id bigint, p_admin_mode boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $fn$
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
      'sectionKey', t.section_key,
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
      'sectionKey', t.section_key,
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
$fn$;

REVOKE EXECUTE ON FUNCTION fn_report_template_list(BIGINT, BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_list(BIGINT, BOOLEAN) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (525, 'report_template_list_section_key', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
