-- Migration: 318_cro_create_permissions.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: (1) INSERT 2 new permissions (finance.margin.read + finance.trade.manage).
--              (2) role_permission grants:
--                  finance.margin.read: finance_treasury, executive, platform_admin, Super Admin
--                  finance.trade.manage: finance_treasury, platform_admin, Super Admin
--              Pattern: mig 300 (CR-N, idempotent ON CONFLICT DO NOTHING).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Step 1: 2 new permissions
INSERT INTO permission (code, module, action, description, created_at, is_active)
VALUES
  ('finance.margin.read',   'finance', 'margin.read',   'View trade position list/detail, margin computations, price benchmarks, snapshot history, and aggregate portfolio margin', NOW(), TRUE),
  ('finance.trade.manage',  'finance', 'trade.manage',  'Record price benchmark observations, trigger margin recompute, and manage trade position data', NOW(), TRUE)
ON CONFLICT (code) DO NOTHING;

-- Step 2: role_permission grants
INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r CROSS JOIN permission p
WHERE (r.name, p.code) IN (
  -- finance.margin.read: wide read access (finance + exec + admin)
  ('Super Admin',       'finance.margin.read'),
  ('platform_admin',    'finance.margin.read'),
  ('finance_treasury',  'finance.margin.read'),
  ('executive',         'finance.margin.read'),

  -- finance.trade.manage: write access restricted to finance + admin
  ('Super Admin',       'finance.trade.manage'),
  ('platform_admin',    'finance.trade.manage'),
  ('finance_treasury',  'finance.trade.manage')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (318, '318_cro_create_permissions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM role_permission WHERE permission_id IN (
--   SELECT id FROM permission WHERE code IN ('finance.margin.read','finance.trade.manage'));
-- DELETE FROM permission WHERE code IN ('finance.margin.read','finance.trade.manage');
-- DELETE FROM schema_migrations WHERE version = 318;
-- COMMIT;
-- ============================================================
