-- ============================================================================
-- Migration 694 — Flag-only escalation + Manual origin + manual risk-type override
-- ============================================================================
-- 1. ESCALATION IS A FLAG, NOT A STATUS. fn_risk_case_escalate previously set
--    status='escalated' AND reassigned to the next role (blanking the assignee).
--    Now it only MARKS the case escalated (metadata.escalated + escalatedAt) and
--    leaves status + assignee exactly as the persona set them.
-- 2. MANUAL ORIGIN. fn_risk_origin gains a case_type arg: a case with no signal
--    and case_type='manual' is 'manual' (manually-logged), distinct from the
--    internal/external auto-classification.
-- 3. MANUAL RISK TYPE. Manually-created cases carry a chosen risk type in
--    metadata.riskType; fn_risk_case_list + fn_risk_case_get_by_id prefer it over
--    fn_classify_risk. Both also expose isEscalated (metadata.escalated).
-- 4. Reverts demo case 24 (escalated last round) to a clean state: status
--    in_review, persona restored, flagged escalated.
-- ============================================================================

BEGIN;

-- ── 1. fn_risk_origin — add case_type → 'manual' ────────────────────────────
DROP FUNCTION IF EXISTS public.fn_risk_origin(text, text);
CREATE OR REPLACE FUNCTION public.fn_risk_origin(p_signal_kind TEXT, p_risk_type TEXT, p_case_type TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE
    WHEN p_signal_kind = 'internal' THEN 'internal'
    WHEN p_signal_kind IS NOT NULL  THEN 'external'
    WHEN p_case_type = 'manual'     THEN 'manual'
    ELSE CASE p_risk_type
      WHEN 'budget_overrun'             THEN 'internal'
      WHEN 'sla_breach'                 THEN 'internal'
      WHEN 'milestone_slippage'         THEN 'internal'
      WHEN 'approval_workflow'          THEN 'internal'
      WHEN 'vendor_supplier'            THEN 'internal'
      WHEN 'counterparty_concentration' THEN 'internal'
      ELSE 'external'
    END
  END;
$fn$;
COMMENT ON FUNCTION public.fn_risk_origin(TEXT, TEXT, TEXT) IS
  '694 — internal / external / manual risk origin. Signal kind authoritative; no-signal manual cases = manual; otherwise risk-type map.';
REVOKE ALL ON FUNCTION public.fn_risk_origin(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_origin(TEXT, TEXT, TEXT) TO neondb_owner;

-- ── 2. fn_risk_case_escalate — flag-only (keep status + assignment) ─────────
CREATE OR REPLACE FUNCTION public.fn_risk_case_escalate(
  p_actor_id BIGINT,
  p_id       BIGINT,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $function$
DECLARE
  v_case      RECORD;
  v_hop_count INTEGER;
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

  v_hop_count := COALESCE((v_case.metadata->>'escalationHops')::INTEGER, 0);

  -- 694 — FLAG ONLY. status and assignee are left untouched; escalation is now
  -- a marker that surfaces an "Escalated" pill + highlight, not a status change.
  UPDATE risk_case
     SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
                      'escalated',        true,
                      'escalatedAt',      now(),
                      'escalatedBy',      NULLIF(p_actor_id, 0),
                      'escalationReason', p_reason,
                      'escalationHops',   v_hop_count + 1
                    ),
         updated_at = CURRENT_TIMESTAMP,
         updated_by = NULLIF(p_actor_id, 0)
   WHERE id = p_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_case.tenant_id, p_id, 'escalated', NULLIF(p_actor_id, 0),
            jsonb_build_object('flagOnly', true, 'reason', p_reason,
                               'escalationHops', v_hop_count + 1))
    RETURNING id INTO v_evt_id;
  PERFORM fn_audit_log_record_v2('risk_case_event', v_evt_id, 'INSERT', NULL,
    jsonb_build_object('eventType','escalated'), NULLIF(p_actor_id, 0));

  RETURN jsonb_build_object(
    'riskCase', fn_risk_case_get_by_id(p_actor_id, p_id),
    'escalated', true,
    'escalationHops', v_hop_count + 1
  );
END;
$function$;

-- ── 3. fn_risk_case_list — riskType override + manual origin + isEscalated ──
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

-- ── 4. fn_risk_case_get_by_id — riskType override + manual origin + isEscalated
CREATE OR REPLACE FUNCTION public.fn_risk_case_get_by_id(
  p_actor_id bigint,
  p_id       bigint
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_case        RECORD;
  v_caller_role TEXT;
  v_vis_map     JSONB;
  v_full_access BOOLEAN := FALSE;
  v_visible     BOOLEAN := FALSE;
  v_risk_type   TEXT;
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

  v_risk_type := COALESCE(NULLIF(v_case.metadata->>'riskType',''),
                          fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                                           v_case.title, v_case.assigned_role, v_case.case_type));

  RETURN jsonb_build_object(
    'riskCase', jsonb_build_object(
      'id', v_case.id,
      'tenantId', v_case.tenant_id,
      'correlationId', v_case.correlation_id,
      'contractId', v_case.contract_id,
      'caseType', v_case.case_type,
      'riskType', v_risk_type,
      'riskOrigin', fn_risk_origin(
                      (SELECT os.kind FROM correlation co JOIN osint_signal os ON os.id = co.signal_id
                        WHERE co.id = v_case.correlation_id),
                      v_risk_type, v_case.case_type
                    ),
      'isEscalated', COALESCE((v_case.metadata->>'escalated')::boolean, false),
      'priority', v_case.priority,
      'title', v_case.title,
      'body', v_case.body,
      'assignedRole', v_case.assigned_role,
      'assignedRoleDisplay', CASE v_case.assigned_role
                                WHEN 'compliance_esg'             THEN 'Compliance & ESG'
                                WHEN 'legal_counsel'              THEN 'Legal Counsel'
                                WHEN 'finance_treasury'           THEN 'Finance & Treasury'
                                WHEN 'procurement_supplier_risk'  THEN 'Procurement & Supplier Risk'
                                WHEN 'operations'                 THEN 'Operations'
                                WHEN 'platform_admin'             THEN 'Platform Admin'
                                WHEN 'contract_drafter'           THEN 'Contract Drafter'
                                WHEN 'contract_approver'          THEN 'Contract Approver'
                                WHEN 'contract_approver_2'        THEN 'Contract Approver (Stage 2)'
                                WHEN 'contract_recipient'         THEN 'Contract Recipient'
                                WHEN 'executive'                  THEN 'Executive'
                                WHEN 'Super Admin'                THEN 'Super Admin'
                                ELSE                                  COALESCE(v_case.assigned_role, '—')
                              END,
      'assignedUserId', v_case.assigned_user_id,
      'assignedUserName', (
        SELECT (u.first_name || ' ' || u.last_name)
          FROM "user" u WHERE u.id = v_case.assigned_user_id
      ),
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
               'actorName', NULLIF(TRIM(COALESCE(au.first_name,'') || ' ' || COALESCE(au.last_name,'')), ''),
               'payload', e.payload,
               'occurredAt', e.occurred_at
             ) ORDER BY e.occurred_at ASC)
        FROM risk_case_event e
        LEFT JOIN "user" au ON au.id = e.actor_id
        WHERE e.risk_case_id = v_case.id
    ), '[]'::jsonb),
    'attachments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'fileName', a.file_name,
               'fileMime', a.file_mime,
               'fileBytes', a.file_bytes,
               'uploadedBy', a.uploaded_by,
               'uploadedByName', NULLIF(TRIM(COALESCE(uu.first_name,'') || ' ' || COALESCE(uu.last_name,'')), ''),
               'uploadedAt', a.uploaded_at
             ) ORDER BY a.uploaded_at DESC)
        FROM risk_case_attachment a
        LEFT JOIN "user" uu ON uu.id = a.uploaded_by
        WHERE a.risk_case_id = v_case.id AND a.is_active = TRUE
    ), '[]'::jsonb),
    'linkedCorrelation', (
      SELECT jsonb_build_object('id', c.id, 'ruleId', c.rule_id, 'confidence', c.confidence,
                                'matchReason', c.match_reason, 'status', c.status)
        FROM correlation c WHERE c.id = v_case.correlation_id
    ),
    'linkedContract', (
      SELECT jsonb_build_object(
               'id', c.id,
               'titleEn', c.title_en,
               'titleAr', c.title_ar,
               'title', c.title_en,
               'status', c.status,
               'contractNumber', c.contract_number
             )
        FROM contract c WHERE c.id = v_case.contract_id
    ),
    'counterparty', (
      SELECT jsonb_build_object(
               'id',                    p.id,
               'nameEn',                p.name_en,
               'nameAr',                p.name_ar,
               'partyType',             p.party_type,
               'country',               p.country,
               'emirate',               p.emirate,
               'isVerified',            p.is_verified,
               'sanctionsStatus',       p.sanctions_status,
               'sanctionsLastChecked',  p.sanctions_last_checked,
               'sanctionsMatchSignalId',p.sanctions_match_signal_id,
               'icvStatus',             p.icv_status,
               'icvPct',                p.icv_pct,
               'esgScore',              p.esg_score,
               'parentId',              p.parent_id,
               'parentName',            pp.name_en,
               'aliases',               COALESCE(p.aliases, '[]'::jsonb)
             )
        FROM contract c
        JOIN party p   ON p.id  = c.counterparty_id
        LEFT JOIN party pp ON pp.id = p.parent_id
       WHERE c.id = v_case.contract_id
    ),
    'sourceSystemRecord', (
      SELECT jsonb_build_object(
               'systemCode',     iss.system_code,
               'systemName',     iss.display_name,
               'systemKind',     iss.kind,
               'recordRef',      os.source_record_ref,
               'recordUrl',      os.url,
               'capturedAt',     os.fetched_at,
               'signalSubtype',  os.signal_kind_subtype,
               'snapshot',       os.source_record_snapshot
             )
        FROM correlation co
        JOIN osint_signal os ON os.id = co.signal_id AND os.kind = 'internal'
        LEFT JOIN internal_system_source iss ON iss.id = os.internal_system_id
       WHERE co.id = v_case.correlation_id
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
      CASE WHEN v_case.due_at IS NOT NULL
           AND v_case.status NOT IN ('closed','approved','rejected','accept_risk')
           THEN EXTRACT(EPOCH FROM (v_case.due_at - fn_demo_now()))::INTEGER
           ELSE NULL END
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_case_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

-- ── 5. Revert demo case 24 (escalated last round) to a clean flagged state ──
DO $$
DECLARE v_tenant UUID := '00000000-0000-0000-0000-000000000001'::uuid;
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::text, true);
  PERFORM set_config('app.current_user_id', '1', true);
  UPDATE risk_case
     SET status           = 'in_review',
         assigned_role    = 'operations',
         assigned_user_id = 12,
         metadata         = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('escalated', true, 'escalatedAt', now()),
         updated_at       = now()
   WHERE id = 24 AND tenant_id = v_tenant;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (694, 'flag-only escalate + manual origin + manual riskType override + isEscalated', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK: restore fns from migs 692/258 + fn_risk_origin(text,text) from 692;
--           DELETE schema_migrations WHERE version=694.
