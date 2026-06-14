-- ============================================================================
-- Migration 655 — Phase E in-flight fix: reassign event_type
-- ============================================================================
-- DEFECT-PHASE-E-1 (caught by Playwright walk 2026-06-13):
--   fn_risk_triage_reassign (mig 651) wrote risk_case_event rows with
--   event_type='reassigned', but the table's CHECK constraint
--   risk_case_event_event_type_check only allows:
--     created / assigned / status_changed / comment_added / evidence_uploaded /
--     escalated / accepted_risk / snoozed / closed / reopened /
--     tier2_auto_escalated
--
-- Two options considered:
--   (a) Add 'reassigned' to the CHECK constraint — requires DROP + ADD on
--       a constraint already in production, more invasive.
--   (b) Use 'assigned' (existing valid value, semantically close — that's
--       what fn_risk_case_assign emits). The payload still carries
--       {fromUserId, fromRole, toUserId, toRole, fromUserName, toUserName}
--       so the distinction (assigned vs reassigned) is captured semantically.
--
-- We pick (b) for minimum schema churn. To keep the audit trail readable,
-- the payload also stamps {kind: 'reassigned'} so the UI / export layer
-- can distinguish first-time assignment from a true reassignment.
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

  -- DEFECT-PHASE-E-1 fix: use 'assigned' (valid CHECK value) instead of
  -- 'reassigned'. payload.kind='reassigned' preserves the audit semantic.
  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'assigned', p_actor_id,
            jsonb_build_object(
              'kind',          'reassigned',
              'fromUserId',    v_case.assigned_user_id,
              'fromRole',      v_case.assigned_role,
              'toUserId',      p_new_user_id,
              'toRole',        v_new_role,
              'fromUserName',  v_old_user_name,
              'toUserName',    v_new_user_name
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

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (655, 'fix_risk_triage_reassign_event_type', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
