-- ============================================================================
-- Migration 662 — Assigned Work shows only person-assigned risk cases
-- ============================================================================
-- Final piece of the clean state rule: a case appears in the executive's
-- Assigned Work surface only when a real person is on the hook. Rows
-- with assigned_user_id IS NULL belong in Risk Triage (mig 661), not here.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_risk_case_list_assigned_by_actor(
  p_actor_id BIGINT,
  p_limit    INTEGER DEFAULT 25
) RETURNS JSONB
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
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'actorId is required' USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_build_object(
    'asOf', CURRENT_TIMESTAMP,
    'rows', COALESCE(
      (SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.action_at DESC NULLS LAST, x.id ASC)
         FROM (
           SELECT
             rc.id::text                                                AS id,
             rc.title                                                   AS title,
             rc.status                                                  AS status,
             rc.priority                                                AS priority,
             fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                              rc.title, rc.assigned_role, rc.case_type) AS risk_type,
             rc.assigned_role                                           AS assigned_role,
             rc.assigned_user_id::text                                  AS assigned_user_id,
             TRIM(CONCAT_WS(' ', u.first_name, u.last_name))            AS assigned_user_name,
             c.contract_number                                          AS contract_number,
             COALESCE(c.title_en, c.title_ar)                           AS contract_title,
             cp.name_en                                                 AS counterparty_name,
             rc.created_at                                              AS created_at,
             COALESCE(
               (rc.metadata->>'lastReassignedAt')::timestamptz,
               (rc.metadata->>'promotedFromTier2At')::timestamptz,
               rc.created_at
             )                                                          AS action_at,
             CASE
               WHEN (rc.metadata->>'lastReassignedBy')::bigint = p_actor_id
                 THEN 'reassigned'
               WHEN (rc.metadata->>'promotedBy')::bigint = p_actor_id
                 THEN 'promoted'
               WHEN rc.created_by = p_actor_id
                 THEN 'created'
               ELSE 'other'
             END                                                        AS action_kind
             FROM risk_case rc
             LEFT JOIN "user"   u  ON u.id  = rc.assigned_user_id
             LEFT JOIN contract c  ON c.id  = rc.contract_id
             LEFT JOIN party    cp ON cp.id = c.counterparty_id
            WHERE rc.is_active = TRUE
              AND rc.tenant_id = v_tenant_id
              -- mig 662: a case appears in Assigned Work only when a real
              -- person owns it. Unassigned cases live in Risk Triage.
              AND rc.assigned_user_id IS NOT NULL
              AND (
                (rc.metadata->>'lastReassignedBy')::bigint = p_actor_id
                OR (rc.metadata->>'promotedBy')::bigint    = p_actor_id
                OR rc.created_by = p_actor_id
              )
            ORDER BY action_at DESC NULLS LAST, rc.id DESC
            LIMIT p_limit
         ) x),
      '[]'::jsonb
    )
  );
END;
$function$;

COMMENT ON FUNCTION public.fn_risk_case_list_assigned_by_actor(BIGINT, INTEGER) IS
  'mig 662 — Assigned Work source. Only returns risk cases where the actor '
  'pinned a specific person (assigned_user_id IS NOT NULL). Unassigned '
  'cases live in Risk Triage Tier-2 (mig 661).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (662, 'fn_risk_case_list_assigned_by_actor_requires_user', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
