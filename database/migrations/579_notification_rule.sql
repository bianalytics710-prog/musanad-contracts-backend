-- Migration: 579_notification_rule.sql
-- Module: Email/notification trigger rules (Platform Admin, feature B)
-- Date: 2026-06-05
--
-- Goal: replace the hardcoded "when X happens, fire template Y" wiring with
-- an admin-controllable rule table. v1 deliverable: a registry that admins
-- can browse, toggle on/off, and edit basic routing for. The dispatch fn
-- (fn_notification_send) consults this table before fanning out; toggling a
-- rule off silences the corresponding template immediately.
--
-- Two tables:
--   notification_event_type   — closed enum of event types (e.g.
--                                'approval.pending', 'contract.expiry_30day').
--   notification_rule         — per-event, per-channel routing config.
--
-- Per-tenant overrides supported: tenant_id NULL = system default
-- (applies to all tenants when no tenant override exists). Tenant-specific
-- rows win over NULL.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. notification_event_type ───────────────────────────────
CREATE TABLE IF NOT EXISTS notification_event_type (
  code         TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  description  TEXT,
  category     TEXT NOT NULL CHECK (category IN (
    'approval','contract','signature','advisory','impact','user',
    'import','watch','regulatory','comment','system'
  )),
  sort_order   INTEGER NOT NULL DEFAULT 100,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE notification_event_type IS
  'Closed enum of notification events the platform emits. Each row drives one or more notification_rule entries (one per channel).';

-- Seed the events that are currently hardcoded into BE call sites. Event
-- codes mirror the prefix of existing notification_template.template_id
-- slugs (e.g. template_id "approval.pending.in_app" → event_type
-- "approval.pending").
INSERT INTO notification_event_type (code, display_name, category, description, sort_order) VALUES
  ('approval.pending',                'Approval pending',                'approval',   'Approver assigned a step — waiting for action.',            10),
  ('approval.approved',               'Approval approved',               'approval',   'Approver approved a contract step.',                          20),
  ('approval.rejected',               'Approval rejected',               'approval',   'Approver rejected a contract.',                               30),
  ('approval.escalated',              'Approval escalated',              'approval',   'Step escalated (SLA breach or manual).',                      40),
  ('approval.delegated',              'Approval delegated',              'approval',   'Approver delegated their step to another user.',              50),
  ('approval.requested_changes',      'Approval — changes requested',    'approval',   'Approver requested changes on a contract.',                   60),
  ('contract.assigned',               'Contract assigned',               'contract',   'A contract was assigned to a drafter or counterparty.',       70),
  ('contract.amended',                'Contract amended',                'contract',   'A new version of the contract was published.',                80),
  ('contract.status_change',          'Contract status change',          'contract',   'Lifecycle state moved (Draft → In Review → Active …).',       90),
  ('contract.expiry_30day',           'Contract expiring in 30 days',    'contract',   '30-day expiry reminder.',                                    100),
  ('contract.expiry_7day',            'Contract expiring in 7 days',     'contract',   '7-day expiry reminder.',                                     110),
  ('signature.invitation',            'Signature invitation',            'signature',  'Counter-party invited to sign.',                             120),
  ('signature.reminder',              'Signature reminder',              'signature',  'Reminder to pending signer.',                                130),
  ('signature.completed',             'Signature completed',             'signature',  'All parties have signed.',                                   140),
  ('signature.declined',              'Signature declined',              'signature',  'A signer declined.',                                         150),
  ('comment.mention',                 'Comment @-mention',               'comment',    'You were @-mentioned on a contract.',                        160),
  ('advisory.dispatched',             'Advisory dispatched',             'advisory',   'Legal counsel advisory was dispatched.',                     170),
  ('advisory.acknowledged',           'Advisory acknowledged',           'advisory',   'Advisory was acknowledged by the recipient.',                180),
  ('advisory.rejected',               'Advisory draft rejected',         'advisory',   'Your advisory draft was rejected by the approver.',          190),
  ('impact.signal.notify_drafters',   'Impact signal — drafter notify',  'impact',     'OSINT impact signal that affects active contracts.',         200),
  ('regulatory.update_published',     'Regulatory update published',     'regulatory', 'New regulation impacting active contracts.',                 210),
  ('import.batch_complete',           'Import batch complete',           'import',     'Bulk-import job finished.',                                  220),
  ('import.batch_failed',             'Import batch failed',             'import',     'Bulk-import job failed.',                                    230),
  ('user.invited',                    'User invited',                    'user',       'A new user was invited to the platform.',                    240),
  ('user.password_reset',             'User password reset',             'user',       'A password reset was triggered.',                            250),
  ('watch.activity',                  'Watch activity',                  'watch',      'Contract you watch had activity.',                           260)
ON CONFLICT (code) DO NOTHING;

-- ── 2. notification_rule ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS notification_rule (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID REFERENCES tenant(id) ON DELETE RESTRICT,   -- NULL = system default
  event_type        TEXT NOT NULL REFERENCES notification_event_type(code) ON DELETE RESTRICT,
  template_id       TEXT NOT NULL,                                    -- matches notification_template.template_id (slug)
  channel           TEXT NOT NULL CHECK (channel IN ('email','in_app','teams_capture','slack_capture')),
  is_enabled        BOOLEAN NOT NULL DEFAULT TRUE,
  -- Audience: who should receive. Empty = caller-supplied (today's behavior).
  -- Shape: {"roles":["legal_counsel"], "userIds":[1,2], "additionalEmails":["..."]}
  audience          JSONB NOT NULL DEFAULT '{}'::jsonb,
  -- Optional predicates against the event payload. v1 stores it but
  -- evaluation lives in a later iteration. Shape: { "contract.valueAed": {"gte": 1000000} }
  condition         JSONB,
  priority          TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('low','medium','high','critical')),
  cooldown_minutes  INTEGER NOT NULL DEFAULT 0 CHECK (cooldown_minutes >= 0),
  description       TEXT,

  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by        BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by        BIGINT REFERENCES "user"(id) ON DELETE SET NULL
);

COMMENT ON TABLE notification_rule IS
  'Trigger rules: for each event_type + channel, decide whether to fire and which template to use. tenant_id NULL = system default for all tenants; tenant-specific rows take precedence over NULL.';
COMMENT ON COLUMN notification_rule.audience IS
  'Optional override of who receives the notification. Empty {} means caller-supplied (the dispatch site already knows the recipient).';
COMMENT ON COLUMN notification_rule.condition IS
  'Optional payload predicates. v1 stores it but does not evaluate — future enhancement.';

-- One rule per (tenant or system-default, template, channel).
CREATE UNIQUE INDEX uq_notification_rule_default
  ON notification_rule (template_id, channel)
  WHERE tenant_id IS NULL AND is_active = TRUE;
CREATE UNIQUE INDEX uq_notification_rule_tenant
  ON notification_rule (tenant_id, template_id, channel)
  WHERE tenant_id IS NOT NULL AND is_active = TRUE;

CREATE INDEX idx_notification_rule_event_type
  ON notification_rule (event_type) WHERE is_active = TRUE;

-- FORCE RLS — tenant rows scope to caller, but NULL-tenant defaults are
-- readable by every tenant (system-wide). Platform Admin queries bypass
-- via the SECURITY DEFINER fns below.
ALTER TABLE notification_rule ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_rule FORCE ROW LEVEL SECURITY;

-- Read policy: own tenant rows OR system defaults (NULL tenant_id).
CREATE POLICY notification_rule_select ON notification_rule
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
    OR tenant_id IS NULL
  );

