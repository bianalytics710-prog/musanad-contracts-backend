-- ============================================================================
-- Migration 660 — fn_risk_review_promote requires p_assigned_user_id
-- ============================================================================
-- Reinforces the clean state rule: a risk case is *either* in Risk Triage
-- (no person owner) *or* in Assigned Work (a person owns it). The
-- previous role-only promote path produced an in-between half-state
-- ("Risk Assigned but role-queue awaiting claim") that confused the
-- executive view. Closing that path here at the DB layer so the FE
-- can't ever land a case in the half-state, even by accident.
--
-- Behaviour:
--   - Raise 22023 'assignedUserId is required' when caller passes NULL.
--   - Everything else (defensive role-match check, classify_and_route,
--     risk_case_event audit row) is preserved from mig 649.
--
-- The signature stays (BIGINT, BIGINT, BIGINT) so call sites don't break.
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
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.review.manage') THEN
    RAISE EXCEPTION 'risk.review.manage permission required' USING ERRCODE = '42501';
  END IF;
  -- NEW (mig 660): a person must be picked. Role-only promotes are
  -- no longer allowed — they produced rows that lived in nobody's
  -- inbox.
  IF p_assigned_user_id IS NULL THEN
    RAISE EXCEPTION 'assignedUserId is required — promote must pin a specific person'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_case FROM risk_case WHERE id = p_case_id AND tenant_id = v_tenant_id;
  IF NOT FOUND OR NOT v_case.is_active THEN
    RAISE EXCEPTION 'case not found' USING ERRCODE = 'P0002';
  END IF;

  -- Stage 1: clear executive holding state. status='in_review' avoids
  -- the no-orphan invariant from mig 645 firing mid-transition.
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

  -- Stage 2: routing matrix resolves assigned_role + flips status='open'.
  PERFORM fn_risk_case_classify_and_route(p_case_id);

  SELECT assigned_role INTO v_resolved_role
    FROM risk_case WHERE id = p_case_id;

  -- Stage 3: validate the picked user's role matches the routed role,
  -- then pin them.
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

COMMENT ON FUNCTION public.fn_risk_review_promote(BIGINT, BIGINT, BIGINT) IS
  'mig 660 — promote now REQUIRES p_assigned_user_id. Closes the in-between '
  'role-routed-no-user state the FE could previously create when the modal '
  'submitted without a dropdown pick.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (660, 'fn_risk_review_promote_requires_user', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
