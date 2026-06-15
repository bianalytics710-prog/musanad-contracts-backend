-- ============================================================================
-- Migration 676 — Notification events + templates + rules for advisory review
-- ============================================================================
-- Phase 3 of the executive-review workflow: notifications must go through
-- the platform-admin notification module (events → templates → rules)
-- rather than direct INSERT INTO notification_dispatch_log. This way the
-- platform admin can tune subjects/bodies/audiences from the UI without
-- code changes.
--
-- Three new events covering the routed→approved→sent triangle (and an
-- 'exec modified' variant for Phase 2):
--   advisory.routed_for_review   → exec is told a new draft awaits review
--   advisory.approved_for_send   → LC is told an exec-reviewed draft is ready
--   advisory.modified_by_exec    → LC is told the exec edited the body
--
-- Each event gets one in_app template + one in_app rule (channel + role
-- recipient). Subjects + bodies use Mustache placeholders matching the
-- payload we'll pass via fn_notification_dispatch in mig 677.
-- ============================================================================

BEGIN;

-- 1. Event type catalog -----------------------------------------------------
INSERT INTO notification_event_type (code, display_name, description, category, sort_order)
VALUES
  ('advisory.routed_for_review',
   'Advisory routed for executive review',
   'Legal Counsel sent an advisory draft for executive review before dispatch.',
   'advisory', 30),
  ('advisory.approved_for_send',
   'Advisory approved — ready to send',
   'Executive approved an advisory draft. Legal Counsel can dispatch it.',
   'advisory', 31),
  ('advisory.modified_by_exec',
   'Advisory modified by executive',
   'Executive edited the advisory text. Legal Counsel should re-review before dispatch.',
   'advisory', 32)
ON CONFLICT (code) DO NOTHING;

