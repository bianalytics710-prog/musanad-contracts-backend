-- ============================================================================
-- 094_platform_admin_user_audit_grants.sql
-- ============================================================================
-- Module:    R-PA0 (Platform Admin parity bug fixes)
-- Owner:     Lovable Modernization Agent — Platform Admin parity
-- Depends:   M0 (permission, role, role_permission tables seeded by 002/003).
-- ----------------------------------------------------------------------------
-- Closes Platform Admin parity audit C1 — `/app/admin/users` returned 0 rows
-- because the `platform_admin` role lacks `user.read.all` and `user.manage`,
-- and `/app/admin/audit` was inaccessible because `audit.read` was missing.
-- All three permissions exist (seeded in M0 002); only the role->permission
-- grants were absent.
--
-- Verified state (pre-migration) — platform_admin has 29 of the expected
-- admin permissions but is missing exactly these 3:
--   user.read.all  — list all users via GET /api/v1/users
--   user.manage    — invite/suspend/reset/change-role row actions
--   audit.read     — view the audit log at /app/admin/audit
--
-- Pattern mirrors 054 M6 grants migration. Idempotent via JOIN + ON CONFLICT.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. Role-permission grants (3 distinct rows; 054/046 JOIN pattern)
-- ============================================================================
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
  ('platform_admin', 'user.read.all'),
  ('platform_admin', 'user.manage'),
  ('platform_admin', 'audit.read')
) AS grants(role_name, perm_code)
JOIN role r       ON r.name = grants.role_name AND r.is_active = TRUE
JOIN permission p ON p.code = grants.perm_code AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (94, 'platform_admin_user_audit_grants', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DELETE FROM role_permission
  WHERE role_id = (SELECT id FROM role WHERE name = 'platform_admin')
    AND permission_id IN (
      SELECT id FROM permission
       WHERE code IN ('user.read.all', 'user.manage', 'audit.read')
    );
DELETE FROM schema_migrations WHERE version = 94;
COMMIT;
-- ROLLBACK END
