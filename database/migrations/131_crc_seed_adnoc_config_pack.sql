-- ============================================================
-- Migration 131 — CRC seed_adnoc_config_pack
-- ============================================================
-- Module:      M10 — CR-C
-- Description: Seed ADNOC tenant config pack:
--                - 6 branding.* system_setting keys (logo / colors / footer / favicon).
--                - 26 notification_template rows (bilingual EN/AR; channel mix).
-- Provenance:  EN+AR copy verbatim from .claude/workspace/current-module/seed-data.ts
--              §5 (extracted=signature.invitation.email; remaining 25 = inferred
--              candidate copy with TODO[notification-template-extraction] markers
--              per QA Stage 3 DOC-3 — extraction from real transactional surfaces
--              deferred to a future iteration).
-- Idempotent:  ON CONFLICT (key) DO NOTHING / ON CONFLICT (tenant_id, template_id) DO NOTHING.
-- ============================================================

BEGIN;

-- 1. Branding.* (6 keys)
INSERT INTO system_setting (key, value, description, category, is_secret) VALUES
  ('branding.logo_uri',      '"/branding/musanad-logo.svg"'::jsonb,  'Workspace logo URI (Supabase Storage).', 'branding', FALSE),
  ('branding.color_primary', '"#B8935A"'::jsonb,                     'Primary brand color (ADNOC gold).',      'branding', FALSE),
  ('branding.color_accent',  '"#5B8374"'::jsonb,                     'Accent brand color (ADNOC sage).',       'branding', FALSE),
  ('branding.footer_en',     '"© Musanad Contracts Hub"'::jsonb,     'Footer text (English).',                  'branding', FALSE),
  ('branding.footer_ar',     '"© منصة مسند للعقود"'::jsonb,           'Footer text (Arabic).',                   'branding', FALSE),
  ('branding.favicon_uri',   '"/branding/favicon.ico"'::jsonb,       'Workspace favicon URI.',                  'branding', FALSE)
ON CONFLICT (key) DO NOTHING;

-- 2. notification_template (26 rows, ADNOC tenant)
--    Tenant id = 00000000-0000-0000-0000-000000000001 (M7 ADNOC seed UUID).
--    in_app rows have NULL subject_en/subject_ar (no subject lines for in-app channel).

INSERT INTO notification_template (
  tenant_id, template_id, channel,
  subject_en, subject_ar,
  body_en, body_ar,
  parameter_schema,
  data_classification
) VALUES
-- ===== Signature flow (4) =====
('00000000-0000-0000-0000-000000000001'::uuid, 'signature.invitation.email', 'email',
 'You''re invited to sign: {{contractTitle}}',
 'لقد تمت دعوتك للتوقيع على: {{contractTitle}}',
 '<p>Hello {{signerName}},</p><p>You have been invited to sign the contract <strong>{{contractTitle}}</strong>.</p><p><a href="{{signingLink}}">Open signing link</a></p>',
 '<p dir="rtl">مرحباً {{signerName}}،</p><p dir="rtl">لقد تمت دعوتك لتوقيع العقد <strong>{{contractTitle}}</strong>.</p><p dir="rtl"><a href="{{signingLink}}">افتح رابط التوقيع</a></p>',
 '{"signerName":"string","contractTitle":"string","signingLink":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'signature.completed.in_app', 'in_app',
 NULL, NULL,
 '{{signerName}} has signed the contract {{contractTitle}}.',
 'وقّع {{signerName}} على العقد {{contractTitle}}.',
 '{"signerName":"string","contractTitle":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'signature.declined.email', 'email',
 '{{signerName}} declined to sign: {{contractTitle}}',
 'رفض {{signerName}} توقيع: {{contractTitle}}',
 '<p>{{signerName}} declined to sign the contract <strong>{{contractTitle}}</strong>.</p><p>Reason: {{reason}}</p>',
 '<p dir="rtl">رفض {{signerName}} توقيع العقد <strong>{{contractTitle}}</strong>.</p><p dir="rtl">السبب: {{reason}}</p>',
 '{"signerName":"string","contractTitle":"string","reason":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'signature.reminder.email', 'email',
 'Reminder: please sign {{contractTitle}}',
 'تذكير: يُرجى توقيع {{contractTitle}}',
 '<p>Hello {{signerName}},</p><p>This is a reminder to sign the contract <strong>{{contractTitle}}</strong>.</p><p><a href="{{signingLink}}">Open signing link</a></p>',
 '<p dir="rtl">مرحباً {{signerName}}،</p><p dir="rtl">هذا تذكير بتوقيع العقد <strong>{{contractTitle}}</strong>.</p><p dir="rtl"><a href="{{signingLink}}">افتح رابط التوقيع</a></p>',
 '{"signerName":"string","contractTitle":"string","signingLink":"string"}'::jsonb,
 'demo'),

