-- MIGRATION: 218_crh_fn_notification_send_function.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: fn_notification_send (DEFINER) + fn_notification_dispatch_retry_due (DEFINER) +
--              fn_notification_dispatch_update_retry_outcome (DEFINER) — 3 fn_'s.
--              PATCHED per QA Stage 3 DEFECT-S3-10-1: fn_notification_send is 9-arg (not 8).
--              Each followed by COMMENT + REVOKE FROM PUBLIC + GRANT TO neondb_owner (S2-21/S2-27/B14).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ---------------------------------------------------------------------------
-- fn_notification_send (DEFINER VOLATILE) — 9-arg form locked per Design Note 7 (S2-19)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_notification_send(
  p_actor_id                BIGINT,           -- 1
  p_notification_template_id BIGINT,          -- 2
  p_notification_kind       TEXT,             -- 3
  p_channel                 TEXT,             -- 4
  p_priority                TEXT,             -- 5
  p_recipient_user_id       BIGINT,           -- 6
  p_recipient_address       TEXT,             -- 7
  p_context                 JSONB,            -- 8
  p_advisory_draft_id       BIGINT DEFAULT NULL -- 9
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_actor          BIGINT;
  v_tenant_id      UUID;
  v_id             BIGINT;
  v_status         TEXT;
  v_next_retry     TIMESTAMPTZ;
  v_enabled        BOOLEAN;
  v_pm             TEXT;
  v_priority_order INTEGER;
  v_pm_order       INTEGER;
  v_subject        TEXT;
  v_body           TEXT;
BEGIN
  -- S2-20 v_actor=0→NULL
  v_actor := NULLIF(p_actor_id, 0);
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  -- Validation (S2-23 FK pre-validate, S2-22 col-existence)
  IF p_recipient_user_id IS NULL AND p_recipient_address IS NULL THEN
    RAISE EXCEPTION 'fn_notification_send: missing_recipient — recipient_user_id or recipient_address is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_channel NOT IN ('email','in_app','teams_capture','slack_capture') THEN
    RAISE EXCEPTION 'fn_notification_send: invalid_channel — valid values: email, in_app, teams_capture, slack_capture'
      USING ERRCODE = '22023';
  END IF;
  IF p_notification_kind NOT IN ('alert','advisory','approval_request','signature_request','system','risk_case','report') THEN
    RAISE EXCEPTION 'fn_notification_send: invalid_kind — valid values: alert, advisory, approval_request, signature_request, system, risk_case, report'
      USING ERRCODE = '22023';
  END IF;
  IF p_priority NOT IN ('low','medium','high','critical') THEN
    RAISE EXCEPTION 'fn_notification_send: invalid_priority — valid values: low, medium, high, critical'
      USING ERRCODE = '22023';
  END IF;

  -- Notification template FK pre-validate (if provided)
  IF p_notification_template_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM notification_template WHERE id = p_notification_template_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_notification_send: notification_template_not_found'
      USING ERRCODE = '23503';
  END IF;

  -- Extract subject + body from context (Design Note 5: BE pre-renders Mustache)
  v_subject := p_context->>'subject';
  v_body    := p_context->>'bodyRendered';
  IF v_body IS NULL OR trim(v_body) = '' THEN
    v_body := p_context->>'body';  -- fallback key
  END IF;
  IF v_body IS NULL THEN v_body := ''; END IF;

  -- Subscription check (HITL-Q6 default: opt-in to high+critical only)
  v_status := 'pending';
  IF p_recipient_user_id IS NOT NULL THEN
    SELECT ns.enabled, ns.priority_min INTO v_enabled, v_pm
    FROM notification_subscription ns
    WHERE ns.tenant_id = v_tenant_id
      AND ns.user_id = p_recipient_user_id
      AND ns.notification_kind = p_notification_kind
      AND ns.channel = p_channel
      AND ns.is_active = TRUE;

    IF NOT FOUND THEN
      v_enabled := TRUE;
      v_pm      := 'high';  -- default
    END IF;

    v_priority_order := CASE p_priority WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END;
    v_pm_order       := CASE v_pm WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END;

    IF (NOT v_enabled) OR (v_priority_order < v_pm_order) THEN
      v_status := 'suppressed_by_preference';
    END IF;
  END IF;

  -- Resolve final status by channel
  IF v_status = 'pending' THEN
    v_status := CASE p_channel
      WHEN 'teams_capture'  THEN 'captured_only'
      WHEN 'slack_capture'  THEN 'captured_only'
      WHEN 'in_app'         THEN 'sent'
      WHEN 'email'          THEN 'pending_retry'
    END;
    v_next_retry := CASE WHEN v_status = 'pending_retry' THEN NOW() + INTERVAL '0 seconds' ELSE NULL END;
  ELSE
    v_next_retry := NULL;
  END IF;

  -- INSERT notification_dispatch_log (S2-22 — 22 explicit cols)
  INSERT INTO notification_dispatch_log (
    tenant_id, notification_template_id, notification_kind, priority, channel,
    recipient_user_id, recipient_address, subject, body_rendered, context_payload,
    status, delivery_attempted_at, retry_count, next_retry_at,
    advisory_draft_id, data_classification,
    created_at, created_by, is_active
  ) VALUES (
    v_tenant_id,
    p_notification_template_id,
    p_notification_kind,
    p_priority,
    p_channel,
    p_recipient_user_id,
    p_recipient_address,
    v_subject,
    COALESCE(v_body, ''),
    p_context - 'bodyRendered' - 'subject',  -- strip sensitive body from stored context
    v_status,
    NOW(),
    0,
    v_next_retry,
    p_advisory_draft_id,
    'sensitive',
    NOW(), v_actor, TRUE
  )
  RETURNING id INTO v_id;

  -- Strategy A audit (S2-28)
  PERFORM fn_audit_log_record_v2(
    'notification_dispatch_log', v_id, 'INSERT',
    NULL,
    jsonb_build_object(
      'notificationKind', p_notification_kind,
      'channel',          p_channel,
      'priority',         p_priority,
      'status',           v_status,
      'recipientUserId',  p_recipient_user_id,
      'advisoryDraftId',  p_advisory_draft_id,
      'actionCode',       'notification.dispatched'
    ),
    COALESCE(NULLIF(p_actor_id, 0), NULL)  -- S2-20
  );

  RETURN jsonb_build_object(
    'notificationDispatchLogId', v_id,
    'status',                    v_status,
    'renderedSubject',           v_subject,
    'channel',                   p_channel
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_send: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_notification_send(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, JSONB, BIGINT) IS
  'DEFINER. 9-arg form (S2-19 lock). Checks notification_subscription preference, resolves delivery status by channel, inserts notification_dispatch_log, emits Strategy A audit. No direct HTTP route — called by fn_advisory_dispatch and BE notification-dispatcher.service.ts.';
REVOKE EXECUTE ON FUNCTION fn_notification_send(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_send(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, JSONB, BIGINT) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_notification_dispatch_retry_due (DEFINER VOLATILE) — batch claim for retry worker
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_notification_dispatch_retry_due(
  p_batch_size INTEGER DEFAULT 25
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_data JSONB;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                  ndl.id,
    'channel',             ndl.channel,
    'recipientAddress',    ndl.recipient_address,
    'subject',             ndl.subject,
    'bodyRendered',        ndl.body_rendered,
    'retryCount',          ndl.retry_count,
    'deliveryAttemptedAt', ndl.delivery_attempted_at,
    'tenantId',            ndl.tenant_id
  )), '[]'::jsonb) INTO v_data
  FROM notification_dispatch_log ndl
  WHERE ndl.status = 'pending_retry'
    AND ndl.next_retry_at <= NOW()
  ORDER BY ndl.next_retry_at ASC
  LIMIT p_batch_size
  FOR UPDATE SKIP LOCKED;

  RETURN jsonb_build_object('data', v_data);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_dispatch_retry_due: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_notification_dispatch_retry_due(INTEGER) IS
  'DEFINER. Claims a batch of pending_retry notification_dispatch_log rows (FOR UPDATE SKIP LOCKED) for the retry worker. Cross-tenant; returned rows carry tenantId so BE can SET LOCAL app.current_tenant_id.';
REVOKE EXECUTE ON FUNCTION fn_notification_dispatch_retry_due(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_dispatch_retry_due(INTEGER) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_notification_dispatch_update_retry_outcome (DEFINER VOLATILE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_notification_dispatch_update_retry_outcome(
  p_id            BIGINT,
  p_success       BOOLEAN,
  p_error_message TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row       notification_dispatch_log%ROWTYPE;
  v_new_retry INTEGER;
  v_backoff   INTERVAL;
  v_result    JSONB;
BEGIN
  -- S2-17 row lock
  SELECT * INTO v_row FROM notification_dispatch_log
  WHERE id = p_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_notification_dispatch_update_retry_outcome: row_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  IF p_success THEN
    UPDATE notification_dispatch_log SET
      status               = 'sent',
      delivery_completed_at = NOW(),
      error_message         = NULL
    WHERE id = p_id;
  ELSE
    v_new_retry := v_row.retry_count + 1;

    IF v_new_retry >= 5 THEN
      UPDATE notification_dispatch_log SET
        status               = 'final_failed',
        retry_count          = v_new_retry,
        error_message        = p_error_message,
        delivery_completed_at = NULL
      WHERE id = p_id;
    ELSE
      v_backoff := CASE v_new_retry
        WHEN 1 THEN INTERVAL '1 minute'
        WHEN 2 THEN INTERVAL '5 minutes'
        WHEN 3 THEN INTERVAL '30 minutes'
        WHEN 4 THEN INTERVAL '2 hours'
        WHEN 5 THEN INTERVAL '8 hours'
      END;
      -- BACKOFF_SCALE env override applied by BE caller (NOTIFICATION_RETRY_BACKOFF_SCALE_SECONDS)
      UPDATE notification_dispatch_log SET
        status        = 'pending_retry',
        retry_count   = v_new_retry,
        next_retry_at = NOW() + v_backoff,
        error_message = p_error_message
      WHERE id = p_id;
    END IF;
  END IF;

  -- Strategy A audit (S2-28)
  PERFORM fn_audit_log_record_v2(
    'notification_dispatch_log', p_id, 'UPDATE',
    jsonb_build_object('status', v_row.status, 'retryCount', v_row.retry_count),
    jsonb_build_object(
      'success',    p_success,
      'actionCode', CASE WHEN p_success THEN 'notification.retry_success' ELSE 'notification.retry_failed' END
    ),
    NULL  -- system actor (retry worker has no user)
  );

  SELECT jsonb_build_object(
    'id',          ndl.id,
    'status',      ndl.status,
    'retryCount',  ndl.retry_count,
    'nextRetryAt', ndl.next_retry_at
  ) INTO v_result
  FROM notification_dispatch_log ndl
  WHERE ndl.id = p_id;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_dispatch_update_retry_outcome: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_notification_dispatch_update_retry_outcome(BIGINT, BOOLEAN, TEXT) IS
  'DEFINER. Updates notification_dispatch_log after SMTP retry attempt. Backoff sequence: 1m/5m/30m/2h/8h. Marks final_failed at retry_count=5. Emits Strategy A audit. No HTTP route.';
REVOKE EXECUTE ON FUNCTION fn_notification_dispatch_update_retry_outcome(BIGINT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_dispatch_update_retry_outcome(BIGINT, BOOLEAN, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (218, '218_crh_fn_notification_send_function', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_notification_dispatch_update_retry_outcome(BIGINT, BOOLEAN, TEXT);
-- DROP FUNCTION IF EXISTS fn_notification_dispatch_retry_due(INTEGER);
-- DROP FUNCTION IF EXISTS fn_notification_send(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, JSONB, BIGINT);
-- DELETE FROM schema_migrations WHERE version = 218;
-- ============================================================
