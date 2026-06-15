-- ============================================================================
-- Migration 683 — advisory review notification templates → plain text
-- ============================================================================
-- WHY: mig 676 seeded the three advisory-review in-app notification templates
-- with HTML bodies (<p>, <strong>, <a href>). fn_mustache_render does variable
-- substitution only — it does NOT strip/parse HTML — so the rendered body kept
-- the tags, and the notification bell (which renders the body as plain text)
-- showed the raw markup literally: "<p>Hello …</p><a href=…>…</a>".
-- These are in_app templates, which should be plain prose. Rewrite the three
-- bodies to clean text, keeping the same Mustache placeholders. The bell row is
-- already clickable to the contract (context_payload.contractId, mig 677), so
-- the inline <a> link is dropped without losing navigation.
--
-- NOTE: existing rows in notification_dispatch_log already have HTML baked into
-- body_rendered; those are cleaned defensively on the FE (NotificationBell
-- htmlToText). This migration fixes the SOURCE so future notifications are clean.
-- ============================================================================

BEGIN;

UPDATE notification_template
   SET body_en = '{{actorName}} routed an advisory draft for your review: '
                 || '"{{advisoryTitle}}" — contract {{contractNumber}}. '
                 || 'Open it to review, modify, or approve.',
       body_ar = 'قام {{actorName}} بتحويل مسودة استشارة لمراجعتك: '
                 || '«{{advisoryTitle}}» — العقد {{contractNumber}}. '
                 || 'افتحها للمراجعة أو التعديل أو الموافقة.',
       updated_at = now()
 WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
   AND template_id = 'advisory.routed_for_review.in_app';

UPDATE notification_template
   SET body_en = '{{actorName}} approved the advisory you routed for review: '
                 || '"{{advisoryTitle}}" — contract {{contractNumber}}. '
                 || 'You can open and send it now.',
       body_ar = 'وافق {{actorName}} على الاستشارة التي حوّلتها للمراجعة: '
                 || '«{{advisoryTitle}}» — العقد {{contractNumber}}. '
                 || 'يمكنك فتحها وإرسالها الآن.',
       updated_at = now()
 WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
   AND template_id = 'advisory.approved_for_send.in_app';

UPDATE notification_template
   SET body_en = '{{actorName}} modified the advisory text — please re-review '
                 || 'before dispatch: "{{advisoryTitle}}" — contract {{contractNumber}}.',
       body_ar = 'قام {{actorName}} بتعديل نص الاستشارة — يرجى المراجعة مرة أخرى '
                 || 'قبل الإرسال: «{{advisoryTitle}}» — العقد {{contractNumber}}.',
       updated_at = now()
 WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
   AND template_id = 'advisory.modified_by_exec.in_app';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (683, 'advisory_notification_plain_text', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
