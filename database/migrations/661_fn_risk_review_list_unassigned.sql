-- ============================================================================
-- Migration 661 — fn_risk_review_list catches every unassigned case
-- ============================================================================
-- Reinforces the clean state rule: any case without a person owner shows
-- in the Risk Triage Tier-2 tab, regardless of how it got that state.
--
-- Previously the filter was `metadata.tier=2` which only matched cases the
-- auto-create path explicitly tagged. Cases that landed in the in-between
-- state (role-routed but no user, e.g. a buggy promote, an executive
-- reset, a manual create) had `metadata.tier` undefined and fell between
-- the cracks — invisible in Tier-2 AND filtered out of Tier-1 (which
-- requires assigned_user_id IS NOT NULL).
--
-- New filter: `rc.assigned_user_id IS NULL AND status IN ('open','in_review')`.
-- Single source of truth for "unassigned" cases.
--
-- Bonus: previewRole + previewSlaHours preserved from mig 553 so the
-- confirm-risk modal's role label still resolves correctly. The
-- materialityAed × confidence impact_score also stays so the queue
-- ordering doesn't change.
-- ============================================================================

BEGIN;

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
              -- mig 661: catch ANY unassigned case, not just metadata.tier=2.
              -- A case is "unassigned" iff no person owns it. Whether the
              -- engine auto-routed to a role, the executive promoted without
              -- picking a user (now blocked by mig 660 going forward), or a
              -- manual reset put it back here — they all surface here.
              AND rc.assigned_user_id IS NULL
              AND rc.status IN ('open','in_review')
            ORDER BY impact_score DESC, rc.id ASC
            LIMIT p_limit
         ) x),
      '[]'::jsonb
    )
  );
END;
$function$;

COMMENT ON FUNCTION public.fn_risk_review_list(integer) IS
  'mig 661 — Risk Triage Tier-2 / "needs your judgment" tab. Filter is now '
  'assigned_user_id IS NULL — single source of truth for unassigned cases. '
  'Pairs with mig 660 which makes role-only promotes impossible, and mig '
  '662 which keeps Assigned Work clean of unassigned rows.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (661, 'fn_risk_review_list_unassigned', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
