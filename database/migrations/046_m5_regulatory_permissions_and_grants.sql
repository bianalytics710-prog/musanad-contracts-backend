-- ============================================================================
-- 046_m5_regulatory_permissions_and_grants.sql
-- ============================================================================
-- Module:    M5 (Regulatory Radar)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   M0 (permission, role, role_permission tables).
-- ----------------------------------------------------------------------------
-- MANDATORY FIRST migration for M5. Resolves M5-CC-1 — without this, every
-- M5 endpoint that gates on regulations.read / regulations.manage / config.manage
-- returns 403. Mirrors M2 028 / M3 037 / M4 044 precedent (pre-emptive
-- Super Admin grant per M1a 006 / M1c 018 lesson).
--
-- 3 new permission codes:
--   regulations.read    -> Super Admin, platform_admin, legal_counsel,
--                          contract_drafter, contract_approver, contract_approver_2,
--                          executive (7 grants — note Super Admin pre-emptive)
--   regulations.manage  -> Super Admin, platform_admin, legal_counsel (3 grants)
--   config.manage       -> Super Admin, platform_admin (2 grants)
--   contract_recipient  -> EXPLICIT DENY — no grants on any regulations.* code
--                          (per Agent 2 _contract_recipient_explicit_deny)
--
-- Total: 7 + 3 + 2 = 12 distinct (role,permission) grants.
--
-- All ON CONFLICT DO NOTHING idempotent.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. Permissions (3 new codes)
-- ============================================================================
INSERT INTO permission (code, module, action, description, is_active) VALUES
  ('regulations.read',   'regulations', 'read',
   'Read access to the regulatory data plane (regulation library, regulatory updates radar, impact rows on visible contracts).',
   TRUE),
  ('regulations.manage', 'regulations', 'manage',
   'Manage regulatory data — create/update/soft-delete regulations + regulatory updates; create/resolve regulatory impacts on contracts.',
   TRUE),
  ('config.manage',      'config',      'manage',
   'Manage system configuration tables — impact categories (and future config). platform_admin only.',
   TRUE)
ON CONFLICT (code) DO NOTHING;

-- ============================================================================
-- 2. Role-permission grants (12 distinct rows; M3 037 / M4 044 JOIN pattern)
-- ============================================================================
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
  -- regulations.read — 7 roles (incl. pre-emptive Super Admin)
  ('Super Admin',         'regulations.read'),
  ('platform_admin',      'regulations.read'),
  ('legal_counsel',       'regulations.read'),
  ('contract_drafter',    'regulations.read'),
  ('contract_approver',   'regulations.read'),
  ('contract_approver_2', 'regulations.read'),
  ('executive',           'regulations.read'),

  -- regulations.manage — 3 roles
  ('Super Admin',    'regulations.manage'),
  ('platform_admin', 'regulations.manage'),
  ('legal_counsel',  'regulations.manage'),

  -- config.manage — 2 roles
  ('Super Admin',    'config.manage'),
  ('platform_admin', 'config.manage')

  -- contract_recipient: EXPLICIT DENY — intentionally not listed.
) AS grants(role_name, perm_code)
JOIN role r       ON r.name = grants.role_name AND r.is_active = TRUE
JOIN permission p ON p.code = grants.perm_code AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (46, 'm5_regulatory_permissions_and_grants', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DELETE FROM role_permission
  WHERE permission_id IN (
    SELECT id FROM permission WHERE code IN (
      'regulations.read','regulations.manage','config.manage'
    )
  );
DELETE FROM permission WHERE code IN (
  'regulations.read','regulations.manage','config.manage'
);
DELETE FROM schema_migrations WHERE version = 46;
COMMIT;
-- ROLLBACK END
