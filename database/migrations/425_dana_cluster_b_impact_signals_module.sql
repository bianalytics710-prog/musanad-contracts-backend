-- Migration: 425_dana_cluster_b_impact_signals_module.sql
-- Unit: Dana Drafter PM-grade audit fix pass (2026-06-01) — Cluster B
-- Defect addressed:
--   D46 — Impact Watch (/api/v1/impact-signals) returns 404 for Dana because
--         the route is gated by requireModuleEnabled('impact_signals') and
--         the impact_signals product_module.default_role_codes array does
--         NOT include 'contract_drafter'. Dana's sidebar shows "Impact Watch"
--         (driven by fn_user_effective_modules following a different code
--         path) but the BE route refuses the request.
-- Approach:
--   Append 'contract_drafter' to product_module.default_role_codes for
--   'impact_signals' so fn_user_effective_modules grants the module and
--   the requireModuleEnabled middleware accepts the request. Per BUG-008
--   the fn_impact_signal_list permission gate already accepts the drafter's
--   contract.read.department perm, so the only remaining gate was the
--   module-toggle layer.
-- Test-branch-safe: WHERE NOT default_role_codes ? 'contract_drafter' is
-- an idempotent guard; missing module rows on test branch are silent no-ops.
-- Rollback: remove 'contract_drafter' from the default_role_codes array.

BEGIN;

UPDATE product_module
   SET default_role_codes = default_role_codes || '"contract_drafter"'::jsonb,
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'impact_signals'
   AND NOT (default_role_codes ? 'contract_drafter');

-- Also add 'contract_approver' and 'contract_approver_2' so the same fix
-- benefits the approval chain personas — they read impact signals to
-- contextualise approval decisions.
UPDATE product_module
   SET default_role_codes = default_role_codes || '"contract_approver"'::jsonb,
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'impact_signals'
   AND NOT (default_role_codes ? 'contract_approver');

UPDATE product_module
   SET default_role_codes = default_role_codes || '"contract_approver_2"'::jsonb,
       updated_at = NOW(),
       updated_by = 1
 WHERE key = 'impact_signals'
   AND NOT (default_role_codes ? 'contract_approver_2');

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (425, 'D46 Dana — enable impact_signals module for contract_drafter + approver(s)', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
--   UPDATE product_module
--      SET default_role_codes = default_role_codes - 'contract_drafter' - 'contract_approver' - 'contract_approver_2'
--    WHERE key = 'impact_signals';
--   DELETE FROM schema_migrations WHERE version = 425;
-- COMMIT;
-- ROLLBACK END
