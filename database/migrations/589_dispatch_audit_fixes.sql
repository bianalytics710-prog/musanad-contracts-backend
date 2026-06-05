-- Migration: 589_dispatch_audit_fixes.sql
-- Module: Notification trigger rules v2 — audit fixes
-- Date: 2026-06-05
--
-- Fixes two issues surfaced by the v2 audit:
--
-- FIX 1 (CRITICAL): Rule 30's in_app channel pointed at the .email template
--   slug (contract.expiry_30day.email). The dispatcher resolved it, so in-app
--   messages rendered with email-styled content. Creates a proper
--   contract.expiry_30day.in_app template and repoints the channel.
--
-- FIX 2 (HIGH): fn_obligation_flag and fn_obligation_sla_dispatch looped
--   over v_user_ids and called fn_notification_dispatch once per user with
--   each as caller_user_id. When admin added a non-'caller' recipient (e.g.
--   role:legal_counsel) the dispatcher fanned the role recipient across
--   every iteration, multiplying dispatches N × (1 + M).
--
--   Refactor: emit ONE event per obligation with notifyUserIds:[ids] in the
--   payload. The seeded default recipient changes from context:caller to
--   context:notifyUserIds. The resolver code already handles JSON arrays
--   (mig 585) so no resolver change is needed; we just register the
--   resolver name in fn_notification_context_resolver_list so the admin UI
--   shows it in its dropdown.

BEGIN;

