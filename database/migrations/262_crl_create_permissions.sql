-- Migration: 262_crl_create_permissions.sql
-- Module: M20 — CR-L Reports & Briefings
-- CR: CR-L
-- Date: 2026-05-15
-- Description: 4 CR-L permissions + role_permission grants per design §0.3 remap.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO permission (code, module, action, description) VALUES
  ('report.read',             'report', 'read',    'View available report templates and run reports'),
  ('report.template.manage',  'report', 'manage',  'Manage report templates (CRUD)'),
  ('report.schedule.manage',  'report', 'manage',  'Manage scheduled report dispatch configuration'),
  ('report.run.read.all',     'report', 'read',    'Read all report runs across users in tenant')
ON CONFLICT (code) DO NOTHING;

-- report.read (11 roles)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r CROSS JOIN permission p
 WHERE p.code = 'report.read'
   AND r.name IN ('platform_admin','Super Admin','executive','legal_counsel','operations','finance_treasury','compliance_esg','contract_drafter','contract_approver','contract_approver_2','contract_recipient')
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- report.template.manage (2 roles)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r CROSS JOIN permission p
 WHERE p.code = 'report.template.manage'
   AND r.name IN ('platform_admin','Super Admin')
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- report.schedule.manage (2 roles)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r CROSS JOIN permission p
 WHERE p.code = 'report.schedule.manage'
   AND r.name IN ('platform_admin','Super Admin')
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- report.run.read.all (2 roles)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r CROSS JOIN permission p
 WHERE p.code = 'report.run.read.all'
   AND r.name IN ('platform_admin','Super Admin')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (262, '262_crl_create_permissions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code IN ('report.read','report.template.manage','report.schedule.manage','report.run.read.all'));
-- DELETE FROM permission WHERE code IN ('report.read','report.template.manage','report.schedule.manage','report.run.read.all');
-- DELETE FROM schema_migrations WHERE version = 262;
-- ============================================================
