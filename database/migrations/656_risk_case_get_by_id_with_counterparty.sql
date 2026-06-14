-- ============================================================================
-- Migration 656 — Phase E follow-up: surface counterparty on risk-case detail
-- ============================================================================
-- WHY: the risk-case detail page renders a `linkedContract` block but never
-- resolves the contract's counterparty, so a reader can't tell *who* the
-- case is actually about without clicking through to the contract. For
-- sanctions-style cases (e.g. OFAC case 8) the counterparty + sanctions
-- status are the central facts; hiding them under a click is wrong.
--
-- WHAT this migration does:
--   - Extends fn_risk_case_get_by_id with a new top-level `counterparty`
--     object resolved via contract.counterparty_id → party. Returns
--     NULL when the case has no linked contract or the contract has no
--     counterparty (defensive — should always be present for ADNOC seed).
--   - Surfaces sanctions context structurally: sanctionsStatus +
--     sanctionsLastChecked + parentName (party.parent_id → party.name_en).
--   - Preserves the full pre-existing payload shape; the only change is the
--     addition of a single new key. Existing FE callers see no breaking
--     diff (jsonb_build_object accepts unknown keys ok at unwrap time).
-- ============================================================================

BEGIN;

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
      'riskType', fn_classify_risk(
                    NULL, NULL, NULL, NULL, NULL,
                    v_case.title, v_case.assigned_role, v_case.case_type
                  ),
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
    -- mig 656 — counterparty block resolved via contract.counterparty_id → party.
    -- Includes sanctions context structurally so the detail page no longer
    -- relies on free-text body to convey the *who*. parentName resolves
    -- party.parent_id → party.name_en (NULL when no parent chain).
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

COMMENT ON FUNCTION public.fn_risk_case_get_by_id(BIGINT, BIGINT) IS
  'mig 656 (Phase E follow-up) — adds top-level counterparty block joined via '
  'contract.counterparty_id → party so the detail page can render counterparty '
  'name + sanctions status + parent entity without a separate fetch.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (656, 'risk_case_get_by_id_with_counterparty', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
