-- MIGRATION: 551_risk_case_auto_dismiss_fn.sql
-- Date: 2026-06-04
-- Description:
--   Phase C — fn called nightly by risk-case-auto-dismiss.worker to close
--   risk cases that nobody ever self-claimed. Closes with
--   closure_outcome='no_action' so the audit trail remains intact.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_risk_case_auto_dismiss_stale(
  p_stale_days  integer,
  p_actor_id    bigint
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_count integer;
BEGIN
  WITH targets AS (
    SELECT id, tenant_id
      FROM risk_case
     WHERE is_active = TRUE
       AND status IN ('open','in_review')
       AND assigned_user_id IS NULL
       AND created_at < (now() - (p_stale_days * INTERVAL '1 day'))
  ), updates AS (
    UPDATE risk_case rc
       SET status = 'closed',
           closure_outcome = 'no_action',
           closed_at = now(),
           closed_by = p_actor_id,
           metadata = COALESCE(metadata, '{}'::jsonb)
                      || jsonb_build_object('autoDismissedStaleAt', now(),
                                            'autoDismissedStaleDays', p_stale_days),
           updated_at = now(),
           updated_by = p_actor_id
      FROM targets t
     WHERE rc.id = t.id
    RETURNING rc.id, rc.tenant_id
  ), events AS (
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    SELECT u.tenant_id, u.id, 'closed', p_actor_id,
           jsonb_build_object('outcome', 'no_action',
                              'reason', 'auto_dismiss_stale',
                              'staleDays', p_stale_days)
      FROM updates u
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_count FROM events;

  RETURN jsonb_build_object('dismissedCount', COALESCE(v_count, 0));
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_risk_case_auto_dismiss_stale(integer,bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_risk_case_auto_dismiss_stale(integer,bigint) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (551, 'risk_case_auto_dismiss_fn', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
