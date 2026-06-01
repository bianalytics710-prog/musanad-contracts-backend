-- Migration: 427_aisha_cluster_s_sidebar_modules.sql
-- Unit: Aisha Approver PM-grade audit fix pass (2026-06-01) — Cluster S
-- Defects addressed:
--   A2 — /app/queue is a "Coming soon" placeholder; the sidebar entry is in
--        Aisha's effective modules because queue.default_role_codes includes
--        contract_approver + contract_approver_2 (mig 340).
--   A3 — /app/regulations (Impact Watch) is a dead surface for Aisha
--        (100 signals · 0 impacting any contract) because the impact_signal
--        ↔ contract relation isn't seeded. Approver doesn't need this
--        sidebar entry; revert mig 425 which added contract_approver to
--        impact_signals.default_role_codes.
-- Approach:
--   1. Remove contract_approver + contract_approver_2 from queue.default_role_codes.
--   2. Remove contract_approver + contract_approver_2 from impact_signals.default_role_codes
--      (drafter retains it — Dana mig 425 fix preserved).
-- Test-branch-safe: WHERE the jsonb array contains the role key (idempotent).
-- Rollback: re-append the role keys to default_role_codes.

BEGIN;

-- A2 — Queue sidebar entry removal for approver personas.
UPDATE product_module
   SET default_role_codes = default_role_codes - 'contract_approver',
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'queue'
   AND default_role_codes ? 'contract_approver';

UPDATE product_module
   SET default_role_codes = default_role_codes - 'contract_approver_2',
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'queue'
   AND default_role_codes ? 'contract_approver_2';

-- A3 — Impact Watch sidebar entry removal for approver personas.
-- (Dana's contract_drafter entry from mig 425 is preserved.)
UPDATE product_module
   SET default_role_codes = default_role_codes - 'contract_approver',
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'impact_signals'
   AND default_role_codes ? 'contract_approver';

UPDATE product_module
   SET default_role_codes = default_role_codes - 'contract_approver_2',
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'impact_signals'
   AND default_role_codes ? 'contract_approver_2';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (427, 'A2/A3 Aisha — drop queue + impact_signals from contract_approver(_2) module catalog', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
--   UPDATE product_module SET default_role_codes = default_role_codes || '"contract_approver"'::jsonb
--    WHERE key IN ('queue','impact_signals') AND NOT (default_role_codes ? 'contract_approver');
--   UPDATE product_module SET default_role_codes = default_role_codes || '"contract_approver_2"'::jsonb
--    WHERE key IN ('queue','impact_signals') AND NOT (default_role_codes ? 'contract_approver_2');
--   DELETE FROM schema_migrations WHERE version = 427;
-- COMMIT;
-- ROLLBACK END
