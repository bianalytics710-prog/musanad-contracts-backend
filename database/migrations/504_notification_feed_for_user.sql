-- MIGRATION: 504_notification_feed_for_user.sql
-- Date: 2026-06-03
-- Description: fn_notification_feed_list (DEFINER) — returns the calling
--              user's in-app notifications from notification_dispatch_log
--              for the FE bell. Single-tenant tenant fallback.

BEGIN;

CREATE OR REPLACE FUNCTION fn_notification_feed_list(
  p_actor_id BIGINT,
  p_limit    INTEGER DEFAULT 50,
  p_offset   INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER STABLE
AS $function$
DECLARE
  v_tenant_id  UUID;
  v_tenant_guc TEXT;
  v_rows       JSONB;
  v_total      BIGINT;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'actor_required' USING ERRCODE = '22023';
  END IF;

  v_tenant_guc := current_setting('app.current_tenant_id', true);
  IF v_tenant_guc IS NOT NULL AND v_tenant_guc <> '' THEN
    v_tenant_id := v_tenant_guc::uuid;
  ELSE
    SELECT id INTO v_tenant_id FROM tenant WHERE is_active = TRUE LIMIT 1;
  END IF;
  IF v_tenant_id IS NULL THEN
    RETURN jsonb_build_object('data', '[]'::jsonb, 'pagination',
      jsonb_build_object('total', 0, 'limit', p_limit, 'offset', p_offset));
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM notification_dispatch_log
  WHERE tenant_id = v_tenant_id
    AND recipient_user_id = p_actor_id
    AND channel = 'in_app'
    AND status IN ('sent', 'captured_only');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                  ndl.id,
    'notificationKind',    ndl.notification_kind,
    'priority',            ndl.priority,
    'subject',             ndl.subject,
    'bodyRendered',        ndl.body_rendered,
    'contextPayload',      ndl.context_payload,
    'status',              ndl.status,
    'createdAt',           ndl.created_at,
    'deliveryCompletedAt', ndl.delivery_completed_at
  ) ORDER BY ndl.created_at DESC), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM notification_dispatch_log
    WHERE tenant_id = v_tenant_id
      AND recipient_user_id = p_actor_id
      AND channel = 'in_app'
      AND status IN ('sent', 'captured_only')
    ORDER BY created_at DESC
    LIMIT GREATEST(p_limit, 1) OFFSET GREATEST(p_offset, 0)
  ) ndl;

  RETURN jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset)
  );
END;
$function$;

COMMENT ON FUNCTION fn_notification_feed_list(BIGINT, INTEGER, INTEGER) IS
  'DEFINER STABLE. Returns the calling user''s in-app notifications from notification_dispatch_log (sent + captured_only). Single-tenant tenant fallback. Used by the bell.';
REVOKE EXECUTE ON FUNCTION fn_notification_feed_list(BIGINT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_feed_list(BIGINT, INTEGER, INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (504, '504_notification_feed_for_user', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
