-- Migration: 259_crk_fn_risk_case_read_functions.sql
-- Module: M19 — CR-K Risk Cases
-- CR: CR-K
-- Date: 2026-05-15
-- Description: 4 read fn_'s for risk_case: list, get_by_id, evidence_get,
--              escalation_check. STABLE marker; S2-24 split-aggregate.
-- ADAPTATIONS: A9 contract.title -> COALESCE(title_en, title_ar).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 3.1 fn_risk_case_list
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_list(
  p_actor_id              BIGINT,
  p_status                TEXT DEFAULT NULL,
  p_priority              TEXT DEFAULT NULL,
  p_assigned_to_me        BOOLEAN DEFAULT FALSE,
  p_sla_due_within_hours  INTEGER DEFAULT NULL,
  p_case_type             TEXT DEFAULT NULL,
  p_search                TEXT DEFAULT NULL,
  p_page                  INTEGER DEFAULT 1,
  p_limit                 INTEGER DEFAULT 20
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id   UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_caller_role TEXT;
  v_vis_map     JSONB;
  v_full_access BOOLEAN := FALSE;
  v_total       INTEGER;
  v_data        JSONB;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;

  SELECT r.name INTO v_caller_role
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = p_actor_id;

  SELECT value INTO v_vis_map FROM system_setting WHERE key = 'risk_case_visibility_map';
  v_full_access := v_caller_role IN ('platform_admin','Super Admin','executive');

  WITH base AS (
    SELECT rc.id, rc.priority, rc.status, rc.title, rc.case_type,
           rc.assigned_role, rc.assigned_user_id, rc.due_at, rc.created_at,
           rc.contract_id, rc.correlation_id, rc.tenant_id
      FROM risk_case rc
     WHERE rc.is_active = TRUE
       AND rc.tenant_id = v_tenant_id
       AND (p_status IS NULL OR rc.status = p_status OR
            (p_status = 'open_all' AND rc.status NOT IN ('closed','approved','rejected','accept_risk')))
       AND (p_priority IS NULL OR rc.priority = p_priority)
       AND (p_case_type IS NULL OR rc.case_type = p_case_type)
       AND (NOT p_assigned_to_me OR rc.assigned_user_id = p_actor_id)
       AND (p_sla_due_within_hours IS NULL OR (rc.due_at IS NOT NULL AND rc.due_at <= fn_demo_now() + (p_sla_due_within_hours * INTERVAL '1 hour')))
       AND (p_search IS NULL OR rc.title ILIKE '%' || p_search || '%')
       AND (
         v_full_access
         OR rc.assigned_role = v_caller_role
         OR rc.assigned_user_id = p_actor_id
         OR (v_vis_map ? v_caller_role AND (
              (v_vis_map -> v_caller_role) ? '*'
              OR (v_vis_map -> v_caller_role) ? rc.case_type
            ))
       )
  ),
  counted AS (SELECT COUNT(*) AS total FROM base),
  paged AS (
    SELECT * FROM base
     ORDER BY
       CASE priority WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END ASC,
       due_at ASC NULLS LAST,
       created_at DESC
     LIMIT p_limit OFFSET (p_page - 1) * p_limit
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', p.id,
      'priority', p.priority,
      'status', p.status,
      'title', p.title,
      'caseType', p.case_type,
      'assignedRole', p.assigned_role,
      'assignedUserId', p.assigned_user_id,
      'assignedUserName', (SELECT u.first_name || ' ' || u.last_name FROM "user" u WHERE u.id = p.assigned_user_id),
      'dueAt', p.due_at,
      'slaCountdownSeconds',
        CASE WHEN p.due_at IS NOT NULL AND p.status NOT IN ('closed','approved','rejected','accept_risk')
             THEN EXTRACT(EPOCH FROM (p.due_at - fn_demo_now()))::INTEGER
             ELSE NULL END,
      'contractTitle', (SELECT COALESCE(c.title_en, c.title_ar) FROM contract c WHERE c.id = p.contract_id),
      'correlationSummary', (SELECT jsonb_build_object('id', c.id, 'ruleId', c.rule_id, 'confidence', c.confidence)
                              FROM correlation c WHERE c.id = p.correlation_id),
      'createdAt', p.created_at
    )), '[]'::jsonb) INTO v_data FROM paged p;

  SELECT total INTO v_total FROM counted;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', COALESCE(v_total, 0),
      'page', p_page,
      'limit', p_limit,
      'totalPages', CASE WHEN v_total > 0 THEN CEIL(v_total::numeric / p_limit)::INTEGER ELSE 0 END
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, TEXT, TEXT, INTEGER, INTEGER) IS 'Paginated risk case list with persona-scoped visibility per system_setting.risk_case_visibility_map.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, TEXT, TEXT, INTEGER, INTEGER) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 3.2 fn_risk_case_get_by_id
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_get_by_id(
  p_actor_id BIGINT,
  p_id       BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_case        RECORD;
  v_caller_role TEXT;
  v_vis_map     JSONB;
  v_full_access BOOLEAN := FALSE;
  v_visible     BOOLEAN := FALSE;
BEGIN
  SELECT * INTO v_case FROM risk_case WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT r.name INTO v_caller_role
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = p_actor_id;
  SELECT value INTO v_vis_map FROM system_setting WHERE key = 'risk_case_visibility_map';
  v_full_access := v_caller_role IN ('platform_admin','Super Admin','executive');

  v_visible := v_full_access
    OR v_case.assigned_role = v_caller_role
    OR v_case.assigned_user_id = p_actor_id
    OR (v_vis_map IS NOT NULL AND v_vis_map ? v_caller_role AND (
         (v_vis_map -> v_caller_role) ? '*'
         OR (v_vis_map -> v_caller_role) ? v_case.case_type
       ));
  IF NOT v_visible THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'riskCase', jsonb_build_object(
      'id', v_case.id,
      'tenantId', v_case.tenant_id,
      'correlationId', v_case.correlation_id,
      'contractId', v_case.contract_id,
      'caseType', v_case.case_type,
      'priority', v_case.priority,
      'title', v_case.title,
      'body', v_case.body,
      'assignedRole', v_case.assigned_role,
      'assignedUserId', v_case.assigned_user_id,
      'status', v_case.status,
      'slaHours', v_case.sla_hours,
      'dueAt', v_case.due_at,
      'snoozedUntil', v_case.snoozed_until,
      'closedAt', v_case.closed_at,
      'closedBy', v_case.closed_by,
      'closureOutcome', v_case.closure_outcome,
      'dedupeKey', v_case.dedupe_key,
      'metadata', v_case.metadata,
      'dataClassification', v_case.data_classification,
      'createdAt', v_case.created_at,
      'updatedAt', v_case.updated_at,
      'createdBy', v_case.created_by,
      'updatedBy', v_case.updated_by,
      'isActive', v_case.is_active
    ),
    'timeline', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', e.id,
               'eventType', e.event_type,
               'actorId', e.actor_id,
               'payload', e.payload,
               'occurredAt', e.occurred_at
             ) ORDER BY e.occurred_at ASC)
        FROM risk_case_event e WHERE e.risk_case_id = v_case.id
    ), '[]'::jsonb),
    'attachments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'fileName', a.file_name,
               'fileMime', a.file_mime,
               'fileBytes', a.file_bytes,
               'uploadedBy', a.uploaded_by,
               'uploadedAt', a.uploaded_at
             ) ORDER BY a.uploaded_at DESC)
        FROM risk_case_attachment a WHERE a.risk_case_id = v_case.id AND a.is_active = TRUE
    ), '[]'::jsonb),
    'linkedCorrelation', (
      SELECT jsonb_build_object('id', c.id, 'ruleId', c.rule_id, 'confidence', c.confidence,
                                'matchReason', c.match_reason, 'status', c.status)
        FROM correlation c WHERE c.id = v_case.correlation_id
    ),
    'linkedContract', (
      SELECT jsonb_build_object('id', c.id, 'titleEn', c.title_en, 'titleAr', c.title_ar,
                                'status', c.status, 'contractNumber', c.contract_number)
        FROM contract c WHERE c.id = v_case.contract_id
    ),
    'linkedAdvisoryDrafts', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', d.id, 'approvalStatus', d.approval_status,
                                          'templateId', d.template_id, 'createdAt', d.created_at))
        FROM advisory_draft d
       WHERE d.correlation_id = v_case.correlation_id
         AND v_case.correlation_id IS NOT NULL
         AND d.is_active = TRUE
    ), '[]'::jsonb),
    'slaCountdownSeconds',
      CASE WHEN v_case.due_at IS NOT NULL AND v_case.status NOT IN ('closed','approved','rejected','accept_risk')
           THEN EXTRACT(EPOCH FROM (v_case.due_at - fn_demo_now()))::INTEGER
           ELSE NULL END
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_get_by_id(BIGINT, BIGINT) IS 'Full risk case detail with timeline, attachments, linkedCorrelation/Contract/AdvisoryDrafts, slaCountdownSeconds.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_get_by_id(BIGINT, BIGINT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 3.3 fn_risk_case_evidence_get
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_evidence_get(
  p_actor_id     BIGINT,
  p_id           BIGINT,
  p_attachment_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_att RECORD;
BEGIN
  -- visibility-gate parent (re-uses get_by_id which enforces)
  PERFORM fn_risk_case_get_by_id(p_actor_id, p_id);

  SELECT * INTO v_att FROM risk_case_attachment
   WHERE id = p_attachment_id AND risk_case_id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Attachment not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'id', v_att.id,
    'riskCaseId', v_att.risk_case_id,
    'fileUri', v_att.file_uri,
    'fileName', v_att.file_name,
    'fileMime', v_att.file_mime,
    'fileBytes', v_att.file_bytes,
    'uploadedBy', v_att.uploaded_by,
    'uploadedAt', v_att.uploaded_at
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_evidence_get: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_evidence_get(BIGINT, BIGINT, BIGINT) IS 'Get evidence attachment metadata (BE mints signed URL).';
REVOKE EXECUTE ON FUNCTION fn_risk_case_evidence_get(BIGINT, BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_evidence_get(BIGINT, BIGINT, BIGINT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 3.4 fn_risk_case_escalation_check (DEFINER cross-tenant)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_escalation_check(
  p_limit INTEGER DEFAULT 100
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_data JSONB;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', c.id,
    'tenantId', c.tenant_id,
    'priority', c.priority,
    'assignedRole', c.assigned_role,
    'currentDueAt', c.due_at
  ) ORDER BY c.due_at ASC), '[]'::jsonb) INTO v_data
  FROM (
    SELECT id, tenant_id, priority, assigned_role, due_at
      FROM risk_case
     WHERE is_active = TRUE
       AND status NOT IN ('approved','rejected','closed','accept_risk','escalated')
       AND due_at IS NOT NULL
       AND due_at < fn_demo_now()
       AND (snoozed_until IS NULL OR snoozed_until < fn_demo_now())
     ORDER BY due_at ASC
     LIMIT p_limit
  ) c;

  RETURN jsonb_build_object('candidates', v_data);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_escalation_check: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_escalation_check(INTEGER) IS 'DEFINER cross-tenant: returns escalation-overdue risk cases. Worker sets per-tenant GUC before invoking fn_risk_case_escalate.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_escalation_check(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_escalation_check(INTEGER) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (259, '259_crk_fn_risk_case_read_functions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_risk_case_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, TEXT, TEXT, INTEGER, INTEGER);
-- DROP FUNCTION IF EXISTS fn_risk_case_get_by_id(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_risk_case_evidence_get(BIGINT, BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_risk_case_escalation_check(INTEGER);
-- DELETE FROM schema_migrations WHERE version = 259;
-- ============================================================
