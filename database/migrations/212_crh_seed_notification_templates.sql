-- MIGRATION: 212_crh_seed_notification_templates.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: INSERT 3 net-new notification_template rows for dispatch events.
--              advisory.draft.created.in_app + advisory.draft.created.email seeded by M10/131 — NOT re-inserted.
--              New: advisory.dispatched.email, advisory.dispatched.teams_capture, advisory.dispatched.slack_capture
--              ON CONFLICT (tenant_id, template_id) DO NOTHING — idempotent.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_adnoc UUID := '00000000-0000-0000-0000-000000000001';
BEGIN

INSERT INTO notification_template
  (tenant_id, template_id, channel, subject_en, subject_ar, body_en, body_ar, data_classification, created_at, updated_at, is_active)
VALUES

-- 1. advisory.dispatched.email
(v_adnoc,
 'advisory.dispatched.email',
 'email',
 'ADNOC Advisory Notice: {{draftType}} — Contract {{contractId}}',
 'إشعار استشاري من أدنوك: {{draftType}} — عقد {{contractId}}',
 $$Dear {{recipientName}},

Please find attached the following advisory notice issued by ADNOC Group Legal Affairs.

Advisory Type: {{draftType}}
Contract Reference: {{contractId}}
Approved by: {{approvedByName}}
Approval Date: {{approvedAt}}

Advisory Content:
{{finalTextEn}}

This notice has been dispatched via ADNOC Contracts Hub. For questions, contact the Legal Affairs team.

This email is confidential. If received in error, please notify the sender immediately.

ADNOC Group — Legal Affairs Division$$,
 $$عزيزي {{recipientName}}،

يرجى الاطلاع على الإشعار الاستشاري التالي الصادر عن إدارة الشؤون القانونية في مجموعة أدنوك.

نوع الاستشارة: {{draftType}}
مرجع العقد: {{contractId}}
اعتمد من قِبَل: {{approvedByName}}
تاريخ الاعتماد: {{approvedAt}}

محتوى الاستشارة:
{{finalTextAr}}

تم توزيع هذا الإشعار عبر مركز عقود أدنوك. للاستفسارات، يرجى التواصل مع فريق الشؤون القانونية.

هذا البريد الإلكتروني سري. إذا تلقيته عن طريق الخطأ، يرجى إبلاغ المرسل فوراً.

مجموعة أدنوك — إدارة الشؤون القانونية$$,
 'sensitive', NOW(), NOW(), TRUE),

-- 2. advisory.dispatched.teams_capture
(v_adnoc,
 'advisory.dispatched.teams_capture',
 'teams_capture',
 NULL,
 NULL,
 $${"@type":"MessageCard","@context":"https://schema.org/extensions","summary":"Advisory dispatched","themeColor":"d97706","title":"{{draftType}}","text":"Advisory dispatched for Contract {{contractId}}. Approved by {{approvedByName}} on {{approvedAt}}.","sections":[{"facts":[{"name":"Contract","value":"{{contractId}}"},{"name":"Type","value":"{{draftType}}"},{"name":"Approved By","value":"{{approvedByName}}"}]},{"activityText":"View full advisory in ADNOC Contracts Hub."}]}$$,
 $${"@type":"MessageCard","@context":"https://schema.org/extensions","summary":"تم توزيع الاستشارة","themeColor":"d97706","title":"{{draftType}}","text":"تم توزيع استشارة للعقد {{contractId}}. اعتمد من قِبَل {{approvedByName}} في {{approvedAt}}.","sections":[{"facts":[{"name":"العقد","value":"{{contractId}}"},{"name":"النوع","value":"{{draftType}}"},{"name":"اعتمد من","value":"{{approvedByName}}"}]}]}$$,
 'sensitive', NOW(), NOW(), TRUE),

-- 3. advisory.dispatched.slack_capture
(v_adnoc,
 'advisory.dispatched.slack_capture',
 'slack_capture',
 NULL,
 NULL,
 $${"text":"ADNOC Advisory Notice: {{draftType}} — Contract {{contractId}}","blocks":[{"type":"header","text":{"type":"plain_text","text":"ADNOC Advisory Notice","emoji":false}},{"type":"section","fields":[{"type":"mrkdwn","text":"*Type:* {{draftType}}"},{"type":"mrkdwn","text":"*Contract:* {{contractId}}"},{"type":"mrkdwn","text":"*Approved By:* {{approvedByName}}"},{"type":"mrkdwn","text":"*Approved At:* {{approvedAt}}"}]},{"type":"section","text":{"type":"mrkdwn","text":"Advisory text available in ADNOC Contracts Hub."}}]}$$,
 $${"text":"إشعار استشاري من أدنوك: {{draftType}} — عقد {{contractId}}","blocks":[{"type":"header","text":{"type":"plain_text","text":"إشعار استشاري من أدنوك","emoji":false}},{"type":"section","fields":[{"type":"mrkdwn","text":"*النوع:* {{draftType}}"},{"type":"mrkdwn","text":"*العقد:* {{contractId}}"},{"type":"mrkdwn","text":"*اعتمد من:* {{approvedByName}}"},{"type":"mrkdwn","text":"*تاريخ الاعتماد:* {{approvedAt}}"}]}]}$$,
 'sensitive', NOW(), NOW(), TRUE)

ON CONFLICT (tenant_id, template_id) DO NOTHING;

END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (212, '212_crh_seed_notification_templates', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM notification_template
-- WHERE template_id IN ('advisory.dispatched.email','advisory.dispatched.teams_capture','advisory.dispatched.slack_capture')
--   AND tenant_id = '00000000-0000-0000-0000-000000000001';
-- DELETE FROM schema_migrations WHERE version = 212;
-- ============================================================
