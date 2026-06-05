-- Migration: 588_notification_template_create_fn.sql
-- Module: Email templates — add CREATE so admin can register new templates
-- Date: 2026-06-05
--
-- Today the BE only exposes list / get / update / render. Admin can edit
-- existing rows but cannot register new ones, so any new event_type
-- introduced via the notification rule UI has no template to render. This
-- migration adds fn_notification_template_create with the same shape as
-- _update + an immutable channel + template_id pair.

BEGIN;

CREATE OR REPLACE FUNCTION fn_notification_template_create(
  p_template_id      TEXT,
  p_channel          TEXT,
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
  v_id        BIGINT;
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_notification_template_create: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('notification.template.manage') THEN
    RAISE EXCEPTION 'fn_notification_template_create: forbidden' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_notification_template_create: tenant_context_missing' USING ERRCODE = '42501';
  END IF;

  -- Validation
  IF p_template_id IS NULL OR length(trim(p_template_id)) = 0 THEN
    RAISE EXCEPTION 'fn_notification_template_create: template_id_required' USING ERRCODE = '22023';
  END IF;
  IF p_template_id !~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$' THEN
    RAISE EXCEPTION 'fn_notification_template_create: template_id_format — use dotted lowercase (e.g. "contract.assigned.email")'
      USING ERRCODE = '22023';
  END IF;
  IF p_channel NOT IN ('email','in_app','teams_capture','slack_capture') THEN
    RAISE EXCEPTION 'fn_notification_template_create: invalid_channel — valid: email / in_app / teams_capture / slack_capture'
      USING ERRCODE = '22023';
  END IF;
  IF p_body_en IS NULL OR length(trim(p_body_en)) = 0 THEN
    RAISE EXCEPTION 'fn_notification_template_create: body_en_required' USING ERRCODE = '22023';
  END IF;
  IF p_body_ar IS NULL OR length(trim(p_body_ar)) = 0 THEN
    -- AR body is required by the table constraint; mirror EN body if not supplied
    -- so the row inserts. Admin can refine later.
    p_body_ar := p_body_en;
  END IF;
  IF p_parameter_schema IS NOT NULL AND jsonb_typeof(p_parameter_schema) <> 'object' THEN
    RAISE EXCEPTION 'fn_notification_template_create: parameter_schema_must_be_object' USING ERRCODE = '22023';
  END IF;

  v_actor := v_uid;
  IF v_actor = 0 THEN v_actor := NULL; END IF;

  BEGIN
    INSERT INTO notification_template (
      tenant_id, template_id, channel,
      subject_en, subject_ar, body_en, body_ar,
      parameter_schema, last_modified_by,
      data_classification, created_at, updated_at, created_by, updated_by, is_active
    ) VALUES (
      v_tenant_id, p_template_id, p_channel,
      p_subject_en, p_subject_ar, p_body_en, p_body_ar,
      COALESCE(p_parameter_schema, '{}'::jsonb), v_actor,
      'production', NOW(), NOW(), v_actor, v_actor, TRUE
    )
    RETURNING id INTO v_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'fn_notification_template_create: template_id_already_exists — % (%) is taken for this tenant', p_template_id, p_channel
        USING ERRCODE = '23505';
  END;

  RETURN fn_notification_template_get_by_id(v_id);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN unique_violation THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_template_create: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_notification_template_create(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) IS
  'INVOKER. Creates a notification_template row for the current tenant. template_id is a dotted lowercase slug (e.g. "contract.assigned.email"). channel ∈ email/in_app/teams_capture/slack_capture. Unique per (tenant_id, template_id).';
REVOKE EXECUTE ON FUNCTION fn_notification_template_create(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_template_create(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (588, '588_notification_template_create_fn', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK:
-- DROP FUNCTION IF EXISTS fn_notification_template_create(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB);
-- DELETE FROM schema_migrations WHERE version = 588;
