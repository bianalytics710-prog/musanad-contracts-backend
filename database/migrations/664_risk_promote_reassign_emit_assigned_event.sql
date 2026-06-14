-- ============================================================================
-- Migration 664 — promote + reassign emit an explicit 'assigned' timeline event
-- ============================================================================
-- WHY: today the promote flow writes only a 'status_changed' event, so the
-- case detail timeline reads as "Case created · Status changed to open"
-- with no explicit "Assigned to {person}" entry. The reassign flow writes
-- an 'assigned' event but with a payload shape that doesn't match what
-- RiskCaseTimeline reads — it shows "Assigned to — (—)". Both surfaces
-- look broken from the user's POV.
--
-- WHAT:
--   1. fn_risk_review_promote — keeps the existing 'status_changed' event,
--      adds a second 'assigned' event with payload shape:
--        { to: { role, userId, userName }, kind: 'promoted' }
--      which matches the FE renderer (RiskCaseTimeline:46-60).
--   2. fn_risk_triage_reassign — rewrites its 'assigned' event payload
--      from the flat shape ({fromUserId, toUserId, …}) to the same
--      structured shape:
--        { to: { role, userId, userName }, from: { role, userId, userName },
--          kind: 'reassigned' }
--      so both promote AND reassign now render uniformly as
--      "Assigned to Compliance & ESG (Khalid Al Qubaisi)".
--   3. One-time backfill: insert the missing 'assigned' event on
--      risk_case 32 (the case the user just promoted to Khalid) so the
--      timeline reads correctly without re-promoting.
-- ============================================================================

BEGIN;

-- ─── 1. fn_risk_review_promote — adds the 'assigned' event ────────────
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

  PERFORM fn_risk_case_classify_and_route(p_case_id);

  SELECT assigned_role INTO v_resolved_role
    FROM risk_case WHERE id = p_case_id;

  SELECT r.name, TRIM(CONCAT_WS(' ', u.first_name, u.last_name))
    INTO v_user_role, v_user_name
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

  -- Event 1 — status flip (existing).
  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'status_changed', p_actor_id,
            jsonb_build_object(
              'from', 'in_review',
              'to',   'open',
              'reason', 'risk_review_promote'
            ));

  -- Event 2 — explicit assignment (NEW). Payload shape matches
  -- RiskCaseTimeline:46 so the timeline reads
  -- "Assigned to Compliance & ESG (Khalid Al Qubaisi)".
  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'assigned', p_actor_id,
            jsonb_build_object(
              'kind', 'promoted',
              'to', jsonb_build_object(
                      'role',     v_resolved_role,
                      'userId',   p_assigned_user_id,
                      'userName', v_user_name
                    )
            ));

  RETURN jsonb_build_object(
    'id',              p_case_id,
    'promoted',        TRUE,
    'assignedRole',    v_resolved_role,
    'assignedUserId',  p_assigned_user_id
  );
END;
$function$;

-- ─── 2. fn_risk_triage_reassign — uniform payload shape ──────────────
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
    RAISE EXCEPTION 'reassign_locked: case status is % (must be open)', v_case.status
      USING ERRCODE = 'P0001';
  END IF;

  SELECT r.name, TRIM(CONCAT_WS(' ', u.first_name, u.last_name))
    INTO v_new_role, v_new_user_name
    FROM "user" u
    JOIN role r ON r.id = u.role_id
   WHERE u.id = p_new_user_id AND u.is_active = TRUE;
  IF v_new_role IS NULL THEN
    RAISE EXCEPTION 'new user not found or inactive' USING ERRCODE = 'P0002';
  END IF;

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

  -- Uniform payload shape: { to: { role, userId, userName },
  -- from: { role, userId, userName }, kind: 'reassigned' } so the
  -- FE timeline renderer reads it identically to promote events.
  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'assigned', p_actor_id,
            jsonb_build_object(
              'kind', 'reassigned',
              'to', jsonb_build_object(
                      'role',     v_new_role,
                      'userId',   p_new_user_id,
                      'userName', v_new_user_name
                    ),
              'from', CASE
                        WHEN v_case.assigned_user_id IS NULL THEN NULL
                        ELSE jsonb_build_object(
                               'role',     v_case.assigned_role,
                               'userId',   v_case.assigned_user_id,
                               'userName', v_old_user_name
                             )
                      END
            ));

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

COMMENT ON FUNCTION public.fn_risk_review_promote(BIGINT, BIGINT, BIGINT) IS
  'mig 664 — emits TWO timeline events on promote: status_changed (in_review→open) '
  'plus an explicit assigned event with payload shape matching RiskCaseTimeline.';
COMMENT ON FUNCTION public.fn_risk_triage_reassign(BIGINT, BIGINT, BIGINT) IS
  'mig 664 — assigned event payload rewritten to the uniform shape '
  '{to:{role,userId,userName}, from:{…}, kind:''reassigned''} so the FE renderer '
  'produces a meaningful "Assigned to …" line for reassigns too.';

-- ─── 3. Backfill case 32 so the user sees the fix immediately ─────────
-- Case 32 was promoted to Khalid Al Qubaisi (uid=14, compliance_esg) at
-- 13:50 UTC. Insert the missing 'assigned' event with the right payload.
DO $$
DECLARE
  v_uname TEXT;
  v_role  TEXT;
BEGIN
  SELECT TRIM(CONCAT_WS(' ', u.first_name, u.last_name)), r.name
    INTO v_uname, v_role
    FROM "user" u JOIN role r ON r.id = u.role_id WHERE u.id = 14;

  IF v_uname IS NOT NULL AND EXISTS (
    SELECT 1 FROM risk_case
     WHERE id = 32 AND assigned_user_id = 14 AND status = 'open'
  ) THEN
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload, occurred_at)
    SELECT tenant_id, id, 'assigned', 8,
           jsonb_build_object(
             'kind', 'promoted',
             'backfilledByMig', 664,
             'to', jsonb_build_object('role', v_role, 'userId', 14, 'userName', v_uname)
           ),
           updated_at  -- align with promote timestamp
      FROM risk_case
     WHERE id = 32
       AND NOT EXISTS (
         SELECT 1 FROM risk_case_event
          WHERE risk_case_id = 32
            AND event_type = 'assigned'
            AND payload->>'backfilledByMig' = '664'
       );
  END IF;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (664, 'risk_promote_reassign_emit_assigned_event', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
