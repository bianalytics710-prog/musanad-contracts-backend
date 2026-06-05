-- MIGRATION: 544_classify_risk_taxonomy.sql
-- Date: 2026-06-04
-- Description:
--   Introduces a unified, rule-based risk taxonomy across the platform.
--   Today the Critical Impact frame on the executive dashboard and the
--   Risk Cases module both rely on free-text titles (hand-curated demo
--   copy for internal:harness rows, raw RSS article titles for ingested
--   ones, analyst free-text for manual risk_cases). That works for the
--   demo but doesn't scale: a real production stream would surface noisy
--   titles, and the existing "case_type" column tells you HOW the case
--   was opened (correlation_alert / manual / sla_breach) — not WHAT kind
--   of risk it is.
--
--   This migration ships a SINGLE classifier — fn_classify_risk — that
--   maps the structured fields we already have (category, kind, subtype,
--   source, affected_clause_categories, title, assigned_role, case_type)
--   onto a fixed 12-type taxonomy + "other" fallback. The same fn is
--   used from both surfaces so the labels stay consistent.
--
--   Taxonomy (slug → match rule, first hit wins):
--     force_majeure          Force Majeure Event
--     sanctions              Sanctions Exposure
--     sla_breach             SLA / Performance Breach
--     approval_workflow      Approval / Workflow Risk
--     budget_overrun         Budget Overrun
--     counterparty_concentration  Counterparty Concentration
--     vendor_supplier        Vendor / Supplier Risk
--     icv_local_content      ICV / Local Content Gap
--     esg_sustainability     ESG / Sustainability Risk
--     commodity_price        Commodity / Price Risk
--     regulatory_change      Regulatory Change
--     geopolitical           Geopolitical Risk
--     other                  fallback when no rule matches
--
-- Surface updates (no API change — additive `riskType` field only):
--   - fn_dashboard_executive_critical_impacts: each row gains `riskType`.
--   - fn_risk_case_list: each list item gains `riskType`.
--   - fn_risk_case_get_by_id: the riskCase object gains `riskType`.
--
-- Caller contract:
--   For osint_signal rows, pass (category, kind, subtype, source,
--   clause_categories, title, NULL, NULL).
--   For risk_case rows, pass (NULL, NULL, NULL, NULL, NULL, title,
--   assigned_role, case_type).
--   All parameters are nullable so partial-row callers can leave the
--   irrelevant ones as NULL.

BEGIN;

