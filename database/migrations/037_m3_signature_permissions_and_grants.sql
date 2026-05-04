-- ============================================================================
-- 037_m3_signature_permissions_and_grants.sql
-- ============================================================================
-- Module:    M3 (Signatures + Signer Q&A AI)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   M0 (permission, role, role_permission tables); M3 036.
-- ----------------------------------------------------------------------------
-- 3 new permissions + 10 role_permission grants (incl. Super Admin pre-emptive
-- per ND-6 / M1c 018 / M2 028).
--
-- AC-S8-03 validation: contract_drafter is granted signature.send ONLY — NOT
-- signature.cancel. Drafter can issue/resend but cannot cancel; must escalate.
-- ----------------------------------------------------------------------------

BEGIN;

-- 1. Permissions
INSERT INTO permission (code, module, action, description, is_active)
VALUES
  ('signature.send',     'signatures', 'send',
    'Issue invitations and transition contract to awaiting_signature_*. Drafter (own scope), Legal Counsel (department), Platform Admin (system).',
    TRUE),
  ('signature.cancel',   'signatures', 'cancel',
    'Cancel an active invitation. Legal Counsel (department), Platform Admin (system). NOT granted to drafter.',
    TRUE),
  ('signature.read.all', 'signatures', 'read',
    'Read all signatures across contracts (admin / executive view). System scope only.',
    TRUE)
ON CONFLICT (code) DO NOTHING;

-- 2. Role-permission grants (10 total)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
  ('platform_admin','signature.send'),
  ('legal_counsel','signature.send'),
  ('contract_drafter','signature.send'),
  ('Super Admin','signature.send'),

  ('platform_admin','signature.cancel'),
  ('legal_counsel','signature.cancel'),
  ('Super Admin','signature.cancel'),

  ('platform_admin','signature.read.all'),
  ('executive','signature.read.all'),
  ('Super Admin','signature.read.all')
) AS grants(role_name, perm_code)
JOIN role r       ON r.name = grants.role_name AND r.is_active = TRUE
JOIN permission p ON p.code = grants.perm_code AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (37, 'm3_signature_permissions_and_grants', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DELETE FROM role_permission
  WHERE permission_id IN (
    SELECT id FROM permission WHERE code IN ('signature.send','signature.cancel','signature.read.all')
  );
DELETE FROM permission WHERE code IN ('signature.send','signature.cancel','signature.read.all');
DELETE FROM schema_migrations WHERE version = 37;
COMMIT;
-- ROLLBACK END
