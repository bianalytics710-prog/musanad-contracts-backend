-- MIGRATION: 219_crh_fn_notification_log_subscription_functions.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: fn_notification_dispatch_log_list (STABLE INVOKER) / _get_by_id (STABLE INVOKER)
--              + fn_notification_subscription_list (STABLE INVOKER) / _set (VOLATILE INVOKER) — 4 fn_'s.
--              Each followed by COMMENT + REVOKE FROM PUBLIC + GRANT TO neondb_owner (S2-21/S2-27/B14).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ---------------------------------------------------------------------------
-- fn_notification_dispatch_log_list (STABLE INVOKER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_notification_dispatch_log_list(
  p_actor_id          BIGINT,
  p_channel           TEXT DEFAULT NULL,
  p_status            TEXT DEFAULT NULL,
  p_notification_kind TEXT DEFAULT NULL,
  p_priority          TEXT DEFAULT NULL,
  p_recipient_user_id BIGINT DEFAULT NULL,
  p_from              TIMESTAMPTZ DEFAULT NULL,
  p_to                TIMESTAMPTZ DEFAULT NULL,
  p_page              INTEGER DEFAULT 1,
  p_limit             INTEGER DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_tenant_id  UUID;
  v_actor_role TEXT;
  v_offset     INTEGER;
  v_total      INTEGER;
  v_data       JSONB;
BEGIN
  -- Permission gate: notification.dispatch_log.read
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin') THEN
    RAISE EXCEPTION 'fn_notification_dispatch_log_list: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  IF p_page < 1 THEN p_page := 1; END IF;
  IF p_limit NOT BETWEEN 1 AND 200 THEN p_limit := 50; END IF;
  v_offset := (p_page - 1) * p_limit;

  SELECT COUNT(*) INTO v_total
  FROM notification_dispatch_log ndl
  WHERE ndl.tenant_id = v_tenant_id
    AND (p_channel IS NULL OR ndl.channel = p_channel)
    AND (p_status IS NULL OR ndl.status = p_status)
    AND (p_notification_kind IS NULL OR ndl.notification_kind = p_notification_kind)
    AND (p_priority IS NULL OR ndl.priority = p_priority)
    AND (p_recipient_user_id IS NULL OR ndl.recipient_user_id = p_recipient_user_id)
    AND (p_from IS NULL OR ndl.delivery_attempted_at >= p_from)
    AND (p_to IS NULL OR ndl.delivery_attempted_at <= p_to);

  SELECT COALESCE(jsonb_agg(row_obj ORDER BY delivery_attempted_at DESC), '[]'::jsonb) INTO v_data
  FROM (
    SELECT jsonb_build_object(
      'id',                  ndl.id,
      'notificationKind',    ndl.notification_kind,
      'priority',            ndl.priority,
      'channel',             ndl.channel,
      'recipientUserId',     ndl.recipient_user_id,
      'recipientAddress',    '[REDACTED]',
      'subject',             ndl.subject,
      'bodyRendered',        substring(ndl.body_rendered, 1, 500),  -- truncated to 500 chars
      'status',              ndl.status,
      'deliveryAttemptedAt', ndl.delivery_attempted_at,
      'deliveryCompletedAt', ndl.delivery_completed_at,
      'retryCount',          ndl.retry_count,
      'nextRetryAt',         ndl.next_retry_at,
      'advisoryDraftId',     ndl.advisory_draft_id,
      'createdAt',           ndl.created_at
    ) AS row_obj,
    ndl.delivery_attempted_at
    FROM notification_dispatch_log ndl
    WHERE ndl.tenant_id = v_tenant_id
      AND (p_channel IS NULL OR ndl.channel = p_channel)
      AND (p_status IS NULL OR ndl.status = p_status)
      AND (p_notification_kind IS NULL OR ndl.notification_kind = p_notification_kind)
      AND (p_priority IS NULL OR ndl.priority = p_priority)
      AND (p_recipient_user_id IS NULL OR ndl.recipient_user_id = p_recipient_user_id)
      AND (p_from IS NULL OR ndl.delivery_attempted_at >= p_from)
      AND (p_to IS NULL OR ndl.delivery_attempted_at <= p_to)
    ORDER BY ndl.delivery_attempted_at DESC
    LIMIT p_limit OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       p_page,
      'limit',      p_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::FLOAT / p_limit)::INTEGER END
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_dispatch_log_list: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_notification_dispatch_log_list(BIGINT, TEXT, TEXT, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, INTEGER) IS
  'Paginated universal notification dispatch log. body_rendered truncated to 500 chars; full body via _get_by_id. Requires notification.dispatch_log.read (Super Admin / platform_admin).';
REVOKE EXECUTE ON FUNCTION fn_notification_dispatch_log_list(BIGINT, TEXT, TEXT, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_dispatch_log_list(BIGINT, TEXT, TEXT, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, INTEGER) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_notification_dispatch_log_get_by_id (STABLE INVOKER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_notification_dispatch_log_get_by_id(
  p_actor_id BIGINT,
  p_id       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_tenant_id  UUID;
  v_actor_role TEXT;
  v_has_perm   BOOLEAN;
  v_result     JSONB;
BEGIN
  -- Permission gate: notification.dispatch_log.read OR self (recipient_user_id = p_actor_id)
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  v_has_perm := v_actor_role IN ('Super Admin','platform_admin');

  SELECT jsonb_build_object(
    'id',                    ndl.id,
    'tenantId',              ndl.tenant_id,
    'notificationTemplateId',ndl.notification_template_id,
    'notificationKind',      ndl.notification_kind,
    'priority',              ndl.priority,
    'channel',               ndl.channel,
    'recipientUserId',       ndl.recipient_user_id,
    'recipientAddress',      CASE WHEN v_has_perm THEN ndl.recipient_address ELSE '[REDACTED]' END,
    'subject',               ndl.subject,
    'bodyRendered',          ndl.body_rendered,  -- full body here
    'contextPayload',        ndl.context_payload,
    'status',                ndl.status,
    'deliveryAttemptedAt',   ndl.delivery_attempted_at,
    'deliveryCompletedAt',   ndl.delivery_completed_at,
    'errorMessage',          ndl.error_message,
    'retryCount',            ndl.retry_count,
    'nextRetryAt',           ndl.next_retry_at,
    'advisoryDraftId',       ndl.advisory_draft_id,
    'dataClassification',    ndl.data_classification,
    'createdAt',             ndl.created_at
  ) INTO v_result
  FROM notification_dispatch_log ndl
  WHERE ndl.id = p_id
    AND ndl.tenant_id = v_tenant_id
    AND (v_has_perm OR ndl.recipient_user_id = p_actor_id);

  RETURN v_result;  -- NULL on not-found or not-visible

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_dispatch_log_get_by_id: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_notification_dispatch_log_get_by_id(BIGINT, BIGINT) IS
  'Full notification_dispatch_log row including untruncated body_rendered. Visible to Super Admin/platform_admin (full) or recipient (own row only). Returns NULL on not-found.';
REVOKE EXECUTE ON FUNCTION fn_notification_dispatch_log_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_dispatch_log_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_notification_subscription_list (STABLE INVOKER) — always returns 28 rows (7×4 grid)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_notification_subscription_list(
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_tenant_id UUID;
  v_data      JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  -- 7 kinds × 4 channels grid with explicit_subscription LEFT JOIN
  -- Missing rows synthesised as enabled=true, priorityMin='high' (HITL-Q6 default)
  WITH explicit AS (
    SELECT notification_kind, channel, priority_min, enabled, TRUE AS is_explicit
    FROM notification_subscription
    WHERE user_id = p_actor_id
      AND tenant_id = v_tenant_id
      AND is_active = TRUE
  ),
  kinds AS (
    SELECT unnest(ARRAY[
      'alert','advisory','approval_request','signature_request',
      'system','risk_case','report'
    ]::text[]) AS notification_kind
  ),
  channels AS (
    SELECT unnest(ARRAY['email','in_app','teams_capture','slack_capture']::text[]) AS channel
  ),
  grid AS (
    SELECT k.notification_kind, c.channel
    FROM kinds k CROSS JOIN channels c
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'notificationKind', g.notification_kind,
    'channel',          g.channel,
    'enabled',          COALESCE(e.enabled, TRUE),
    'priorityMin',      COALESCE(e.priority_min, 'high'),
    'isExplicit',       COALESCE(e.is_explicit, FALSE)
  ) ORDER BY g.notification_kind, g.channel), '[]'::jsonb) INTO v_data
  FROM grid g
  LEFT JOIN explicit e
    ON e.notification_kind = g.notification_kind
    AND e.channel = g.channel;

  RETURN jsonb_build_object('data', v_data);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_subscription_list: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_notification_subscription_list(BIGINT) IS
  'Returns the current user''s notification subscription grid — always 28 rows (7 kinds × 4 channels). Missing rows synthesised as enabled=true, priorityMin=high (HITL-Q6 default). isExplicit=false for synthesised rows.';
REVOKE EXECUTE ON FUNCTION fn_notification_subscription_list(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_subscription_list(BIGINT) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_notification_subscription_set (VOLATILE INVOKER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_notification_subscription_set(
  p_actor_id        BIGINT,
  p_notification_kind TEXT,
  p_channel         TEXT,
  p_priority_min    TEXT DEFAULT 'high',
  p_enabled         BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant_id UUID;
  v_actor_role TEXT;
  v_id         BIGINT;
  v_result     JSONB;
BEGIN
  -- Permission gate: notification.preferences.write.self (all authenticated roles)
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role IS NULL THEN
    RAISE EXCEPTION 'fn_notification_subscription_set: unauthenticated'
      USING ERRCODE = '42501';
  END IF;

  -- Enum validation (S2-25)
  IF p_notification_kind NOT IN ('alert','advisory','approval_request','signature_request','system','risk_case','report') THEN
    RAISE EXCEPTION 'fn_notification_subscription_set: invalid_kind — valid values: alert, advisory, approval_request, signature_request, system, risk_case, report'
      USING ERRCODE = '22023';
  END IF;
  IF p_channel NOT IN ('email','in_app','teams_capture','slack_capture') THEN
    RAISE EXCEPTION 'fn_notification_subscription_set: invalid_channel — valid values: email, in_app, teams_capture, slack_capture'
      USING ERRCODE = '22023';
  END IF;
  IF p_priority_min NOT IN ('low','medium','high','critical') THEN
    RAISE EXCEPTION 'fn_notification_subscription_set: invalid_priority — valid values: low, medium, high, critical'
      USING ERRCODE = '22023';
  END IF;

  -- UPSERT — user_id hard-set to p_actor_id (defence-in-depth, RLS also blocks cross-user writes)
  INSERT INTO notification_subscription (
    tenant_id, user_id, notification_kind, channel, priority_min, enabled,
    created_at, updated_at, created_by, updated_by, is_active
  ) VALUES (
    v_tenant_id, p_actor_id, p_notification_kind, p_channel,
    COALESCE(p_priority_min, 'high'), COALESCE(p_enabled, TRUE),
    NOW(), NOW(), p_actor_id, p_actor_id, TRUE
  )
  ON CONFLICT (tenant_id, user_id, notification_kind, channel) DO UPDATE SET
    priority_min = EXCLUDED.priority_min,
    enabled      = EXCLUDED.enabled,
    updated_at   = NOW(),
    updated_by   = p_actor_id,
    is_active    = TRUE
  RETURNING id INTO v_id;

  SELECT jsonb_build_object(
    'id',               ns.id,
    'tenantId',         ns.tenant_id,
    'userId',           ns.user_id,
    'notificationKind', ns.notification_kind,
    'channel',          ns.channel,
    'priorityMin',      ns.priority_min,
    'enabled',          ns.enabled,
    'isActive',         ns.is_active,
    'createdAt',        ns.created_at,
    'updatedAt',        ns.updated_at
  ) INTO v_result
  FROM notification_subscription ns WHERE ns.id = v_id;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_subscription_set: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_notification_subscription_set(BIGINT, TEXT, TEXT, TEXT, BOOLEAN) IS
  'Upserts a single notification_subscription row for the current user (user_id hard-set to actor). Validates kind/channel/priority enums. All authenticated roles.';
REVOKE EXECUTE ON FUNCTION fn_notification_subscription_set(BIGINT, TEXT, TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_subscription_set(BIGINT, TEXT, TEXT, TEXT, BOOLEAN) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (219, '219_crh_fn_notification_log_subscription_functions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_notification_subscription_set(BIGINT, TEXT, TEXT, TEXT, BOOLEAN);
-- DROP FUNCTION IF EXISTS fn_notification_subscription_list(BIGINT);
-- DROP FUNCTION IF EXISTS fn_notification_dispatch_log_get_by_id(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_notification_dispatch_log_list(BIGINT, TEXT, TEXT, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, INTEGER);
-- DELETE FROM schema_migrations WHERE version = 219;
-- ============================================================
