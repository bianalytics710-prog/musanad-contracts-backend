-- Migration: 582_notification_dispatch_fn.sql
-- Module: Notification trigger rules v2 — dispatcher
-- Date: 2026-06-05
--
-- Adds the single source-of-truth dispatcher fn_notification_dispatch and a
-- small set of helper readers that the admin UI uses (module catalogue,
-- recipient resolver catalogue, rule CRUD).
--
-- fn_notification_dispatch(event_type, payload) is the new entry point for
-- every BE code path that emits a notification event. It:
--   1. Selects all enabled, active rules matching event_type for the current
--      tenant or system default.
--   2. Skips rules whose dedupe_key (Mustache-substituted from payload) was
--      already dispatched inside the cooldown_minutes window.
--   3. For each rule, walks its channel rows.
--   4. For each channel row, resolves its recipient rows:
--        role     → SELECT user_id FROM user_role WHERE role.name = value
--        user     → value as bigint
--        context  → read payload->>resolverName (single id) or array of ids
--        email    → recipient_address only, recipient_user_id NULL
--   5. For each resolved (user_id, channel) pair, calls fn_notification_send
--      with the rule's template_id (looked up from template_slug).
--
-- The legacy mig-580 short-circuit inside fn_notification_send still applies —
-- so toggling a rule off silences both legacy direct callers and new event
-- emitters. Day-1 behavior preserved.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. Mustache-light substitution helper ────────────────────
-- Minimal {{key}} → payload.key substitution used by dedupe_key. Pure SQL,
-- handles missing keys by leaving the literal {{key}} in place.
CREATE OR REPLACE FUNCTION fn_internal_dedupe_key_render(
  p_template TEXT,
  p_payload  JSONB
) RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_result TEXT := COALESCE(p_template, '');
  v_match TEXT;
  v_key   TEXT;
  v_val   TEXT;