-- ===== Approval flow (6) =====
('00000000-0000-0000-0000-000000000001'::uuid, 'approval.pending.in_app', 'in_app',
 NULL, NULL,
 'Approval pending: {{approverName}}, please review {{contractTitle}}.',
 'موافقة معلّقة: {{approverName}}، يُرجى مراجعة {{contractTitle}}.',
 '{"approverName":"string","contractTitle":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'approval.approved.email', 'email',
 '{{approverName}} approved {{contractTitle}}',
 'وافق {{approverName}} على {{contractTitle}}',
 '<p>{{approverName}} approved the contract <strong>{{contractTitle}}</strong>.</p>',
 '<p dir="rtl">وافق {{approverName}} على العقد <strong>{{contractTitle}}</strong>.</p>',
 '{"approverName":"string","contractTitle":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'approval.rejected.email', 'email',
 '{{approverName}} rejected {{contractTitle}}',
 'رفض {{approverName}} {{contractTitle}}',
 '<p>{{approverName}} rejected the contract <strong>{{contractTitle}}</strong>.</p><p>Reason: {{reason}}</p>',
 '<p dir="rtl">رفض {{approverName}} العقد <strong>{{contractTitle}}</strong>.</p><p dir="rtl">السبب: {{reason}}</p>',
 '{"approverName":"string","contractTitle":"string","reason":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'approval.requested_changes.in_app', 'in_app',
 NULL, NULL,
 '{{approverName}} requested changes on {{contractTitle}}: {{note}}',
 'طلب {{approverName}} تعديلات على {{contractTitle}}: {{note}}',
 '{"approverName":"string","contractTitle":"string","note":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'approval.delegated.in_app', 'in_app',
 NULL, NULL,
 '{{fromName}} delegated approval of {{contractTitle}} to {{toName}}.',
 'فوّض {{fromName}} الموافقة على {{contractTitle}} إلى {{toName}}.',
 '{"fromName":"string","toName":"string","contractTitle":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'approval.escalated.email', 'email',
 'Escalated: approval of {{contractTitle}}',
 'تم التصعيد: الموافقة على {{contractTitle}}',
 '<p>Approval of {{contractTitle}} from {{approverName}} has been escalated to {{escalatedTo}}.</p>',
 '<p dir="rtl">تم تصعيد الموافقة على {{contractTitle}} من {{approverName}} إلى {{escalatedTo}}.</p>',
 '{"approverName":"string","contractTitle":"string","escalatedTo":"string"}'::jsonb,
 'demo'),

-- ===== Contract lifecycle (5) =====
('00000000-0000-0000-0000-000000000001'::uuid, 'contract.assigned.email', 'email',
 'You have been assigned to {{contractTitle}}',
 'تم تعيينك على {{contractTitle}}',
 '<p>Hello {{assigneeName}},</p><p>You have been assigned to the contract <strong>{{contractTitle}}</strong>.</p><p><a href="{{contractLink}}">Open contract</a></p>',
 '<p dir="rtl">مرحباً {{assigneeName}}،</p><p dir="rtl">تم تعيينك على العقد <strong>{{contractTitle}}</strong>.</p><p dir="rtl"><a href="{{contractLink}}">افتح العقد</a></p>',
 '{"assigneeName":"string","contractTitle":"string","contractLink":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'contract.status_change.in_app', 'in_app',
 NULL, NULL,
 '{{contractTitle}} is now {{newStatus}}.',
 '{{contractTitle}} أصبح الآن {{newStatus}}.',
 '{"contractTitle":"string","newStatus":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'contract.expiry_30day.email', 'email',
 '{{contractTitle}} expires in {{daysToExpiry}} days',
 'ينتهي {{contractTitle}} خلال {{daysToExpiry}} يومًا',
 '<p>The contract <strong>{{contractTitle}}</strong> expires in {{daysToExpiry}} days.</p>',
 '<p dir="rtl">العقد <strong>{{contractTitle}}</strong> ينتهي خلال {{daysToExpiry}} يومًا.</p>',
 '{"contractTitle":"string","daysToExpiry":"number"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'contract.expiry_7day.email', 'email',
 'Urgent: {{contractTitle}} expires in {{daysToExpiry}} days',
 'عاجل: ينتهي {{contractTitle}} خلال {{daysToExpiry}} يومًا',
 '<p>The contract <strong>{{contractTitle}}</strong> expires in {{daysToExpiry}} days. Please take action.</p>',
 '<p dir="rtl">العقد <strong>{{contractTitle}}</strong> ينتهي خلال {{daysToExpiry}} يومًا. يُرجى اتخاذ الإجراء.</p>',
 '{"contractTitle":"string","daysToExpiry":"number"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'contract.amended.in_app', 'in_app',
 NULL, NULL,
 '{{contractTitle}} has a new {{amendmentType}} amendment.',
 '{{contractTitle}} لديه تعديل جديد من نوع {{amendmentType}}.',
 '{"contractTitle":"string","amendmentType":"string"}'::jsonb,
 'demo'),

