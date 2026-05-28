-- Migration: 292_crm_create_permissions.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: (1) INSERT 4 new permissions (regulatory.cascade.read/run + party.workforce.read/manage).
--              (2) Seed procurement_supplier_risk role (CLOSES DEFECT-CRH-DB-01 — carried since CR-H).
--                  Decision CR-M-Q3: seed in 292 (needed by AC#7 read-gating + Stories 1/2).
--              (3) role_permission grants (idempotent ON CONFLICT DO NOTHING pattern — mig 210).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Step 1: 4 new permissions
INSERT INTO permission (code, module, action, description, created_at, is_active)
VALUES
  ('regulatory.cascade.read', 'regulatory', 'cascade.read', 'View regulatory cascade runs and items', NOW(), TRUE),
  ('regulatory.cascade.run',  'regulatory', 'cascade.run',  'Execute the labor-law regulatory cascade', NOW(), TRUE),
  ('party.workforce.read',    'party',      'workforce.read',   'View contractor workforce attributes', NOW(), TRUE),
  ('party.workforce.manage',  'party',      'workforce.manage', 'Create/update contractor workforce attributes', NOW(), TRUE)
ON CONFLICT (code) DO NOTHING;

-- Step 2: Seed procurement_supplier_risk role (closes DEFECT-CRH-DB-01)
-- Pattern mirrors mig 181 (operations/finance_treasury/compliance_esg seed)
INSERT INTO role (name, description, is_active)
VALUES ('procurement_supplier_risk', 'CR-M: Procurement & Supplier Risk persona (closes DEFECT-CRH-DB-01)', TRUE)
ON CONFLICT (name) DO NOTHING;

-- Step 3: role_permission grants
-- Pattern: (r.name, p.code) IN (...) — exact copy of mig 210 pattern; idempotent.
INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r
CROSS JOIN permission p
WHERE (r.name, p.code) IN (
  -- regulatory.cascade.read: wide read access
  ('Super Admin',                 'regulatory.cascade.read'),
  ('platform_admin',              'regulatory.cascade.read'),
  ('compliance_esg',              'regulatory.cascade.read'),
  ('legal_counsel',               'regulatory.cascade.read'),
  ('executive',                   'regulatory.cascade.read'),
  ('procurement_supplier_risk',   'regulatory.cascade.read'),

  -- regulatory.cascade.run: run-capable roles only
  ('Super Admin',                 'regulatory.cascade.run'),
  ('platform_admin',              'regulatory.cascade.run'),
  ('compliance_esg',              'regulatory.cascade.run'),

  -- party.workforce.read: wide read access
  ('Super Admin',                 'party.workforce.read'),
  ('platform_admin',              'party.workforce.read'),
  ('compliance_esg',              'party.workforce.read'),
  ('legal_counsel',               'party.workforce.read'),
  ('executive',                   'party.workforce.read'),
  ('procurement_supplier_risk',   'party.workforce.read'),

  -- party.workforce.manage: manage-capable roles only
  ('Super Admin',                 'party.workforce.manage'),
  ('platform_admin',              'party.workforce.manage'),
  ('compliance_esg',              'party.workforce.manage')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (292, '292_crm_create_permissions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 292;
-- DELETE FROM role_permission WHERE permission_id IN (
--   SELECT id FROM permission WHERE code IN (
--     'regulatory.cascade.read','regulatory.cascade.run',
--     'party.workforce.read','party.workforce.manage'));
-- DELETE FROM permission WHERE code IN (
--   'regulatory.cascade.read','regulatory.cascade.run',
--   'party.workforce.read','party.workforce.manage');
-- DELETE FROM role WHERE name = 'procurement_supplier_risk';
-- COMMIT;
-- ============================================================
