-- Migration: 439_oqoodai_contract_body_rename.sql
-- Unit: OqoodAI rebrand (2026-06-01) — Phase 1 — Contract body labels
-- Scope: rename Musanad → OqoodAI inside the markdown body text of every
--        seeded contract row (the "reference number" / company entity
--        mentions inside the recitals). Excludes the contract_number column
--        itself — that's renamed in mig 441.
-- Functional impact: NONE — only the body_en + body_ar text is rewritten.
--        contract.id, signature joins, audit_log etc. unchanged.

BEGIN;

-- Single-pass chained REPLACE (PostgreSQL forbids multiple SET assignments
-- to the same column in one UPDATE).
UPDATE contract
   SET body_en =
         REPLACE(
           REPLACE(
             REPLACE(body_en,
               'Musanad Technologies FZ-LLC', 'OqoodAI Technologies FZ-LLC'),
             'Musanad" or the "Service Provider"', 'OqoodAI" or the "Service Provider"'),
           '"Musanad"', '"OqoodAI"'),
       updated_at = NOW(),
       updated_by = 1
 WHERE body_en LIKE '%Musanad%';

UPDATE contract
   SET body_ar =
         REPLACE(
           REPLACE(
             REPLACE(
               REPLACE(body_ar,
                 'شركة مُسنَد للتكنولوجيا ذ.م.م المنطقة الحرة', 'شركة OqoodAI للتكنولوجيا ذ.م.م المنطقة الحرة'),
               'شركة مُسنَد للتكنولوجيا', 'شركة OqoodAI للتكنولوجيا'),
             'بـ"مُسنَد"', 'بـ"OqoodAI"'),
           '"مُسنَد"', '"OqoodAI"'),
       updated_at = NOW(),
       updated_by = 1
 WHERE body_ar LIKE '%مُسنَد%';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (439, 'OqoodAI Phase 1 — contract body inline brand replace', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
--   UPDATE contract SET body_en=REPLACE(body_en,'OqoodAI','Musanad'), body_ar=REPLACE(body_ar,'OqoodAI','مُسنَد');
--   DELETE FROM schema_migrations WHERE version=439;
-- COMMIT;
-- ROLLBACK END