BEGIN
  IF v_result = '' THEN RETURN NULL; END IF;
  -- Loop over {{...}} matches.
  LOOP
    v_match := substring(v_result FROM '\{\{[a-zA-Z0-9_\.]+\}\}');
    EXIT WHEN v_match IS NULL;
    v_key := substring(v_match FROM 3 FOR length(v_match) - 4);
    v_val := COALESCE(p_payload #>> string_to_array(v_key, '.'), '');
    v_result := replace(v_result, v_match, v_val);
  END LOOP;
  RETURN v_result;
END $$;

REVOKE ALL ON FUNCTION fn_internal_dedupe_key_render(TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_internal_dedupe_key_render(TEXT, JSONB) TO neondb_owner;

-- ── 2. Recipient resolver ────────────────────────────────────
-- Given a recipient row and the event payload, returns the set of resolved
-- (user_id, email) pairs. user_id may be NULL for type='email'.
-- recipient_type='context' value='caller' returns the caller-supplied
-- recipient_user_id / recipient_address (preserves legacy behavior).
CREATE OR REPLACE FUNCTION fn_internal_resolve_recipient(
  p_recipient_type  TEXT,
  p_recipient_value TEXT,
  p_payload         JSONB,
  p_caller_user_id  BIGINT,
  p_caller_email    TEXT
) RETURNS TABLE (user_id BIGINT, email TEXT)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_tenant UUID := current_setting('app.current_tenant_id', true)::uuid;
  v_json_arr JSONB;
  v_single   TEXT;
BEGIN
  IF p_recipient_type = 'role' THEN
    RETURN QUERY
      SELECT DISTINCT ur.user_id, NULL::TEXT
      FROM "user_role" ur
      JOIN role r ON r.id = ur.role_id
      WHERE r.name = p_recipient_value
        AND ur.is_active = TRUE
        AND r.is_active = TRUE;
    RETURN;
  END IF;

  IF p_recipient_type = 'user' THEN
    BEGIN
      RETURN QUERY SELECT p_recipient_value::BIGINT, NULL::TEXT;
    EXCEPTION WHEN OTHERS THEN
      RETURN; -- bad id, silently drop
    END;
    RETURN;
  END IF;

  IF p_recipient_type = 'email' THEN
    RETURN QUERY SELECT NULL::BIGINT, p_recipient_value;
    RETURN;
  END IF;

  IF p_recipient_type = 'context' THEN
    -- 'caller' = use whoever the call site supplied. Preserves legacy behavior.
    IF p_recipient_value = 'caller' THEN
      IF p_caller_user_id IS NOT NULL OR p_caller_email IS NOT NULL THEN
        RETURN QUERY SELECT p_caller_user_id, p_caller_email;
      END IF;
      RETURN;
    END IF;

    -- Try payload->>p_recipient_value as a single bigint id first.
    v_single := p_payload->>p_recipient_value;
    IF v_single IS NOT NULL AND v_single ~ '^[0-9]+$' THEN
      RETURN QUERY SELECT v_single::BIGINT, NULL::TEXT;
      RETURN;
    END IF;

    -- Otherwise check whether it's a JSON array of ids.
    v_json_arr := p_payload->p_recipient_value;
    IF v_json_arr IS NOT NULL AND jsonb_typeof(v_json_arr) = 'array' THEN
      RETURN QUERY
        SELECT (val::TEXT)::BIGINT, NULL::TEXT
        FROM jsonb_array_elements_text(v_json_arr) val
        WHERE val ~ '^[0-9]+$';
      RETURN;
    END IF;

    -- Unknown resolver / missing payload key → no recipients.
    RETURN;
  END IF;
END $$;

REVOKE ALL ON FUNCTION fn_internal_resolve_recipient(TEXT, TEXT, JSONB, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_internal_resolve_recipient(TEXT, TEXT, JSONB, BIGINT, TEXT) TO neondb_owner;

-- ── 3. Main dispatcher ───────────────────────────────────────
-- Inputs:
--   p_actor_id           — typically the user who triggered the event.
--   p_event_type         — must match notification_event_type.code (or be unknown — then no-op).
--   p_payload            — JSONB context. Convention: include any id the resolvers need
--                          (contractId, contractAssigneeId, approvalApproverId, …) plus
--                          'subject' + 'bodyRendered' for the template.
--   p_notification_kind  — alert/advisory/approval_request/signature_request/system/risk_case/report.
--   p_priority           — low/medium/high/critical. Overridden per-rule by rule.priority if set.
--   p_caller_user_id     — legacy 'caller' resolver fallback.
--   p_caller_email       — legacy 'caller' resolver fallback.
--
-- Returns: JSONB with rulesEvaluated, rulesFired, dispatchesCreated counts +
-- per-rule details for debugging.
CREATE OR REPLACE FUNCTION fn_notification_dispatch(
  p_actor_id          BIGINT,
  p_event_type        TEXT,
  p_payload           JSONB,
  p_notification_kind TEXT,
  p_priority          TEXT,
  p_caller_user_id    BIGINT DEFAULT NULL,
  p_caller_email      TEXT   DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant       UUID := current_setting('app.current_tenant_id', true)::uuid;
  v_rule         RECORD;
  v_chan         RECORD;
  v_rec          RECORD;
  v_resolved     RECORD;
  v_template_pk  BIGINT;
  v_dedupe_str   TEXT;
  v_last_dedupe  TIMESTAMPTZ;
  v_rules_eval   INT := 0;
  v_rules_fired  INT := 0;
  v_dispatches   INT := 0;
  v_send_priority TEXT;
  v_send_res     JSONB;
  v_per_rule     JSONB := '[]'::jsonb;
  v_rule_detail  JSONB;
BEGIN
  -- Iterate rules: tenant-specific first, then system defaults. ordering ASC.
  FOR v_rule IN
    SELECT r.*
    FROM notification_rule r
    WHERE r.event_type = p_event_type
      AND r.is_active  = TRUE
      AND r.is_enabled = TRUE
      AND (r.tenant_id = v_tenant OR r.tenant_id IS NULL)
    ORDER BY (r.tenant_id IS NULL) ASC, r.ordering ASC, r.id ASC
  LOOP
    v_rules_eval := v_rules_eval + 1;
    v_rule_detail := jsonb_build_object('ruleId', v_rule.id, 'name', v_rule.name);

    -- Dedupe check.
    IF v_rule.dedupe_key IS NOT NULL AND v_rule.cooldown_minutes > 0 THEN
      v_dedupe_str := fn_internal_dedupe_key_render(v_rule.dedupe_key, p_payload);
      IF v_dedupe_str IS NOT NULL AND length(v_dedupe_str) > 0 THEN
        SELECT MAX(delivery_attempted_at) INTO v_last_dedupe
        FROM notification_dispatch_log
        WHERE tenant_id = v_tenant
          AND context_payload ? 'eventType'
          AND context_payload->>'eventType' = p_event_type
          AND context_payload->>'dedupeKey' = v_dedupe_str
          AND delivery_attempted_at > NOW() - (v_rule.cooldown_minutes || ' minutes')::INTERVAL;
        IF v_last_dedupe IS NOT NULL THEN
          v_rule_detail := v_rule_detail || jsonb_build_object('skipped', 'dedupe', 'lastAt', v_last_dedupe);
          v_per_rule := v_per_rule || v_rule_detail;
          CONTINUE;
        END IF;
      END IF;
    END IF;

    v_send_priority := COALESCE(v_rule.priority, p_priority, 'medium');

    -- Walk channels.
    FOR v_chan IN
      SELECT * FROM notification_rule_channel
      WHERE rule_id = v_rule.id AND is_active = TRUE
    LOOP
      -- Resolve template_slug → notification_template.id (pk).
      SELECT id INTO v_template_pk
      FROM notification_template
      WHERE template_id = v_chan.template_slug
        AND is_active = TRUE
      LIMIT 1;

      IF v_template_pk IS NULL THEN
        CONTINUE; -- template missing; skip silently
      END IF;

      -- Walk recipients.
      FOR v_rec IN
        SELECT * FROM notification_rule_recipient
        WHERE rule_id = v_rule.id AND is_active = TRUE
      LOOP
        FOR v_resolved IN
          SELECT * FROM fn_internal_resolve_recipient(
            v_rec.recipient_type, v_rec.recipient_value, p_payload,
            p_caller_user_id, p_caller_email
          )
        LOOP
          -- Skip if both are null.
          IF v_resolved.user_id IS NULL AND v_resolved.email IS NULL THEN
            CONTINUE;
          END IF;

          BEGIN
            v_send_res := fn_notification_send(
              p_actor_id,
              v_template_pk,
              p_notification_kind,
              v_chan.channel,
              v_send_priority,
              v_resolved.user_id,
              v_resolved.email,
              -- Stamp the payload with eventType + dedupeKey so the dedupe
              -- lookup above can find it next time. Subject + bodyRendered
              -- are passed through from the caller's payload.
              p_payload || jsonb_build_object(
                'eventType', p_event_type,
                'dedupeKey', COALESCE(v_dedupe_str, ''),
                'ruleId',    v_rule.id
              ),
              NULL
            );
            v_dispatches := v_dispatches + 1;
          EXCEPTION WHEN OTHERS THEN
            -- One bad send shouldn't sink the whole event. Log via dispatch fn's own audit.
            NULL;
          END;
        END LOOP;
      END LOOP;
    END LOOP;

    v_rules_fired := v_rules_fired + 1;
    v_rule_detail := v_rule_detail || jsonb_build_object('fired', TRUE);
    v_per_rule := v_per_rule || v_rule_detail;
  END LOOP;

  RETURN jsonb_build_object(
    'eventType',         p_event_type,
    'rulesEvaluated',    v_rules_eval,
    'rulesFired',        v_rules_fired,
    'dispatchesCreated', v_dispatches,
    'ruleDetails',       v_per_rule
  );
END $$;

REVOKE ALL ON FUNCTION fn_notification_dispatch(BIGINT, TEXT, JSONB, TEXT, TEXT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_dispatch(BIGINT, TEXT, JSONB, TEXT, TEXT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_notification_dispatch(BIGINT, TEXT, JSONB, TEXT, TEXT, BIGINT, TEXT) IS
  'Single source-of-truth dispatcher. Reads notification_rule + _channel + _recipient and fans out to fn_notification_send per (channel, recipient). Replaces hardcoded fn_notification_send calls at every event-emitting code path.';

-- ── 4. Catalogue helper: module list with rule counts ────────
CREATE OR REPLACE FUNCTION fn_notification_module_list()
RETURNS JSONB
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

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'module',     module,
    'ruleCount',  rule_count,
    'eventCount', event_count
  ) ORDER BY module), '[]'::jsonb)
  INTO v_data
  FROM (
    SELECT
      r.module,
      COUNT(DISTINCT r.id) AS rule_count,
      COUNT(DISTINCT r.event_type) AS event_count
    FROM notification_rule r
    WHERE r.is_active = TRUE
      AND r.module IS NOT NULL
      AND (r.tenant_id = v_tenant OR r.tenant_id IS NULL)
    GROUP BY r.module
  ) sub;
  RETURN jsonb_build_object('data', v_data);
END $$;

REVOKE ALL ON FUNCTION fn_notification_module_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_module_list() TO neondb_owner;

-- ── 5. Recipient resolver catalogue ──────────────────────────
-- Static list exposed to the admin UI's recipient-picker so the dropdown
-- shows the available resolvers. Returns hardcoded list (no table) because
-- the resolvers are implemented inside fn_internal_resolve_recipient.
CREATE OR REPLACE FUNCTION fn_notification_context_resolver_list()
RETURNS JSONB
LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_build_object('data', jsonb_build_array(
    jsonb_build_object('code','caller',                'label','Whoever the call site supplied (legacy default)'),
    jsonb_build_object('code','contractAssignee',      'label','Contract assignee'),
    jsonb_build_object('code','contractDrafter',       'label','Contract drafter'),
    jsonb_build_object('code','contractCreator',       'label','Contract creator'),
    jsonb_build_object('code','approvalRequester',     'label','Approval requester'),
    jsonb_build_object('code','approvalApprover',      'label','Approval current approver'),
    jsonb_build_object('code','signatureSigner',       'label','Signature signer'),
    jsonb_build_object('code','commentMentionees',     'label','Comment @-mentioned users'),
    jsonb_build_object('code','currentWatchers',       'label','Contract watchers'),
    jsonb_build_object('code','advisoryRecipient',     'label','Advisory recipient')
  ));
$$;

REVOKE ALL ON FUNCTION fn_notification_context_resolver_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_context_resolver_list() TO neondb_owner;

-- ── 6. Detailed rule reader (with channels + recipients) ─────
CREATE OR REPLACE FUNCTION fn_notification_rule_get_detail(p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant   UUID := current_setting('app.current_tenant_id', true)::uuid;
  v_rule     JSONB;
  v_channels JSONB;
  v_recips   JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('platform.notifications.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.notifications.manage required' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',               r.id,
    'tenantId',         r.tenant_id,
    'isSystemDefault',  (r.tenant_id IS NULL),
    'module',           r.module,
    'name',             r.name,
    'description',      r.description,
    'eventType',        r.event_type,
    'eventCategory',    et.category,
    'eventDisplayName', et.display_name,
    'isEnabled',        r.is_enabled,
    'priority',         r.priority,
    'condition',        r.condition,
    'cooldownMinutes',  r.cooldown_minutes,
    'dedupeKey',        r.dedupe_key,
    'ordering',         r.ordering
  )
  INTO v_rule
  FROM notification_rule r
  LEFT JOIN notification_event_type et ON et.code = r.event_type
  WHERE r.id = p_id AND r.is_active = TRUE
    AND (r.tenant_id = v_tenant OR r.tenant_id IS NULL);

  IF v_rule IS NULL THEN
    RAISE EXCEPTION 'notification_rule % not found', p_id USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',              c.id,
    'channel',         c.channel,
    'templateSlug',    c.template_slug,
    'subjectOverride', c.subject_override,
    'bodyOverride',    c.body_override
  ) ORDER BY c.channel), '[]'::jsonb)
  INTO v_channels
  FROM notification_rule_channel c
  WHERE c.rule_id = p_id AND c.is_active = TRUE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             r.id,
    'recipientType',  r.recipient_type,
    'recipientValue', r.recipient_value
  ) ORDER BY r.id), '[]'::jsonb)
  INTO v_recips
  FROM notification_rule_recipient r
  WHERE r.rule_id = p_id AND r.is_active = TRUE;

  RETURN v_rule || jsonb_build_object('channels', v_channels, 'recipients', v_recips);
