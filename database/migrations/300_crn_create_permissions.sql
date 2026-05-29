-- Migration: 300_crn_create_permissions.sql
-- Module: CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half)
-- Description: (1) INSERT 2 new permissions (finance.budget.read + finance.budget.manage).
--              (2) role_permission grants — read: finance_treasury, executive,
--                  procurement_supplier_risk, operations, platform_admin, Super Admin;
--                  manage: finance_treasury, platform_admin, Super Admin.
--              Pattern: mig 292 (idempotent ON CONFLICT DO NOTHING).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Step 1: 2 new permissions
INSERT INTO permission (code, module, action, description, created_at, is_active)
VALUES
  ('finance.budget.read',   'finance', 'budget.read',   'View contract budget allocation, actual spend, burn, variance, and projection', NOW(), TRUE),
  ('finance.budget.manage', 'finance', 'budget.manage', 'Create/update contract budget lines and record cost actuals', NOW(), TRUE)
ON CONFLICT (code) DO NOTHING;

-- Step 2: role_permission grants
INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r CROSS JOIN permission p
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
VALUES (300, '300_crn_create_permissions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM role_permission WHERE permission_id IN (
--   SELECT id FROM permission WHERE code IN ('finance.budget.read','finance.budget.manage'));
-- DELETE FROM permission WHERE code IN ('finance.budget.read','finance.budget.manage');
-- DELETE FROM schema_migrations WHERE version = 300;
-- COMMIT;
-- ============================================================
