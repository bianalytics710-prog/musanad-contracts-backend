-- Migration: 154_cre_permissions_grants_seed.sql
-- Module: M13 / CR-E — Correlation Rule Engine
-- Description: 4 net-new permissions + 9 role_permission grants (db-design.md §2.6).
--   rule.read (platform_admin + legal_counsel = 2 grants)
--   rule.manage (platform_admin only = 1 grant)
--   correlation.read (platform_admin + legal_counsel + [compliance_esg deferred] = 2 active grants)
--   correlation.dismiss (platform_admin + legal_counsel + [compliance_esg deferred] = 2 active grants)
--   NOTE: compliance_esg role does not exist yet — deferred to CR-G per HITL scopeNotes.
--   Total active grants: 7 (not 9 — 2 compliance_esg deferred per scope decision).
--   ON CONFLICT DO NOTHING — idempotent.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- 4 net-new permissions
INSERT INTO permission (code, module, action, description, is_active, created_at)
VALUES
  ('rule.read',          'rule',        'read',     'Read correlation rule definitions and list (admin only).',                  TRUE, NOW()),
  ('rule.manage',        'rule',        'manage',   'Create, update, delete, and test correlation rules (platform admin only).', TRUE, NOW()),
  ('correlation.read',   'correlation', 'read',     'List and view correlation rule firings per role-scoped access.',            TRUE, NOW()),
  ('correlation.dismiss','correlation', 'dismiss',  'Dismiss a correlation with a required reason.',                             TRUE, NOW())
ON CONFLICT (code) DO NOTHING;

-- rule.read × 2 (platform_admin + legal_counsel)
INSERT INTO role_permission (role_id, permission_id, is_active, created_at)
SELECT r.id, p.id, TRUE, NOW()
FROM role r, permission p
WHERE r.name IN ('platform_admin', 'legal_counsel') AND p.code = 'rule.read'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- rule.manage × 1 (platform_admin only per AC-S12-01)
INSERT INTO role_permission (role_id, permission_id, is_active, created_at)
SELECT r.id, p.id, TRUE, NOW()
FROM role r, permission p
WHERE r.name = 'platform_admin' AND p.code = 'rule.manage'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- correlation.read × 2 active (platform_admin + legal_counsel)
-- NOTE: compliance_esg deferred to CR-G — role not yet seeded
INSERT INTO role_permission (role_id, permission_id, is_active, created_at)
SELECT r.id, p.id, TRUE, NOW()
FROM role r, permission p
WHERE r.name IN ('platform_admin', 'legal_counsel') AND p.code = 'correlation.read'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- correlation.dismiss × 2 active (platform_admin + legal_counsel)
-- NOTE: compliance_esg deferred to CR-G — role not yet seeded
INSERT INTO role_permission (role_id, permission_id, is_active, created_at)
SELECT r.id, p.id, TRUE, NOW()
FROM role r, permission p
WHERE r.name IN ('platform_admin', 'legal_counsel') AND p.code = 'correlation.dismiss'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (154, '154_cre_permissions_grants_seed', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 154;
-- DELETE FROM role_permission
--   WHERE permission_id IN (SELECT id FROM permission WHERE code IN ('rule.read','rule.manage','correlation.read','correlation.dismiss'));
-- DELETE FROM permission WHERE code IN ('rule.read','rule.manage','correlation.read','correlation.dismiss');
-- ============================================================
