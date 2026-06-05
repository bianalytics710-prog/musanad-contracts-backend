-- Migration: 587_condition_evaluator.sql
-- Module: Notification trigger rules v2 — condition predicate evaluator
-- Date: 2026-06-05
--
-- Adds fn_internal_condition_matches(condition JSONB, payload JSONB) and
-- wires it into fn_notification_dispatch so rules can be conditional
-- (e.g. "only when contract.valueAed >= 1_000_000").
--
-- Supported predicates (v1):
--   Equality           { "key.path": value }              — literal == compare
--   Greater-or-equal   { "key.path": { "gte": 10 } }
--   Greater-than       { "key.path": { "gt":  10 } }
--   Less-or-equal      { "key.path": { "lte": 10 } }
--   Less-than          { "key.path": { "lt":  10 } }
--   In list            { "key.path": { "in":  ["A","B"] } }
--   Not in list        { "key.path": { "notIn": ["A","B"] } }
--   Substring          { "key.path": { "contains": "foo" } }
--
-- Multiple keys are ANDed. JSON-pointer-style dotted paths (e.g.
-- "contract.valueAed") read from the payload via #>> string_to_array.
-- NULL or empty condition → always matches.

BEGIN;

CREATE OR REPLACE FUNCTION fn_internal_condition_matches(
  p_condition JSONB,
  p_payload   JSONB
) RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_key      TEXT;
  v_expected JSONB;
  v_actual   TEXT;
  v_actual_num NUMERIC;
  v_op       TEXT;
  v_op_val   JSONB;
  v_op_text  TEXT;
  v_op_num   NUMERIC;
  v_in_arr   JSONB;
  v_in_elem  JSONB;
  v_in_match BOOLEAN;
BEGIN
  -- NULL / empty / non-object → always true (rule fires for every payload).
  IF p_condition IS NULL OR jsonb_typeof(p_condition) <> 'object'
     OR (SELECT COUNT(*) FROM jsonb_object_keys(p_condition)) = 0 THEN
    RETURN TRUE;
  END IF;

  -- Iterate top-level keys. Each must match (AND semantics).
  FOR v_key, v_expected IN SELECT * FROM jsonb_each(p_condition)
  LOOP
    v_actual := p_payload #>> string_to_array(v_key, '.');

    -- Operator object form: { "gte": N } / { "in": [...] } / etc.
    IF jsonb_typeof(v_expected) = 'object' THEN
      FOR v_op, v_op_val IN SELECT * FROM jsonb_each(v_expected)
      LOOP
        CASE v_op
          WHEN 'gte', 'gt', 'lte', 'lt' THEN
            IF v_actual IS NULL THEN RETURN FALSE; END IF;
            BEGIN
              v_actual_num := v_actual::NUMERIC;
              v_op_num     := (v_op_val #>> '{}')::NUMERIC;
            EXCEPTION WHEN OTHERS THEN
              RETURN FALSE;
            END;
            IF (v_op = 'gte' AND v_actual_num <  v_op_num) THEN RETURN FALSE; END IF;
            IF (v_op = 'gt'  AND v_actual_num <= v_op_num) THEN RETURN FALSE; END IF;
            IF (v_op = 'lte' AND v_actual_num >  v_op_num) THEN RETURN FALSE; END IF;
            IF (v_op = 'lt'  AND v_actual_num >= v_op_num) THEN RETURN FALSE; END IF;

          WHEN 'eq' THEN
            v_op_text := v_op_val #>> '{}';
            IF v_actual IS DISTINCT FROM v_op_text THEN RETURN FALSE; END IF;

          WHEN 'neq' THEN
            v_op_text := v_op_val #>> '{}';
            IF v_actual IS NOT DISTINCT FROM v_op_text THEN RETURN FALSE; END IF;

          WHEN 'in' THEN
            IF v_actual IS NULL OR jsonb_typeof(v_op_val) <> 'array' THEN RETURN FALSE; END IF;
            v_in_match := FALSE;
            FOR v_in_elem IN SELECT * FROM jsonb_array_elements(v_op_val) LOOP
              IF (v_in_elem #>> '{}') = v_actual THEN
                v_in_match := TRUE; EXIT;
              END IF;
            END LOOP;
            IF NOT v_in_match THEN RETURN FALSE; END IF;

          WHEN 'notIn' THEN
            IF jsonb_typeof(v_op_val) <> 'array' THEN RETURN FALSE; END IF;
            v_in_match := FALSE;
            FOR v_in_elem IN SELECT * FROM jsonb_array_elements(v_op_val) LOOP
              IF (v_in_elem #>> '{}') = COALESCE(v_actual, '') THEN
                v_in_match := TRUE; EXIT;
              END IF;
            END LOOP;
            IF v_in_match THEN RETURN FALSE; END IF;

          WHEN 'contains' THEN
            v_op_text := v_op_val #>> '{}';
            IF v_actual IS NULL OR POSITION(v_op_text IN v_actual) = 0 THEN
              RETURN FALSE;
            END IF;

          ELSE
            -- Unknown operator → conservative: treat as no match.
            RETURN FALSE;
        END CASE;
      END LOOP;
    ELSE
      -- Scalar expected → literal equality.
      v_op_text := v_expected #>> '{}';
      IF v_actual IS DISTINCT FROM v_op_text THEN
        RETURN FALSE;
      END IF;
    END IF;
  END LOOP;

  RETURN TRUE;
END $$;

REVOKE ALL ON FUNCTION fn_internal_condition_matches(JSONB, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_internal_condition_matches(JSONB, JSONB) TO neondb_owner;

COMMENT ON FUNCTION fn_internal_condition_matches(JSONB, JSONB) IS
  'Evaluates a rule-condition predicate AST against an event payload. Operators: eq/neq/gte/gt/lte/lt/in/notIn/contains. Multiple keys ANDed. NULL/empty condition → always true.';

-- ── Re-deploy fn_notification_dispatch with condition gating ──────────────
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
  v_per_rule     JSONB := '[]'::jsonb;
  v_rule_detail  JSONB;
  v_cond_ok      BOOLEAN;
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

    -- Condition gating (NEW in mig 587).
    v_cond_ok := fn_internal_condition_matches(v_rule.condition, p_payload);
    IF NOT v_cond_ok THEN
      v_rule_detail := v_rule_detail || jsonb_build_object('skipped', 'condition');
      v_per_rule := v_per_rule || v_rule_detail;
      CONTINUE;
    END IF;

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
      SELECT id INTO v_template_pk
      FROM notification_template
      WHERE template_id = v_chan.template_slug AND is_active = TRUE
      LIMIT 1;
      IF v_template_pk IS NULL THEN CONTINUE; END IF;

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
          BEGIN
            PERFORM fn_notification_send(
              p_actor_id,
              v_template_pk,
              p_notification_kind,
              v_chan.channel,
              v_send_priority,
              v_resolved.user_id,
              v_resolved.email,
              p_payload || jsonb_build_object(
                'eventType', p_event_type,
                'dedupeKey', COALESCE(v_dedupe_str, ''),
                'ruleId',    v_rule.id
              ),
              NULL
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
END $$;

REVOKE ALL ON FUNCTION fn_notification_dispatch(BIGINT, TEXT, JSONB, TEXT, TEXT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_dispatch(BIGINT, TEXT, JSONB, TEXT, TEXT, BIGINT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (587, '587_condition_evaluator', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