-- ===== Advisory (2) =====
('00000000-0000-0000-0000-000000000001'::uuid, 'advisory.dispatched.email', 'email',
 'New advisory: {{advisoryTitle}}',
 'استشارة جديدة: {{advisoryTitle}}',
 '<p>Hello {{recipientName}},</p><p>A new advisory <strong>{{advisoryTitle}}</strong> has been dispatched.</p><p><a href="{{advisoryLink}}">Open advisory</a></p>',
 '<p dir="rtl">مرحباً {{recipientName}}،</p><p dir="rtl">تم إرسال استشارة جديدة <strong>{{advisoryTitle}}</strong>.</p><p dir="rtl"><a href="{{advisoryLink}}">افتح الاستشارة</a></p>',
 '{"recipientName":"string","advisoryTitle":"string","advisoryLink":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'advisory.acknowledged.in_app', 'in_app',
 NULL, NULL,
 '{{recipientName}} acknowledged the advisory {{advisoryTitle}}.',
 '{{recipientName}} أقرّ بالاستشارة {{advisoryTitle}}.',
 '{"recipientName":"string","advisoryTitle":"string"}'::jsonb,
 'demo'),

-- ===== Comments + Watch (2) =====
('00000000-0000-0000-0000-000000000001'::uuid, 'comment.mention.in_app', 'in_app',
 NULL, NULL,
 '{{mentionerName}} mentioned you on {{contractTitle}}: "{{commentExcerpt}}"',
 'أشار إليك {{mentionerName}} في {{contractTitle}}: "{{commentExcerpt}}"',
 '{"mentionerName":"string","contractTitle":"string","commentExcerpt":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'watch.activity.email', 'email',
 'Activity on watched contract: {{contractTitle}}',
 'نشاط على العقد المراقب: {{contractTitle}}',
 '<p>The contract <strong>{{contractTitle}}</strong> you are watching had activity: {{activityType}}.</p>',
 '<p dir="rtl">العقد <strong>{{contractTitle}}</strong> الذي تراقبه شهد نشاطًا: {{activityType}}.</p>',
 '{"contractTitle":"string","activityType":"string"}'::jsonb,
 'demo'),

-- ===== Imports (2) =====
('00000000-0000-0000-0000-000000000001'::uuid, 'import.batch_complete.email', 'email',
 'Import batch complete: {{batchId}}',
 'اكتمال دفعة الاستيراد: {{batchId}}',
 '<p>Import batch <strong>{{batchId}}</strong> completed with {{rowCount}} rows.</p>',
 '<p dir="rtl">اكتملت دفعة الاستيراد <strong>{{batchId}}</strong> بـ {{rowCount}} سطرًا.</p>',
 '{"batchId":"string","rowCount":"number"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'import.batch_failed.email', 'email',
 'Import batch failed: {{batchId}}',
 'فشل دفعة الاستيراد: {{batchId}}',
 '<p>Import batch <strong>{{batchId}}</strong> failed.</p><p>Error summary: {{errorSummary}}</p>',
 '<p dir="rtl">فشلت دفعة الاستيراد <strong>{{batchId}}</strong>.</p><p dir="rtl">ملخص الخطأ: {{errorSummary}}</p>',
 '{"batchId":"string","errorSummary":"string"}'::jsonb,
 'demo'),

