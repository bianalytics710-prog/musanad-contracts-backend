-- Migration: 441_oqoodai_contract_number_rename.sql
-- Unit: OqoodAI rebrand (2026-06-01) — Phase 1 — Contract number prefix
-- Scope: rename the prefix on every MUSANAD-2026-NNN contract row to
--        OQOOD-2026-NNN. Numeric suffix preserved exactly. Also rewrites
--        the embedded "reference number MUSANAD-2026-NNN" inside the
--        contract body markdown so the recitals match the header.
-- Functional impact: NONE on joins — every relationship keys by
--        contract.id (BIGINT), never contract_number. UNIQUE constraint on
--        contract_number is preserved; we replace each value 1:1.
-- New contracts going forward use the auto-generator's existing CT-YYYY-NNNNNN
-- prefix (set in fn_contract_create / mig 005) — unchanged by this migration.

BEGIN;

-- 1) Rename the contract_number column value for all seeded rows
UPDATE contract
   SET contract_number = REPLACE(contract_number, 'MUSANAD-', 'OQOOD-'),
       updated_at = NOW(),
       updated_by = 1
 WHERE contract_number LIKE 'MUSANAD-%';

-- 2) Rewrite the embedded "reference number MUSANAD-2026-NNN" inside the
--    contract body markdown so the recitals match the header.
UPDATE contract
   SET body_en = REPLACE(body_en, 'MUSANAD-2026-', 'OQOOD-2026-'),
       body_ar = REPLACE(body_ar, 'MUSANAD-2026-', 'OQOOD-2026-'),
       updated_at = NOW(),
       updated_by = 1
 WHERE body_en LIKE '%MUSANAD-2026-%' OR body_ar LIKE '%MUSANAD-2026-%';

-- 3) Also patch any notification / advisory / report templates that
--    referenced specific contract numbers.
UPDATE notification_template
   SET subject_en = REPLACE(subject_en, 'MUSANAD-2026-', 'OQOOD-2026-'),
       subject_ar = REPLACE(subject_ar, 'MUSANAD-2026-', 'OQOOD-2026-'),
       body_en = REPLACE(body_en, 'MUSANAD-2026-', 'OQOOD-2026-'),
       body_ar = REPLACE(body_ar, 'MUSANAD-2026-', 'OQOOD-2026-'),
       updated_at = NOW(),
       updated_by = 1
 WHERE subject_en LIKE '%MUSANAD-2026-%'
    OR subject_ar LIKE '%MUSANAD-2026-%'
    OR body_en    LIKE '%MUSANAD-2026-%'
    OR body_ar    LIKE '%MUSANAD-2026-%';

UPDATE advisory_template
   SET body_template_en = REPLACE(body_template_en, 'MUSANAD-2026-', 'OQOOD-2026-'),
       body_template_ar = REPLACE(body_template_ar, 'MUSANAD-2026-', 'OQOOD-2026-'),
       updated_at = NOW(),
       updated_by = 1
 WHERE body_template_en LIKE '%MUSANAD-2026-%' OR body_template_ar LIKE '%MUSANAD-2026-%';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (441, 'OqoodAI Phase 1 — contract_number MUSANAD-* → OQOOD-* + inline body refs', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
--   UPDATE contract SET contract_number = REPLACE(contract_number,'OQOOD-','MUSANAD-') WHERE contract_number LIKE 'OQOOD-%';
--   UPDATE contract SET body_en=REPLACE(body_en,'OQOOD-2026-','MUSANAD-2026-'), body_ar=REPLACE(body_ar,'OQOOD-2026-','MUSANAD-2026-');
--   UPDATE notification_template SET body_en=REPLACE(body_en,'OQOOD-2026-','MUSANAD-2026-');
--   UPDATE advisory_template SET body_en=REPLACE(body_en,'OQOOD-2026-','MUSANAD-2026-');
--   DELETE FROM schema_migrations WHERE version=441;
-- COMMIT;
-- ROLLBACK END