-- ============================================================
-- FIX 1 — Create contract.expiry_30day.in_app template + repoint rule 30
-- ============================================================
INSERT INTO notification_template (
  tenant_id, template_id, channel,
  subject_en, subject_ar,
  body_en, body_ar,
  parameter_schema, data_classification,
  is_active, created_at, updated_at
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'contract.expiry_30day.in_app',
  'in_app',
  '{{contractTitle}} expires in {{daysToExpiry}} days',
  'ينتهي {{contractTitle}} خلال {{daysToExpiry}} يومًا',
  'The contract {{contractTitle}} expires in {{daysToExpiry}} days. Open the contract to renew or extend.',
  'العقد {{contractTitle}} ينتهي خلال {{daysToExpiry}} يومًا. افتح العقد لتجديده أو تمديده.',
  '{"daysToExpiry":"number","contractTitle":"string"}'::jsonb,
  'demo',
  TRUE, NOW(), NOW()
WHERE NOT EXISTS (
  SELECT 1 FROM notification_template
  WHERE template_id = 'contract.expiry_30day.in_app' AND is_active = TRUE
);

UPDATE notification_rule_channel
   SET template_slug = 'contract.expiry_30day.in_app',
       updated_at    = NOW()
 WHERE rule_id = 30
   AND channel = 'in_app'
   AND template_slug = 'contract.expiry_30day.email'
   AND is_active = TRUE;

-- Keep the v1 mirror in sync: rule 30's first (and only) channel is in_app,
-- so notification_rule.template_id must follow the same slug change.
UPDATE notification_rule
   SET template_id = 'contract.expiry_30day.in_app',
       updated_at  = NOW()
 WHERE id = 30
   AND template_id = 'contract.expiry_30day.email';

-- ============================================================
-- FIX 2a — Refactor fn_obligation_flag to single-dispatch-per-event
-- ============================================================
CREATE OR REPLACE FUNCTION fn_obligation_flag(
  p_actor_id      BIGINT,
  p_obligation_id BIGINT,
  p_note          TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id     UUID;
  v_tenant_guc    TEXT;
  v_role_mapping  JSONB;
  v_oblig         contract_obligation%ROWTYPE;
  v_role_codes    TEXT[];
  v_user_ids      BIGINT[];
  v_event_id      BIGINT;
  v_contract_no   TEXT;
  v_subject       TEXT;
  v_body          TEXT;
  v_dispatch_res  JSONB;
  v_notif_count   INTEGER := 0;
BEGIN
  IF NOT fn_current_user_has_permission('obligation.flag') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_tenant_guc := current_setting('app.current_tenant_id', true);
  IF v_tenant_guc IS NOT NULL AND v_tenant_guc <> '' THEN
    v_tenant_id := v_tenant_guc::uuid;
  ELSE
    SELECT id INTO v_tenant_id FROM tenant WHERE is_active = TRUE LIMIT 1;
  END IF;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_not_resolved' USING ERRCODE = '22023';
  END IF;
  PERFORM set_config('app.current_tenant_id', v_tenant_id::text, true);

  SELECT * INTO v_oblig FROM contract_obligation WHERE id = p_obligation_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'obligation_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT contract_number INTO v_contract_no FROM contract WHERE id = v_oblig.contract_id;
  SELECT value INTO v_role_mapping FROM system_setting WHERE key = 'obligations.escalation.role_mapping';
  IF v_role_mapping IS NULL THEN
    v_role_codes := ARRAY[]::TEXT[];
  ELSE
    SELECT COALESCE(array_agg(DISTINCT role_name), ARRAY[]::TEXT[]) INTO v_role_codes
    FROM jsonb_array_elements_text(v_role_mapping->v_oblig.obligation_type) AS role_name;
  END IF;

  -- Build candidate user list (deduplicated, excluding the actor themselves).
  SELECT COALESCE(array_agg(DISTINCT u.id), ARRAY[]::BIGINT[]) INTO v_user_ids
  FROM "user" u
  JOIN role r ON r.id = u.role_id AND r.is_active = TRUE
  WHERE u.is_active = TRUE
    AND r.name = ANY(v_role_codes)
    AND u.id <> p_actor_id;

  IF v_oblig.assignee_user_id IS NOT NULL AND v_oblig.assignee_user_id <> p_actor_id THEN
    v_user_ids := array(SELECT DISTINCT unnest(v_user_ids || v_oblig.assignee_user_id));
  END IF;

  v_subject := 'Obligation flagged: ' || COALESCE(v_oblig.title_en, '(untitled)');
  v_body :=
    'An executive has flagged this obligation for your attention.' ||
    E'\n\nContract: '   || COALESCE(v_contract_no, '—') ||
    E'\nObligation: '   || COALESCE(v_oblig.title_en, '—') ||
    E'\nDue date: '     || COALESCE(v_oblig.due_date::text, '—') ||
    CASE WHEN p_note IS NOT NULL AND length(trim(p_note)) > 0
         THEN E'\n\nNote from executive:\n' || trim(p_note)
         ELSE ''
    END;

  INSERT INTO obligation_escalation_event (
    tenant_id, obligation_id, escalation_type, tier_day,
    escalated_by_user_id, notified_role_codes, notified_user_ids,
    notification_count, note, created_at, created_by, is_active
  ) VALUES (
    v_tenant_id, p_obligation_id, 'manual', NULL,
    p_actor_id, v_role_codes, v_user_ids,
    0, p_note, NOW(), p_actor_id, TRUE
  ) RETURNING id INTO v_event_id;

  -- v2 (mig 589) — emit ONE event with notifyUserIds:[ids]. The seeded
  -- default rule uses recipient_type='context' value='notifyUserIds' which
  -- expands the array via fn_internal_resolve_recipient. Admin-added
  -- recipients (e.g. role:legal_counsel) fire ONCE per event instead of
  -- multiplying across each candidate user.
  BEGIN
    v_dispatch_res := fn_notification_dispatch(
      p_actor_id,
      'obligation.flag',
      jsonb_build_object(
        'subject',        v_subject,
        'bodyRendered',   v_body,
        'obligationId',   p_obligation_id,
        'contractId',     v_oblig.contract_id,
        'flagEventId',    v_event_id,
        'notifyUserIds',  to_jsonb(v_user_ids),
        'source',         'obligation.flag'
      ),
      'alert',
      'high',
      NULL::BIGINT,         -- caller no longer used; the 'caller' resolver
      NULL::TEXT            -- would return zero recipients (intentional)
    );
    v_notif_count := COALESCE((v_dispatch_res->>'dispatchesCreated')::integer, 0);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'fn_obligation_flag: dispatch failed: %', SQLERRM;
  END;

  UPDATE obligation_escalation_event SET notification_count = v_notif_count WHERE id = v_event_id;

  PERFORM fn_audit_log_record_v2(
    'contract_obligation', p_obligation_id, 'UPDATE',
    NULL::jsonb,
    jsonb_build_object(
      'flagged',           TRUE,
      'escalationEventId', v_event_id,
      'roleCodes',         v_role_codes,
      'notificationCount', v_notif_count,
      'actionCode',        'obligation.flag'
    ),
    p_actor_id
  );

  RETURN jsonb_build_object(
    'eventId',           v_event_id,
    'roleCodes',         v_role_codes,
    'notifiedUserIds',   v_user_ids,
    'notificationCount', v_notif_count
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_obligation_flag(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligation_flag(BIGINT, BIGINT, TEXT) TO neondb_owner;

-- ============================================================
-- FIX 2b — Refactor fn_obligation_sla_dispatch to single-dispatch-per-event
-- ============================================================
CREATE OR REPLACE FUNCTION fn_obligation_sla_dispatch(
  p_obligation_id BIGINT,
  p_tier_day      INTEGER
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_tenant_id    UUID;
  v_oblig        contract_obligation%ROWTYPE;
  v_contract_no  TEXT;
  v_role_mapping JSONB;
  v_tiers        JSONB;
  v_tier         JSONB;
  v_priority     TEXT;
  v_extra_roles  TEXT[];
  v_type_roles   TEXT[];
  v_role_codes   TEXT[];
  v_user_ids     BIGINT[];
  v_event_id     BIGINT;
  v_subject      TEXT;
  v_body         TEXT;
  v_dispatch_res JSONB;
  v_notif_count  INTEGER := 0;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_obligation_sla_dispatch: tenant_context_missing' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_oblig FROM contract_obligation WHERE id = p_obligation_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'obligation_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (
    SELECT 1 FROM obligation_escalation_event
    WHERE obligation_id = p_obligation_id
      AND escalation_type = 'sla'
      AND tier_day = p_tier_day
  ) THEN
    RETURN jsonb_build_object('skipped', TRUE, 'reason', 'already_dispatched');
  END IF;

  SELECT contract_number INTO v_contract_no FROM contract WHERE id = v_oblig.contract_id;
  SELECT value INTO v_role_mapping FROM system_setting WHERE key = 'obligations.escalation.role_mapping';
  SELECT value INTO v_tiers        FROM system_setting WHERE key = 'obligations.escalation.sla_tiers';

  SELECT t INTO v_tier
  FROM jsonb_array_elements(v_tiers) t
  WHERE (t->>'tierDay')::int = p_tier_day;

  IF v_tier IS NULL THEN
    RAISE EXCEPTION 'sla_tier_not_found' USING ERRCODE = 'P0002';
  END IF;
  v_priority := COALESCE(v_tier->>'priority', 'high');

  SELECT COALESCE(array_agg(DISTINCT role_name), ARRAY[]::TEXT[]) INTO v_type_roles
  FROM jsonb_array_elements_text(v_role_mapping->v_oblig.obligation_type) AS role_name;
  SELECT COALESCE(array_agg(DISTINCT role_name), ARRAY[]::TEXT[]) INTO v_extra_roles
  FROM jsonb_array_elements_text(v_tier->'notifyRoles') AS role_name;
  v_role_codes := array(SELECT DISTINCT unnest(v_type_roles || v_extra_roles));

  SELECT COALESCE(array_agg(DISTINCT u.id), ARRAY[]::BIGINT[]) INTO v_user_ids
  FROM "user" u JOIN role r ON r.id = u.role_id AND r.is_active = TRUE
  WHERE u.is_active = TRUE AND r.name = ANY(v_role_codes);

  IF v_oblig.assignee_user_id IS NOT NULL THEN
    v_user_ids := array(SELECT DISTINCT unnest(v_user_ids || v_oblig.assignee_user_id));
  END IF;

  v_subject := 'Obligation overdue (T+' || p_tier_day || 'd): ' || COALESCE(v_oblig.title_en, '(untitled)');
  v_body :=
    'This obligation is more than ' || p_tier_day || ' day(s) overdue and has been auto-escalated.' ||
    E'\n\nContract: '   || COALESCE(v_contract_no, '—') ||
    E'\nObligation: '   || COALESCE(v_oblig.title_en, '—') ||
    E'\nDue date: '     || COALESCE(v_oblig.due_date::text, '—');

  INSERT INTO obligation_escalation_event (
    tenant_id, obligation_id, escalation_type, tier_day,
    escalated_by_user_id, notified_role_codes, notified_user_ids,
    notification_count, note, created_at, created_by, is_active
  ) VALUES (
    v_tenant_id, p_obligation_id, 'sla', p_tier_day,
    NULL, v_role_codes, v_user_ids,
    0, NULL, NOW(), NULL, TRUE
  ) RETURNING id INTO v_event_id;

  -- v2 (mig 589) — single dispatch with notifyUserIds:[ids].
  BEGIN
    v_dispatch_res := fn_notification_dispatch(
      0::BIGINT,
      'obligation.sla_breach',
      jsonb_build_object(
        'subject',       v_subject,
        'bodyRendered',  v_body,
        'obligationId',  p_obligation_id,
        'contractId',    v_oblig.contract_id,
        'tierDay',       p_tier_day,
        'flagEventId',   v_event_id,
        'notifyUserIds', to_jsonb(v_user_ids),
        'source',        'obligation.sla'
      ),
      'alert',
      v_priority,
      NULL::BIGINT,
      NULL::TEXT
    );
    v_notif_count := COALESCE((v_dispatch_res->>'dispatchesCreated')::integer, 0);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'fn_obligation_sla_dispatch: dispatch failed: %', SQLERRM;
  END;

  UPDATE obligation_escalation_event SET notification_count = v_notif_count WHERE id = v_event_id;

  RETURN jsonb_build_object(
    'eventId',           v_event_id,
    'tierDay',           p_tier_day,
    'roleCodes',         v_role_codes,
    'notifiedUserIds',   v_user_ids,
    'notificationCount', v_notif_count
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_obligation_sla_dispatch(BIGINT, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligation_sla_dispatch(BIGINT, INTEGER) TO neondb_owner;

-- ============================================================
-- FIX 2c — Update seeded recipients: caller → notifyUserIds for the two events
-- ============================================================
UPDATE notification_rule_recipient
   SET recipient_value = 'notifyUserIds',
       updated_at      = NOW()
 WHERE rule_id IN (
         SELECT id FROM notification_rule
          WHERE event_type IN ('obligation.flag','obligation.sla_breach')
            AND tenant_id IS NULL
            AND is_active = TRUE
       )
   AND recipient_type  = 'context'
   AND recipient_value = 'caller'
   AND is_active       = TRUE;

-- ============================================================
-- FIX 2d — Register notifyUserIds in the resolver catalogue so the admin UI
-- shows it in its dropdown.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_notification_context_resolver_list()
RETURNS JSONB
LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_build_object('data', jsonb_build_array(
    jsonb_build_object('code','caller',            'label','Whoever the call site supplied (legacy default)'),
    jsonb_build_object('code','notifyUserIds',     'label','Caller-supplied user-id array (multi-recipient events)'),
    jsonb_build_object('code','contractAssignee',  'label','Contract assignee'),
    jsonb_build_object('code','contractDrafter',   'label','Contract drafter'),
    jsonb_build_object('code','contractCreator',   'label','Contract creator'),
    jsonb_build_object('code','approvalRequester', 'label','Approval requester'),
    jsonb_build_object('code','approvalApprover', 'label','Approval current approver'),
    jsonb_build_object('code','signatureSigner',   'label','Signature signer'),
    jsonb_build_object('code','commentMentionees', 'label','Comment @-mentioned users'),
    jsonb_build_object('code','currentWatchers',   'label','Contract watchers'),
    jsonb_build_object('code','advisoryRecipient', 'label','Advisory recipient')
  ));
$$;

REVOKE ALL ON FUNCTION fn_notification_context_resolver_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_context_resolver_list() TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (589, '589_dispatch_audit_fixes', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- UPDATE notification_rule_recipient
--    SET recipient_value = 'caller'
--  WHERE rule_id IN (
--          SELECT id FROM notification_rule
--           WHERE event_type IN ('obligation.flag','obligation.sla_breach')
--             AND tenant_id IS NULL
--             AND is_active = TRUE
--        )
--    AND recipient_type  = 'context'
--    AND recipient_value = 'notifyUserIds';
-- UPDATE notification_rule_channel
--    SET template_slug = 'contract.expiry_30day.email'
--  WHERE rule_id = 30 AND channel = 'in_app';
-- UPDATE notification_rule
--    SET template_id = 'contract.expiry_30day.email'
--  WHERE id = 30;
-- UPDATE notification_template SET is_active = FALSE
--  WHERE template_id = 'contract.expiry_30day.in_app';
-- -- The two fn refactors must be hand-rolled-back from mig 586 source.
-- DELETE FROM schema_migrations WHERE version = 589;
-- COMMIT;
