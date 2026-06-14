-- ============================================================================
-- Migration 652 — Phase E.5: dismiss-as-noise — extend to cover Tier-1
-- ============================================================================
-- WHY: today fn_risk_review_dismiss closes a Tier-2 case as 'no_action'. The
-- BE controller calls it from /risk-cases/:id/dismiss-as-noise — but Phase
-- E adds Tier-1 surfacing to Risk Triage and the executive needs the same
-- "Mark as noise" button there. Rather than fork into two near-identical
-- fns, we extend fn_risk_review_dismiss to:
--   - Work on both Tier-1 (assigned_user_id IS NOT NULL) and Tier-2 rows.
--   - When the row has an assigned_user_id, fire a notification to that
--     user via risk_case.dismissed_as_noise so they see the dismissal in
--     their inbox (otherwise the row would just disappear from their
--     My Work surface with no explanation).
-- Decision (per E plan §3.1): one fn handles both tiers — fn_risk_review_dismiss
-- is renamed in intent but keeps its signature so the BE controller and the
-- existing bulk transaction don't break.
--
-- WHAT:
--   - Replace fn_risk_review_dismiss(case_id, actor_id) body.
--   - Same closure-outcome ('no_action') + metadata.dismissedByExecAt as
--     before (rename of dismissedAt → dismissedByExecAt per plan §3.5).
--   - If assigned_user_id is set, fire fn_notification_dispatch.
--   - Keep the original event_type='closed' risk_case_event row.
--
-- Permission gate unchanged: risk.review.manage.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_risk_review_dismiss(
  p_case_id  BIGINT,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant_id  UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_case       RECORD;
  v_old_user_name TEXT;
  v_payload    JSONB;
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
  IF v_case.status = 'closed' THEN
    RAISE EXCEPTION 'case already closed' USING ERRCODE = 'P0001';
  END IF;

  UPDATE risk_case
     SET status          = 'closed',
         closure_outcome = 'no_action',
         closed_at       = now(),
         closed_by       = p_actor_id,
         metadata        = COALESCE(metadata, '{}'::jsonb)
                           || jsonb_build_object(
                                'dismissedAsNoise',  TRUE,
                                'dismissedByExecAt', now(),
                                'dismissedBy',       p_actor_id,
                                'dismissedFromUserId', v_case.assigned_user_id,
                                'dismissedFromRole',   v_case.assigned_role
                              ),
         updated_at      = now(),
         updated_by      = p_actor_id
   WHERE id = p_case_id;

  INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_case_id, 'closed', p_actor_id,
            jsonb_build_object(
              'outcome',         'no_action',
              'reason',          'risk_review_dismiss',
              'dismissedFromUserId', v_case.assigned_user_id,
              'dismissedFromRole',   v_case.assigned_role
            ));

  -- Notify the previously-assigned user, if any. Tier-2 cases assigned to
  -- 'executive' role with NULL user_id skip this fanout.
  IF v_case.assigned_user_id IS NOT NULL THEN
    SELECT TRIM(CONCAT_WS(' ', u.first_name, u.last_name))
      INTO v_old_user_name
      FROM "user" u WHERE u.id = v_case.assigned_user_id;

    v_payload := jsonb_build_object(
      'riskCaseId',     p_case_id,
      'title',          v_case.title,
      'fromUserId',     v_case.assigned_user_id,
      'fromUserName',   COALESCE(v_old_user_name, 'Unknown'),
      'dismissedBy',    p_actor_id,
      'notifyUserIds',  jsonb_build_array(v_case.assigned_user_id),
      'subject',        'Risk case dismissed as noise: ' || v_case.title,
      'bodyRendered',   'The case "' || v_case.title || '" was closed by the executive as noise.'
    );

    BEGIN
      PERFORM fn_notification_dispatch(
        p_actor_id, 'risk_case.dismissed_as_noise', v_payload,
        'risk_case', 'low', NULL, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'id',                 p_case_id,
    'closed',             TRUE,
    'dismissedFromUserId', v_case.assigned_user_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_review_dismiss(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_review_dismiss(BIGINT, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_risk_review_dismiss(BIGINT, BIGINT) IS
  'Phase E.5 (mig 652) — close case with closure_outcome=no_action. Works on '
  'both Tier-1 (assigned to a user) and Tier-2 (assigned to executive role) '
  'rows. Tier-1 fires a risk_case.dismissed_as_noise notification to the '
  'previously-assigned user. Signature preserved for compat with existing '
  'bulk transaction.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (652, 'fn_risk_triage_dismiss_as_noise_extends_dismiss', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
