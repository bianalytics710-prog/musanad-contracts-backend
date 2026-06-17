-- ============================================================================
-- Migration 690 — Internal vs External risk classification + source-system record
--                 + 3 internal Tier-2 triage cases
-- ============================================================================
-- WHY (consolidates the piecemeal internal-signal work into a coherent story):
--   1. A risk case is INTERNAL when its triggering signal came from one of our
--      own systems (kind='internal' → SAP/ServiceNow/Primavera/…); EXTERNAL when
--      it came from an OSINT feed (sanctions/weather/commodity/…). That origin
--      was computed-but-never-shown, so Risk Triage and Risk Cases couldn't tell
--      them apart. We now surface `riskOrigin` on the triage lists, the risk-case
--      list, and the case detail.
--   2. For internal cases the demo must show the ACTUAL fetched system record —
--      system name, record id, and the field/values that triggered the
--      correlation (e.g. budget overrun → SAP PO, approved vs committed vs
--      variance) — not just an outbound link. We add osint_signal.source_record_
--      snapshot (a structured JSONB of the fetched record) and surface it on the
--      case detail as a "Source system record" block.
--   3. Seed 3 internal Tier-2 triage cases (awaiting Confirm-risk / Mark-as-noise):
--        - Budget overrun        → SAP S/4HANA Finance   (contract 52, Jack-Up Drilling)
--        - Milestone slippage     → Oracle Primavera P6   (contract 77, EPC Crude Stab.)
--        - SLA breach             → ServiceNow ITSM        (contract 243, Gas SPA)
--      Each is married to an internal osint_signal carrying a rich record snapshot.
--
-- Origin is DERIVED (correlation → osint_signal.kind), so it stays correct with
-- no per-row bookkeeping. All fn changes are additive.
-- ============================================================================

BEGIN;

-- ── 1. Structured source-record snapshot on internal signals ────────────────
ALTER TABLE osint_signal
  ADD COLUMN IF NOT EXISTS source_record_snapshot JSONB;

COMMENT ON COLUMN osint_signal.source_record_snapshot IS
  '690 — for kind=internal signals, the ACTUAL record fetched from the source system that triggered the signal: { systemName, systemCode, systemKind, recordType, recordId, recordUrl, capturedAt, fields:[{label,value}] }. Rendered inline on the risk-case detail so a reviewer sees the real system data, not just a link. NULL for external signals.';

-- ── 2. budget_overrun as a first-class internal signal kind ─────────────────
ALTER TABLE internal_signal_kind DROP CONSTRAINT internal_signal_kind_signal_type_check;
ALTER TABLE internal_signal_kind ADD CONSTRAINT internal_signal_kind_signal_type_check
  CHECK (signal_type IN (
    'milestone_slippage','sla_breach','payment_delay','invoice_dispute',
    'vendor_incident','ics_incident','icv_status_change','certificate_expiry',
    'budget_overrun'));

INSERT INTO internal_signal_kind (
  tenant_id, signal_type, display_name, display_name_ar, description,
  parameter_schema, default_severity
) VALUES (
  '00000000-0000-0000-0000-000000000001','budget_overrun',
  'Budget Overrun','تجاوز الميزانية',
  'A contract''s committed cost has exceeded its approved budget.',
  '{"required":["contractId","observedAt"],"optional":["severityCalcInput","poRef","budgetRef","variancePct"]}'::jsonb,
  'high')
ON CONFLICT (tenant_id, signal_type) DO NOTHING;

