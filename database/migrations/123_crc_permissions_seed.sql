-- ============================================================
-- Migration 123 — CRC permissions_seed
-- ============================================================
-- Module:      M10 — CR-C — Audit Hardening + Multi-Tenancy + Admin Cockpit Foundation
-- Description: 6 net-new permissions + 12 role_permission grants.
--              Permissions: audit.verify, email.config.manage, tenant.read,
--                           branding.manage, notification.template.manage, demo.purge.
--              Grants:      Super Admin gets all 6 net-new (6 grants).
--                           platform_admin gets 5 of 6 net-new (NOT demo.purge — Super Admin only)
--                           PLUS 1 NEW grant on existing M0 role.manage (agentNote A2).
-- Decisions:   NAMING-CONFLICT-2 — settings.write REUSED (R-PA0 097); system.config.write NOT introduced.
-- Idempotent:  ON CONFLICT (code) DO NOTHING; ON CONFLICT (role_id, permission_id) DO NOTHING.
-- ============================================================

BEGIN;

-- 1. Net-new permissions (6 rows)
INSERT INTO permission (code, module, action, description, is_active) VALUES
  ('audit.verify',                 'audit',        'verify', 'Walk and verify hash-chained audit_log integrity.',                  TRUE),
  ('email.config.manage',          'email',        'config', 'View and edit email server SMTP config + trigger test send.',        TRUE),
  ('tenant.read',                  'tenant',       'read',   'List tenants.',                                                       TRUE),
  ('branding.manage',              'branding',     'manage', 'Upload logo / favicon, edit colors, edit footer EN/AR.',              TRUE),
  ('notification.template.manage', 'notification', 'manage', 'CRUD bilingual notification templates.',                              TRUE),
  ('demo.purge',                   'demo',         'purge',  'Run demo-data purge utility (Super Admin only).',                     TRUE)
ON CONFLICT (code) DO NOTHING;

-- 2. Role-permission grants (12 rows)
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM (VALUES
  -- Super Admin — all 6 net-new
  ('Super Admin',    'audit.verify'),
  ('Super Admin',    'email.config.manage'),
  ('Super Admin',    'tenant.read'),
  ('Super Admin',    'branding.manage'),
  ('Super Admin',    'notification.template.manage'),
  ('Super Admin',    'demo.purge'),
  -- platform_admin — 5 of 6 net-new (NOT demo.purge — Super Admin only)
  ('platform_admin', 'audit.verify'),
  ('platform_admin', 'email.config.manage'),
  ('platform_admin', 'tenant.read'),
  ('platform_admin', 'branding.manage'),
  ('platform_admin', 'notification.template.manage'),
  -- platform_admin — NEW grant on existing M0 role.manage (agentNote A2; permission already existed)
  ('platform_admin', 'role.manage')
) AS grants(role_name, perm_code)
JOIN role       r ON r.name = grants.role_name AND r.is_active = TRUE
JOIN permission p ON p.code = grants.perm_code AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (123, 'crc_permissions_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DELETE FROM role_permission
--  WHERE permission_id IN (
--    SELECT id FROM permission
--     WHERE code IN ('audit.verify','email.config.manage','tenant.read',
--                    'branding.manage','notification.template.manage','demo.purge')
--  )
--    OR (
--      role_id = (SELECT id FROM role WHERE name = 'platform_admin')
--      AND permission_id = (SELECT id FROM permission WHERE code = 'role.manage')
--    );
-- DELETE FROM permission
--  WHERE code IN ('audit.verify','email.config.manage','tenant.read',
--                 'branding.manage','notification.template.manage','demo.purge');
-- DELETE FROM schema_migrations WHERE version = 123;
-- COMMIT;
-- ROLLBACK END
