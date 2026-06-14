-- ============================================================================
-- Migration 665 — fn_risk_review_promote accepts a user from any role
-- ============================================================================
-- WHY: the previous version (mig 660 / 664) enforced that the picked user's
-- role must match the routing matrix's resolved role. This made sense when
-- promote was thought of as "pick a person inside the routed team", but
-- for the executive demo we want the dropdown to span all personas (Legal
-- Counsel, Approver, Drafter, etc.) so a borderline case can be routed
-- wherever the executive thinks fit — not where the engine guessed.
--
-- WHAT changes:
--   - The defensive `v_user_role = v_resolved_role` check is dropped.
--   - assigned_role is set to the picked user's role (was: kept at the
--     routed role). This guarantees the no-orphan invariant
--     (status='open' implies assigned_role IS NOT NULL) stays satisfied
--     when the user belongs to a role different from what the engine
--     resolved.
--   - The SLA and due_at remain whatever fn_risk_case_classify_and_route
--     set during stage 2 — the rule's SLA is the "correct" risk-class
--     SLA regardless of who Eman picked as owner.
--   - The 'assigned' timeline event payload's `role` field now reflects
--     the picked user's role so the FE renders "Assigned to {user role}
--     ({user name})" honestly.
--
-- Other guards preserved:
--   - p_assigned_user_id NOT NULL (mig 660) — promote still requires a
--     person.
--   - User must be is_active = TRUE.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_risk_review_promote(
  p_case_id           BIGINT,
  p_actor_id          BIGINT,
  p_assigned_user_id  BIGINT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant_id      UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_case           RECORD;
  v_resolved_role  TEXT;
  v_user_role      TEXT;
  v_user_name      TEXT;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.review.manage') THEN
    RAISE EXCEPTION 'risk.review.manage permission required' USING ERRCODE = '42501';
  END IF;
  IF p_assigned_user_id IS NULL THEN
    RAISE EXCEPTION 'assignedUserId is required — promote must pin a specific person'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_case FROM risk_case WHERE id = p_case_id AND tenant_id = v_tenant_id;
  IF NOT FOUND OR NOT v_case.is_active THEN
    RAISE EXCEPTION 'case not found' USING ERRCODE = 'P0002';
  END IF;

  -- Stage 1 — clear executive holding state. Status stays 'in_review' so
  -- the no-orphan invariant doesn't trip while assigned_role is briefly
  -- NULL.
  UPDATE risk_case
     SET assigned_role    = NULL,
         assigned_user_id = NULL,
         status           = 'in_review',
         metadata         = COALESCE(metadata, '{}'::jsonb) - 'tier' - 'tierReason' - 'suppressedReason'
                            || jsonb_build_object(
                                 'promotedFromTier2At', now(),
                                 'promotedBy',          p_actor_id
                               ),
         updated_at       = now(),
         updated_by       = p_actor_id
   WHERE id = p_case_id;

  -- Stage 2 — routing matrix resolves the SLA + due_at. classify_and_route
  -- also sets assigned_role to its resolved role; we OVERRIDE that in
  -- stage 3 to the picked user's role, but keep the SLA the rule defined.
  PERFORM fn_risk_case_classify_and_route(p_case_id);
  SELECT assigned_role INTO v_resolved_role FROM risk_case WHERE id = p_case_id;

  -- Stage 3 — resolve the picked user. mig 665: role no longer needs to
  -- equal the resolved role. We adopt the user's role as assigned_role.
  SELECT r.name, TRIM(CONCAT_WS(' ', u.first_name, u.last_name))
    INTO v_user_role, v_user_name
    FROM "user" u
    JOIN role r ON r.id = u.role_id
   WHERE u.id = p_assigned_user_id AND u.is_active = TRUE;
  IF v_user_role IS NULL THEN
    RAISE EXCEPTION 'assignee user not found or inactive' USING ERRCODE = 'P0002';
  END IF;

  UPDATE risk_case
     SET assigned_user_id = p_assigned_user_id,
         assigned_role    = v_user_role,    -- mig 665: follow the picked user
         updated_at       = now(),
         updated_by       = p_actor_id
   WHERE id = p_case_id;

  -- Event 1 — status flip.
  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'status_changed', p_actor_id,
            jsonb_build_object(
              'from', 'in_review',
              'to',   'open',
              'reason', 'risk_review_promote'
            ));

  -- Event 2 — explicit assignment. payload.routedRole captures the
  -- engine's original suggestion so future analytics can compare
  -- "what the engine said" vs "what the executive did".
  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'assigned', p_actor_id,
            jsonb_build_object(
              'kind', 'promoted',
              'to', jsonb_build_object(
                      'role',     v_user_role,
                      'userId',   p_assigned_user_id,
                      'userName', v_user_name
                    ),
              'routedRole', v_resolved_role
            ));

  RETURN jsonb_build_object(
    'id',              p_case_id,
    'promoted',        TRUE,
    'assignedRole',    v_user_role,
    'assignedUserId',  p_assigned_user_id,
    'routedRole',      v_resolved_role
  );
END;
$function$;

COMMENT ON FUNCTION public.fn_risk_review_promote(BIGINT, BIGINT, BIGINT) IS
  'mig 665 — promote accepts a user from any role. assigned_role follows the '
  'picked user. SLA + due_at come from the routing rule. payload.routedRole '
  'on the assigned event preserves the engine''s original role suggestion.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (665, 'fn_risk_review_promote_any_role', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