-- ── 3. fn_risk_review_list (Tier-2 triage) — add risk_origin ────────────────
--    Verbatim from mig 663 + a derived risk_origin column.
CREATE OR REPLACE FUNCTION public.fn_risk_review_list(p_limit integer DEFAULT 10)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_tenant_id UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.review.manage') THEN
    RAISE EXCEPTION 'risk.review.manage permission required' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'asOf', CURRENT_TIMESTAMP,
    'rows', COALESCE(
      (SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.impact_score DESC, x.id ASC)
         FROM (
           SELECT
             rc.id::text                                     AS id,
             rc.title                                        AS title,
             rc.priority                                     AS priority,
             rc.status                                       AS status,
             COALESCE(rc.body, '')                           AS description,
             rc.metadata->>'suppressedReason'                AS suppressed_reason,
             COALESCE((rc.metadata->>'confidence')::numeric, 0) AS confidence,
             COALESCE((rc.metadata->>'materialityAed')::numeric, 0) AS materiality_aed,
             fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                              rc.title, rc.assigned_role, rc.case_type) AS risk_type,
             -- 690 — internal vs external, derived from the triggering signal.
             COALESCE((SELECT CASE WHEN os.kind = 'internal' THEN 'internal' ELSE 'external' END
                         FROM correlation co JOIN osint_signal os ON os.id = co.signal_id
                        WHERE co.id = rc.correlation_id), 'external') AS risk_origin,
             rc.contract_id::text                            AS contract_id,
             c.contract_number                               AS contract_number,
             COALESCE(c.title_en, c.title_ar)                AS contract_title,
             cp.name_en                                      AS counterparty_name,
             c.value_aed                                     AS value_aed,
             c.currency                                      AS currency,
             rc.created_at                                   AS created_at,
             COALESCE((rc.metadata->>'materialityAed')::numeric, 0)
               * COALESCE((rc.metadata->>'confidence')::numeric, 0) AS impact_score,
             rr.assigned_role                                AS preview_role,
             CASE rr.assigned_role
               WHEN 'compliance_esg'             THEN 'Compliance & ESG'
               WHEN 'legal_counsel'              THEN 'Legal Counsel'
               WHEN 'finance_treasury'           THEN 'Finance & Treasury'
               WHEN 'procurement_supplier_risk'  THEN 'Procurement & Supplier Risk'
               WHEN 'operations'                 THEN 'Operations'
               WHEN 'contract_approver'          THEN 'Contract Approver'
               WHEN 'executive'                  THEN 'Executive'
               WHEN 'platform_admin'             THEN 'Platform Admin'
               ELSE                                   COALESCE(rr.assigned_role, '—')
             END                                            AS preview_role_display,
             rr.sla_hours                                   AS preview_sla_hours
             FROM risk_case rc
             LEFT JOIN contract c ON c.id = rc.contract_id
             LEFT JOIN party cp ON cp.id = c.counterparty_id
             LEFT JOIN LATERAL (
               SELECT r.assigned_role, r.sla_hours
                 FROM risk_routing_rule r
                WHERE r.tenant_id = rc.tenant_id
                  AND r.is_active = TRUE
                  AND (r.case_type     IS NULL OR r.case_type = rc.case_type)
                  AND (r.risk_type     IS NULL OR r.risk_type =
                       fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                                        rc.title, rc.assigned_role, rc.case_type))
                  AND (r.priority_min  IS NULL OR
                       (CASE rc.priority WHEN 'critical' THEN 4 WHEN 'high' THEN 3
                                         WHEN 'medium'   THEN 2 WHEN 'low'  THEN 1 ELSE 0 END)
                       >=
                       (CASE r.priority_min WHEN 'critical' THEN 4 WHEN 'high' THEN 3
                                            WHEN 'medium'   THEN 2 WHEN 'low'  THEN 1 ELSE 0 END))
                  AND (r.contract_type IS NULL OR r.contract_type = c.contract_type)
                ORDER BY r.rule_order ASC
                LIMIT 1
             ) rr ON TRUE
            WHERE rc.is_active = TRUE
              AND rc.tenant_id = v_tenant_id
              AND rc.assigned_user_id IS NULL
              AND rc.status IN ('open','in_review')
              AND fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                                   rc.title, rc.assigned_role, rc.case_type)
                  <> 'approval_workflow'
            ORDER BY impact_score DESC, rc.id ASC
            LIMIT p_limit
         ) x),
      '[]'::jsonb
    )
  );
END;
$function$;

