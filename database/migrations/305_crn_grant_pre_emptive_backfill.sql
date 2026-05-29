-- Migration: 305_crn_grant_pre_emptive_backfill.sql
-- Module: CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half)
-- Description: Belt-and-suspenders defensive re-application (pattern: mig 293):
--              (1) Re-apply REVOKE EXECUTE FROM PUBLIC + GRANT EXECUTE TO neondb_owner
--                  on all 9 CR-N fn_'s (CREATE OR REPLACE drops COMMENT + grants — B14/S2-21).
--              (2) Re-apply all role_permission grants from 300 defensively.
--              This migration is safe to re-run (all idempotent).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- Part 1: REVOKE/GRANT on all 9 CR-N fn_'s (S2-21 / B14)
-- ============================================================

-- Internal helper
REVOKE EXECUTE ON FUNCTION fn_contract_cost_actual_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_cost_actual_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- Budget list/get
REVOKE EXECUTE ON FUNCTION fn_contract_budget_list(BIGINT, BIGINT, INTEGER, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_budget_list(BIGINT, BIGINT, INTEGER, TEXT, INTEGER, INTEGER) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_contract_budget_get(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_budget_get(BIGINT, BIGINT) TO neondb_owner;

-- Cost actual list + record
REVOKE EXECUTE ON FUNCTION fn_contract_cost_actual_list(BIGINT, BIGINT, INTEGER, TEXT, VARCHAR, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_cost_actual_list(BIGINT, BIGINT, INTEGER, TEXT, VARCHAR, INTEGER, INTEGER) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_contract_cost_actual_record(BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_cost_actual_record(BIGINT, BIGINT, JSONB) TO neondb_owner;

-- Analytics / intelligence fn_'s
REVOKE EXECUTE ON FUNCTION fn_budget_burn_compute(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_burn_compute(BIGINT, BIGINT) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_budget_variance_for_contract(BIGINT, BIGINT, NUMERIC) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_variance_for_contract(BIGINT, BIGINT, NUMERIC) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_budget_year_end_projection(BIGINT, BIGINT, VARCHAR) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_year_end_projection(BIGINT, BIGINT, VARCHAR) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_budget_burn_portfolio(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_budget_burn_portfolio(BIGINT, JSONB) TO neondb_owner;

-- Also re-apply executive dashboard fn (extended in 299)
REVOKE EXECUTE ON FUNCTION fn_dashboard_executive(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_executive(INTEGER) TO neondb_owner;

-- ============================================================
-- Part 2: Defensive role_permission re-application (all 300 grants)
-- ============================================================

INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r
CROSS JOIN permission p
WHERE (r.name, p.code) IN (
  -- finance.budget.read: wide read access
  ('Super Admin',                'finance.budget.read'),
  ('platform_admin',             'finance.budget.read'),
  ('finance_treasury',           'finance.budget.read'),
  ('executive',                  'finance.budget.read'),
  ('procurement_supplier_risk',  'finance.budget.read'),
  ('operations',                 'finance.budget.read'),

  -- finance.budget.manage: finance + admin only
  ('Super Admin',                'finance.budget.manage'),
  ('platform_admin',             'finance.budget.manage'),
  ('finance_treasury',           'finance.budget.manage')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (305, '305_crn_grant_pre_emptive_backfill', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 305;
-- -- REVOKE/GRANT cannot be rolled back meaningfully; no-op.
-- COMMIT;
-- ============================================================
