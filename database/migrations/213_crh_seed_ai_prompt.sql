-- MIGRATION: 213_crh_seed_ai_prompt.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: INSERT 3 ai_prompt rows kind/variant for advisory_drafter (fm_invocation, sanctions_hold, cure_notice).
--              NOTE: ai_prompt table uses prompt_id (TEXT PK), not tenant-scoped.
--              ON CONFLICT (prompt_id) DO NOTHING — idempotent.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO ai_prompt
  (prompt_id, description_en, description_ar, default_model, default_temperature, default_max_tokens,
   default_ttl_seconds, supports_streaming, supports_tool_call, public_endpoint,
   prompt_file_path, rate_limit_per_user_per_hour, rate_limit_per_user_per_day,
   data_classification, created_at, updated_at, is_active)
VALUES

-- 1. advisory_drafter / fm_invocation
('advisory_drafter__fm_invocation',
 'Advisory Drafter — Force Majeure Invocation. Drafts a formal FM invocation notice for Hormuz/Gulf shipping disruption scenarios.',
 'مُسوِّد الاستشارة — استدعاء القوة القاهرة. يصيغ إشعار استدعاء رسمي للقوة القاهرة لسيناريوهات اضطراب الشحن في الخليج/هرمز.',
 'gpt-4o',
 0.2,
 2000,
 0,
 FALSE,
 FALSE,
 FALSE,
 'prompts/advisory_drafter/fm_invocation.md',
 10,
 50,
 'sensitive',
 NOW(), NOW(), TRUE),

-- 2. advisory_drafter / sanctions_hold
('advisory_drafter__sanctions_hold',
 'Advisory Drafter — Sanctions Hold Notice. Drafts a formal contract performance suspension notice due to OFAC/EU/UN sanctions designation.',
 'مُسوِّد الاستشارة — إشعار وقف العقوبات. يصيغ إشعار تعليق رسمي لتنفيذ العقد بسبب تصنيف العقوبات.',
 'gpt-4o',
 0.2,
 2000,
 0,
 FALSE,
 FALSE,
 FALSE,
 'prompts/advisory_drafter/sanctions_hold.md',
 10,
 50,
 'sensitive',
 NOW(), NOW(), TRUE),

-- 3. advisory_drafter / cure_notice
('advisory_drafter__cure_notice',
 'Advisory Drafter — Cure Notice. Drafts a formal cure notice for identified contract breach with cure period specification.',
 'مُسوِّد الاستشارة — إشعار الإصلاح. يصيغ إشعار إصلاح رسمي للمخالفة التعاقدية المحددة مع تحديد مدة الإصلاح.',
 'gpt-4o',
 0.2,
 2000,
 0,
 FALSE,
 FALSE,
 FALSE,
 'prompts/advisory_drafter/cure_notice.md',
 10,
 50,
 'sensitive',
 NOW(), NOW(), TRUE)

ON CONFLICT (prompt_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (213, '213_crh_seed_ai_prompt', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM ai_prompt WHERE prompt_id IN (
--   'advisory_drafter__fm_invocation','advisory_drafter__sanctions_hold','advisory_drafter__cure_notice'
-- );
-- DELETE FROM schema_migrations WHERE version = 213;
-- ============================================================