-- ── 4. fn_risk_triage_tier1_list — add risk_origin ──────────────────────────
CREATE OR REPLACE FUNCTION public.fn_risk_triage_tier1_list(p_limit INTEGER DEFAULT 25)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_tenant_id UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.review.manage') THEN
    RAISE EXCEPTION 'risk.review.manage permission required' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'asOf', CURRENT_TIMESTAMP,
    'rows', COALESCE(
      (SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at DESC, x.id ASC)
         FROM (
           SELECT
             rc.id::text                                       AS id,
             rc.title                                          AS title,
             rc.priority                                       AS priority,
             rc.status                                         AS status,
             COALESCE(rc.body, '')                             AS description,
             COALESCE((rc.metadata->>'confidence')::numeric, 0) AS confidence,
             COALESCE((rc.metadata->>'materialityAed')::numeric, 0) AS materiality_aed,
             fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                              rc.title, rc.assigned_role, rc.case_type) AS risk_type,
             COALESCE((SELECT CASE WHEN os.kind = 'internal' THEN 'internal' ELSE 'external' END
                         FROM correlation co JOIN osint_signal os ON os.id = co.signal_id
                        WHERE co.id = rc.correlation_id), 'external') AS risk_origin,
             rc.contract_id::text                              AS contract_id,
             c.contract_number                                 AS contract_number,
             COALESCE(c.title_en, c.title_ar)                  AS contract_title,
             cp.name_en                                        AS counterparty_name,
             c.value_aed                                       AS value_aed,
             c.currency                                        AS currency,
             rc.created_at                                     AS created_at,
             rc.assigned_role                                  AS assigned_role,
             rc.assigned_user_id::text                         AS assigned_user_id,
             TRIM(CONCAT_WS(' ', u.first_name, u.last_name))   AS assigned_user_name,
             u.email                                           AS assigned_user_email,
             rc.sla_hours                                      AS sla_hours,
             rc.due_at                                         AS due_at
             FROM risk_case rc
             LEFT JOIN contract c ON c.id = rc.contract_id
             LEFT JOIN party    cp ON cp.id = c.counterparty_id
             LEFT JOIN "user"   u  ON u.id  = rc.assigned_user_id
            WHERE rc.is_active = TRUE
              AND rc.tenant_id = v_tenant_id
              AND rc.status = 'open'
              AND rc.assigned_role IS NOT NULL
              AND rc.assigned_user_id IS NOT NULL
              AND COALESCE((rc.metadata->>'tier')::int, 1) = 1
              AND fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                                   rc.title, rc.assigned_role, rc.case_type)
                  <> 'approval_workflow'
            ORDER BY rc.created_at DESC, rc.id ASC
            LIMIT p_limit
         ) x),
      '[]'::jsonb
    )
  );
END;
$function$;

-- ── 5. fn_risk_case_list (canonical /app/risk-cases) — add riskOrigin ───────
--    Verbatim from mig 548 + 'riskOrigin' on each row object.
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
      -- 690 — internal vs external origin.
      'riskOrigin', COALESCE((SELECT CASE WHEN os.kind = 'internal' THEN 'internal' ELSE 'external' END
                                FROM correlation co JOIN osint_signal os ON os.id = co.signal_id
                               WHERE co.id = p.correlation_id), 'external'),
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

-- ── 6. fn_risk_case_get_by_id — add riskOrigin + sourceSystemRecord ─────────
--    Verbatim from mig 656 + 'riskOrigin' on riskCase + a top-level
--    'sourceSystemRecord' block (the fetched internal system record).
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
      -- 690 — internal vs external origin (derived from the triggering signal).
      'riskOrigin', COALESCE((SELECT CASE WHEN os.kind = 'internal' THEN 'internal' ELSE 'external' END
                                FROM correlation co JOIN osint_signal os ON os.id = co.signal_id
                               WHERE co.id = v_case.correlation_id), 'external'),
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
    -- 690 — Source system record. For internal cases this is the ACTUAL record
    -- fetched from the originating system (SAP/ServiceNow/Primavera/…) that drove
    -- the correlation: system identity + the structured field/value snapshot.
    -- NULL for external cases (the counterparty/OSINT context covers those).
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

-- ── 7. Seed 3 internal Tier-2 triage cases ──────────────────────────────────
DO $seed$
DECLARE
  v_tenant   UUID := '00000000-0000-0000-0000-000000000001'::uuid;
  v_admin    BIGINT;
  v_corr_status TEXT;
  v_corr_dc  TEXT;
  v_sig      BIGINT;
  v_corr     BIGINT;
