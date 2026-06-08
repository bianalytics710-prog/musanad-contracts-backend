-- Migration: 602_rename_al_nahyan_surnames.sql
-- Module: Seed-data correction — drop royal-family surname references
-- Date: 2026-06-08
--
-- "Al Nahyan" is the Abu Dhabi royal family name. Using it for either
-- the demo Contract Approver persona or for fictional vendor companies
-- in our procurement seed data is inappropriate for the ADNOC audience.
--
-- Replace "Al Nahyan" with "Al Marri" — a common, non-royal Emirati
-- surname of similar shape so initials + visual feel stay consistent:
--
--   user row id=6 — Aisha Al Nahyan → Aisha Al Marri
--                   (initials AN → AM, login email + role_id unchanged
--                    so JWT / RBAC / approval-routing all unaffected)
--
--   vendor companies (CRQ procurement seed, mig 327):
--     Al Nahyan Well Services       → Al Marri Well Services
--     Al Nahyan Small Contractors   → Al Marri Small Contractors
--
-- All other column values stay identical. Idempotent — running twice is
-- a no-op because the WHERE clause checks for the old string.

BEGIN;

-- ── 1. Approver user row
UPDATE "user"
   SET last_name = 'Al Marri',
       updated_at = NOW(),
       updated_by = 1
 WHERE id = 6
   AND lower(email) = 'approver@musanad.local'
   AND last_name = 'Al Nahyan';

-- ── 2. Vendor company names (party + contractor tables)
-- party table holds the canonical counterparty rows.
UPDATE party
   SET name_en = REPLACE(name_en, 'Al Nahyan', 'Al Marri'),
       updated_at = NOW(),
       updated_by = 1
 WHERE name_en ILIKE '%Al Nahyan%'
   AND is_active = TRUE;

-- Arabic mirror — the Arabic glyph string in mig 327 is the romanised
-- transliteration of "Al Nahyan"; replace with the transliteration of
-- "Al Marri" so the AR column stays paired with the EN column.
UPDATE party
   SET name_ar = REPLACE(name_ar, 'آل نهيان', 'آل المري'),
       updated_at = NOW(),
       updated_by = 1
 WHERE name_ar ILIKE '%آل نهيان%'
   AND is_active = TRUE;

-- contractor table (CRQ workforce data) — same string lives there
-- under the `name` column. Conditionally update if the table exists
-- (skip silently on environments where the CRQ extension isn't loaded).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
     WHERE table_schema='public' AND table_name='contractor'
  ) THEN
    UPDATE contractor
       SET name = REPLACE(name, 'Al Nahyan', 'Al Marri'),
           updated_at = NOW()
     WHERE name ILIKE '%Al Nahyan%';
  END IF;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (602, '602_rename_al_nahyan_surnames', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- UPDATE "user" SET last_name = 'Al Nahyan' WHERE id = 6;
-- UPDATE party  SET name_en = REPLACE(name_en, 'Al Marri', 'Al Nahyan') WHERE name_en ILIKE '%Al Marri%';
-- UPDATE party  SET name_ar = REPLACE(name_ar, 'آل المري', 'آل نهيان') WHERE name_ar ILIKE '%آل المري%';
-- DO $$ BEGIN
--   IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='contractor') THEN
--     UPDATE contractor SET name = REPLACE(name, 'Al Marri', 'Al Nahyan') WHERE name ILIKE '%Al Marri%';
--   END IF;
-- END $$;
-- DELETE FROM schema_migrations WHERE version = 602;
-- COMMIT;
