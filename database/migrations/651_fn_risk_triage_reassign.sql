-- ============================================================================
-- Migration 651 — Phase E.4: fn_risk_triage_reassign(case_id, actor_id, new_user_id)
-- ============================================================================
-- WHY: per locked decision E-Q3, the executive can override a Tier-1
-- routing decision while the receiver hasn't started yet (status='open').
-- Once the receiver moves to in_review or beyond, reassign locks. Decision
-- E-Q5 widens the dropdown to ANY active user (executive override), so
-- the new user may be in a different role than the current one — in that
-- case the case_role moves with the user.
--
-- WHAT:
--   - Validates status='open' (anything else → 'reassign_locked').
--   - Validates the new user exists + is_active.
--   - Updates assigned_user_id, and assigned_role to the new user's role
--     so the constraint risk_case_no_orphan_open (status='open' implies
--     assigned_role IS NOT NULL) stays satisfied even when the user is
--     in a different role.
--   - Writes a risk_case_event of type='reassigned' with {fromUserId,
--     toUserId, fromRole, toRole}.
--   - Fires fn_notification_dispatch for event_type='risk_case.reassigned'
--     with notifyUserIds = [old_user, new_user] so both inboxes see the
--     change. The actual rule + template are seeded in mig 653.
--
-- Permission gate: risk.review.manage.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_risk_triage_reassign(
  p_case_id     BIGINT,
  p_actor_id    BIGINT,
  p_new_user_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant_id     UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_case          RECORD;
  v_new_role      TEXT;
  v_new_user_name TEXT;
  v_old_user_name TEXT;
  v_payload       JSONB;
  v_notify_ids    JSONB;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;
  IF NOT fn_current_user_has_permission('risk.review.manage') THEN
    RAISE EXCEPTION 'risk.review.manage permission required' USING ERRCODE = '42501';
  END IF;
  IF p_new_user_id IS NULL THEN
    RAISE EXCEPTION 'newUserId is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_case FROM risk_case WHERE id = p_case_id AND tenant_id = v_tenant_id;
  IF NOT FOUND OR NOT v_case.is_active THEN
    RAISE EXCEPTION 'case not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_case.status <> 'open' THEN
    -- Receiver has started (in_review / snoozed / closed) — reassign locks.
    RAISE EXCEPTION 'reassign_locked: case status is % (must be open)', v_case.status
      USING ERRCODE = 'P0001';
  END IF;

  -- Resolve new user → role.
  SELECT r.name, TRIM(CONCAT_WS(' ', u.first_name, u.last_name))
    INTO v_new_role, v_new_user_name
    FROM "user" u
    JOIN role r ON r.id = u.role_id
   WHERE u.id = p_new_user_id AND u.is_active = TRUE;
  IF v_new_role IS NULL THEN
    RAISE EXCEPTION 'new user not found or inactive' USING ERRCODE = 'P0002';
  END IF;

  -- Capture old user name for the event payload (NULL-safe).
  IF v_case.assigned_user_id IS NOT NULL THEN
    SELECT TRIM(CONCAT_WS(' ', u.first_name, u.last_name))
      INTO v_old_user_name
      FROM "user" u WHERE u.id = v_case.assigned_user_id;
  END IF;

  UPDATE risk_case
     SET assigned_user_id = p_new_user_id,
         assigned_role    = v_new_role,
         metadata         = COALESCE(metadata, '{}'::jsonb)
                            || jsonb_build_object(
                                 'lastReassignedAt', now(),
                                 'lastReassignedBy', p_actor_id,
                                 'lastReassignedFromUserId', v_case.assigned_user_id,
                                 'lastReassignedFromRole', v_case.assigned_role
                               ),
         updated_at       = now(),
         updated_by       = p_actor_id
   WHERE id = p_case_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'reassigned', p_actor_id,
            jsonb_build_object(
              'fromUserId',  v_case.assigned_user_id,
              'fromRole',    v_case.assigned_role,
              'toUserId',    p_new_user_id,
              'toRole',      v_new_role,
              'fromUserName', v_old_user_name,
              'toUserName',   v_new_user_name
            ));

  -- Fire notification fanout. Recipients (both old + new owner) are
  -- carried in the payload under notifyUserIds; the rule seeded in
  -- mig 653 uses recipient_type='context' to read it.
  v_notify_ids := '[]'::jsonb;
  IF v_case.assigned_user_id IS NOT NULL AND v_case.assigned_user_id <> p_new_user_id THEN
    v_notify_ids := v_notify_ids || to_jsonb(v_case.assigned_user_id);
  END IF;
  v_notify_ids := v_notify_ids || to_jsonb(p_new_user_id);

  v_payload := jsonb_build_object(
    'riskCaseId',     p_case_id,
    'title',          v_case.title,
    'fromUserId',     v_case.assigned_user_id,
    'fromUserName',   COALESCE(v_old_user_name, 'Unassigned'),
    'toUserId',       p_new_user_id,
    'toUserName',     v_new_user_name,
    'toRole',         v_new_role,
    'reassignedBy',   p_actor_id,
    'notifyUserIds',  v_notify_ids,
    'subject',        'Risk case reassigned: ' || v_case.title,
    'bodyRendered',   COALESCE(v_old_user_name, 'Unassigned') || ' → ' || v_new_user_name
                      || ' (' || v_case.title || ')'
  );

  -- Suppress notification errors so they never sink the reassign itself.
  BEGIN
    PERFORM fn_notification_dispatch(
      p_actor_id, 'risk_case.reassigned', v_payload,
      'risk_case', 'medium', NULL, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'id',             p_case_id,
    'reassigned',     TRUE,
    'fromUserId',     v_case.assigned_user_id,
    'toUserId',       p_new_user_id,
    'toRole',         v_new_role
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_triage_reassign(BIGINT, BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_triage_reassign(BIGINT, BIGINT, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_risk_triage_reassign(BIGINT, BIGINT, BIGINT) IS
  'Phase E.4 (mig 651) — executive override that moves a Tier-1 case '
  'from one user to another while status=open. Updates assigned_role to '
  'match the new user. Locks once receiver moves to in_review. Notifies '
  'both old + new owner via risk_case.reassigned event.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (651, 'fn_risk_triage_reassign', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