END $$;

REVOKE ALL ON FUNCTION fn_notification_rule_get_detail(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_rule_get_detail(BIGINT) TO neondb_owner;

-- ── 7. Atomic upsert that handles rule + channels + recipients ──
-- Replaces the v1 fn_notification_rule_upsert. Channels and recipients are
-- replaced wholesale: pass the full desired set, and the fn diffs + persists.
CREATE OR REPLACE FUNCTION fn_notification_rule_upsert_v2(
  p_actor_id        BIGINT,
  p_id              BIGINT,                -- NULL = create
  p_tenant_id       UUID,                  -- NULL = system default
  p_module          TEXT,
  p_name            TEXT,
  p_description     TEXT,
  p_event_type      TEXT,
  p_is_enabled      BOOLEAN,
  p_priority        TEXT,
  p_condition       JSONB,
  p_cooldown_minutes INTEGER,
  p_dedupe_key      TEXT,
  p_ordering        INTEGER,
  p_channels        JSONB,                 -- array of { channel, templateSlug, subjectOverride, bodyOverride }
  p_recipients      JSONB                  -- array of { recipientType, recipientValue }
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id    BIGINT;
  v_legacy_template TEXT;
  v_legacy_channel  TEXT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.notifications.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.notifications.manage required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_channels) <> 'array' OR jsonb_array_length(p_channels) = 0 THEN
    RAISE EXCEPTION 'at least one channel is required' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_recipients) <> 'array' OR jsonb_array_length(p_recipients) = 0 THEN
    RAISE EXCEPTION 'at least one recipient is required' USING ERRCODE = '22023';
  END IF;

  -- The legacy template_id + channel columns on notification_rule are NOT NULL,
  -- so we populate them from the first channel row to keep the rows valid.
  v_legacy_channel := p_channels->0->>'channel';
  v_legacy_template := p_channels->0->>'templateSlug';

  IF p_id IS NULL THEN
    INSERT INTO notification_rule (
      tenant_id, module, name, description, event_type,
      template_id, channel,   -- legacy mirror
      is_enabled, priority, condition, cooldown_minutes, dedupe_key, ordering,
      created_by, updated_by
    ) VALUES (
      p_tenant_id, p_module, p_name, p_description, p_event_type,
      v_legacy_template, v_legacy_channel,
      COALESCE(p_is_enabled, TRUE),
      COALESCE(p_priority, 'medium'),
      p_condition,
      COALESCE(p_cooldown_minutes, 0),
      NULLIF(TRIM(COALESCE(p_dedupe_key, '')), ''),
      COALESCE(p_ordering, 100),
      p_actor_id, p_actor_id
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE notification_rule
    SET module           = p_module,
        name             = p_name,
        description      = p_description,
        event_type       = p_event_type,
        template_id      = v_legacy_template,
        channel          = v_legacy_channel,
        is_enabled       = COALESCE(p_is_enabled, is_enabled),
        priority         = COALESCE(p_priority, priority),
        condition        = p_condition,
        cooldown_minutes = COALESCE(p_cooldown_minutes, cooldown_minutes),
        dedupe_key       = NULLIF(TRIM(COALESCE(p_dedupe_key, '')), ''),
        ordering         = COALESCE(p_ordering, ordering),
        updated_at       = NOW(),
        updated_by       = p_actor_id
    WHERE id = p_id AND is_active = TRUE
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'notification_rule % not found', p_id USING ERRCODE = 'P0002';
    END IF;
    -- Wholesale replace child rows.
    UPDATE notification_rule_channel   SET is_active = FALSE WHERE rule_id = v_id AND is_active = TRUE;
    UPDATE notification_rule_recipient SET is_active = FALSE WHERE rule_id = v_id AND is_active = TRUE;
  END IF;

  -- Insert channels.
  INSERT INTO notification_rule_channel (rule_id, channel, template_slug, subject_override, body_override, created_by, updated_by)
  SELECT v_id,
         elem->>'channel',
         elem->>'templateSlug',
         NULLIF(TRIM(COALESCE(elem->>'subjectOverride','')), ''),
         NULLIF(TRIM(COALESCE(elem->>'bodyOverride','')), ''),
         p_actor_id, p_actor_id
  FROM jsonb_array_elements(p_channels) elem;

  -- Insert recipients.
  INSERT INTO notification_rule_recipient (rule_id, recipient_type, recipient_value, created_by, updated_by)
  SELECT v_id,
         elem->>'recipientType',
         elem->>'recipientValue',
         p_actor_id, p_actor_id
  FROM jsonb_array_elements(p_recipients) elem;

  RETURN fn_notification_rule_get_detail(v_id);
END $$;

REVOKE ALL ON FUNCTION fn_notification_rule_upsert_v2(BIGINT, BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, JSONB, INTEGER, TEXT, INTEGER, JSONB, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_rule_upsert_v2(BIGINT, BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, JSONB, INTEGER, TEXT, INTEGER, JSONB, JSONB) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (582, '582_notification_dispatch_fn', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_notification_rule_upsert_v2(BIGINT, BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, JSONB, INTEGER, TEXT, INTEGER, JSONB, JSONB);
-- DROP FUNCTION IF EXISTS fn_notification_rule_get_detail(BIGINT);
-- DROP FUNCTION IF EXISTS fn_notification_context_resolver_list();
-- DROP FUNCTION IF EXISTS fn_notification_module_list();
-- DROP FUNCTION IF EXISTS fn_notification_dispatch(BIGINT, TEXT, JSONB, TEXT, TEXT, BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_internal_resolve_recipient(TEXT, TEXT, JSONB, BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_internal_dedupe_key_render(TEXT, JSONB);
-- DELETE FROM schema_migrations WHERE version = 582;
-- COMMIT;
-- ============================================================
