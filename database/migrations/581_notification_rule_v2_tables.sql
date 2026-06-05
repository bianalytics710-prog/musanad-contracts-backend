-- Migration: 581_notification_rule_v2_tables.sql
-- Module: Notification trigger rules v2 — single-source-of-truth refactor
-- Date: 2026-06-05
--
-- Goal: replace the simple v1 (one rule = one template + one channel + caller-supplied recipient)
-- with the multi-recipient, multi-channel model inspired by ServiceNow / Jira / Salesforce.
--
-- Three tables in the final model:
--   notification_rule              — one logical rule (extended with module + name + dedupe_key)
--   notification_rule_channel      — one rule → N channels, each with its own template
--   notification_rule_recipient    — one rule → N recipient sources (role / user / context / email)
--
-- This migration adds the two new tables + extends notification_rule with the
-- columns the new dispatcher needs. The existing `template_id` + `channel`
-- columns on notification_rule remain temporarily for backwards-compat reads
-- during the transition; the next migration (582) migrates the existing 29
-- rows into the new model and switches the dispatcher to read from the new
-- tables.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. Extend notification_rule ──────────────────────────────
ALTER TABLE notification_rule
  ADD COLUMN IF NOT EXISTS module       TEXT,
  ADD COLUMN IF NOT EXISTS name         TEXT,
  ADD COLUMN IF NOT EXISTS dedupe_key   TEXT,
  ADD COLUMN IF NOT EXISTS ordering     INTEGER NOT NULL DEFAULT 100;

COMMENT ON COLUMN notification_rule.module IS
  'Closed enum-ish: contracts / approvals / signatures / advisory / impact / regulatory / imports / users / watch / comments / system. Derived from notification_event_type.category when not set explicitly; required for the module-first admin UI grouping.';
COMMENT ON COLUMN notification_rule.name IS
  'Human-friendly rule name (e.g. "Notify legal counsel on high-value contracts"). NULL is allowed during the transition; new rules require it.';
COMMENT ON COLUMN notification_rule.dedupe_key IS
  'Mustache-ish key (e.g. "{{contractId}}") used by the dispatcher to throttle repeated firings within cooldown_minutes window. NULL = no dedupe.';
COMMENT ON COLUMN notification_rule.ordering IS
  'Evaluation order. Lower = earlier. Matters when multiple rules match the same event and dedupe rules conflict.';

-- Backfill module from event_type.category for the 29 existing rows.
UPDATE notification_rule r
SET module = et.category
FROM notification_event_type et
WHERE r.event_type = et.code AND r.module IS NULL;

-- ── 2. notification_rule_channel ─────────────────────────────
CREATE TABLE IF NOT EXISTS notification_rule_channel (
  id                BIGSERIAL PRIMARY KEY,
  rule_id           BIGINT NOT NULL REFERENCES notification_rule(id) ON DELETE CASCADE,
  channel           TEXT NOT NULL CHECK (channel IN ('email','in_app','teams_capture','slack_capture')),
  template_slug     TEXT NOT NULL,            -- matches notification_template.template_id
  -- Optional per-channel overrides for v1.5+; left null in the migration.
  subject_override  TEXT,
  body_override     TEXT,

  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by        BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by        BIGINT REFERENCES "user"(id) ON DELETE SET NULL
);

COMMENT ON TABLE notification_rule_channel IS
  'One rule fires N channels. Each row picks a channel + the notification_template slug to render. A single rule can email + in-app simultaneously with two rows.';

CREATE UNIQUE INDEX uq_notification_rule_channel
  ON notification_rule_channel (rule_id, channel)
  WHERE is_active = TRUE;

CREATE INDEX idx_notification_rule_channel_template
  ON notification_rule_channel (template_slug) WHERE is_active = TRUE;

ALTER TABLE notification_rule_channel ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_rule_channel FORCE ROW LEVEL SECURITY;

-- Inherit visibility from the parent rule: visible if parent is visible
-- (tenant match or system default). Modify is allowed only on own-tenant rules.
CREATE POLICY notification_rule_channel_select ON notification_rule_channel
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM notification_rule r
      WHERE r.id = rule_id
        AND (r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
             OR r.tenant_id IS NULL)
    )
  );

CREATE POLICY notification_rule_channel_modify ON notification_rule_channel
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM notification_rule r
      WHERE r.id = rule_id
        AND r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    )
  ) WITH CHECK (
    EXISTS (
      SELECT 1 FROM notification_rule r
      WHERE r.id = rule_id
        AND r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    )
  );

CREATE POLICY notification_rule_channel_deny_direct_delete ON notification_rule_channel
  AS RESTRICTIVE FOR DELETE USING (FALSE);

