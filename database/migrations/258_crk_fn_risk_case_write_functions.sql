-- Migration: 258_crk_fn_risk_case_write_functions.sql
-- Module: M19 — CR-K Risk Cases
-- CR: CR-K
-- Date: 2026-05-15
-- Description: 10 write fn_'s for risk_case lifecycle (S2-21 trio per fn).
-- ADAPTATION NOTES:
--   A1: user_role join table does NOT exist — adapted via user.role_id direct FK.
--   A2: fn_current_user_has_permission(text) — single TEXT arg form reads
--       app.current_user_id GUC. Used in all permission gates.
--   A3: fn_audit_log_record_v2 signature is (p_table_name, p_record_id, p_action,
--       p_old_values, p_new_values, p_changed_by) — adapted accordingly.
--   A6/A7: correlation_rule has no priority/sla_hours column — defaulted to 'medium'
--          and NULL respectively in fn_risk_case_auto_create_from_correlation.
--   A9: contract.title is title_en/title_ar — fn bodies use COALESCE(title_en,title_ar).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 2.1 fn_risk_case_create
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_create(
  p_actor_id          BIGINT,
  p_priority          TEXT,
  p_title             TEXT,
  p_contract_id       BIGINT DEFAULT NULL,
  p_body              TEXT DEFAULT NULL,
  p_assigned_role     TEXT DEFAULT NULL,
  p_assigned_user_id  BIGINT DEFAULT NULL,
  p_sla_hours         INTEGER DEFAULT NULL,
  p_metadata          JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_id        BIGINT;
  v_due_at    TIMESTAMPTZ;
  v_dedupe    TEXT;
BEGIN
  IF NOT fn_current_user_has_permission('risk.case.create') THEN
    RAISE EXCEPTION 'risk.case.create permission required' USING ERRCODE = '42501';
  END IF;

  IF p_title IS NULL OR length(trim(p_title)) = 0 THEN
    RAISE EXCEPTION 'title is required' USING ERRCODE = '22023';
  END IF;
  IF p_priority NOT IN ('low','medium','high','critical') THEN
    RAISE EXCEPTION 'priority must be one of low, medium, high, critical' USING ERRCODE = '22023';
  END IF;
  IF p_assigned_role IS NOT NULL AND NOT EXISTS (SELECT 1 FROM role WHERE name = p_assigned_role AND is_active = TRUE) THEN
    RAISE EXCEPTION 'assignedRole not found or inactive' USING ERRCODE = '22023';
  END IF;
  IF p_assigned_user_id IS NOT NULL AND p_assigned_role IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM "user" u JOIN role r ON r.id = u.role_id
       WHERE u.id = p_assigned_user_id AND r.name = p_assigned_role AND u.is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'User does not hold the assigned role' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;

  v_due_at := CASE WHEN p_sla_hours IS NOT NULL THEN fn_demo_now() + (p_sla_hours * INTERVAL '1 hour') ELSE NULL END;
  v_dedupe := p_metadata->>'idempotencyKey';

  BEGIN
    INSERT INTO risk_case (
      tenant_id, contract_id, case_type, priority, title, body,
      assigned_role, assigned_user_id, status, sla_hours, due_at,
      dedupe_key, metadata, created_by, updated_by
    ) VALUES (
      v_tenant_id, p_contract_id, 'manual', p_priority, trim(p_title), p_body,
      p_assigned_role, p_assigned_user_id, 'open', p_sla_hours, v_due_at,
      v_dedupe, COALESCE(p_metadata, '{}'::jsonb), NULLIF(p_actor_id, 0), NULLIF(p_actor_id, 0)
    ) RETURNING id INTO v_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'Idempotency conflict — dedupe_key collision' USING ERRCODE = '23505';
    WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'contract not found' USING ERRCODE = 'P0002';
  END;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, v_id, 'created', NULLIF(p_actor_id, 0),
            jsonb_build_object('title', trim(p_title), 'priority', p_priority));

  PERFORM fn_audit_log_record_v2('risk_case_event', v_id, 'INSERT', NULL,
    jsonb_build_object('eventType','created','riskCaseId',v_id), NULLIF(p_actor_id, 0));

  RETURN fn_risk_case_get_by_id(p_actor_id, v_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_create: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_create(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB) IS 'Create a manual risk case with INVOKER auth + RLS. Permission gate risk.case.create.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_create(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_create(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 2.2 fn_risk_case_auto_create_from_correlation
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_auto_create_from_correlation(
  p_correlation_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_tenant_id   UUID;
  v_contract_id BIGINT;
  v_rule_id     TEXT;
  v_rule_name   TEXT;
  v_priority    TEXT := 'medium';   -- A6: correlation_rule has no priority col
  v_id          BIGINT;
  v_was_new     BOOLEAN := FALSE;
  v_dedupe      TEXT;
  v_title       TEXT;
BEGIN
  SELECT c.tenant_id, c.contract_id, c.rule_id INTO v_tenant_id, v_contract_id, v_rule_id
    FROM correlation c WHERE c.id = p_correlation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('riskCaseId', NULL, 'wasNew', FALSE);
  END IF;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'correlation has no tenant_id (impossible)' USING ERRCODE = 'P0001';
  END IF;

  SELECT cr.name INTO v_rule_name FROM correlation_rule cr WHERE cr.rule_id = v_rule_id LIMIT 1;
  v_title := left('Correlation alert: ' || COALESCE(v_rule_name, v_rule_id), 200);
  v_dedupe := 'correlation:' || p_correlation_id;

  BEGIN
    INSERT INTO risk_case (
      tenant_id, correlation_id, contract_id, case_type, priority, title, body,
      dedupe_key, status, sla_hours, due_at, metadata, created_by, updated_by
    ) VALUES (
      v_tenant_id, p_correlation_id, v_contract_id, 'correlation_alert', v_priority, v_title, NULL,
      v_dedupe, 'open', NULL, NULL,
      jsonb_build_object('autoCreated', TRUE, 'autoCreateReason', 'rule_flag_true', 'ruleId', v_rule_id),
      NULL, NULL
    ) RETURNING id INTO v_id;
    v_was_new := TRUE;
  EXCEPTION
    WHEN unique_violation THEN
      SELECT id INTO v_id FROM risk_case WHERE tenant_id = v_tenant_id AND dedupe_key = v_dedupe;
      v_was_new := FALSE;
  END;

  IF v_was_new THEN
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
      VALUES (v_tenant_id, v_id, 'created', NULL,
              jsonb_build_object('ruleId', v_rule_id, 'correlationId', p_correlation_id, 'autoCreate', TRUE));
    PERFORM fn_audit_log_record_v2('risk_case_event', v_id, 'INSERT', NULL,
      jsonb_build_object('eventType','created','autoCreate',TRUE), NULL);
  END IF;

  RETURN jsonb_build_object('riskCaseId', v_id, 'wasNew', v_was_new);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_auto_create_from_correlation: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_auto_create_from_correlation(BIGINT) IS 'DEFINER: idempotent auto-create of risk_case from correlation. Called by correlation-evaluator.worker.ts after produce_yaml parse. Dedupe via dedupe_key=correlation:<id>.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_auto_create_from_correlation(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_auto_create_from_correlation(BIGINT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 2.3 fn_risk_case_assign
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_assign(
  p_actor_id          BIGINT,
  p_id                BIGINT,
  p_assigned_role     TEXT DEFAULT NULL,
  p_assigned_user_id  BIGINT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_case RECORD;
BEGIN
  IF p_assigned_role IS NULL AND p_assigned_user_id IS NULL THEN
    RAISE EXCEPTION 'Either assignedRole or assignedUserId is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_case FROM risk_case WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (fn_current_user_has_permission('risk.case.create')
       OR fn_current_user_has_permission('risk.case.escalate')
       OR v_case.assigned_user_id = p_actor_id) THEN
    RAISE EXCEPTION 'permission denied (risk.case.create or risk.case.escalate or current assignee required)' USING ERRCODE = '42501';
  END IF;

  IF v_case.status IN ('closed','rejected') THEN
    RAISE EXCEPTION 'Cannot assign a closed/rejected case' USING ERRCODE = 'P0001';
  END IF;

  IF p_assigned_role IS NOT NULL AND NOT EXISTS (SELECT 1 FROM role WHERE name = p_assigned_role AND is_active = TRUE) THEN
    RAISE EXCEPTION 'assignedRole not found or inactive' USING ERRCODE = '22023';
  END IF;
  IF p_assigned_user_id IS NOT NULL AND p_assigned_role IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM "user" u JOIN role r ON r.id = u.role_id
       WHERE u.id = p_assigned_user_id AND r.name = p_assigned_role AND u.is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'User does not hold the assigned role' USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE risk_case
     SET assigned_role = COALESCE(p_assigned_role, assigned_role),
         assigned_user_id = COALESCE(p_assigned_user_id, assigned_user_id),
         updated_by = NULLIF(p_actor_id, 0),
         updated_at = CURRENT_TIMESTAMP
   WHERE id = p_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_case.tenant_id, p_id, 'assigned', NULLIF(p_actor_id, 0),
            jsonb_build_object('fromRole', v_case.assigned_role, 'toRole', p_assigned_role,
                               'fromUserId', v_case.assigned_user_id, 'toUserId', p_assigned_user_id));
  PERFORM fn_audit_log_record_v2('risk_case_event', p_id, 'INSERT', NULL,
    jsonb_build_object('eventType','assigned'), NULLIF(p_actor_id, 0));

  RETURN fn_risk_case_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_assign: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_assign(BIGINT, BIGINT, TEXT, BIGINT) IS 'Assign risk case to a role + optional user. Composite permission gate.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_assign(BIGINT, BIGINT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_assign(BIGINT, BIGINT, TEXT, BIGINT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 2.4 fn_risk_case_add_comment
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_add_comment(
  p_actor_id BIGINT,
  p_id       BIGINT,
  p_comment  TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_event_id  BIGINT;
BEGIN
  IF p_comment IS NULL OR length(trim(p_comment)) = 0 THEN
    RAISE EXCEPTION 'comment is required' USING ERRCODE = '22023';
  END IF;

  SELECT tenant_id INTO v_tenant_id FROM risk_case WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_id, 'comment_added', NULLIF(p_actor_id, 0),
            jsonb_build_object('comment', trim(p_comment)))
    RETURNING id INTO v_event_id;

  PERFORM fn_audit_log_record_v2('risk_case_event', v_event_id, 'INSERT', NULL,
    jsonb_build_object('eventType','comment_added'), NULLIF(p_actor_id, 0));

  RETURN jsonb_build_object('eventId', v_event_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_add_comment: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_add_comment(BIGINT, BIGINT, TEXT) IS 'Append a comment to risk case timeline.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_add_comment(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_add_comment(BIGINT, BIGINT, TEXT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 2.5 fn_risk_case_add_evidence
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_add_evidence(
  p_actor_id   BIGINT,
  p_id         BIGINT,
  p_file_uri   TEXT,
  p_file_name  TEXT,
  p_file_mime  TEXT,
  p_file_bytes BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_case   RECORD;
  v_att_id BIGINT;
  v_evt_id BIGINT;
BEGIN
  IF p_file_bytes IS NULL OR p_file_bytes <= 0 OR p_file_bytes > 52428800 THEN
    RAISE EXCEPTION 'fileBytes must be > 0 and <= 50MB' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO v_case FROM risk_case WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_case.status IN ('closed','rejected') THEN
    RAISE EXCEPTION 'Cannot upload evidence to a closed case' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO risk_case_attachment (tenant_id, risk_case_id, file_uri, file_name, file_mime, file_bytes, uploaded_by)
    VALUES (v_case.tenant_id, p_id, p_file_uri, p_file_name, p_file_mime, p_file_bytes, p_actor_id)
    RETURNING id INTO v_att_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_case.tenant_id, p_id, 'evidence_uploaded', NULLIF(p_actor_id, 0),
            jsonb_build_object('fileName', p_file_name, 'fileBytes', p_file_bytes, 'attachmentId', v_att_id))
    RETURNING id INTO v_evt_id;

  PERFORM fn_audit_log_record_v2('risk_case_event', v_evt_id, 'INSERT', NULL,
    jsonb_build_object('eventType','evidence_uploaded','attachmentId',v_att_id), NULLIF(p_actor_id, 0));

  RETURN jsonb_build_object('attachmentId', v_att_id, 'eventId', v_evt_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_add_evidence: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_add_evidence(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT) IS 'Attach evidence file metadata; file body uploaded to Supabase Storage by BE before fn call.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_add_evidence(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_add_evidence(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 2.6 fn_risk_case_status_transition
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_status_transition(
  p_actor_id      BIGINT,
  p_id            BIGINT,
  p_to_status     TEXT,
  p_decision_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_case        RECORD;
  v_evt_id      BIGINT;
  v_can_act     BOOLEAN := FALSE;
BEGIN
  IF p_to_status NOT IN ('in_review','approved','rejected') THEN
    RAISE EXCEPTION 'toStatus must be in_review, approved or rejected' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_case FROM risk_case WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  -- Strict matrix
  IF NOT (
    (v_case.status = 'open'      AND p_to_status = 'in_review')
    OR (v_case.status = 'in_review' AND p_to_status IN ('approved','rejected'))
  ) THEN
    RAISE EXCEPTION 'Invalid transition: % -> %', v_case.status, p_to_status USING ERRCODE = 'P0001';
  END IF;

  -- Per-case_type permission gate
  IF v_case.case_type IN ('correlation_alert','sla_breach') THEN
    v_can_act := fn_current_user_has_permission('risk.case.escalate') OR v_case.assigned_user_id = p_actor_id;
  ELSE
    v_can_act := fn_current_user_has_permission('risk.case.create') OR v_case.assigned_user_id = p_actor_id;
  END IF;
  IF NOT v_can_act THEN
    RAISE EXCEPTION 'permission denied for case_type %', v_case.case_type USING ERRCODE = '42501';
  END IF;

  UPDATE risk_case
     SET status = p_to_status,
         updated_at = CURRENT_TIMESTAMP,
         updated_by = NULLIF(p_actor_id, 0)
   WHERE id = p_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_case.tenant_id, p_id, 'status_changed', NULLIF(p_actor_id, 0),
            jsonb_build_object('from', v_case.status, 'to', p_to_status, 'decisionNote', p_decision_note))
    RETURNING id INTO v_evt_id;
  PERFORM fn_audit_log_record_v2('risk_case_event', v_evt_id, 'INSERT', NULL,
    jsonb_build_object('eventType','status_changed','to',p_to_status), NULLIF(p_actor_id, 0));

  RETURN fn_risk_case_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_status_transition: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_status_transition(BIGINT, BIGINT, TEXT, TEXT) IS 'Strict state-machine transition open->in_review->approved|rejected. Per-case_type permission gate.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_status_transition(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_status_transition(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 2.7 fn_risk_case_escalate
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_escalate(
  p_actor_id BIGINT,
  p_id       BIGINT,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_case      RECORD;
  v_matrix    JSONB;
  v_hop_count INTEGER;
  v_next_role TEXT;
  v_evt_id    BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('risk.case.escalate') THEN
    RAISE EXCEPTION 'risk.case.escalate permission required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_case FROM risk_case WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_case.status IN ('closed','rejected','approved','accept_risk') THEN
    RAISE EXCEPTION 'Cannot escalate a closed/rejected/approved/accept_risk case' USING ERRCODE = 'P0001';
  END IF;

  SELECT value INTO v_matrix FROM system_setting WHERE key = 'escalation_matrix';
  IF v_matrix IS NULL THEN
    RAISE EXCEPTION 'Escalation matrix not configured' USING ERRCODE = 'P0001';
  END IF;

  v_hop_count := COALESCE((v_case.metadata->>'escalationHops')::INTEGER, 0);
  IF v_hop_count >= 10 THEN
    RAISE EXCEPTION 'matrix_cycle_detected (hopCount exceeded 10)' USING ERRCODE = 'P0001';
  END IF;

  IF v_case.assigned_role IS NULL THEN
    RAISE EXCEPTION 'Cannot escalate — assigned_role is NULL' USING ERRCODE = 'P0001';
  END IF;

  v_next_role := v_matrix #>> ARRAY['priorities', v_case.priority, v_case.assigned_role, 'next'];
  IF v_next_role IS NULL THEN
    RAISE EXCEPTION 'Cannot escalate further — already at top of matrix' USING ERRCODE = 'P0001';
  END IF;

  UPDATE risk_case
     SET assigned_role = v_next_role,
         assigned_user_id = NULL,
         status = 'escalated',
         metadata = jsonb_set(metadata, '{escalationHops}', to_jsonb(v_hop_count + 1), true),
         updated_at = CURRENT_TIMESTAMP,
         updated_by = NULLIF(p_actor_id, 0)
   WHERE id = p_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_case.tenant_id, p_id, 'escalated', NULLIF(p_actor_id, 0),
            jsonb_build_object('fromRole', v_case.assigned_role, 'toRole', v_next_role,
                               'matrixHopCount', v_hop_count + 1, 'reason', p_reason))
    RETURNING id INTO v_evt_id;
  PERFORM fn_audit_log_record_v2('risk_case_event', v_evt_id, 'INSERT', NULL,
    jsonb_build_object('eventType','escalated','toRole',v_next_role), NULLIF(p_actor_id, 0));

  RETURN jsonb_build_object(
    'riskCase', fn_risk_case_get_by_id(p_actor_id, p_id),
    'newAssignedRole', v_next_role,
    'matrixHopCount', v_hop_count + 1
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_escalate: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_escalate(BIGINT, BIGINT, TEXT) IS 'Escalate case to next role per system_setting.escalation_matrix. Cycle detection at hopCount > 10.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_escalate(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_escalate(BIGINT, BIGINT, TEXT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 2.8 fn_risk_case_accept_risk
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_accept_risk(
  p_actor_id         BIGINT,
  p_id               BIGINT,
  p_approver_user_id BIGINT,
  p_justification    TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_case          RECORD;
  v_matrix        JSONB;
  v_required_role TEXT;
  v_evt_id        BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('risk.case.accept_risk') THEN
    RAISE EXCEPTION 'risk.case.accept_risk permission required' USING ERRCODE = '42501';
  END IF;
  IF p_justification IS NULL OR length(trim(p_justification)) < 10 THEN
    RAISE EXCEPTION 'justification must be at least 10 characters' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_case FROM risk_case WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_case.status IN ('closed','rejected') THEN
    RAISE EXCEPTION 'Invalid transition: cannot accept risk on closed/rejected case' USING ERRCODE = 'P0001';
  END IF;

  SELECT value INTO v_matrix FROM system_setting WHERE key = 'accept_risk_approval_matrix';
  IF v_matrix IS NULL THEN
    RAISE EXCEPTION 'approval matrix not configured' USING ERRCODE = 'P0001';
  END IF;

  v_required_role := v_matrix #>> ARRAY['priorities', v_case.priority];
  IF v_required_role IS NULL THEN
    RAISE EXCEPTION 'approval matrix has no entry for priority %', v_case.priority USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM "user" u JOIN role r ON r.id = u.role_id
     WHERE u.id = p_approver_user_id AND r.name = v_required_role AND u.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Approver role insufficient for priority' USING ERRCODE = 'P0001';
  END IF;

  UPDATE risk_case
     SET status = 'accept_risk',
         closure_outcome = 'accepted',
         metadata = jsonb_set(metadata, '{approverUserId}', to_jsonb(p_approver_user_id), true),
         updated_at = CURRENT_TIMESTAMP,
         updated_by = NULLIF(p_actor_id, 0)
   WHERE id = p_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_case.tenant_id, p_id, 'accepted_risk', NULLIF(p_actor_id, 0),
            jsonb_build_object('approverUserId', p_approver_user_id, 'justification', p_justification))
    RETURNING id INTO v_evt_id;
  PERFORM fn_audit_log_record_v2('risk_case_event', v_evt_id, 'INSERT', NULL,
    jsonb_build_object('eventType','accepted_risk','approverUserId',p_approver_user_id), NULLIF(p_actor_id, 0));

  RETURN fn_risk_case_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_accept_risk: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_accept_risk(BIGINT, BIGINT, BIGINT, TEXT) IS 'Accept-Risk decision with named approver per system_setting.accept_risk_approval_matrix.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_accept_risk(BIGINT, BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_accept_risk(BIGINT, BIGINT, BIGINT, TEXT) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 2.9 fn_risk_case_snooze
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_snooze(
  p_actor_id      BIGINT,
  p_id            BIGINT,
  p_snoozed_until TIMESTAMPTZ
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_case   RECORD;
  v_evt_id BIGINT;
BEGIN
  SELECT * INTO v_case FROM risk_case WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (fn_current_user_has_permission('risk.case.create')
       OR fn_current_user_has_permission('risk.case.escalate')
       OR v_case.assigned_user_id = p_actor_id) THEN
    RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
  END IF;

  IF p_snoozed_until <= fn_demo_now() THEN
    RAISE EXCEPTION 'snoozedUntil must be in the future' USING ERRCODE = '22023';
  END IF;
  IF p_snoozed_until > fn_demo_now() + INTERVAL '30 days' THEN
    RAISE EXCEPTION 'snoozedUntil cannot be more than 30 days from now' USING ERRCODE = '22023';
  END IF;

  IF v_case.status IN ('closed','rejected') THEN
    RAISE EXCEPTION 'Cannot snooze a closed/rejected case' USING ERRCODE = 'P0001';
  END IF;

  UPDATE risk_case
     SET status = 'snoozed',
         snoozed_until = p_snoozed_until,
         updated_at = CURRENT_TIMESTAMP,
         updated_by = NULLIF(p_actor_id, 0)
   WHERE id = p_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_case.tenant_id, p_id, 'snoozed', NULLIF(p_actor_id, 0),
            jsonb_build_object('snoozedUntil', p_snoozed_until))
    RETURNING id INTO v_evt_id;
  PERFORM fn_audit_log_record_v2('risk_case_event', v_evt_id, 'INSERT', NULL,
    jsonb_build_object('eventType','snoozed'), NULLIF(p_actor_id, 0));

  RETURN fn_risk_case_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_snooze: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_snooze(BIGINT, BIGINT, TIMESTAMPTZ) IS 'Snooze case until future timestamp (cap 30 days from fn_demo_now()).';
REVOKE EXECUTE ON FUNCTION fn_risk_case_snooze(BIGINT, BIGINT, TIMESTAMPTZ) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_snooze(BIGINT, BIGINT, TIMESTAMPTZ) TO neondb_owner;


-- ─────────────────────────────────────────────────────────────
-- 2.10 fn_risk_case_close
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_risk_case_close(
  p_actor_id    BIGINT,
  p_id          BIGINT,
  p_outcome     TEXT,
  p_closure_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_case   RECORD;
  v_evt_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('risk.case.close') THEN
    RAISE EXCEPTION 'risk.case.close permission required' USING ERRCODE = '42501';
  END IF;
  IF p_outcome NOT IN ('mitigated','accepted','no_action','advisory_dispatched') THEN
    RAISE EXCEPTION 'invalid outcome' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_case FROM risk_case WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Risk case not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_case.status NOT IN ('approved','rejected','accept_risk','escalated') THEN
    RAISE EXCEPTION 'Cannot close case from status ''%'' without prior action', v_case.status USING ERRCODE = 'P0001';
  END IF;

  UPDATE risk_case
     SET status = 'closed',
         closed_at = fn_demo_now(),
         closed_by = NULLIF(p_actor_id, 0),
         closure_outcome = p_outcome,
         updated_at = CURRENT_TIMESTAMP,
         updated_by = NULLIF(p_actor_id, 0)
   WHERE id = p_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_case.tenant_id, p_id, 'closed', NULLIF(p_actor_id, 0),
            jsonb_build_object('outcome', p_outcome, 'closureNote', p_closure_note))
    RETURNING id INTO v_evt_id;
  PERFORM fn_audit_log_record_v2('risk_case_event', v_evt_id, 'INSERT', NULL,
    jsonb_build_object('eventType','closed','outcome',p_outcome), NULLIF(p_actor_id, 0));

  RETURN fn_risk_case_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_close: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
COMMENT ON FUNCTION fn_risk_case_close(BIGINT, BIGINT, TEXT, TEXT) IS 'Close risk case with closure_outcome. Requires prior approved/rejected/accept_risk/escalated.';
REVOKE EXECUTE ON FUNCTION fn_risk_case_close(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_close(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (258, '258_crk_fn_risk_case_write_functions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_risk_case_create(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB);
-- DROP FUNCTION IF EXISTS fn_risk_case_auto_create_from_correlation(BIGINT);
-- DROP FUNCTION IF EXISTS fn_risk_case_assign(BIGINT, BIGINT, TEXT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_risk_case_add_comment(BIGINT, BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_risk_case_add_evidence(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_risk_case_status_transition(BIGINT, BIGINT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_risk_case_escalate(BIGINT, BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_risk_case_accept_risk(BIGINT, BIGINT, BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_risk_case_snooze(BIGINT, BIGINT, TIMESTAMPTZ);
-- DROP FUNCTION IF EXISTS fn_risk_case_close(BIGINT, BIGINT, TEXT, TEXT);
-- DELETE FROM schema_migrations WHERE version = 258;
-- ============================================================
