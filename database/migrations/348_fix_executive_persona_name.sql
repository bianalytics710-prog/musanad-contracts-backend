-- Migration: 348_fix_executive_persona_name.sql
-- Unit: QA Phase 3 autonomous run 2026-05-31 — BUG-007 fix
-- Description: The executive persona's first_name in the DB was 'Eshaan' but the
--              LoginForm.tsx persona card + ADNOC-Demo-Flow.md runbook anchor both
--              use 'Eman Executive'. Normalize the DB record so the in-app avatar
--              + header display matches the persona card the demo audience just
--              clicked. Cosmetic only; no permission change.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

UPDATE "user"
   SET first_name = 'Eman',
       updated_at = NOW(),
       updated_by = 1
 WHERE email = 'executive@musanad.local'
   AND first_name = 'Eshaan';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (348, 'BUG-007 fix executive persona name Eshaan→Eman to match LoginForm + runbook', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- UPDATE "user" SET first_name = 'Eshaan' WHERE email = 'executive@musanad.local';
-- DELETE FROM schema_migrations WHERE version = 348;
