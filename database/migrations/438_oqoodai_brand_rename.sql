-- Migration: 438_oqoodai_brand_rename.sql
-- Unit: OqoodAI rebrand (2026-06-01) — Phase 1 — Brand labels
-- Scope: rename every USER-VISIBLE "Musanad" reference inside data tables
--        (party display name, system_setting workspace labels,
--        notification + advisory template subject/body strings).
-- Functional impact: NONE — every join key, FK, role code, module key, and
--        contract.id remains unchanged. Only display strings move.
-- Rollback: reverse REPLACE'd labels.

BEGIN;

-- 1) Our-party display name (the OUR PARTY shown on every contract detail)
UPDATE party
   SET name_en = REPLACE(name_en, 'Musanad Technologies FZ-LLC', 'OqoodAI Technologies FZ-LLC'),
       name_ar = COALESCE(name_ar, ''),
       updated_at = NOW(),
       updated_by = 1
 WHERE name_en LIKE '%Musanad Technologies%';

UPDATE party
   SET name_ar = REPLACE(name_ar, 'مُسنَد للتقنيات', 'OqoodAI للتكنولوجيا'),
       updated_at = NOW(),
       updated_by = 1
 WHERE name_ar LIKE '%مُسنَد%';

-- 2) System settings — workspace + footer labels
UPDATE system_setting
   SET value = '"OqoodAI Contracts Hub"'::jsonb,
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'workspaceName'
   AND value::text = '"Musanad Contracts Hub"';

UPDATE system_setting
   SET value = '"© OqoodAI Contracts Hub"'::jsonb,
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'branding.footer_en'
   AND value::text = '"© Musanad Contracts Hub"';

-- 3) Notification + advisory + email templates — body/subject swap.
-- Single-pass REPLACE chaining via nested calls (PostgreSQL forbids
-- multiple assignments to the same column in one UPDATE SET clause).
UPDATE notification_template
   SET subject_en = REPLACE(REPLACE(subject_en, 'Musanad Contracts Hub', 'OqoodAI Contracts Hub'), 'Musanad ', 'OqoodAI '),
       subject_ar = REPLACE(subject_ar, 'مُسنَد', 'OqoodAI'),
       body_en = REPLACE(REPLACE(body_en, 'Musanad Contracts Hub', 'OqoodAI Contracts Hub'), 'Musanad ', 'OqoodAI '),
       body_ar = REPLACE(body_ar, 'مُسنَد', 'OqoodAI'),
       updated_at = NOW(),
       updated_by = 1
 WHERE subject_en LIKE '%Musanad%' OR subject_ar LIKE '%مُسنَد%'
    OR body_en LIKE '%Musanad%'    OR body_ar LIKE '%مُسنَد%';

UPDATE advisory_template
   SET body_template_en = REPLACE(body_template_en, 'Musanad', 'OqoodAI'),
       body_template_ar = REPLACE(body_template_ar, 'مُسنَد', 'OqoodAI'),
       updated_at = NOW(),
       updated_by = 1
 WHERE body_template_en LIKE '%Musanad%' OR body_template_ar LIKE '%مُسنَد%';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (438, 'OqoodAI Phase 1 — brand labels (party / system_setting / notification + advisory templates)', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
--   UPDATE party SET name_en = REPLACE(name_en, 'OqoodAI Technologies FZ-LLC', 'Musanad Technologies FZ-LLC');
--   UPDATE system_setting SET value = '"Musanad Contracts Hub"'::jsonb WHERE key='workspaceName';
--   UPDATE system_setting SET value = '"© Musanad Contracts Hub"'::jsonb WHERE key='branding.footer_en';
--   UPDATE notification_template SET subject_en=REPLACE(subject_en,'OqoodAI','Musanad'), body_en=REPLACE(body_en,'OqoodAI','Musanad');
--   UPDATE advisory_template SET body_en=REPLACE(body_en,'OqoodAI','Musanad');
--   DELETE FROM schema_migrations WHERE version=438;
-- COMMIT;
-- ROLLBACK END
