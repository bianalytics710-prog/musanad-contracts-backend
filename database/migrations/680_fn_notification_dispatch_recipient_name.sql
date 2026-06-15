-- Migration 680 — Fix recipient name lookup in fn_notification_dispatch.
-- mig 679 referenced v_resolved.full_name but fn_internal_resolve_recipient
-- returns only (user_id, email). Look up full_name from "user" instead.
BEGIN;

CREATE OR REPLACE FUNCTION public.fn_notification_dispatch(
  p_actor_id          BIGINT,
  p_event_type        TEXT,
  p_payload           JSONB,
  p_notification_kind TEXT,
  p_priority          TEXT,
  p_caller_user_id    BIGINT DEFAULT NULL,
  p_caller_email      TEXT   DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant         UUID := current_setting('app.current_tenant_id', true)::uuid;
  v_rule           RECORD;
  v_chan           RECORD;
  v_rec            RECORD;
  v_resolved       RECORD;
  v_template_row   RECORD;
  v_dedupe_str     TEXT;
  v_last_dedupe    TIMESTAMPTZ;
  v_rules_eval     INT := 0;
  v_rules_fired    INT := 0;
  v_dispatches     INT := 0;
  v_send_priority  TEXT;
  v_per_rule       JSONB := '[]'::jsonb;
  v_rule_detail    JSONB;
  v_cond_ok        BOOLEAN;
  v_subject_en     TEXT;
  v_body_en        TEXT;
  v_subject_ar     TEXT;
  v_body_ar        TEXT;
  v_render_ctx     JSONB;
  v_recipient_name TEXT;
BEGIN
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

    v_cond_ok := fn_internal_condition_matches(v_rule.condition, p_payload);
    IF NOT v_cond_ok THEN
      v_rule_detail := v_rule_detail || jsonb_build_object('skipped', 'condition');
      v_per_rule := v_per_rule || v_rule_detail;
      CONTINUE;
    END IF;

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
          v_rule_detail := v_rule_detail || jsonb_build_object('skipped', 'dedupe');
          v_per_rule := v_per_rule || v_rule_detail;
          CONTINUE;
        END IF;
      END IF;
    END IF;

    v_send_priority := COALESCE(v_rule.priority, p_priority, 'medium');

    FOR v_chan IN
      SELECT * FROM notification_rule_channel
      WHERE rule_id = v_rule.id AND is_active = TRUE
    LOOP
      SELECT *
        INTO v_template_row
      FROM notification_template
      WHERE template_id = v_chan.template_slug AND is_active = TRUE
      LIMIT 1;
      IF v_template_row.id IS NULL THEN CONTINUE; END IF;

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
          IF v_resolved.user_id IS NULL AND v_resolved.email IS NULL THEN CONTINUE; END IF;

          v_recipient_name := NULL;
          IF v_resolved.user_id IS NOT NULL THEN
            SELECT TRIM(CONCAT_WS(' ', first_name, last_name))
              INTO v_recipient_name
              FROM "user" WHERE id = v_resolved.user_id;
          END IF;

          v_render_ctx := p_payload || jsonb_build_object(
            'recipientName',  COALESCE(v_recipient_name, ''),
            'recipientEmail', COALESCE(v_resolved.email, '')
          );
          v_subject_en := fn_mustache_render(v_template_row.subject_en, v_render_ctx);
          v_body_en    := fn_mustache_render(v_template_row.body_en,    v_render_ctx);
          v_subject_ar := fn_mustache_render(v_template_row.subject_ar, v_render_ctx);
          v_body_ar    := fn_mustache_render(v_template_row.body_ar,    v_render_ctx);

          BEGIN
            PERFORM fn_notification_send(
              p_actor_id,
              v_template_row.id,
              p_notification_kind,
              v_chan.channel,
              v_send_priority,
              v_resolved.user_id,
              v_resolved.email,
              v_render_ctx || jsonb_build_object(
                'eventType',        p_event_type,
                'dedupeKey',        COALESCE(v_dedupe_str, ''),
                'ruleId',           v_rule.id,
                'subject',          v_subject_en,
                'bodyRendered',     v_body_en,
                'subjectAr',        v_subject_ar,
                'bodyRenderedAr',   v_body_ar
              ),
              NULLIF((p_payload->>'advisoryDraftId')::text, '')::bigint
            );
            v_dispatches := v_dispatches + 1;
          EXCEPTION WHEN OTHERS THEN
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
END
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (680, 'fn_notification_dispatch_recipient_name', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
