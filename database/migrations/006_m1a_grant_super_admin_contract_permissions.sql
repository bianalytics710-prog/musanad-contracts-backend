-- ============================================================================
-- 006_m1a_grant_super_admin_contract_permissions.sql
--   Grant the M0 "Super Admin" role all 9 M1a contract.* permissions.
-- ============================================================================
-- Module:    M1a (Contracts: Core CRUD & Lifecycle) — patch
-- Owner:     DB Implementation Agent (smoke-test follow-up patch)
-- Depends:   001_foundation.sql, 002_security_hardening.sql,
--            003_m1a_contracts.sql, 004_m1a_extend_sensitive_fields.sql,
--            005_m1a_contract_functions.sql
-- ----------------------------------------------------------------------------
-- Why:
--   Migration 003 seeded 7 NEW M1a roles (platform_admin, legal_counsel,
--   contract_drafter, contract_approver, contract_approver_2,
--   contract_recipient, executive) and granted the 9 contract.* permissions
--   only to those new roles. The pre-existing M0 "Super Admin" role was not
--   reassigned and got no contract.* grants, so the bootstrap admin user
--   admin@musanad.local (role_id=1, "Super Admin") returns 403 on every
--   /api/v1/contracts* call (auth middleware checks permission codes,
--   not role names).
--
-- Fix:
--   Insert role_permission rows linking role.name='Super Admin' to all 9
--   contract.* permissions. Resilient to id changes (matches by name/code).
--   Idempotent via ON CONFLICT DO NOTHING.
--
-- The 9 permission codes:
--   contract.read.all, contract.read.department, contract.read.own,
--   contract.draft, contract.edit, contract.delete, contract.export,
--   contract.tag.manage, contract.status.update
-- ----------------------------------------------------------------------------

BEGIN;

INSERT INTO role_permission (role_id, permission_id, is_active)
SELECT r.id, p.id, true
FROM role r
CROSS JOIN permission p
WHERE r.name = 'Super Admin'
  AND p.code IN (
    'contract.read.all', 'contract.read.department', 'contract.read.own',
    'contract.draft', 'contract.edit', 'contract.delete', 'contract.export',
    'contract.tag.manage', 'contract.status.update'
  )
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (6, 'm1a_grant_super_admin_contract_permissions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 006_m1a_grant_super_admin_contract_permissions.sql
-- ============================================================================
-- ROLLBACK BEGIN
BEGIN;
  DELETE FROM role_permission rp
   USING role r, permission p
   WHERE rp.role_id = r.id
     AND rp.permission_id = p.id
     AND r.name = 'Super Admin'
     AND p.code IN (
       'contract.read.all', 'contract.read.department', 'contract.read.own',
       'contract.draft', 'contract.edit', 'contract.delete', 'contract.export',
       'contract.tag.manage', 'contract.status.update'
     );
  DELETE FROM schema_migrations WHERE version = 6;
COMMIT;
-- ROLLBACK END
