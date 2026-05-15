-- Migration: 264_crl_fn_report_run_functions.sql
-- Module: M20 — CR-L Reports & Briefings
-- CR: CR-L
-- Date: 2026-05-15
-- Description: 4 fn_'s for report_run lifecycle: trigger, complete, get_by_id, pending_get.
-- ADAPTATIONS: A1 user.role_id direct FK; A3 fn_audit_log_record_v2 6-arg signature.
-- S2-RLS-1: report_run has RESTRICTIVE deny-UPDATE; lifecycle UPDATEs require DEFINER
--           fns (fn_report_run_complete + fn_report_run_pending_get).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- fn_report_run_trigger
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_run_trigger(
  p_actor_id     BIGINT,
  p_template_id  BIGINT,
  p_format       TEXT,
  p_parameters   JSONB DEFAULT '{}',
  p_triggered_by TEXT DEFAULT 'manual'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_t           RECORD;
  v_caller_role TEXT;
  v_overlap     BOOLEAN := FALSE;
  v_id          BIGINT;
  v_tenant_id   UUID;
BEGIN
  IF p_triggered_by NOT IN ('manual','scheduled') THEN
    RAISE EXCEPTION 'triggeredBy must be manual or scheduled' USING ERRCODE = '22023';
  END IF;
  IF p_format NOT IN ('excel','pdf') THEN
    RAISE EXCEPTION 'format must be excel or pdf' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_t FROM report_template WHERE id = p_template_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Template not found or soft-deleted' USING ERRCODE = 'P0002';
  END IF;
  IF NOT v_t.enabled THEN
    RAISE EXCEPTION 'Template is not enabled' USING ERRCODE = '22023';
  END IF;

  -- format must match report_kind
  IF v_t.report_kind <> 'both' AND v_t.report_kind <> p_format THEN
    RAISE EXCEPTION 'format incompatible with template.report_kind' USING ERRCODE = '22023';
  END IF;

  v_tenant_id := v_t.tenant_id;

  IF p_triggered_by = 'scheduled' THEN
    IF COALESCE(p_actor_id, 0) <> 0 THEN
      RAISE EXCEPTION 'scheduled triggers must use system actor (actor_id 0 or NULL)' USING ERRCODE = '42501';
    END IF;
  ELSE
    -- manual: caller role must overlap template.assigned_roles
    IF NOT fn_current_user_has_permission('report.read') THEN
      RAISE EXCEPTION 'report.read permission required' USING ERRCODE = '42501';
    END IF;
    SELECT r.name INTO v_caller_role FROM "user" u JOIN role r ON r.id = u.role_id WHERE u.id = p_actor_id;
    v_overlap := v_caller_role IS NOT NULL AND v_t.assigned_roles ? v_caller_role;
    IF NOT v_overlap THEN
      RAISE EXCEPTION 'caller role does not overlap with template.assigned_roles' USING ERRCODE = '42501';
    END IF;
  END IF;

  INSERT INTO report_run (
    tenant_id, report_template_id, triggered_by, triggered_by_user_id,
    parameters, format, status
  ) VALUES (
    v_tenant_id, p_template_id, p_triggered_by,
    CASE WHEN p_triggered_by = 'manual' THEN NULLIF(p_actor_id, 0) ELSE NULL END,
    COALESCE(p_parameters, '{}'::jsonb), p_format, 'pending'
  ) RETURNING id INTO v_id;

  -- Strategy A audit (redact parameters)
  PERFORM fn_audit_log_record_v2('report_run', v_id, 'INSERT', NULL,
    jsonb_build_object('templateId', p_template_id, 'format', p_format,
                       'triggeredBy', p_triggered_by, 'status', 'pending'),
    NULLIF(p_actor_id, 0));

  RETURN jsonb_build_object('runId', v_id, 'status', 'pending');

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_run_trigger: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_run_trigger(BIGINT, BIGINT, TEXT, JSONB, TEXT) IS 'Trigger a report run; inserts pending row. Worker picks up via fn_report_run_pending_get.';
REVOKE EXECUTE ON FUNCTION fn_report_run_trigger(BIGINT, BIGINT, TEXT, JSONB, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_run_trigger(BIGINT, BIGINT, TEXT, JSONB, TEXT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- fn_report_run_complete (DEFINER — bypasses report_run deny-UPDATE)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_run_complete(
  p_run_id            BIGINT,
  p_status            TEXT,
  p_output_uri        TEXT DEFAULT NULL,
  p_output_size_bytes BIGINT DEFAULT NULL,
  p_error_message     TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_run RECORD;
BEGIN
  IF p_status NOT IN ('complete','failed') THEN
    RAISE EXCEPTION 'status must be complete or failed' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_run FROM report_run WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Run not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_run.status IN ('complete','failed') THEN
    RAISE EXCEPTION 'Run already in terminal state' USING ERRCODE = 'P0001';
  END IF;

  IF p_status = 'complete' THEN
    IF p_output_uri IS NULL OR length(trim(p_output_uri)) = 0 OR p_output_size_bytes IS NULL THEN
      RAISE EXCEPTION 'outputUri and outputSizeBytes required when status=complete' USING ERRCODE = '22023';
    END IF;
  ELSE
    IF p_error_message IS NULL OR length(trim(p_error_message)) = 0 THEN
      RAISE EXCEPTION 'errorMessage required when status=failed' USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE report_run
     SET status = p_status,
         output_uri = CASE WHEN p_status = 'complete' THEN p_output_uri ELSE output_uri END,
         output_size_bytes = CASE WHEN p_status = 'complete' THEN p_output_size_bytes ELSE output_size_bytes END,
         error_message = CASE WHEN p_status = 'failed' THEN p_error_message ELSE error_message END,
         completed_at = fn_demo_now()
   WHERE id = p_run_id;

  IF p_status = 'complete' THEN
    UPDATE report_template SET last_run_at = fn_demo_now() WHERE id = v_run.report_template_id;
  END IF;

  -- Strategy A audit (redact output_uri/error_message via field-name redact rule)
  PERFORM fn_audit_log_record_v2('report_run', p_run_id, 'UPDATE',
    jsonb_build_object('status', v_run.status),
    jsonb_build_object('status', p_status, 'completedAt', fn_demo_now()),
    NULL);

  RETURN jsonb_build_object('runId', p_run_id, 'status', p_status);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_run_complete: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_run_complete(BIGINT, TEXT, TEXT, BIGINT, TEXT) IS 'DEFINER: worker-only terminal-state hand-off. Transitions generating->complete|failed; bumps report_template.last_run_at on complete.';
REVOKE EXECUTE ON FUNCTION fn_report_run_complete(BIGINT, TEXT, TEXT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_run_complete(BIGINT, TEXT, TEXT, BIGINT, TEXT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- fn_report_run_get_by_id
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_run_get_by_id(
  p_actor_id BIGINT,
  p_run_id   BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_run     RECORD;
  v_can_see BOOLEAN := FALSE;
BEGIN
  SELECT * INTO v_run FROM report_run WHERE id = p_run_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Run not found' USING ERRCODE = 'P0002';
  END IF;

  v_can_see := (v_run.triggered_by_user_id = p_actor_id)
            OR fn_current_user_has_permission('report.run.read.all');
  IF NOT v_can_see THEN
    RAISE EXCEPTION 'Run not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'runId', v_run.id,
    'reportTemplateId', v_run.report_template_id,
    'triggeredBy', v_run.triggered_by,
    'triggeredByUserId', v_run.triggered_by_user_id,
    'format', v_run.format,
    'status', v_run.status,
    'outputUri', v_run.output_uri,
    'outputSizeBytes', v_run.output_size_bytes,
    'errorMessage', v_run.error_message,
    'startedAt', v_run.started_at,
    'completedAt', v_run.completed_at,
    'createdAt', v_run.created_at
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_run_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_run_get_by_id(BIGINT, BIGINT) IS 'Get report run by id. Visibility: triggered_by_user_id = caller OR report.run.read.all.';
REVOKE EXECUTE ON FUNCTION fn_report_run_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_run_get_by_id(BIGINT, BIGINT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- fn_report_run_pending_get (DEFINER — worker pickup; S2-8 4-CTE chain)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_report_run_pending_get(
  p_limit INTEGER DEFAULT 5
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_data JSONB;
BEGIN
  -- 4-CTE chain: picked -> updated -> audited (consumed) -> final SELECT
  WITH picked AS (
    SELECT id, tenant_id, report_template_id, format, parameters, triggered_by
      FROM report_run
     WHERE status = 'pending'
     ORDER BY created_at ASC
     LIMIT p_limit
     FOR UPDATE SKIP LOCKED
  ),
  updated AS (
    UPDATE report_run rr
       SET status = 'generating', started_at = fn_demo_now()
      FROM picked
     WHERE rr.id = picked.id
    RETURNING rr.id, rr.tenant_id, rr.report_template_id, rr.format, rr.parameters, rr.triggered_by
  ),
  audited AS (
    SELECT u.id, u.tenant_id, u.report_template_id, u.format, u.parameters, u.triggered_by,
           fn_audit_log_record_v2('report_run', u.id, 'UPDATE',
                                  jsonb_build_object('status','pending'),
                                  jsonb_build_object('status','generating','startedAt',fn_demo_now(),'pickedBy','report-run-worker'),
                                  NULL) AS audit_id
      FROM updated u
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', a.id,
    'tenantId', a.tenant_id,
    'reportTemplateId', a.report_template_id,
    'format', a.format,
    'parameters', a.parameters,
    'triggeredBy', a.triggered_by
  )), '[]'::jsonb) INTO v_data
  FROM audited a;

  RETURN jsonb_build_object('runs', v_data);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_report_run_pending_get: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_report_run_pending_get(INTEGER) IS 'DEFINER worker-pickup: 4-CTE chain (picked->updated->audited->select). FOR UPDATE SKIP LOCKED for parallel workers. Strategy A audit emitted inside CTE.';
REVOKE EXECUTE ON FUNCTION fn_report_run_pending_get(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_run_pending_get(INTEGER) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (264, '264_crl_fn_report_run_functions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_report_run_trigger(BIGINT, BIGINT, TEXT, JSONB, TEXT);
-- DROP FUNCTION IF EXISTS fn_report_run_complete(BIGINT, TEXT, TEXT, BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_report_run_get_by_id(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_report_run_pending_get(INTEGER);
-- DELETE FROM schema_migrations WHERE version = 264;
-- ============================================================
