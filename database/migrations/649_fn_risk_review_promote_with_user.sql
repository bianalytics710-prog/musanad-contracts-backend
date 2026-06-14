-- ============================================================================
-- Migration 649 — Phase E.2: fn_risk_review_promote(case_id, actor_id, user_id)
-- ============================================================================
-- WHY: Phase E.1 (mig 648) lets the FE pick a specific person inside the
-- target role when confirming a Tier-2 case. Today's fn_risk_review_promote
-- accepts only (case_id, actor_id) — it clears assigned_user_id, runs the
-- routing matrix to set assigned_role, and then leaves it to the team to
-- self-claim. The new contract: if the caller supplies p_assigned_user_id,
-- pin that user as the owner AFTER routing resolves the role. If NULL,
-- behave exactly as before (role-only routing).
--
-- WHAT this migration does:
--   - Replaces fn_risk_review_promote with a 3-arg variant that adds
--     p_assigned_user_id BIGINT DEFAULT NULL.
--   - Drops the previous 2-arg signature (call sites are migrating to
--     pass an explicit NULL third arg via the BE controller).
--   - When p_assigned_user_id is provided:
--       * Validates the user is active + belongs to the role the routing
--         matrix resolved (defence in depth — FE dropdown already filters
--         by role, but the DB should not trust the client).
--       * Updates assigned_user_id inline (after classify_and_route has
--         set assigned_role + status='open' + due_at).
--       * Inserts a richer risk_case_event payload with the picked userId
--         so the audit trail captures the executive's choice.
--
-- WHAT it does NOT do:
--   - Does not call fn_risk_case_assign — that fn requires
--     risk.case.create | risk.case.escalate, neither of which the executive
--     holds. The executive's authority comes from risk.review.manage; the
--     inline UPDATE keeps the permission gate at exactly one fn (this one).
--   - Does not notify the newly-assigned user here. fn_risk_case_assign
--     already triggers work_order.assigned-style fanout for other code
--     paths; for Tier-2 promotions the existing UX is the receiver opens
--     their My Work to see the new case. Phase E.6 wires explicit
--     notification on reassign + dismiss-as-noise which are higher-touch.
-- ============================================================================

BEGIN;

-- Drop the previous 2-arg signature so the new 3-arg form is unambiguous.
DROP FUNCTION IF EXISTS public.fn_risk_review_promote(BIGINT, BIGINT);

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
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.review.manage') THEN
    RAISE EXCEPTION 'risk.review.manage permission required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_case FROM risk_case WHERE id = p_case_id AND tenant_id = v_tenant_id;
  IF NOT FOUND OR NOT v_case.is_active THEN
    RAISE EXCEPTION 'case not found' USING ERRCODE = 'P0002';
  END IF;

  -- Stage 1: clear executive holding state. Status stays 'in_review'
  -- until classify_and_route succeeds so the no-orphan invariant
  -- (status='open' implies assigned_role IS NOT NULL) is never violated.
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

  -- Stage 2: routing matrix resolves assigned_role + flips status to 'open'.
  PERFORM fn_risk_case_classify_and_route(p_case_id);

  -- Re-read so we know which role landed.
  SELECT assigned_role INTO v_resolved_role
    FROM risk_case WHERE id = p_case_id;

  -- Stage 3 (only when caller pinned a user): validate role match, then
  -- assign. The check defends against a stale FE dropdown — if the rule
  -- resolved to a different role than the user the executive picked, fail
  -- loudly rather than silently mis-route.
  IF p_assigned_user_id IS NOT NULL THEN
    SELECT r.name INTO v_user_role
      FROM "user" u
      JOIN role r ON r.id = u.role_id
     WHERE u.id = p_assigned_user_id AND u.is_active = TRUE;
    IF v_user_role IS NULL THEN
      RAISE EXCEPTION 'assignee user not found or inactive' USING ERRCODE = 'P0002';
    END IF;
    IF v_resolved_role IS NULL THEN
      RAISE EXCEPTION 'routing matrix resolved no role; cannot pin user'
        USING ERRCODE = '22023';
    END IF;
    IF v_user_role <> v_resolved_role THEN
      RAISE EXCEPTION 'assignee role (%) does not match routed role (%)',
        v_user_role, v_resolved_role USING ERRCODE = '22023';
    END IF;

    UPDATE risk_case
       SET assigned_user_id = p_assigned_user_id,
           updated_at       = now(),
           updated_by       = p_actor_id
     WHERE id = p_case_id;
  END IF;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'status_changed', p_actor_id,
            jsonb_build_object(
              'to',              'open',
              'reason',          'risk_review_promote',
              'assignedRole',    v_resolved_role,
              'assignedUserId',  p_assigned_user_id
            ));

  RETURN jsonb_build_object(
    'id',              p_case_id,
    'promoted',        TRUE,
    'assignedRole',    v_resolved_role,
    'assignedUserId',  p_assigned_user_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_review_promote(BIGINT, BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_review_promote(BIGINT, BIGINT, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_risk_review_promote(BIGINT, BIGINT, BIGINT) IS
  'Phase E.2 (mig 649) — promote a Tier-2 case to Tier-1 with optional '
  'caller-supplied assigned_user_id. NULL = role-only routing (legacy 2-arg '
  'behaviour). Non-NULL pins the user AFTER classify_and_route resolves the '
  'role, with a defensive role-match check.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (649, 'fn_risk_review_promote_with_user', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