CREATE TRIGGER audit_notification_rule_channel_changes
  AFTER INSERT OR UPDATE OR DELETE ON notification_rule_channel
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ── 3. notification_rule_recipient ───────────────────────────
CREATE TABLE IF NOT EXISTS notification_rule_recipient (
  id                BIGSERIAL PRIMARY KEY,
  rule_id           BIGINT NOT NULL REFERENCES notification_rule(id) ON DELETE CASCADE,

  recipient_type    TEXT NOT NULL CHECK (recipient_type IN ('role','user','context','email')),
  --   role     → recipient_value = role code (e.g. 'legal_counsel'). Dispatcher
  --              expands to all users in that role.
  --   user     → recipient_value = user id as text (e.g. '42'). Direct target.
  --   context  → recipient_value = resolver name. Dispatcher reads from payload.
  --              Recognised resolvers (extensible):
  --                'caller'              — legacy: use whoever the call site supplied
  --                'contractAssignee'    — payload.contractAssigneeId
  --                'contractDrafter'     — payload.contractDrafterId
  --                'contractCreator'     — payload.createdById
  --                'approvalRequester'   — payload.approvalRequesterId
  --                'approvalApprover'    — payload.approvalApproverId
  --                'signatureSigner'     — payload.signerUserId
  --                'commentMentionees'   — payload.mentionedUserIds (array)
  --                'currentWatchers'     — payload.watcherUserIds (array)
  --                'advisoryRecipient'   — payload.advisoryRecipientId
  --   email    → recipient_value = literal email address. recipient_user_id stays NULL.
  recipient_value   TEXT NOT NULL,

  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by        BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by        BIGINT REFERENCES "user"(id) ON DELETE SET NULL
);

COMMENT ON TABLE notification_rule_recipient IS
  'One rule → N recipient sources. Each row is a recipient_type + value. Dispatcher resolves to user_ids/emails at fire time. Multiple rows allowed (e.g. role:legal_counsel + role:platform_admin + context:contractAssignee = three audiences).';
COMMENT ON COLUMN notification_rule_recipient.recipient_type IS
  '"role" = user_role lookup; "user" = direct user id; "context" = resolver name read from payload; "email" = literal external address (no user_id).';
COMMENT ON COLUMN notification_rule_recipient.recipient_value IS
  'Interpreted per recipient_type. See table comment for resolver names.';

CREATE INDEX idx_notification_rule_recipient_rule
  ON notification_rule_recipient (rule_id) WHERE is_active = TRUE;
CREATE INDEX idx_notification_rule_recipient_type
  ON notification_rule_recipient (recipient_type) WHERE is_active = TRUE;

ALTER TABLE notification_rule_recipient ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_rule_recipient FORCE ROW LEVEL SECURITY;

CREATE POLICY notification_rule_recipient_select ON notification_rule_recipient
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM notification_rule r
      WHERE r.id = rule_id
        AND (r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
             OR r.tenant_id IS NULL)
    )
  );

CREATE POLICY notification_rule_recipient_modify ON notification_rule_recipient
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM notification_rule r
      WHERE r.id = rule_id
        AND r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    )
  ) WITH CHECK (
    EXISTS (
      SELECT 1 FROM notification_rule r
      WHERE r.id = rule_id
        AND r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    )
  );

CREATE POLICY notification_rule_recipient_deny_direct_delete ON notification_rule_recipient
  AS RESTRICTIVE FOR DELETE USING (FALSE);

CREATE TRIGGER audit_notification_rule_recipient_changes
  AFTER INSERT OR UPDATE OR DELETE ON notification_rule_recipient
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ── 4. Backfill notification_rule_channel from existing 29 rows ──
-- Each existing notification_rule has (template_id, channel) baked into it.
-- We mirror those into notification_rule_channel so the new dispatcher can
-- read uniformly. The legacy template_id + channel columns on notification_rule
-- remain populated for the transition.
INSERT INTO notification_rule_channel (rule_id, channel, template_slug)
SELECT r.id, r.channel, r.template_id
FROM notification_rule r
WHERE r.is_active = TRUE
  AND NOT EXISTS (
    SELECT 1 FROM notification_rule_channel c
    WHERE c.rule_id = r.id AND c.channel = r.channel
  );

-- ── 5. Backfill notification_rule_recipient with the "caller" context ──
-- For the 29 existing rules, we don't yet know recipients — they're
-- caller-supplied today. We seed one recipient row of type='context' /
-- value='caller' so the dispatcher knows "this rule preserves legacy
-- behavior — forward whatever recipient the call site passes".
--
-- When admin opens an existing rule in the new UI and adds explicit
-- recipients (role:legal_counsel, etc.), the 'caller' row should typically
-- be removed (replaced by the explicit list); the UI handles that.
INSERT INTO notification_rule_recipient (rule_id, recipient_type, recipient_value)
SELECT r.id, 'context', 'caller'
FROM notification_rule r
WHERE r.is_active = TRUE
  AND NOT EXISTS (
    SELECT 1 FROM notification_rule_recipient rec
    WHERE rec.rule_id = r.id
  );

-- ── 6. Backfill notification_rule.name for the 29 existing rows ──
UPDATE notification_rule r
SET name = COALESCE(
  r.name,
  et.display_name || ' (' || r.channel || ')'
)
FROM notification_event_type et
WHERE r.event_type = et.code AND r.name IS NULL;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (581, '581_notification_rule_v2_tables', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_notification_rule_recipient_changes ON notification_rule_recipient;
-- DROP TRIGGER IF EXISTS audit_notification_rule_channel_changes  ON notification_rule_channel;
-- DROP TABLE IF EXISTS notification_rule_recipient;
-- DROP TABLE IF EXISTS notification_rule_channel;
-- ALTER TABLE notification_rule DROP COLUMN IF EXISTS ordering;
-- ALTER TABLE notification_rule DROP COLUMN IF EXISTS dedupe_key;
-- ALTER TABLE notification_rule DROP COLUMN IF EXISTS name;
-- ALTER TABLE notification_rule DROP COLUMN IF EXISTS module;
-- DELETE FROM schema_migrations WHERE version = 581;
-- COMMIT;
-- ============================================================
