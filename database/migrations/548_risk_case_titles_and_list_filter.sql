-- MIGRATION: 548_risk_case_titles_and_list_filter.sql
-- Date: 2026-06-04
-- Description:
--   Phase A — Risk Cases UX cleanup (DB side).
--
--   1) Drop the "Correlation alert: " jargon prefix from titles.
--      fn_risk_case_auto_create_from_correlation today builds titles as
--      "Correlation alert: <rule name>", which is developer plumbing the
--      customer should never see. Rule name on its own already reads as
--      a human sentence (e.g. "Sanctions designation directly hits a
--      contract counterparty"). Drop the prefix in the fn and backfill
--      any existing rows that carry it.
--
--   2) Add p_assigned_user_id to fn_risk_case_list so the new
--      "Assigned to" filter on the Risk Cases list can filter server-
--      side instead of paging then client-filtering. Additive parameter
--      — existing callers that pass NULL get unchanged behaviour.

BEGIN;

-- 1. Drop the "Correlation alert: " title prefix ----------------------

CREATE OR REPLACE FUNCTION public.fn_risk_case_auto_create_from_correlation(p_correlation_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tenant_id   UUID;
  v_contract_id BIGINT;
  v_rule_id     TEXT;
  v_rule_name   TEXT;
  v_priority    TEXT := 'medium';
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
  -- Title is the rule name directly. No "Correlation alert:" prefix —
  -- that string is developer jargon, never customer-facing.
  v_title := left(COALESCE(v_rule_name, v_rule_id), 200);
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
$function$;

-- Backfill any existing rows that already carry the prefix. None match
-- in the current seed, but defensive against future re-seeds.
UPDATE risk_case
   SET title = regexp_replace(title, '^Correlation alert:\s*', '')
 WHERE title LIKE 'Correlation alert: %';

-- 2. Add p_assigned_user_id to fn_risk_case_list ----------------------

CREATE OR REPLACE FUNCTION public.fn_risk_case_list(
  p_actor_id              bigint,
  p_status                text DEFAULT NULL,
  p_priority              text DEFAULT NULL,
  p_assigned_to_me        boolean DEFAULT false,
  p_sla_due_within_hours  integer DEFAULT NULL,
  p_case_type             text DEFAULT NULL,
  p_search                text DEFAULT NULL,
  p_page                  integer DEFAULT 1,
  p_limit                 integer DEFAULT 20,
  p_assigned_user_id      bigint  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
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

  SELECT COUNT(*) INTO v_total
    FROM risk_case rc
   WHERE rc.is_active = TRUE
     AND rc.tenant_id = v_tenant_id
     AND (p_status IS NULL OR rc.status = p_status OR
          (p_status = 'open_all' AND rc.status NOT IN ('closed','approved','rejected','accept_risk')))
     AND (p_priority IS NULL OR rc.priority = p_priority)
     AND (p_case_type IS NULL OR rc.case_type = p_case_type)
     AND (NOT p_assigned_to_me OR rc.assigned_user_id = p_actor_id)
     AND (p_assigned_user_id IS NULL OR rc.assigned_user_id = p_assigned_user_id)
     AND (p_sla_due_within_hours IS NULL
          OR (rc.due_at IS NOT NULL
              AND rc.due_at <= fn_demo_now() + (p_sla_due_within_hours * INTERVAL '1 hour')))
     AND (p_search IS NULL OR rc.title ILIKE '%' || p_search || '%')
     AND (
       v_full_access
       OR rc.assigned_role = v_caller_role
       OR rc.assigned_user_id = p_actor_id
       OR (v_vis_map ? v_caller_role AND (
            (v_vis_map -> v_caller_role) ? '*'
            OR (v_vis_map -> v_caller_role) ? rc.case_type
          ))
     );

  WITH paged AS (
    SELECT rc.id, rc.priority, rc.status, rc.title, rc.case_type,
           rc.assigned_role, rc.assigned_user_id, rc.due_at, rc.created_at,
           rc.contract_id, rc.correlation_id
      FROM risk_case rc
     WHERE rc.is_active = TRUE
       AND rc.tenant_id = v_tenant_id
       AND (p_status IS NULL OR rc.status = p_status OR
            (p_status = 'open_all' AND rc.status NOT IN ('closed','approved','rejected','accept_risk')))
       AND (p_priority IS NULL OR rc.priority = p_priority)
       AND (p_case_type IS NULL OR rc.case_type = p_case_type)
       AND (NOT p_assigned_to_me OR rc.assigned_user_id = p_actor_id)
       AND (p_assigned_user_id IS NULL OR rc.assigned_user_id = p_assigned_user_id)
       AND (p_sla_due_within_hours IS NULL
            OR (rc.due_at IS NOT NULL
                AND rc.due_at <= fn_demo_now() + (p_sla_due_within_hours * INTERVAL '1 hour')))
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
     ORDER BY
       CASE rc.priority WHEN 'critical' THEN 1 WHEN 'high' THEN 2
                        WHEN 'medium'   THEN 3 WHEN 'low'  THEN 4 ELSE 5 END ASC,
       rc.due_at ASC NULLS LAST,
       rc.created_at DESC
     LIMIT p_limit OFFSET (p_page - 1) * p_limit
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', p.id,
      'priority', p.priority,
      'status', p.status,
      'title', p.title,
      'caseType', p.case_type,
      'riskType', fn_classify_risk(
                    NULL, NULL, NULL, NULL, NULL,
                    p.title, p.assigned_role, p.case_type
                  ),
      'assignedRole', p.assigned_role,
      'assignedUserId', p.assigned_user_id,
      'assignedUserName', (SELECT u.first_name || ' ' || u.last_name
                             FROM "user" u WHERE u.id = p.assigned_user_id),
      'dueAt', p.due_at,
      'slaCountdownSeconds',
        CASE WHEN p.due_at IS NOT NULL
             AND p.status NOT IN ('closed','approved','rejected','accept_risk')
             THEN EXTRACT(EPOCH FROM (p.due_at - fn_demo_now()))::INTEGER
             ELSE NULL END,
      -- Contract metadata for the new dedicated Contract + Counterparty columns
      'contractId',     p.contract_id,
      'contractNumber', (SELECT c.contract_number FROM contract c WHERE c.id = p.contract_id),
      'contractTitle',  (SELECT COALESCE(c.title_en, c.title_ar) FROM contract c WHERE c.id = p.contract_id),
      'counterpartyName', (
        SELECT cp.name_en
          FROM contract c
          LEFT JOIN party cp ON cp.id = c.counterparty_id
         WHERE c.id = p.contract_id
      ),
      'correlationSummary', (SELECT jsonb_build_object(
                                      'id', c.id,
                                      'ruleId', c.rule_id,
                                      'confidence', c.confidence)
                               FROM correlation c WHERE c.id = p.correlation_id),
      'createdAt', p.created_at
    )), '[]'::jsonb) INTO v_data FROM paged p;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', COALESCE(v_total, 0),
      'page', p_page,
      'limit', p_limit,
      'totalPages', CASE WHEN v_total > 0
                         THEN CEIL(v_total::numeric / p_limit)::INTEGER
                         ELSE 0 END
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

