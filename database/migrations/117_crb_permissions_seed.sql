-- Migration: 117_crb_permissions_seed.sql
-- Module: M9 — Counterparty Graph (CR-B)
-- Description: Insert 2 net-new permissions + 9 unconditional role grants + 1 guarded compliance_esg no-op grant.
-- Rollback: DELETE FROM role_permission/permission for the 2 new codes.

BEGIN;

-- 1. Net-new permissions
INSERT INTO permission (code, module, action, description) VALUES
  ('party.graph.read',   'party', 'graph.read',
     'Read party_relationship edges + invoke chain traversal + chain summary fns.'),
  ('party.graph.manage', 'party', 'graph.manage',
     'Insert/update/soft-delete party_relationship edges + edit party graph fields.')
ON CONFLICT (code) DO NOTHING;

-- 2. Unconditional grants (M2/M3/M4/M7 join pattern)
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r CROSS JOIN permission p
WHERE (r.name, p.code) IN (
  -- party.graph.read — all party-readable roles
  ('platform_admin',    'party.graph.read'),
  ('legal_counsel',     'party.graph.read'),
  ('contract_drafter',  'party.graph.read'),
  ('contract_approver', 'party.graph.read'),
  ('executive',         'party.graph.read'),
  ('Super Admin',       'party.graph.read'),
  -- party.graph.manage — gated to platform_admin + legal_counsel + Super Admin
  ('platform_admin',    'party.graph.manage'),
  ('legal_counsel',     'party.graph.manage'),
  ('Super Admin',       'party.graph.manage')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- 3. Guarded compliance_esg grant — no-op until CR-G activates the role
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r, permission p
WHERE r.name = 'compliance_esg' AND r.is_active = TRUE
  AND p.code = 'party.graph.read' AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (117, 'crb_permissions_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DELETE FROM role_permission WHERE permission_id IN
--   (SELECT id FROM permission WHERE code IN ('party.graph.read','party.graph.manage'));
-- DELETE FROM permission WHERE code IN ('party.graph.read','party.graph.manage');
-- DELETE FROM schema_migrations WHERE version = 117;
-- COMMIT;
