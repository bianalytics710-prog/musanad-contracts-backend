-- ============================================================================
-- Migration 650 — Phase E.3: fn_risk_triage_tier1_list(p_limit)
-- ============================================================================
-- WHY: per locked decision E-Q1, Risk Triage grows a second tab showing
-- Tier-1 cases the engine auto-routed without executive judgement. The
-- executive needs oversight on those rows too — to override the receiver
-- (reassign) or to close noise the engine couldn't tell from real signal
-- (dismiss-as-noise).
--
-- WHAT: returns active Tier-1 cases (auto-routed: has assigned_role AND
-- assigned_user_id IS NOT NULL → engine picked an owner via the routing
-- matrix). Same envelope as fn_risk_review_list so the FE can render
-- through the same row component with minimal forking. Adds an
-- assignee_user_id / _name / _role display block so the executive sees
-- who currently owns each row.
--
-- Permission gate: risk.review.manage.
-- ============================================================================

BEGIN;

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
            ORDER BY rc.created_at DESC, rc.id ASC
            LIMIT p_limit
         ) x),
      '[]'::jsonb
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_triage_tier1_list(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_triage_tier1_list(INTEGER) TO neondb_owner;

COMMENT ON FUNCTION public.fn_risk_triage_tier1_list(INTEGER) IS
  'Phase E.3 (mig 650). Returns auto-routed Tier-1 cases (status=open + '
  'assigned_role + assigned_user_id) for executive oversight in Risk Triage. '
  'Same envelope as fn_risk_review_list; adds assignee display fields. Gated '
  'by risk.review.manage.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (650, 'fn_risk_triage_tier1_list', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