-- 2. Templates (in_app channel, Mustache bodies) ----------------------------
-- Use the existing tenant for the demo (single-tenant scope; mig 380 +
-- many others follow this convention).
INSERT INTO notification_template (
  tenant_id, template_id, channel, subject_en, subject_ar, body_en, body_ar,
  parameter_schema, data_classification, created_by, updated_by
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'advisory.routed_for_review.in_app',
  'in_app',
  'Advisory awaiting your review — {{advisoryTitle}}',
  'استشارة بانتظار مراجعتك — {{advisoryTitle}}',
  '<p>Hello {{recipientName}},</p>'
    || '<p>{{actorName}} routed an advisory draft for your review:</p>'
    || '<p><strong>{{advisoryTitle}}</strong> — contract {{contractNumber}}</p>'
    || '<p><a href="{{advisoryLink}}">Open the advisory</a> to review, modify, or approve.</p>',
  '<p>مرحباً {{recipientName}}،</p>'
    || '<p>قام {{actorName}} بتحويل مسودة استشارة لمراجعتك:</p>'
    || '<p><strong>{{advisoryTitle}}</strong> — العقد {{contractNumber}}</p>'
    || '<p><a href="{{advisoryLink}}">افتح الاستشارة</a> للمراجعة أو التعديل أو الموافقة.</p>',
  jsonb_build_object(
    'required', jsonb_build_array('actorName','advisoryTitle','contractNumber','advisoryLink'),
    'optional', jsonb_build_array('recipientName')
  ),
  'demo', NULL, NULL
WHERE NOT EXISTS (
  SELECT 1 FROM notification_template
   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
     AND template_id = 'advisory.routed_for_review.in_app'
);

INSERT INTO notification_template (
  tenant_id, template_id, channel, subject_en, subject_ar, body_en, body_ar,
  parameter_schema, data_classification, created_by, updated_by
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'advisory.approved_for_send.in_app',
  'in_app',
  'Advisory approved — ready to send: {{advisoryTitle}}',
  'تمت الموافقة على الاستشارة — جاهزة للإرسال: {{advisoryTitle}}',
  '<p>Hello {{recipientName}},</p>'
    || '<p>{{actorName}} approved the advisory you routed for review:</p>'
    || '<p><strong>{{advisoryTitle}}</strong> — contract {{contractNumber}}</p>'
    || '<p><a href="{{advisoryLink}}">Open and send now</a>.</p>',
  '<p>مرحباً {{recipientName}}،</p>'
    || '<p>وافق {{actorName}} على الاستشارة التي حوّلتها للمراجعة:</p>'
    || '<p><strong>{{advisoryTitle}}</strong> — العقد {{contractNumber}}</p>'
    || '<p><a href="{{advisoryLink}}">افتح وأرسل الآن</a>.</p>',
  jsonb_build_object(
    'required', jsonb_build_array('actorName','advisoryTitle','contractNumber','advisoryLink'),
    'optional', jsonb_build_array('recipientName')
  ),
  'demo', NULL, NULL
WHERE NOT EXISTS (
  SELECT 1 FROM notification_template
   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
     AND template_id = 'advisory.approved_for_send.in_app'
);

INSERT INTO notification_template (
  tenant_id, template_id, channel, subject_en, subject_ar, body_en, body_ar,
  parameter_schema, data_classification, created_by, updated_by
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  'advisory.modified_by_exec.in_app',
  'in_app',
  'Advisory edited by executive: {{advisoryTitle}}',
  'تم تعديل الاستشارة من قِبل التنفيذي: {{advisoryTitle}}',
  '<p>Hello {{recipientName}},</p>'
    || '<p>{{actorName}} modified the advisory text. Please re-review before dispatch:</p>'
    || '<p><strong>{{advisoryTitle}}</strong> — contract {{contractNumber}}</p>'
    || '<p><a href="{{advisoryLink}}">Open advisory</a>.</p>',
  '<p>مرحباً {{recipientName}}،</p>'
    || '<p>قام {{actorName}} بتعديل نص الاستشارة. يرجى المراجعة مرة أخرى قبل الإرسال:</p>'
    || '<p><strong>{{advisoryTitle}}</strong> — العقد {{contractNumber}}</p>'
    || '<p><a href="{{advisoryLink}}">افتح الاستشارة</a>.</p>',
  jsonb_build_object(
    'required', jsonb_build_array('actorName','advisoryTitle','contractNumber','advisoryLink'),
    'optional', jsonb_build_array('recipientName')
  ),
  'demo', NULL, NULL
WHERE NOT EXISTS (
  SELECT 1 FROM notification_template
   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
     AND template_id = 'advisory.modified_by_exec.in_app'
);

-- 3. Rules (event → channel/template → recipient role) ----------------------
-- Global rules (tenant_id IS NULL) so they fire across all tenants in the
-- single-tenant demo. Each rule has one in_app channel + one role recipient.

-- 3a. routed_for_review → executive
DO $$
DECLARE
  v_rule_id BIGINT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM notification_rule WHERE event_type = 'advisory.routed_for_review') THEN
    INSERT INTO notification_rule (
      tenant_id, event_type, template_id, channel, is_enabled, audience, condition,
      priority, cooldown_minutes, description, module, name, ordering, created_by, updated_by
    ) VALUES (
      NULL, 'advisory.routed_for_review',
      'advisory.routed_for_review.in_app', 'in_app',
      TRUE, '{}'::jsonb, NULL,
      'high', 0,
      'Notify the executive when Legal Counsel routes an advisory draft for review.',
      'advisory',
      'Advisory routed for review (in_app → executive)',
      100, NULL, NULL
    ) RETURNING id INTO v_rule_id;

    INSERT INTO notification_rule_channel (rule_id, channel, template_slug, is_active, created_by, updated_by)
    VALUES (v_rule_id, 'in_app', 'advisory.routed_for_review.in_app', TRUE, NULL, NULL);

    INSERT INTO notification_rule_recipient (rule_id, recipient_type, recipient_value, is_active, created_by, updated_by)
    VALUES (v_rule_id, 'role', 'executive', TRUE, NULL, NULL);
  END IF;
END $$;

-- 3b. approved_for_send → legal_counsel
DO $$
DECLARE
  v_rule_id BIGINT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM notification_rule WHERE event_type = 'advisory.approved_for_send') THEN
    INSERT INTO notification_rule (
      tenant_id, event_type, template_id, channel, is_enabled, audience, condition,
      priority, cooldown_minutes, description, module, name, ordering, created_by, updated_by
    ) VALUES (
      NULL, 'advisory.approved_for_send',
      'advisory.approved_for_send.in_app', 'in_app',
      TRUE, '{}'::jsonb, NULL,
      'high', 0,
      'Notify Legal Counsel when the executive approves their routed advisory.',
      'advisory',
      'Advisory approved for send (in_app → legal_counsel)',
      100, NULL, NULL
    ) RETURNING id INTO v_rule_id;

    INSERT INTO notification_rule_channel (rule_id, channel, template_slug, is_active, created_by, updated_by)
    VALUES (v_rule_id, 'in_app', 'advisory.approved_for_send.in_app', TRUE, NULL, NULL);

    INSERT INTO notification_rule_recipient (rule_id, recipient_type, recipient_value, is_active, created_by, updated_by)
    VALUES (v_rule_id, 'role', 'legal_counsel', TRUE, NULL, NULL);
  END IF;
END $$;

-- 3c. modified_by_exec → legal_counsel
DO $$
DECLARE
  v_rule_id BIGINT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM notification_rule WHERE event_type = 'advisory.modified_by_exec') THEN
    INSERT INTO notification_rule (
      tenant_id, event_type, template_id, channel, is_enabled, audience, condition,
      priority, cooldown_minutes, description, module, name, ordering, created_by, updated_by
    ) VALUES (
      NULL, 'advisory.modified_by_exec',
      'advisory.modified_by_exec.in_app', 'in_app',
      TRUE, '{}'::jsonb, NULL,
      'high', 0,
      'Notify Legal Counsel when the executive edits the advisory body.',
      'advisory',
      'Advisory modified by exec (in_app → legal_counsel)',
      100, NULL, NULL
    ) RETURNING id INTO v_rule_id;

    INSERT INTO notification_rule_channel (rule_id, channel, template_slug, is_active, created_by, updated_by)
    VALUES (v_rule_id, 'in_app', 'advisory.modified_by_exec.in_app', TRUE, NULL, NULL);

    INSERT INTO notification_rule_recipient (rule_id, recipient_type, recipient_value, is_active, created_by, updated_by)
    VALUES (v_rule_id, 'role', 'legal_counsel', TRUE, NULL, NULL);
  END IF;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (676, 'notification_advisory_review_events', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
