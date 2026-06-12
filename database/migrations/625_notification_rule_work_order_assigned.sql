-- Migration: 625_notification_rule_work_order_assigned.sql
-- Module: Work Order Queue (M21) — notification rule + template
-- Date: 2026-06-11
--
-- Seed templates + rules for the work_order.assigned event so drafters
-- get an in-app (and email) notification when the exec assigns them a
-- draft request. Visible + togglable in Platform Admin → Notification
-- Rules.

BEGIN;

-- ============================================================
-- 0. Event type catalog (FK target for notification_rule.event_type)
-- ============================================================
INSERT INTO public.notification_event_type
  (code, display_name, description, category, sort_order, is_active, created_at, updated_at)
VALUES
  ('work_order.assigned',
   'Work order assigned',
   'Drafter is assigned a draft-request work order by an executive.',
   'contract', 100, TRUE, now(), now())
ON CONFLICT (code) DO NOTHING;

-- ============================================================
-- 1. Notification templates (in_app + email)
-- ============================================================
INSERT INTO public.notification_template (
  tenant_id, template_id, channel, subject_en, subject_ar, body_en, body_ar,
  parameter_schema, data_classification, is_active, created_at, updated_at
)
VALUES
  -- in-app
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'work_order.assigned.in_app',
   'in_app',
   NULL, NULL,
   '{{assignedByName}} asked you to draft a contract like {{sourceContractNumber}} for {{counterpartyName}}.',
   '{{assignedByName}} طلب منك صياغة عقد مماثل لـ {{sourceContractNumber}} لصالح {{counterpartyName}}.',
   '{"sourceContractNumber":"string","counterpartyName":"string","assignedByName":"string"}'::jsonb,
   'production', TRUE, now(), now()),
  -- email
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'work_order.assigned.email',
   'email',
   'New draft request — {{sourceContractNumber}}',
   'طلب صياغة جديد — {{sourceContractNumber}}',
   'Hi {{assignedToName}},

{{assignedByName}} has asked you to draft a contract similar to {{sourceContractNumber}} ({{sourceTitleEn}}) for {{counterpartyName}}.

{{#instructionNote}}Instructions: "{{instructionNote}}"{{/instructionNote}}

Open the request in OqoodAI → My Work to start composing.

— OqoodAI',
   'مرحباً {{assignedToName}}،

طلب {{assignedByName}} منك صياغة عقد مماثل لـ {{sourceContractNumber}} ({{sourceTitleEn}}) لصالح {{counterpartyName}}.

{{#instructionNote}}التعليمات: "{{instructionNote}}"{{/instructionNote}}

افتح الطلب في OqoodAI → مهامي للبدء.

— OqoodAI',
   '{"sourceContractNumber":"string","sourceTitleEn":"string","counterpartyName":"string","assignedByName":"string","assignedToName":"string","instructionNote":"string"}'::jsonb,
   'production', TRUE, now(), now())
ON CONFLICT DO NOTHING;

-- ============================================================
-- 2. Notification rules
-- ============================================================
INSERT INTO public.notification_rule (
  tenant_id, event_type, template_id, channel, is_enabled,
  audience, condition, priority, cooldown_minutes, description,
  is_active, created_at, updated_at, module, name, ordering
)
VALUES
  -- in-app: targets the assigned drafter explicitly (no fallback role)
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'work_order.assigned',
   'work_order.assigned.in_app',
   'in_app',
   TRUE,
   jsonb_build_object('users', jsonb_build_array(jsonb_build_object('source','payload','path','assignedToUserId'))),
   NULL,
   'medium', 0,
   'In-app notification fires when an exec assigns a draft-request work order.',
   TRUE, now(), now(),
   'work_order',
   'Work order assigned (in_app)',
   100),
  -- email: same audience, optional channel — defaults enabled
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'work_order.assigned',
   'work_order.assigned.email',
   'email',
   TRUE,
   jsonb_build_object('users', jsonb_build_array(jsonb_build_object('source','payload','path','assignedToUserId'))),
   NULL,
   'medium', 0,
   'Email notification fires when an exec assigns a draft-request work order.',
   TRUE, now(), now(),
   'work_order',
   'Work order assigned (email)',
   110)
ON CONFLICT DO NOTHING;

COMMIT;