-- Write policy: only own-tenant rows. System defaults are edited via the
-- SECURITY DEFINER admin fns (which check platform.notifications.manage).
CREATE POLICY notification_rule_modify ON notification_rule
  FOR ALL USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  ) WITH CHECK (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY notification_rule_deny_direct_delete ON notification_rule
  AS RESTRICTIVE FOR DELETE USING (FALSE);

CREATE TRIGGER audit_notification_rule_changes
  AFTER INSERT OR UPDATE OR DELETE ON notification_rule
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ── 3. Seed system defaults (one per existing template) ──────
-- Backfills the 29 hardcoded mappings so day-1 behavior is identical with
-- everything enabled. Admins can toggle off any single row to silence.
-- Each seed has tenant_id=NULL (system default).
INSERT INTO notification_rule (event_type, template_id, channel, is_enabled, priority, description)
SELECT
  -- Derive event_type by stripping the trailing channel suffix off the slug.
  CASE
    WHEN nt.template_id LIKE '%.email'          THEN substring(nt.template_id from 1 for length(nt.template_id) - 6)
    WHEN nt.template_id LIKE '%.in_app'         THEN substring(nt.template_id from 1 for length(nt.template_id) - 7)
    WHEN nt.template_id LIKE '%.teams_capture'  THEN substring(nt.template_id from 1 for length(nt.template_id) - 14)
    WHEN nt.template_id LIKE '%.slack_capture'  THEN substring(nt.template_id from 1 for length(nt.template_id) - 14)
    ELSE nt.template_id
  END AS event_type,
  nt.template_id,
  nt.channel,
  TRUE,
  CASE
    WHEN nt.template_id LIKE 'approval.escalated%' THEN 'high'
    WHEN nt.template_id LIKE 'import.batch_failed%' THEN 'high'
    WHEN nt.template_id LIKE 'advisory.%'           THEN 'high'
    WHEN nt.template_id LIKE 'contract.expiry_7day%' THEN 'high'
    WHEN nt.template_id LIKE 'signature.invitation%' THEN 'high'
    ELSE 'medium'
  END,
  'Seeded from notification_template; backfills the hardcoded BE wiring.'
FROM (
  SELECT DISTINCT template_id, channel FROM notification_template WHERE is_active = TRUE
) nt
WHERE EXISTS (
  SELECT 1 FROM notification_event_type net WHERE net.code = (
    CASE
      WHEN nt.template_id LIKE '%.email'          THEN substring(nt.template_id from 1 for length(nt.template_id) - 6)
      WHEN nt.template_id LIKE '%.in_app'         THEN substring(nt.template_id from 1 for length(nt.template_id) - 7)
      WHEN nt.template_id LIKE '%.teams_capture'  THEN substring(nt.template_id from 1 for length(nt.template_id) - 14)
      WHEN nt.template_id LIKE '%.slack_capture'  THEN substring(nt.template_id from 1 for length(nt.template_id) - 14)
      ELSE nt.template_id
    END
  )
)
ON CONFLICT DO NOTHING;

-- ── 4. New permission + role grants ──────────────────────────
INSERT INTO permission (code, module, action, description)
VALUES (
  'platform.notifications.manage', 'platform', 'notifications.manage',
  'Manage notification trigger rules (which event fires which template via which channel). Platform Admin + Super Admin only.'
)
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permission (role_id, permission_id, created_at)
SELECT r.id, p.id, NOW()
  FROM role r, permission p
 WHERE p.code = 'platform.notifications.manage'
   AND r.name IN ('platform_admin','Super Admin')
ON CONFLICT DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (579, '579_notification_rule', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_notification_rule_changes ON notification_rule;
-- DROP TABLE IF EXISTS notification_rule;
-- DROP TABLE IF EXISTS notification_event_type;
-- DELETE FROM role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code='platform.notifications.manage');
-- DELETE FROM permission WHERE code='platform.notifications.manage';
-- DELETE FROM schema_migrations WHERE version = 579;
-- COMMIT;
-- ============================================================
