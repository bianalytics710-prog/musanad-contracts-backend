-- Migration: 432_aisha_cluster_s_regulations_module_fix.sql
-- Unit: Aisha Approver PM-grade audit fix pass (2026-06-01) — Cluster S follow-up
-- Defect addressed:
--   A3 (follow-up) — mig 427 removed contract_approver from impact_signals
--                    default_role_codes, but the BE actually returns the
--                    sibling module key `regulations` (a duplicate seeded
--                    earlier). Aisha's sidebar still showed Impact Watch
--                    because `regulations.default_role_codes` still
--                    contained contract_approver. Remove from the right
--                    module key.
-- Test-branch-safe: idempotent (drop role if present).
-- Rollback: re-append the role keys.

BEGIN;

UPDATE product_module
   SET default_role_codes = default_role_codes - 'contract_approver',
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'regulations'
   AND default_role_codes ? 'contract_approver';

UPDATE product_module
   SET default_role_codes = default_role_codes - 'contract_approver_2',
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'regulations'
   AND default_role_codes ? 'contract_approver_2';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (432, 'A3 follow-up — drop contract_approver(_2) from regulations module', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
--   UPDATE product_module SET default_role_codes = default_role_codes || '"contract_approver"'::jsonb
--    WHERE key = 'regulations' AND NOT (default_role_codes ? 'contract_approver');
--   UPDATE product_module SET default_role_codes = default_role_codes || '"contract_approver_2"'::jsonb
--    WHERE key = 'regulations' AND NOT (default_role_codes ? 'contract_approver_2');
--   DELETE FROM schema_migrations WHERE version=432;
-- COMMIT;
-- ROLLBACK END
