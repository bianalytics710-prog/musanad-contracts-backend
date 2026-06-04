-- Migration: 454_template_body_unescape_newlines.sql
-- Module: Compose Wizard — G1 fix (post-verification gap)
-- Description: contract_template.body_en and body_ar were seeded with
--              literal backslash+n (the two characters '\' and 'n')
--              instead of real LF newlines. When the Compose Wizard
--              pre-fills the Step 3 body textarea from the selected
--              template, Hala sees raw `\n` sequences in the editor.
--              Replace `\n` with real LF (E'\n') across all active
--              contract templates. Also unescape `\t` for good measure.
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

UPDATE contract_template
SET
  body_en = CASE WHEN body_en IS NULL THEN NULL
                 ELSE replace(replace(body_en, '\n', E'\n'), '\t', E'\t')
            END,
  body_ar = CASE WHEN body_ar IS NULL THEN NULL
                 ELSE replace(replace(body_ar, '\n', E'\n'), '\t', E'\t')
            END
WHERE body_en LIKE '%\n%' OR body_ar LIKE '%\n%';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (454, '454_template_body_unescape_newlines', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 454;
-- -- (Reverse not provided — the original seed strings can be restored from
-- -- the seed migration files if needed.)
-- ============================================================
