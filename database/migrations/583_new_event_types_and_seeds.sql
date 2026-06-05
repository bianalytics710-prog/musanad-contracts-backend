-- Migration: 583_new_event_types_and_seeds.sql
-- Module: Notification trigger rules v2 — event catalogue extensions
-- Date: 2026-06-05
--
-- The Phase 2 inventory found 3 events the BE currently emits via hardcoded
-- fn_notification_send calls that didn't yet exist in notification_event_type:
--   - obligation.flag
--   - obligation.sla_breach
--   - report.delivered
--
-- This migration adds them + seeds default rules so the next-migration call
-- site refactor (584) has working rules to dispatch through.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. Extend the category CHECK to allow obligation + report ──
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.notification_event_type'::regclass
      AND conname  = 'notification_event_type_category_check'
  ) THEN
    ALTER TABLE notification_event_type
      DROP CONSTRAINT notification_event_type_category_check;
  END IF;
  ALTER TABLE notification_event_type
    ADD CONSTRAINT notification_event_type_category_check
    CHECK (category IN (
      'approval','contract','signature','advisory','impact','user',
      'import','watch','regulatory','comment','system','obligation','report'
    ));
END $$;

-- ── 2. New events ────────────────────────────────────────────
INSERT INTO notification_event_type (code, display_name, category, description, sort_order) VALUES
  ('obligation.flag',        'Obligation flagged',        'obligation', 'A drafter / counsel manually flagged an obligation for attention.', 270),
  ('obligation.sla_breach',  'Obligation SLA breach',     'obligation', 'An obligation breached its SLA tier.',                              280),
  ('report.delivered',       'Scheduled report delivered','report',     'A scheduled report finished and is ready for the recipients.',      290)
ON CONFLICT (code) DO NOTHING;

-- A few templates these events route to may not exist yet — create minimal
-- in_app placeholders so the dispatcher has something to render. The bodies
-- come from the call site via context_payload.subject + bodyRendered, so the
-- template rows just need to exist + be active.
INSERT INTO notification_template (
  tenant_id, template_id, channel, subject_en, subject_ar, body_en, body_ar, parameter_schema, data_classification
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid, slug, channel,
  default_subject, default_subject,
  default_body,    default_body,
  '{}'::jsonb, 'demo'
FROM (VALUES
  ('obligation.flag.in_app',        'in_app', '{{subject}}', '{{bodyRendered}}'),
  ('obligation.sla_breach.in_app',  'in_app', '{{subject}}', '{{bodyRendered}}'),
  ('report.delivered.email',        'email',  '{{subject}}', '{{bodyRendered}}')
) AS x(slug, channel, default_subject, default_body)
WHERE NOT EXISTS (
  SELECT 1 FROM notification_template t WHERE t.template_id = x.slug AND t.is_active = TRUE
);

-- ── 3. Seed default rules for the new events ────────────────
-- All 3 use the 'caller' context resolver so day-1 behavior is identical:
-- whatever recipient the BE code site passes today gets the notification.
INSERT INTO notification_rule (
  tenant_id, module, name, event_type, template_id, channel,
  is_enabled, priority, description, ordering
) VALUES
  (NULL, 'obligation', 'Obligation flagged (in_app)',       'obligation.flag',       'obligation.flag.in_app',       'in_app', TRUE, 'high', 'Day-1 wiring for the manual obligation-flag dispatcher.', 100),
  (NULL, 'obligation', 'Obligation SLA breach (in_app)',    'obligation.sla_breach', 'obligation.sla_breach.in_app', 'in_app', TRUE, 'high', 'Day-1 wiring for the SLA-breach cron.',                    100),
  (NULL, 'report',     'Scheduled report delivered (email)','report.delivered',      'report.delivered.email',       'email',  TRUE, 'medium','Day-1 wiring for the scheduled-report worker.',           100)
ON CONFLICT DO NOTHING;

-- ── 4. Add the corresponding channel + recipient rows ───────
INSERT INTO notification_rule_channel (rule_id, channel, template_slug)
SELECT r.id, r.channel, r.template_id
FROM notification_rule r
WHERE r.event_type IN ('obligation.flag','obligation.sla_breach','report.delivered')
  AND r.tenant_id IS NULL
  AND r.is_active = TRUE
  AND NOT EXISTS (
    SELECT 1 FROM notification_rule_channel c
    WHERE c.rule_id = r.id AND c.channel = r.channel
  );

INSERT INTO notification_rule_recipient (rule_id, recipient_type, recipient_value)
SELECT r.id, 'context', 'caller'
FROM notification_rule r
WHERE r.event_type IN ('obligation.flag','obligation.sla_breach','report.delivered')
  AND r.tenant_id IS NULL
  AND r.is_active = TRUE
  AND NOT EXISTS (
    SELECT 1 FROM notification_rule_recipient rec WHERE rec.rule_id = r.id
  );

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (583, '583_new_event_types_and_seeds', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DELETE FROM notification_rule_recipient WHERE rule_id IN
--   (SELECT id FROM notification_rule WHERE event_type IN ('obligation.flag','obligation.sla_breach','report.delivered'));
-- DELETE FROM notification_rule_channel WHERE rule_id IN
--   (SELECT id FROM notification_rule WHERE event_type IN ('obligation.flag','obligation.sla_breach','report.delivered'));
-- DELETE FROM notification_rule WHERE event_type IN ('obligation.flag','obligation.sla_breach','report.delivered');
-- DELETE FROM notification_template WHERE template_id IN
--   ('obligation.flag.in_app','obligation.sla_breach.in_app','report.delivered.email');
-- DELETE FROM notification_event_type WHERE code IN ('obligation.flag','obligation.sla_breach','report.delivered');
-- DELETE FROM schema_migrations WHERE version = 583;
-- COMMIT;
-- ============================================================
