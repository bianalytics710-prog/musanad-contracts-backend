-- Migration: 229_demo_permissions.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: 4 net-new demo permission rows + role_permission grants for platform_admin + Super Admin.
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO permission (code, module, action, description, created_at, is_active) VALUES
  ('demo.scenario.trigger',   'demo', 'scenario.trigger',   'Trigger demo scenarios via admin panel',          NOW(), TRUE),
  ('demo.reset',              'demo', 'reset',              'Reset demo data and reload seed packs',           NOW(), TRUE),
  ('demo.time_freeze.manage', 'demo', 'time_freeze.manage', 'Set or clear the demo time-freeze GUC',           NOW(), TRUE),
  ('demo.health_check.read',  'demo', 'health_check.read',  'Read pre-demo health check status',               NOW(), TRUE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permission (role_id, permission_id)
  SELECT r.id, p.id
  FROM role r CROSS JOIN permission p
  WHERE r.name IN ('platform_admin', 'Super Admin')
    AND p.code IN ('demo.scenario.trigger','demo.reset','demo.time_freeze.manage','demo.health_check.read')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (229, '229_demo_permissions', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 229;
-- DELETE FROM role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code IN ('demo.scenario.trigger','demo.reset','demo.time_freeze.manage','demo.health_check.read'));
-- DELETE FROM permission WHERE code IN ('demo.scenario.trigger','demo.reset','demo.time_freeze.manage','demo.health_check.read');
-- ============================================================
