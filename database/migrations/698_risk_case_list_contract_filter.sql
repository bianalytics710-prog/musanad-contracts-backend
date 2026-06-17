-- ============================================================================
-- Migration 698 — fn_risk_case_list gains a contract_id filter
-- ============================================================================
-- The contract detail "Risk" tab will list only the contract's MANAGED risk
-- cases (Tier-1 auto-routed + Tier-2 confirmed) instead of raw score signals.
-- fn_risk_case_list already excludes triage-pending (mig 691) and, with
-- status='open_all', closed/terminal cases — so filtering it by contract_id
-- yields exactly the managed, active cases for that contract.
--
-- Verbatim from mig 694 + a new trailing p_contract_id param (default NULL,
-- so existing 10-arg call sites are unaffected) applied to COUNT + paged query.
-- ============================================================================

BEGIN;

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
  p_assigned_user_id      bigint  DEFAULT NULL,
  p_contract_id           bigint  DEFAULT NULL
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
     AND (p_contract_id IS NULL OR rc.contract_id = p_contract_id)
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
     AND NOT (
       rc.status IN ('open','in_review')
       AND rc.assigned_user_id IS NULL
       AND fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                            rc.title, rc.assigned_role, rc.case_type) <> 'approval_workflow'
     )
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
           rc.contract_id, rc.correlation_id, rc.metadata
      FROM risk_case rc
     WHERE rc.is_active = TRUE
       AND rc.tenant_id = v_tenant_id
       AND (p_contract_id IS NULL OR rc.contract_id = p_contract_id)
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
       AND NOT (
         rc.status IN ('open','in_review')
         AND rc.assigned_user_id IS NULL
         AND fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                              rc.title, rc.assigned_role, rc.case_type) <> 'approval_workflow'
       )
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
      'riskType', COALESCE(NULLIF(p.metadata->>'riskType',''),
                           fn_classify_risk(NULL, NULL, NULL, NULL, NULL, p.title, p.assigned_role, p.case_type)),
      'riskOrigin', fn_risk_origin(
                      (SELECT os.kind FROM correlation co JOIN osint_signal os ON os.id = co.signal_id
                        WHERE co.id = p.correlation_id),
                      COALESCE(NULLIF(p.metadata->>'riskType',''),
                               fn_classify_risk(NULL, NULL, NULL, NULL, NULL, p.title, p.assigned_role, p.case_type)),
                      p.case_type
                    ),
      'isEscalated', COALESCE((p.metadata->>'escalated')::boolean, false),
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

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (698, 'fn_risk_case_list contract_id filter', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