-- 3. Helper fn for assignable-users endpoint --------------------------
--
-- Returns active users whose role is one of the risk-eligible roles —
-- i.e., any role that can plausibly own a risk_case (covers the demo's
-- 5 personas + the 4 specialist roles that routing rules target).

CREATE OR REPLACE FUNCTION public.fn_risk_case_assignable_users(p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_caller_role TEXT;
BEGIN
  SELECT r.name INTO v_caller_role
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = p_actor_id;

  IF v_caller_role IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
  END IF;

  RETURN COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
        'id',           u.id::text,
        'name',         TRIM(COALESCE(u.first_name,'') || ' ' || COALESCE(u.last_name,'')),
        'email',        u.email,
        'roleName',     r.name,
        'roleDisplay',  CASE r.name
                          WHEN 'compliance_esg'             THEN 'Compliance & ESG'
                          WHEN 'legal_counsel'              THEN 'Legal Counsel'
                          WHEN 'finance_treasury'           THEN 'Finance & Treasury'
                          WHEN 'procurement_supplier_risk'  THEN 'Procurement & Supplier Risk'
                          WHEN 'operations'                 THEN 'Operations'
                          WHEN 'contract_approver'          THEN 'Contract Approver'
                          WHEN 'contract_approver_2'        THEN 'Contract Approver (Stage 2)'
                          WHEN 'executive'                  THEN 'Executive'
                          WHEN 'platform_admin'             THEN 'Platform Admin'
                          WHEN 'Super Admin'                THEN 'Super Admin'
                          ELSE r.name
                        END
      ) ORDER BY r.name, u.first_name)
       FROM "user" u
       JOIN role r ON r.id = u.role_id
      WHERE u.is_active = TRUE
        AND r.is_active = TRUE
        AND r.name IN (
          'compliance_esg','legal_counsel','finance_treasury',
          'procurement_supplier_risk','operations',
          'contract_approver','contract_approver_2','executive',
          'platform_admin','Super Admin'
        )),
    '[]'::jsonb
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_case_assignable_users(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_case_assignable_users(bigint) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (548, 'risk_case_titles_and_list_filter', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
