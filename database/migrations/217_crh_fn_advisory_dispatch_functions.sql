-- MIGRATION: 217_crh_fn_advisory_dispatch_functions.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: fn_advisory_dispatch (DEFINER VOLATILE) + fn_advisory_dispatch_log_list (STABLE INVOKER) — 2 fn_'s.
--              Each followed by COMMENT + REVOKE FROM PUBLIC + GRANT TO neondb_owner (S2-21/S2-27/B14).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ---------------------------------------------------------------------------
-- fn_advisory_dispatch (DEFINER VOLATILE) — orchestrator, S2-17 idempotency lock
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_dispatch(
  p_actor_id   BIGINT,
  p_id         BIGINT,
  p_recipients JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_actor          BIGINT;
  v_actor_role     TEXT;
  v_tenant_id      UUID;
  v_d              advisory_draft%ROWTYPE;
  v_channels       JSONB;
  v_chan           TEXT;
  v_rcpt           JSONB;
  v_ctx            JSONB;
  v_adv_id         BIGINT;
  v_notif_result   JSONB;
  v_advisory_log_ids   JSONB := '[]'::jsonb;
  v_notif_log_ids      JSONB := '[]'::jsonb;
  v_now            TIMESTAMPTZ;
  v_channel_label  TEXT;
  v_recipient_addr TEXT;
  v_rendered_payload JSONB;
BEGIN
  -- S2-20 v_actor=0→NULL
  v_actor := NULLIF(p_actor_id, 0);

  -- Permission gate: advisory.dispatch
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_actor AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_dispatch: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  -- S2-17 row lock (idempotency)
  SELECT * INTO v_d FROM advisory_draft
  WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_advisory_dispatch: draft_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Must be approved
  IF v_d.approval_status <> 'approved' THEN
    RAISE EXCEPTION 'fn_advisory_dispatch: draft_not_approved — approval_status must be approved, got %', v_d.approval_status
      USING ERRCODE = '23514';
  END IF;

  -- S2-18 NULL-safe IS NULL check (idempotency guard)
  IF v_d.dispatched_at IS NOT NULL THEN
    RAISE EXCEPTION 'fn_advisory_dispatch: already_dispatched'
      USING ERRCODE = '23505';
  END IF;

  -- Validate recipients
  IF p_recipients IS NULL OR jsonb_typeof(p_recipients) <> 'array' OR jsonb_array_length(p_recipients) < 1 THEN
    RAISE EXCEPTION 'fn_advisory_dispatch: missing_recipients — recipients must be a non-empty array'
      USING ERRCODE = '22023';
  END IF;

  -- Resolve template dispatch channels
  SELECT dispatch_channels INTO v_channels
  FROM advisory_template WHERE id = v_d.template_id;

  -- Loop over channels × recipients
  FOR v_chan IN SELECT jsonb_array_elements_text(v_channels) LOOP
    FOR v_rcpt IN SELECT jsonb_array_elements(p_recipients) LOOP
      -- Build context payload (subject + body pre-rendered by BE; passed via recipient object)
      v_ctx := v_d.template_context
               || jsonb_build_object(
                    'subject',          v_rcpt->>'subject',
                    'bodyRendered',     v_rcpt->>'body',
                    'advisoryDraftId',  v_d.id,
                    'correlationId',    v_d.correlation_id,
                    'contractId',       v_d.contract_id
                  );

      v_recipient_addr := v_rcpt->>'email';
      v_rendered_payload := jsonb_build_object(
        'channel',          v_chan,
        'recipient',        v_rcpt,
        'advisoryDraftId',  v_d.id,
        'draftType',        v_d.draft_type
      );

      -- Insert into advisory_dispatch_log (S2-22 explicit columns)
      INSERT INTO advisory_dispatch_log (
        tenant_id, advisory_draft_id, channel, recipient_address, rendered_payload,
        status, delivery_attempted_at, retry_count, data_classification,
        created_at, created_by, is_active
      ) VALUES (
        v_tenant_id, v_d.id, v_chan, v_recipient_addr, v_rendered_payload,
        CASE v_chan WHEN 'email' THEN 'pending_retry' ELSE 'captured_only' END,
        NOW(), 0, 'sensitive',
        NOW(), v_actor, TRUE
      )
      RETURNING id INTO v_adv_id;

      v_advisory_log_ids := v_advisory_log_ids || to_jsonb(v_adv_id);

      -- Strategy A audit for advisory_dispatch_log row
      PERFORM fn_audit_log_record_v2(
        'advisory_dispatch_log', v_adv_id, 'INSERT',
        NULL,
        jsonb_build_object(
          'channel',         v_chan,
          'advisoryDraftId', v_d.id,
          'recipientAddress','[REDACTED]',
          'actionCode',      'advisory.dispatch_log.created'
        ),
        v_actor
      );

      -- Delegate to fn_notification_send — 9-arg form locked per Design Note 7 (S2-19)
      v_notif_result := fn_notification_send(
        v_actor,                             -- 1 p_actor_id
        NULL::bigint,                         -- 2 p_notification_template_id
        'advisory'::text,                     -- 3 p_notification_kind
        v_chan,                              -- 4 p_channel
        'high'::text,                        -- 5 p_priority
        (v_rcpt->>'userId')::bigint,         -- 6 p_recipient_user_id
        v_rcpt->>'email',                    -- 7 p_recipient_address
        v_ctx,                               -- 8 p_context
        v_d.id                               -- 9 p_advisory_draft_id
      );

      v_notif_log_ids := v_notif_log_ids || (v_notif_result->'notificationDispatchLogId');

    END LOOP;
  END LOOP;

  -- Compute final channel label and mark dispatched
  v_now := NOW();
  v_channel_label := CASE jsonb_array_length(v_channels)
    WHEN 1 THEN v_channels->>0
    ELSE 'multi'
  END;

  UPDATE advisory_draft SET
    dispatched_at       = v_now,
    dispatch_channel    = v_channel_label,
    dispatch_recipients = p_recipients,
    updated_at          = v_now,
    updated_by          = v_actor
  WHERE id = p_id AND tenant_id = v_tenant_id;

  -- Lineage audit for dispatch event
  PERFORM fn_audit_log_record_v2(
    'advisory_draft', p_id, 'UPDATE',
    jsonb_build_object('dispatchedAt', NULL, 'dispatchChannel', NULL),
    jsonb_build_object(
      'dispatchedAt',    v_now,
      'dispatchChannel', v_channel_label,
      'recipientCount',  jsonb_array_length(p_recipients),
      'actionCode',      'advisory.dispatched'
    ),
    v_actor
  );

  RETURN jsonb_build_object(
    'draftId',                  p_id,
    'dispatchedAt',             v_now,
    'channels',                 v_channels,
    'advisoryDispatchLogIds',   v_advisory_log_ids,
    'notificationDispatchLogIds', v_notif_log_ids
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_dispatch: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_dispatch(BIGINT, BIGINT, JSONB) IS
  'DEFINER. Dispatches approved advisory to all configured channels × recipients. Idempotent (rejects if already dispatched). Calls fn_notification_send per channel/recipient. Emits lineage audit.';
REVOKE EXECUTE ON FUNCTION fn_advisory_dispatch(BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_dispatch(BIGINT, BIGINT, JSONB) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_advisory_dispatch_log_list (STABLE INVOKER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_dispatch_log_list(
  p_actor_id        BIGINT,
  p_advisory_draft_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_tenant_id  UUID;
  v_actor_role TEXT;
  v_has_perm   BOOLEAN;
  v_data       JSONB;
BEGIN
  -- Permission gate: advisory.draft.review OR notification.dispatch_log.read
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  v_has_perm := v_actor_role IN ('Super Admin','platform_admin','legal_counsel');
  IF NOT v_has_perm THEN
    RAISE EXCEPTION 'fn_advisory_dispatch_log_list: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  -- Verify draft exists in tenant
  IF NOT EXISTS (
    SELECT 1 FROM advisory_draft
    WHERE id = p_advisory_draft_id AND tenant_id = v_tenant_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'fn_advisory_dispatch_log_list: draft_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                  adl.id,
    'advisoryDraftId',     adl.advisory_draft_id,
    'channel',             adl.channel,
    'recipientAddress',    '[REDACTED]',
    'status',              adl.status,
    'deliveryAttemptedAt', adl.delivery_attempted_at,
    'deliveryCompletedAt', adl.delivery_completed_at,
    'retryCount',          adl.retry_count,
    'dataClassification',  adl.data_classification,
    'createdAt',           adl.created_at
  ) ORDER BY adl.delivery_attempted_at DESC), '[]'::jsonb) INTO v_data
  FROM advisory_dispatch_log adl
  WHERE adl.advisory_draft_id = p_advisory_draft_id
    AND adl.tenant_id = v_tenant_id;

  RETURN jsonb_build_object('data', v_data);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_dispatch_log_list: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_dispatch_log_list(BIGINT, BIGINT) IS
  'Returns all advisory_dispatch_log rows for the given advisory_draft, ordered by delivery_attempted_at DESC. Requires advisory.draft.review or notification.dispatch_log.read.';
REVOKE EXECUTE ON FUNCTION fn_advisory_dispatch_log_list(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_dispatch_log_list(BIGINT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (217, '217_crh_fn_advisory_dispatch_functions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_advisory_dispatch_log_list(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_advisory_dispatch(BIGINT, BIGINT, JSONB);
-- DELETE FROM schema_migrations WHERE version = 217;
-- ============================================================
