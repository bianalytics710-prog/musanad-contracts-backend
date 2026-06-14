-- ============================================================================
-- Migration 658 — fn_risk_case_list_assigned_by_actor (Gap 3)
-- ============================================================================
-- WHY: today the executive's "Assigned Work" page (AssignedByMeView) only
-- reads work_order outbox rows. The Phase E promote-with-user + reassign
-- actions stamp metadata.promotedBy / metadata.lastReassignedBy on the
-- risk_case row but nothing surfaces them, so Eman has no reverse-view
-- of risk routing she initiated.
--
-- WHAT: a new STABLE INVOKER fn that returns the recent set of risk cases
-- whose routing the actor initiated. Three pathways count as "she
-- assigned it":
--   1. She promoted a Tier-2 case (metadata.promotedBy = actor)
--   2. She reassigned a Tier-1 case (metadata.lastReassignedBy = actor)
--   3. She created the case manually (created_by = actor) — covers
--      future flows where the executive opens a case directly.
--
-- Per-row payload includes: current owner display, current status, the
-- timestamp of the most recent assignment action, and which action it was.
-- Ordering is by most-recent assignment action DESC so the freshly-routed
-- row sits on top.
--
-- Permission gate: risk.review.manage (same as the Phase E surfaces). RLS
-- on risk_case handles tenant scoping; this fn is INVOKER so the GUC
-- tenant context applies.
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
             -- Pick the most-recent action timestamp + its kind.
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

REVOKE ALL ON FUNCTION public.fn_risk_case_list_assigned_by_actor(BIGINT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_case_list_assigned_by_actor(BIGINT, INTEGER) TO neondb_owner;

COMMENT ON FUNCTION public.fn_risk_case_list_assigned_by_actor(BIGINT, INTEGER) IS
  'mig 658 (Gap 3 closure). Returns risk cases whose routing the actor '
  'initiated — promoted (Tier-2→Tier-1), reassigned (Tier-1→other user), '
  'or created. Powers AssignedByMeView reverse-view for the executive.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (658, 'fn_risk_case_list_assigned_by_actor', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
