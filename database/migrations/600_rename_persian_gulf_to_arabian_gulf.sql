-- Migration: 600_rename_persian_gulf_to_arabian_gulf.sql
-- Module: Seed-data correction — geographical naming for ADNOC audience
-- Date: 2026-06-08
--
-- The customer we're demoing to is Arab. Multiple seeded signals + a
-- risk-case body use "Persian Gulf" — the politically-loaded Western
-- toponym. Across the Gulf states the same body of water is called
-- the Arabian Gulf, and that's what should appear on every surface.
--
-- Audit (DB-only — FE strings + i18n are clean):
--   • osint_signal.title_en  — 4 rows
--   • osint_signal.title     — 4 rows (legacy mirror, same rows)
--   • osint_signal.summary   — 4 rows
--   • risk_case.body         — 1 row
--
-- Replace literal "Persian Gulf" with "Arabian Gulf" via REPLACE() —
-- idempotent (running twice is a no-op) and limited to rows that
-- actually contain the term.

BEGIN;

UPDATE osint_signal
   SET title_en = REPLACE(title_en, 'Persian Gulf', 'Arabian Gulf'),
       updated_at = NOW()
 WHERE title_en ILIKE '%Persian Gulf%' AND is_active = TRUE;

UPDATE osint_signal
   SET title = REPLACE(title, 'Persian Gulf', 'Arabian Gulf'),
       updated_at = NOW()
 WHERE title ILIKE '%Persian Gulf%' AND is_active = TRUE;

UPDATE osint_signal
   SET summary = REPLACE(summary, 'Persian Gulf', 'Arabian Gulf'),
       updated_at = NOW()
 WHERE summary ILIKE '%Persian Gulf%' AND is_active = TRUE;

UPDATE risk_case
   SET body = REPLACE(body, 'Persian Gulf', 'Arabian Gulf'),
       updated_at = NOW()
 WHERE body ILIKE '%Persian Gulf%' AND is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (600, '600_rename_persian_gulf_to_arabian_gulf', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- UPDATE osint_signal SET title_en = REPLACE(title_en, 'Arabian Gulf', 'Persian Gulf') WHERE title_en ILIKE '%Arabian Gulf%';
-- UPDATE osint_signal SET title    = REPLACE(title,    'Arabian Gulf', 'Persian Gulf') WHERE title    ILIKE '%Arabian Gulf%';
-- UPDATE osint_signal SET summary  = REPLACE(summary,  'Arabian Gulf', 'Persian Gulf') WHERE summary  ILIKE '%Arabian Gulf%';
-- UPDATE risk_case    SET body     = REPLACE(body,     'Arabian Gulf', 'Persian Gulf') WHERE body     ILIKE '%Arabian Gulf%';
-- DELETE FROM schema_migrations WHERE version = 600;
-- COMMIT;