-- ===== Regulatory + Impact signals (3) =====
('00000000-0000-0000-0000-000000000001'::uuid, 'regulatory.update_published.in_app', 'in_app',
 NULL, NULL,
 'New update on {{regulationTitle}}: {{updateSummary}}',
 'تحديث جديد على {{regulationTitle}}: {{updateSummary}}',
 '{"regulationTitle":"string","updateSummary":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'impact.signal.notify_drafters.email', 'email',
 'Impact signal on {{contractTitle}}',
 'إشارة تأثير على {{contractTitle}}',
 '<p>An impact signal was detected on the contract <strong>{{contractTitle}}</strong>: {{impactSummary}}</p>',
 '<p dir="rtl">تم رصد إشارة تأثير على العقد <strong>{{contractTitle}}</strong>: {{impactSummary}}</p>',
 '{"contractTitle":"string","impactSummary":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'impact.signal.notify_drafters.in_app', 'in_app',
 NULL, NULL,
 'Impact signal on {{contractTitle}}: {{impactSummary}}',
 'إشارة تأثير على {{contractTitle}}: {{impactSummary}}',
 '{"contractTitle":"string","impactSummary":"string"}'::jsonb,
 'demo'),

-- ===== User lifecycle (2) =====
('00000000-0000-0000-0000-000000000001'::uuid, 'user.invited.email', 'email',
 'You''re invited to Musanad Contracts Hub',
 'تمت دعوتك إلى منصة مسند للعقود',
 '<p>Hello {{inviteeName}},</p><p>{{inviterName}} has invited you to Musanad Contracts Hub.</p><p><a href="{{activationLink}}">Activate your account</a></p>',
 '<p dir="rtl">مرحباً {{inviteeName}}،</p><p dir="rtl">دعاك {{inviterName}} للانضمام إلى منصة مسند للعقود.</p><p dir="rtl"><a href="{{activationLink}}">تفعيل حسابك</a></p>',
 '{"inviteeName":"string","inviterName":"string","activationLink":"string"}'::jsonb,
 'demo'),
('00000000-0000-0000-0000-000000000001'::uuid, 'user.password_reset.email', 'email',
 'Password reset requested',
 'طلب إعادة تعيين كلمة المرور',
 '<p>Hello {{userName}},</p><p>A password reset was requested for your account.</p><p><a href="{{resetLink}}">Reset your password</a></p><p>If you did not request this, please ignore this email.</p>',
 '<p dir="rtl">مرحباً {{userName}}،</p><p dir="rtl">تم طلب إعادة تعيين كلمة المرور لحسابك.</p><p dir="rtl"><a href="{{resetLink}}">إعادة تعيين كلمة المرور</a></p><p dir="rtl">إذا لم تطلب ذلك، يُرجى تجاهل هذه الرسالة.</p>',
 '{"userName":"string","resetLink":"string"}'::jsonb,
 'demo')
ON CONFLICT (tenant_id, template_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (131, 'crc_seed_adnoc_config_pack', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DELETE FROM notification_template
--  WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
--    AND template_id IN (
--      'signature.invitation.email','signature.completed.in_app','signature.declined.email','signature.reminder.email',
--      'approval.pending.in_app','approval.approved.email','approval.rejected.email','approval.requested_changes.in_app',
--      'approval.delegated.in_app','approval.escalated.email',
--      'contract.assigned.email','contract.status_change.in_app','contract.expiry_30day.email','contract.expiry_7day.email','contract.amended.in_app',
--      'advisory.dispatched.email','advisory.acknowledged.in_app',
--      'comment.mention.in_app','watch.activity.email',
--      'import.batch_complete.email','import.batch_failed.email',
--      'regulatory.update_published.in_app','impact.signal.notify_drafters.email','impact.signal.notify_drafters.in_app',
--      'user.invited.email','user.password_reset.email'
--    );
-- DELETE FROM system_setting WHERE key IN (
--   'branding.logo_uri','branding.color_primary','branding.color_accent',
--   'branding.footer_en','branding.footer_ar','branding.favicon_uri'
-- );
-- DELETE FROM schema_migrations WHERE version = 131;
-- COMMIT;
-- ROLLBACK END