-- 1. Classifier helper -------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_classify_risk(
  p_category           text,
  p_kind               text,
  p_subtype            text,
  p_source             text,
  p_clause_categories  text[],
  p_title              text,
  p_assigned_role      text,
  p_case_type          text
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  t  TEXT := COALESCE(p_title, '');
  cc TEXT[] := COALESCE(p_clause_categories, ARRAY[]::text[]);
BEGIN
  -- 1. Force Majeure Event
  IF 'force_majeure' = ANY(cc)
     OR p_subtype IN ('cyclone_warning','ics_incident','routing_disruption')
     OR p_kind = 'weather'
     OR t ~* '\m(force majeure|fm clause|hormuz routing|hormuz.*fm)\M' THEN
    RETURN 'force_majeure';
  END IF;

  -- 2. Sanctions Exposure
  IF t ~* '\m(ofac|sanction|sanctions)\M'
     OR p_subtype ILIKE '%sanction%' THEN
    RETURN 'sanctions';
  END IF;

  -- 3. ICV / Local Content Gap   (checked early — "ICV" should not
  --    be swallowed by the SLA / counterparty rules below)
  IF t ~* '\m(icv|in-country value|local content)\M' THEN
    RETURN 'icv_local_content';
  END IF;

  -- 4. ESG / Sustainability Risk
  IF (p_assigned_role = 'compliance_esg'
        AND t ~* '\m(esg|water[- ]stress|emissions|sustainab|environmental)\M')
     OR t ~* '\m(esg concern memo|sustainability)\M' THEN
    RETURN 'esg_sustainability';
  END IF;

  -- 5. Budget Overrun
  IF t ~* '\m(budget breach|budget overrun|over budget|projected.{0,40}year[- ]end)\M' THEN
    RETURN 'budget_overrun';
  END IF;

  -- 6. Counterparty Concentration
  IF t ~* '\m(concentration|single[- ]contract.{0,30}exposure|exposure[^a-z0-9]{0,5}>\s*\d{1,2}\s*%)\M' THEN
    RETURN 'counterparty_concentration';
  END IF;

  -- 7. Approval / Workflow Risk
  IF (p_case_type = 'sla_breach' AND p_assigned_role = 'contract_approver')
     OR t ~* '\m(approval cycle|approver assignment|stage[- ]?\d.{0,30}assignment)\M' THEN
    RETURN 'approval_workflow';
  END IF;

  -- 8. SLA / Performance Breach
  IF p_case_type = 'sla_breach'
     OR p_subtype IN ('sla_breach','milestone_slippage')
     OR t ~* '\m(milestone slippage|uptime miss|demurrage|day[- ]rate|ceiling exceeded|scorecard refresh stalled|uptime)\M' THEN
    RETURN 'sla_breach';
  END IF;

  -- 9. Vendor / Supplier Risk
  IF (p_assigned_role = 'procurement_supplier_risk'
        AND t ~* '\m(scorecard|credit.{0,15}downgrade|sub[- ]tier|supplier|vendor)\M')
     OR p_subtype = 'vendor_incident' THEN
    RETURN 'vendor_supplier';
  END IF;

  -- 10. Commodity / Price Risk
  IF p_category = 'commodity_prices'
     OR p_source IN ('commodity_feed','fx_feed','commodity_crude','fx_usd_aed')
     OR t ~* '\m(crude.{0,20}band|price review trigger|brent.{0,20}band)\M' THEN
    RETURN 'commodity_price';
  END IF;

  -- 11. Regulatory Change
  IF p_category = 'regulatory'
     OR p_source IN ('mohre_labor','ncm_uae')
     OR t ~* '\m(decree[- ]law|federal decree|regulator|schedule annex refresh)\M' THEN
    RETURN 'regulatory_change';
  END IF;

  -- 12. Geopolitical Risk
  IF p_category = 'geopolitical' THEN
    RETURN 'geopolitical';
  END IF;

  RETURN 'other';
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_classify_risk(text,text,text,text,text[],text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_classify_risk(text,text,text,text,text[],text,text,text) TO neondb_owner;

COMMENT ON FUNCTION public.fn_classify_risk(text,text,text,text,text[],text,text,text) IS
  'Rule-based classifier mapping signal/risk_case fields onto a 12-type risk taxonomy + ''other'' fallback. '
  'Single source of truth for both fn_dashboard_executive_critical_impacts and fn_risk_case_list.';

-- 2. Update fn_dashboard_executive_critical_impacts --------------------
--
-- Same body as 543, with riskType added inside the jsonb_build_object
-- output. Sort order unchanged.

CREATE OR REPLACE FUNCTION public.fn_dashboard_executive_critical_impacts(
  p_window_days integer DEFAULT 7
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_role     TEXT;
  v_user_id  BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  v_rows     JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive_critical_impacts: unauthorized'
      USING ERRCODE = '42501';
  END IF;

  IF p_window_days < 1 OR p_window_days > 90 THEN
    RAISE EXCEPTION 'fn_dashboard_executive_critical_impacts: windowDays must be 1..90'
      USING ERRCODE = '22023';
  END IF;

  SELECT r.name INTO v_role
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = v_user_id;

  IF v_role NOT IN ('executive', 'platform_admin', 'Super Admin')
     AND NOT fn_current_user_has_permission('insights.executive') THEN
    RAISE EXCEPTION 'fn_dashboard_executive_critical_impacts: forbidden'
      USING ERRCODE = '42501';
  END IF;

  WITH
  signal_rows AS (
    SELECT
      'impact_signal'::text                                AS kind,
      s.id::text                                           AS id,
      COALESCE(s.title_en, s.title, '(untitled signal)')   AS title,
      COALESCE(s.description_en, s.summary)                AS description,
      s.severity                                           AS criticality,
      (s.published_date::timestamptz)                      AS occurred_at,
      s.source                                             AS source,
      s.url                                                AS source_url,
      s.category                                           AS category,
      fn_classify_risk(
        s.category, s.kind, s.signal_kind_subtype, s.source,
        s.affected_clause_categories, COALESCE(s.title_en, s.title),
        NULL, NULL
      )                                                    AS risk_type,
      COALESCE(
        (SELECT jsonb_agg(jsonb_build_object(
            'id',               c.id::text,
            'contractNumber',   c.contract_number,
            'titleEn',          c.title_en,
            'valueAed',         c.value_aed,
            'currency',         c.currency,
            'counterpartyName', cp.name_en
          ) ORDER BY c.value_aed DESC NULLS LAST, c.id ASC)
         FROM impact_signal_contract isc
         JOIN contract c ON c.id = isc.contract_id AND c.is_active = TRUE
         LEFT JOIN party cp ON cp.id = c.counterparty_id
         WHERE isc.signal_id = s.id AND isc.is_active = TRUE),
        '[]'::jsonb
      )                                                    AS contracts
    FROM osint_signal s
    WHERE s.is_active = TRUE
      AND s.severity = 'critical'
      AND s.published_date >= CURRENT_DATE - (p_window_days || ' days')::interval
  ),
  case_rows AS (
    SELECT
      'risk_case'::text                                    AS kind,
      rc.id::text                                          AS id,
      rc.title                                             AS title,
      LEFT(COALESCE(rc.body, ''), 600)                     AS description,
      rc.priority                                          AS criticality,
      rc.created_at                                        AS occurred_at,
      COALESCE(rc.case_type, 'manual')                     AS source,
      NULL::text                                           AS source_url,
      'risk_case'::text                                    AS category,
      fn_classify_risk(
        NULL, NULL, NULL, NULL, NULL,
        rc.title, rc.assigned_role, rc.case_type
      )                                                    AS risk_type,
      CASE
        WHEN rc.contract_id IS NULL THEN '[]'::jsonb
        ELSE COALESCE(
          (SELECT jsonb_build_array(jsonb_build_object(
              'id',               c.id::text,
              'contractNumber',   c.contract_number,
              'titleEn',          c.title_en,
              'valueAed',         c.value_aed,
              'currency',         c.currency,
              'counterpartyName', cp.name_en
            ))
           FROM contract c
           LEFT JOIN party cp ON cp.id = c.counterparty_id
           WHERE c.id = rc.contract_id AND c.is_active = TRUE),
          '[]'::jsonb)
      END                                                  AS contracts
    FROM risk_case rc
    WHERE rc.is_active = TRUE
      AND rc.priority  = 'critical'
      AND rc.status NOT IN ('closed','resolved','accepted_risk','dismissed')
      AND rc.created_at >= CURRENT_TIMESTAMP - (p_window_days || ' days')::interval
  ),
  merged AS (
    SELECT * FROM signal_rows
    UNION ALL
    SELECT * FROM case_rows
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'kind',               m.kind,
      'id',                 m.id,
      'title',              m.title,
      'description',        m.description,
      'criticality',        m.criticality,
      'occurredAt',         m.occurred_at,
      'source',             m.source,
      'sourceUrl',          m.source_url,
      'category',           m.category,
      'riskType',           m.risk_type,
      'contractsAffected',  jsonb_array_length(m.contracts),
      'contracts',          m.contracts
    ) ORDER BY m.occurred_at DESC, m.id DESC
  ), '[]'::jsonb)
  INTO v_rows
  FROM merged m;

  RETURN jsonb_build_object(
    'windowDays', p_window_days,
    'asOf',       CURRENT_TIMESTAMP,
    'rows',       v_rows
  );
END;
$function$;

-- 3. Update fn_risk_case_list ------------------------------------------
--
-- Same shape as before — just adds `riskType` inside the per-row JSONB.

CREATE OR REPLACE FUNCTION public.fn_risk_case_list(
  p_actor_id              bigint,
  p_status                text DEFAULT NULL,
  p_priority              text DEFAULT NULL,
  p_assigned_to_me        boolean DEFAULT false,
  p_sla_due_within_hours  integer DEFAULT NULL,
  p_case_type             text DEFAULT NULL,
  p_search                text DEFAULT NULL,
  p_page                  integer DEFAULT 1,
  p_limit                 integer DEFAULT 20
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
      'contractTitle', (SELECT COALESCE(c.title_en, c.title_ar)
                          FROM contract c WHERE c.id = p.contract_id),
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

-- 4. Update fn_risk_case_get_by_id -------------------------------------
--
-- Adds `riskType` inside the `riskCase` nested object so the detail page
-- can render the same pill.

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

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (544, 'classify_risk_taxonomy', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