BEGIN
  SELECT id INTO v_admin FROM "user" WHERE email = 'admin@musanad.local' LIMIT 1;
  IF v_admin IS NULL THEN RAISE NOTICE '690 seed skipped — no bootstrap admin'; RETURN; END IF;
  PERFORM set_config('app.current_tenant_id', v_tenant::text, true);
  PERFORM set_config('app.current_user_id',   v_admin::text, true);
  -- Reuse an existing correlation's enum values to stay schema-safe.
  SELECT status, data_classification INTO v_corr_status, v_corr_dc
    FROM correlation WHERE is_active = TRUE LIMIT 1;
  v_corr_status := COALESCE(v_corr_status, 'active');
  v_corr_dc     := COALESCE(v_corr_dc, 'demo');

  -- ===== Case 1 — Budget overrun → SAP S/4HANA Finance (contract 52) =====
  IF NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'internal-demo-budget-overrun-52') THEN
    INSERT INTO osint_signal (
      tenant_id, osint_source_id, source_id, source_reliability, fetched_at, event_date_v2,
      kind, signal_kind_subtype, title, summary, geographies, affected_entities,
      severity_v2, confidence, url, raw_payload, dedup_hash, data_classification,
      internal_system_id, source_record_ref, source_record_snapshot, metadata,
      created_by, updated_by, ext_id, category, source, severity, title_en, published_date
    ) VALUES (
      v_tenant, 15, 'internal:harness', 1.00, now(), now(),
      'internal', 'budget_overrun',
      'Budget Overrun — Jack-Up Drilling Rigs committed cost +8.5%',
      'SAP S/4HANA Finance: committed cost has exceeded the approved budget by 8.5%.',
      '[]'::jsonb, '[]'::jsonb, 'high', 1.00,
      'https://s4hana-finance.adnoc.ae/record/PO-4500087231',
      jsonb_build_object('contractId',52,'poRef','PO 4500087231','variancePct',8.5),
      'internal-demo-budget-overrun-52', 'demo',
      1, 'PO 4500087231',
      jsonb_build_object(
        'systemName','SAP S/4HANA Finance','systemCode','sap_s4_finance','systemKind','finance',
        'recordType','Purchase Order / WBS element','recordId','PO 4500087231',
        'recordUrl','https://s4hana-finance.adnoc.ae/record/PO-4500087231',
        'capturedAt', now(),
        'fields', jsonb_build_array(
          jsonb_build_object('label','Approved budget','value','AED 4,220,000,000'),
          jsonb_build_object('label','Committed to date','value','AED 4,578,700,000'),
          jsonb_build_object('label','Variance','value','+8.5% (AED 358,700,000)'),
          jsonb_build_object('label','Cost center','value','CC-OFF-238-DRILL'),
          jsonb_build_object('label','WBS element','value','C-52-CAPEX-JACKUP')
        )),
      '{}'::jsonb, v_admin, v_admin,
      'internal:budget-overrun-52', 'commodity_prices', 'internal:harness', 'high',
      'Budget Overrun — Jack-Up Drilling Rigs committed cost +8.5%', now()::date
    ) RETURNING id INTO v_sig;

    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id, rule_version_hash, confidence,
      match_reason, match_evidence, match_geographies, match_entities, status,
      data_classification, created_by, updated_by
    ) VALUES (
      v_tenant, v_sig, 52, 'rule.internal.budget_overrun', 'v1-internal-demo', 0.92,
      'Committed cost AED 4.579B exceeds approved budget AED 4.220B by 8.5% (SAP S/4HANA Finance PO 4500087231)',
      '{}'::jsonb, '[]'::jsonb, '[]'::jsonb, v_corr_status, v_corr_dc, v_admin, v_admin
    ) RETURNING id INTO v_corr;

    INSERT INTO risk_case (
      tenant_id, correlation_id, contract_id, case_type, priority, title, body,
      assigned_role, assigned_user_id, status, sla_hours, due_at, dedupe_key,
      metadata, data_classification, created_by, updated_by
    ) VALUES (
      v_tenant, v_corr, 52, 'correlation_alert', 'high',
      'Budget overrun — committed cost 8.5% over approved budget on Jack-Up Drilling Rigs',
      'SAP S/4HANA Finance reports committed cost of AED 4.579B against an approved budget of AED 4.220B — a +8.5% (AED 358.7M) overrun on the offshore jack-up drilling programme. Confirm as a finance risk or dismiss as noise.',
      'finance_treasury', NULL, 'open', 48, now() + interval '48 hours',
      'internal-demo-budget-overrun-52',
      jsonb_build_object('confidence',0.92,'materialityAed',358700000,'tier',2,
        'suppressedReason','Single-source (SAP) — confidence below Finance auto-route floor; exec confirmation requested.'),
      'internal', v_admin, v_admin
    );
  END IF;

  -- ===== Case 2 — Milestone slippage → Oracle Primavera P6 (contract 77) =====
  IF NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'internal-demo-milestone-slippage-77') THEN
    INSERT INTO osint_signal (
      tenant_id, osint_source_id, source_id, source_reliability, fetched_at, event_date_v2,
      kind, signal_kind_subtype, title, summary, geographies, affected_entities,
      severity_v2, confidence, url, raw_payload, dedup_hash, data_classification,
      internal_system_id, source_record_ref, source_record_snapshot, metadata,
      created_by, updated_by, ext_id, category, source, severity, title_en, published_date
    ) VALUES (
      v_tenant, 15, 'internal:harness', 1.00, now(), now(),
      'internal', 'milestone_slippage',
      'Milestone Slippage — EPC Crude Stabilization critical activity +21d',
      'Oracle Primavera P6: a critical-path activity is forecast 21 days behind baseline.',
      '[]'::jsonb, '[]'::jsonb, 'high', 1.00,
      'https://p6.adnoc.ae/record/A1340',
      jsonb_build_object('contractId',77,'milestoneRef','A1340','daysOverdue',21),
      'internal-demo-milestone-slippage-77', 'demo',
      6, 'A1340',
      jsonb_build_object(
        'systemName','Oracle Primavera P6','systemCode','primavera_p6','systemKind','scm',
        'recordType','Schedule activity','recordId','A1340 — Mechanical Completion',
        'recordUrl','https://p6.adnoc.ae/record/A1340',
        'capturedAt', now(),
        'fields', jsonb_build_array(
          jsonb_build_object('label','Activity ID','value','A1340 — Mechanical Completion'),
          jsonb_build_object('label','Baseline finish','value','2026-04-30'),
          jsonb_build_object('label','Forecast finish','value','2026-05-21'),
          jsonb_build_object('label','Days slipped','value','21 days'),
          jsonb_build_object('label','On critical path','value','Yes')
        )),
      '{}'::jsonb, v_admin, v_admin,
      'internal:milestone-slippage-77', 'supply_chain', 'internal:harness', 'high',
      'Milestone Slippage — EPC Crude Stabilization critical activity +21d', now()::date
    ) RETURNING id INTO v_sig;

    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id, rule_version_hash, confidence,
      match_reason, match_evidence, match_geographies, match_entities, status,
      data_classification, created_by, updated_by
    ) VALUES (
      v_tenant, v_sig, 77, 'rule.internal.milestone_slippage', 'v1-internal-demo', 0.88,
      'Critical-path activity A1340 forecast 21 days behind baseline finish (Oracle Primavera P6)',
      '{}'::jsonb, '[]'::jsonb, '[]'::jsonb, v_corr_status, v_corr_dc, v_admin, v_admin
    ) RETURNING id INTO v_corr;

    INSERT INTO risk_case (
      tenant_id, correlation_id, contract_id, case_type, priority, title, body,
      assigned_role, assigned_user_id, status, sla_hours, due_at, dedupe_key,
      metadata, data_classification, created_by, updated_by
    ) VALUES (
      v_tenant, v_corr, 77, 'correlation_alert', 'high',
      'Milestone slippage — critical-path activity 21 days behind baseline on EPC Crude Stabilization',
      'Oracle Primavera P6 shows critical-path activity A1340 (Mechanical Completion) forecast to finish 21 days after its baseline date — exposing the contract to liquidated-damages. Confirm as an operations risk or dismiss as noise.',
      'operations', NULL, 'open', 48, now() + interval '48 hours',
      'internal-demo-milestone-slippage-77',
      jsonb_build_object('confidence',0.88,'materialityAed',95000000,'tier',2,
        'suppressedReason','Forecast (not actual) slippage — exec confirmation requested before paging Operations.'),
      'internal', v_admin, v_admin
    );
  END IF;

  -- ===== Case 3 — SLA breach → ServiceNow ITSM (contract 243) =====
  IF NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'internal-demo-sla-breach-243') THEN
    INSERT INTO osint_signal (
      tenant_id, osint_source_id, source_id, source_reliability, fetched_at, event_date_v2,
      kind, signal_kind_subtype, title, summary, geographies, affected_entities,
      severity_v2, confidence, url, raw_payload, dedup_hash, data_classification,
      internal_system_id, source_record_ref, source_record_snapshot, metadata,
      created_by, updated_by, ext_id, category, source, severity, title_en, published_date
    ) VALUES (
      v_tenant, 15, 'internal:harness', 1.00, now(), now(),
      'internal', 'sla_breach',
      'SLA Breach — Gas dispatch scheduling API incident +11h',
      'ServiceNow ITSM: a P2 incident resolution exceeded the contractual SLA target.',
      '[]'::jsonb, '[]'::jsonb, 'medium', 1.00,
      'https://adnoc.service-now.com/record/INC0048921',
      jsonb_build_object('contractId',243,'ticketRef','INC0048921'),
      'internal-demo-sla-breach-243', 'demo',
      5, 'INC0048921',
      jsonb_build_object(
        'systemName','ServiceNow ITSM','systemCode','servicenow_itsm','systemKind','itsm',
        'recordType','Incident','recordId','INC0048921',
        'recordUrl','https://adnoc.service-now.com/record/INC0048921',
        'capturedAt', now(),
        'fields', jsonb_build_array(
          jsonb_build_object('label','Incident #','value','INC0048921'),
          jsonb_build_object('label','SLA target','value','Resolve within 8h (P2)'),
          jsonb_build_object('label','Actual resolution','value','19h 42m'),
          jsonb_build_object('label','Breach','value','+11h 42m over target'),
          jsonb_build_object('label','Service','value','Gas dispatch scheduling API')
        )),
      '{}'::jsonb, v_admin, v_admin,
      'internal:sla-breach-243', 'supply_chain', 'internal:harness', 'medium',
      'SLA Breach — Gas dispatch scheduling API incident +11h', now()::date
    ) RETURNING id INTO v_sig;

    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id, rule_version_hash, confidence,
      match_reason, match_evidence, match_geographies, match_entities, status,
      data_classification, created_by, updated_by
    ) VALUES (
      v_tenant, v_sig, 243, 'rule.internal.sla_breach', 'v1-internal-demo', 0.83,
      'Incident INC0048921 resolved in 19h 42m against an 8h P2 SLA target — 11h 42m breach (ServiceNow ITSM)',
      '{}'::jsonb, '[]'::jsonb, '[]'::jsonb, v_corr_status, v_corr_dc, v_admin, v_admin
    ) RETURNING id INTO v_corr;

    INSERT INTO risk_case (
      tenant_id, correlation_id, contract_id, case_type, priority, title, body,
      assigned_role, assigned_user_id, status, sla_hours, due_at, dedupe_key,
      metadata, data_classification, created_by, updated_by
    ) VALUES (
      v_tenant, v_corr, 243, 'sla_breach', 'medium',
      'SLA breach — incident resolution exceeded contractual target by 11h',
      'ServiceNow incident INC0048921 (Gas dispatch scheduling API) took 19h 42m to resolve against the 8-hour P2 SLA in the Gas SPA — an 11h 42m breach. Confirm as an operations risk or dismiss as noise.',
      'operations', NULL, 'open', 48, now() + interval '48 hours',
      'internal-demo-sla-breach-243',
      jsonb_build_object('confidence',0.83,'materialityAed',12000000,'tier',2,
        'suppressedReason','First breach in window — exec confirmation requested before raising a formal case.'),
      'internal', v_admin, v_admin
    );
  END IF;

  RAISE NOTICE '690 internal triage seed complete';
END
$seed$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (690, 'internal risk origin + source_record_snapshot + 3 internal Tier-2 triage cases', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK (manual)
-- ============================================================================
-- BEGIN;
-- DELETE FROM risk_case WHERE dedupe_key IN ('internal-demo-budget-overrun-52','internal-demo-milestone-slippage-77','internal-demo-sla-breach-243');
-- DELETE FROM correlation WHERE rule_id IN ('rule.internal.budget_overrun','rule.internal.milestone_slippage','rule.internal.sla_breach') AND rule_version_hash='v1-internal-demo';
-- DELETE FROM osint_signal WHERE dedup_hash IN ('internal-demo-budget-overrun-52','internal-demo-milestone-slippage-77','internal-demo-sla-breach-243');
-- -- restore fn bodies from migrations 663 (review/tier1), 548 (list), 656 (get_by_id)
-- ALTER TABLE osint_signal DROP COLUMN IF EXISTS source_record_snapshot;
-- -- (budget_overrun stays in the kind CHECK; harmless)
-- DELETE FROM schema_migrations WHERE version = 690;
-- COMMIT;
-- ============================================================================
