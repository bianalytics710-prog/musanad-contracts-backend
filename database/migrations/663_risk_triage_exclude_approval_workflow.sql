-- ============================================================================
-- Migration 663 — Risk Triage excludes approval-workflow rows
-- ============================================================================
-- WHY: After mig 661 relaxed the Tier-2 filter to "any unassigned case",
-- the executive's Risk Triage queue started showing approval-workflow
-- rows (case_type='sla_breach'/'manual' with risk_type='approval_workflow'):
--   - "Crescent Petroleum — approval SLA at 4 days · review or delegate"
--   - "Microsoft Azure Subscription MSA — approval cycle review"
--   - "IBM Watson AI SOW — Stage-2 approver assignment pending"
--
-- Those are operational delays in the contracts pipeline — symptoms of
-- process friction, NOT external risk signals. They already have a home
-- in the Approvals module + drafter / approver dashboards where the
-- actor can actually do something about them (delegate, reassign, nudge).
-- Showing them in Risk Triage:
--   1. Wrong audience — exec shouldn't filter out workflow noise to find
--      sanctions / FM / ESG signals.
--   2. Wrong actions — promote-with-person dropdown can't meaningfully
--      "route an approval delay to a specialist team".
--   3. Pollutes the queue — 3 of 12 Tier-2 rows were approval-workflow,
--      stealing 25% of executive attention.
--
-- WHAT: exclude risk_type='approval_workflow' from fn_risk_review_list
-- (Tier-2 tab) and fn_risk_triage_tier1_list (Tier-1 tab) so the
-- workflow rows stay only in their natural home, the Approvals page.
--
-- WHAT it does NOT do:
--   - Doesn't delete the risk_case rows; they remain in risk_case and
--     are still visible in /app/risk-cases (the canonical list) under
--     their proper risk_type='approval_workflow' badge.
--   - Doesn't touch fn_classify_risk — the taxonomy stays intact.
--   - Doesn't filter approval-workflow rows out of fn_my_work_list_v2;
--     receivers (approvers) still see their assigned cases in My Work.
-- ============================================================================

BEGIN;

-- ─── fn_risk_review_list ──────────────────────────────────────────────
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
              -- mig 663: approval-workflow cases live in the Approvals
              -- module, not Risk Triage. Exclude here so the executive
              -- queue stays focused on substantive business risk.
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

-- ─── fn_risk_triage_tier1_list ────────────────────────────────────────
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
              -- mig 663: same exclusion as the Tier-2 fn — workflow
              -- delays don't belong in the executive oversight tab.
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

COMMENT ON FUNCTION public.fn_risk_review_list(integer) IS
  'mig 663 — Risk Triage Tier-2 tab. Filters: assigned_user_id IS NULL + '
  'status IN (open, in_review) + risk_type <> approval_workflow.';
COMMENT ON FUNCTION public.fn_risk_triage_tier1_list(INTEGER) IS
  'mig 663 — Risk Triage Tier-1 tab. Filters: assigned_user_id IS NOT NULL '
  '+ status=open + tier=1 + risk_type <> approval_workflow.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (663, 'risk_triage_exclude_approval_workflow', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
