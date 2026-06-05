-- Migration: 580_notification_rule_fns.sql
-- Module: Email/notification trigger rules (Platform Admin, feature B)
-- Date: 2026-06-05
--
-- Fn surface:
--   fn_notification_rule_list(p_event_type, p_channel, p_search)
--   fn_notification_rule_upsert(p_actor, p_id, p_event_type, p_template_id,
--                               p_channel, p_is_enabled, p_audience,
--                               p_condition, p_priority, p_cooldown_minutes,
--                               p_description)
--   fn_notification_rule_set_enabled(p_actor, p_id, p_is_enabled)
--   fn_notification_rule_deactivate(p_actor, p_id)
--   fn_notification_rule_is_enabled(p_template_id, p_channel)  ← consumed by
--                                                                fn_notification_send
--
-- Plus: REPLACE fn_notification_send so it consults the rule registry and
-- short-circuits with status='suppressed_by_rule' when the matching rule is
-- disabled. Day-1 behavior is identical because the seed enables every
-- existing template. Admins toggle off to silence.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. fn_notification_rule_is_enabled (HOT PATH) ────────────
-- STABLE — same input returns the same value within a statement so the
-- planner can fold the call. SECURITY DEFINER so it bypasses RLS on
-- notification_rule (the dispatcher runs as the original actor; the rule
-- table is a system-wide registry).
CREATE OR REPLACE FUNCTION fn_notification_rule_is_enabled(
  p_template_id TEXT,
  p_channel     TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant   UUID := current_setting('app.current_tenant_id', true)::uuid;
  v_enabled  BOOLEAN;
BEGIN
  -- Tenant-specific rule wins.
  SELECT is_enabled INTO v_enabled
  FROM notification_rule
  WHERE template_id = p_template_id
    AND channel     = p_channel
    AND tenant_id   = v_tenant
    AND is_active   = TRUE
  LIMIT 1;
  IF FOUND THEN RETURN v_enabled; END IF;

  -- Fall back to system default (tenant_id NULL).
  SELECT is_enabled INTO v_enabled
  FROM notification_rule
  WHERE template_id = p_template_id
    AND channel     = p_channel
    AND tenant_id   IS NULL
    AND is_active   = TRUE
  LIMIT 1;
  IF FOUND THEN RETURN v_enabled; END IF;

  -- No rule found → preserve legacy behavior (send).
  RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION fn_notification_rule_is_enabled(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_rule_is_enabled(TEXT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_notification_rule_is_enabled(TEXT, TEXT) IS
  'Hot-path check: returns TRUE if the current tenant should receive (template_id, channel) notifications. Tenant-specific row wins; falls back to system default; defaults TRUE when no rule exists.';

-- ── 2. REPLACE fn_notification_send with rule short-circuit ──
-- Identical to mig 218 except for a 14-line block right before the
-- subscription check that consults the rule registry.
CREATE OR REPLACE FUNCTION fn_notification_send(
  p_actor_id                BIGINT,
  p_notification_template_id BIGINT,
  p_notification_kind       TEXT,
  p_channel                 TEXT,
  p_priority                TEXT,
  p_recipient_user_id       BIGINT,
  p_recipient_address       TEXT,
  p_context                 JSONB,
  p_advisory_draft_id       BIGINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
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
  v_template_slug  TEXT;
  v_rule_enabled   BOOLEAN;
BEGIN
  v_actor := NULLIF(p_actor_id, 0);
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

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

  IF p_notification_template_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM notification_template WHERE id = p_notification_template_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_notification_send: notification_template_not_found'
      USING ERRCODE = '23503';
  END IF;

  v_subject := p_context->>'subject';
  v_body    := p_context->>'bodyRendered';
  IF v_body IS NULL OR trim(v_body) = '' THEN
    v_body := p_context->>'body';
  END IF;
  IF v_body IS NULL THEN v_body := ''; END IF;

  -- ─── NEW: rule registry short-circuit ───────────────────────
  -- Resolve the template_id slug, then ask the rule registry whether the
  -- current tenant wants this (slug, channel) combo. Disabled rule →
  -- record a suppressed_by_rule row and return early (no dispatch).
  IF p_notification_template_id IS NOT NULL THEN
    SELECT template_id INTO v_template_slug
    FROM notification_template
    WHERE id = p_notification_template_id;
    IF v_template_slug IS NOT NULL THEN
      v_rule_enabled := fn_notification_rule_is_enabled(v_template_slug, p_channel);
      IF NOT v_rule_enabled THEN
        INSERT INTO notification_dispatch_log (
          tenant_id, notification_template_id, notification_kind, priority, channel,
          recipient_user_id, recipient_address, subject, body_rendered, context_payload,
          status, delivery_attempted_at, retry_count, next_retry_at,
          advisory_draft_id, data_classification,
          created_at, created_by, is_active
        ) VALUES (
          v_tenant_id, p_notification_template_id, p_notification_kind, p_priority, p_channel,
          p_recipient_user_id, p_recipient_address, v_subject, COALESCE(v_body, ''),
          p_context - 'bodyRendered' - 'subject',
          'suppressed_by_rule', NOW(), 0, NULL,
          p_advisory_draft_id, 'sensitive',
          NOW(), v_actor, TRUE
        )
        RETURNING id INTO v_id;
        RETURN jsonb_build_object(
          'notificationDispatchLogId', v_id,
          'status',                    'suppressed_by_rule',
          'renderedSubject',           v_subject,
          'channel',                   p_channel
        );
      END IF;
    END IF;
  END IF;
  -- ─── end rule short-circuit ─────────────────────────────────

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
      v_pm      := 'high';
    END IF;

    v_priority_order := CASE p_priority WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END;
    v_pm_order       := CASE v_pm WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END;

    IF (NOT v_enabled) OR (v_priority_order < v_pm_order) THEN
      v_status := 'suppressed_by_preference';
    END IF;
  END IF;

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

  INSERT INTO notification_dispatch_log (
    tenant_id, notification_template_id, notification_kind, priority, channel,
    recipient_user_id, recipient_address, subject, body_rendered, context_payload,
    status, delivery_attempted_at, retry_count, next_retry_at,
    advisory_draft_id, data_classification,
    created_at, created_by, is_active
  ) VALUES (
    v_tenant_id, p_notification_template_id, p_notification_kind, p_priority, p_channel,
    p_recipient_user_id, p_recipient_address, v_subject, COALESCE(v_body, ''),
    p_context - 'bodyRendered' - 'subject',
    v_status, NOW(), 0, v_next_retry,
    p_advisory_draft_id, 'sensitive',
    NOW(), v_actor, TRUE
  )
  RETURNING id INTO v_id;

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
    COALESCE(NULLIF(p_actor_id, 0), NULL)
  );

  RETURN jsonb_build_object(
    'notificationDispatchLogId', v_id,
    'status',                    v_status,
    'renderedSubject',           v_subject,
    'channel',                   p_channel
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_notification_send: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_notification_send(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, JSONB, BIGINT) IS
  'DEFINER. Extended in mig 580 with a notification_rule short-circuit: if a matching rule for (template_id, channel) exists and is_enabled=FALSE, records status=suppressed_by_rule and returns without dispatching.';
REVOKE EXECUTE ON FUNCTION fn_notification_send(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_send(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, JSONB, BIGINT) TO neondb_owner;

-- ── 3. Extend the dispatch-log status CHECK to allow suppressed_by_rule ──
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.notification_dispatch_log'::regclass
      AND conname  = 'notification_dispatch_log_status_check'
  ) THEN
    ALTER TABLE notification_dispatch_log
      DROP CONSTRAINT notification_dispatch_log_status_check;
  END IF;
  ALTER TABLE notification_dispatch_log
    ADD CONSTRAINT notification_dispatch_log_status_check
    CHECK (status IN (
      'pending','pending_retry','sent','captured_only','failed','final_failed',
      'suppressed_by_preference','suppressed_by_rule','suppressed'
    ));
END $$;

-- ── 4. Admin CRUD fns ────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_notification_rule_list(
  p_event_type TEXT DEFAULT NULL,
  p_channel    TEXT DEFAULT NULL,
  p_search     TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant UUID := current_setting('app.current_tenant_id', true)::uuid;
  v_data   JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('platform.notifications.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.notifications.manage required' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(row ORDER BY (row->>'sortOrder')::int NULLS LAST, row->>'eventType', row->>'channel'), '[]'::jsonb)
  INTO v_data
  FROM (
    SELECT jsonb_build_object(
      'id',               r.id,
      'tenantId',         r.tenant_id,
      'isSystemDefault',  (r.tenant_id IS NULL),
      'eventType',        r.event_type,
      'eventCategory',    et.category,
      'eventDisplayName', et.display_name,
      'eventDescription', et.description,
      'sortOrder',        et.sort_order,
      'templateId',       r.template_id,
      'channel',          r.channel,
      'isEnabled',        r.is_enabled,
      'audience',         r.audience,
      'condition',        r.condition,
      'priority',         r.priority,
      'cooldownMinutes',  r.cooldown_minutes,
      'description',      r.description,
      'createdAt',        r.created_at,
      'updatedAt',        r.updated_at
    ) AS row
    FROM notification_rule r
    JOIN notification_event_type et ON et.code = r.event_type
    WHERE r.is_active = TRUE
      AND (r.tenant_id = v_tenant OR r.tenant_id IS NULL)
      AND (p_event_type IS NULL OR r.event_type = p_event_type)
      AND (p_channel    IS NULL OR r.channel    = p_channel)
      AND (p_search IS NULL OR
           r.template_id ILIKE '%' || p_search || '%' OR
           et.display_name ILIKE '%' || p_search || '%')
  ) sub;

  RETURN jsonb_build_object('data', v_data);
END $$;

REVOKE ALL ON FUNCTION fn_notification_rule_list(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_rule_list(TEXT, TEXT, TEXT) TO neondb_owner;

-- Set enabled flag in-place. Works for both system defaults (tenant_id IS NULL)
-- and tenant-specific overrides. SECURITY DEFINER, so the platform admin can
-- toggle system rows even though RLS would otherwise block writes.
CREATE OR REPLACE FUNCTION fn_notification_rule_set_enabled(
  p_actor_id  BIGINT,
  p_id        BIGINT,
  p_enabled   BOOLEAN
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.notifications.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.notifications.manage required' USING ERRCODE = '42501';
  END IF;

  UPDATE notification_rule
  SET is_enabled = p_enabled,
      updated_at = NOW(),
      updated_by = p_actor_id
  WHERE id = p_id AND is_active = TRUE
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'notification_rule % not found', p_id USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object('id', v_id, 'isEnabled', p_enabled);
END $$;

REVOKE ALL ON FUNCTION fn_notification_rule_set_enabled(BIGINT, BIGINT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_rule_set_enabled(BIGINT, BIGINT, BOOLEAN) TO neondb_owner;

-- Upsert (create or update). Stores audience/condition as JSONB blobs.
CREATE OR REPLACE FUNCTION fn_notification_rule_upsert(
  p_actor_id        BIGINT,
  p_id              BIGINT,
  p_event_type      TEXT,
  p_template_id     TEXT,
  p_channel         TEXT,
  p_is_enabled      BOOLEAN,
  p_audience        JSONB,
  p_condition       JSONB,
  p_priority        TEXT,
  p_cooldown_minutes INTEGER,
  p_description     TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.notifications.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.notifications.manage required' USING ERRCODE = '42501';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO notification_rule (
      tenant_id, event_type, template_id, channel, is_enabled,
      audience, condition, priority, cooldown_minutes, description,
      created_by, updated_by
    ) VALUES (
      NULL,  -- system default; tenant overrides come later
      p_event_type, p_template_id, p_channel, COALESCE(p_is_enabled, TRUE),
      COALESCE(p_audience, '{}'::jsonb),
      p_condition,
      COALESCE(p_priority, 'medium'),
      COALESCE(p_cooldown_minutes, 0),
      p_description,
      p_actor_id, p_actor_id
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE notification_rule
    SET event_type       = p_event_type,
        template_id      = p_template_id,
        channel          = p_channel,
        is_enabled       = COALESCE(p_is_enabled, is_enabled),
        audience         = COALESCE(p_audience, audience),
        condition        = p_condition,
        priority         = COALESCE(p_priority, priority),
        cooldown_minutes = COALESCE(p_cooldown_minutes, cooldown_minutes),
        description      = p_description,
        updated_at       = NOW(),
        updated_by       = p_actor_id
    WHERE id = p_id AND is_active = TRUE
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'notification_rule % not found', p_id USING ERRCODE = 'P0002';
    END IF;
  END IF;
  RETURN jsonb_build_object('id', v_id);
END $$;

REVOKE ALL ON FUNCTION fn_notification_rule_upsert(BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, JSONB, JSONB, TEXT, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_rule_upsert(BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, JSONB, JSONB, TEXT, INTEGER, TEXT) TO neondb_owner;

-- Soft-delete.
CREATE OR REPLACE FUNCTION fn_notification_rule_deactivate(p_actor_id BIGINT, p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.notifications.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.notifications.manage required' USING ERRCODE = '42501';
  END IF;

  UPDATE notification_rule
  SET is_active = FALSE, updated_at = NOW(), updated_by = p_actor_id
  WHERE id = p_id AND is_active = TRUE
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'notification_rule % not found', p_id USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object('id', v_id, 'isActive', FALSE);
END $$;

REVOKE ALL ON FUNCTION fn_notification_rule_deactivate(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_rule_deactivate(BIGINT, BIGINT) TO neondb_owner;

-- Event-type catalogue read.
CREATE OR REPLACE FUNCTION fn_notification_event_type_list()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_data JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('platform.notifications.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.notifications.manage required' USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'code',        code,
    'displayName', display_name,
    'description', description,
    'category',    category,
    'sortOrder',   sort_order
  ) ORDER BY sort_order, code), '[]'::jsonb)
  INTO v_data
  FROM notification_event_type WHERE is_active = TRUE;
  RETURN jsonb_build_object('data', v_data);
END $$;

REVOKE ALL ON FUNCTION fn_notification_event_type_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_event_type_list() TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (580, '580_notification_rule_fns', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_notification_event_type_list();
-- DROP FUNCTION IF EXISTS fn_notification_rule_deactivate(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_notification_rule_upsert(BIGINT, BIGINT, TEXT, TEXT, TEXT, BOOLEAN, JSONB, JSONB, TEXT, INTEGER, TEXT);
-- DROP FUNCTION IF EXISTS fn_notification_rule_set_enabled(BIGINT, BIGINT, BOOLEAN);
-- DROP FUNCTION IF EXISTS fn_notification_rule_list(TEXT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_notification_rule_is_enabled(TEXT, TEXT);
-- -- (fn_notification_send revert: re-apply mig 218's CREATE OR REPLACE body.)
-- DELETE FROM schema_migrations WHERE version = 580;
-- COMMIT;
-- ============================================================
