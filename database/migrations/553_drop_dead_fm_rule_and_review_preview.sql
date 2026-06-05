-- MIGRATION: 553_drop_dead_fm_rule_and_review_preview.sql
-- Date: 2026-06-04
-- Description:
--   Two coupled changes:
--
--   1) Drop the dead force-majeure → Legal Counsel rule (order 30).
--
--      fn_risk_case_classify_and_route walks rules in ASC rule_order
--      and stops at the first match. Rule 20 (FM → Operations, 4h) and
--      Rule 30 (FM → Legal Counsel, 8h) shared the same predicate, so
--      rule 30 was dead config — never fires. Soft-delete it. Legal
--      Counsel still sees FM cases via the visibility map
--      (system_setting.risk_case_visibility_map) and can self-claim
--      from the queue if they want a parallel review.
--
--      Reversible: UPDATE risk_routing_rule SET is_active=TRUE
--      WHERE rule_order=30.
--
--   2) Extend fn_risk_review_list with a routing preview.
--
--      The Risk Review page now shows a "Confirm risk" modal that needs
--      to display the role each Tier 2 case WOULD be assigned to if
--      promoted. Rather than have the FE re-implement the matrix walk,
--      we add three columns to the per-row payload:
--        - previewRole        — assigned_role from the would-match rule
--        - previewRoleDisplay — humanised label (e.g. "Compliance & ESG")
--        - previewSlaHours    — SLA from the matched rule
--      Computed via a LATERAL subquery against risk_routing_rule using
--      the SAME first-match logic the actual classifier uses, so the
--      preview shown in the modal exactly matches what fn_risk_review_
--      promote will produce.

BEGIN;

-- 1. Soft-delete the dead FM Legal Counsel rule -----------------------

UPDATE risk_routing_rule
   SET is_active = FALSE,
       description = description || ' [disabled 2026-06-04: dead under first-match-wins; legal counsel sees FM cases via visibility map]',
       updated_at = CURRENT_TIMESTAMP
 WHERE rule_order = 30
   AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
   AND is_active = TRUE
   AND risk_type = 'force_majeure'
   AND assigned_role = 'legal_counsel';

-- 2. Extend fn_risk_review_list with previewRole / previewSlaHours ----

CREATE OR REPLACE FUNCTION public.fn_risk_review_list(p_limit integer DEFAULT 10)
 RETURNS jsonb
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
             -- Routing preview — first matching rule, lowest order wins.
             -- Identical predicate logic to fn_risk_case_classify_and_route
             -- so the modal shows exactly what promote would produce.
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
              AND (rc.metadata->>'tier')::int = 2
              AND rc.status IN ('open','in_review')
            ORDER BY impact_score DESC, rc.id ASC
            LIMIT p_limit
         ) x),
      '[]'::jsonb
    )
  );
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (553, 'drop_dead_fm_rule_and_review_preview', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
