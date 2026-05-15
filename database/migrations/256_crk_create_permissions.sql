-- Migration: 256_crk_create_permissions.sql
-- Module: M19 — CR-K Risk Cases
-- CR: CR-K
-- Date: 2026-05-15
-- Description: Seed 4 CR-K permissions + role_permission grants per design §0.3
--              remap table. ON CONFLICT DO NOTHING (idempotent).
-- Roles granted: 13-active-roles subset, per remap.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO permission (code, module, action, description) VALUES
  ('risk.case.create',        'risk_case', 'create',   'Create a manual risk case'),
  ('risk.case.escalate',      'risk_case', 'escalate', 'Escalate a risk case to the next role per matrix'),
  ('risk.case.accept_risk',   'risk_case', 'manage',   'Record an Accept-Risk decision with named approval'),
  ('risk.case.close',         'risk_case', 'manage',   'Close a risk case with closure_outcome')
ON CONFLICT (code) DO NOTHING;

-- risk.case.create (8 roles)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r CROSS JOIN permission p
 WHERE p.code = 'risk.case.create'
   AND r.name IN ('platform_admin','Super Admin','operations','finance_treasury','compliance_esg','legal_counsel','contract_drafter','contract_approver_2')
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- risk.case.escalate (8 roles)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r CROSS JOIN permission p
 WHERE p.code = 'risk.case.escalate'
   AND r.name IN ('platform_admin','Super Admin','operations','finance_treasury','compliance_esg','legal_counsel','executive','contract_approver_2')
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- risk.case.accept_risk (4 roles)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r CROSS JOIN permission p
 WHERE p.code = 'risk.case.accept_risk'
   AND r.name IN ('platform_admin','Super Admin','executive','legal_counsel')
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- risk.case.close (10 roles)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r CROSS JOIN permission p
 WHERE p.code = 'risk.case.close'
   AND r.name IN ('platform_admin','Super Admin','operations','finance_treasury','compliance_esg','legal_counsel','executive','contract_drafter','contract_approver','contract_approver_2')
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (256, '256_crk_create_permissions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code IN ('risk.case.create','risk.case.escalate','risk.case.accept_risk','risk.case.close'));
-- DELETE FROM permission WHERE code IN ('risk.case.create','risk.case.escalate','risk.case.accept_risk','risk.case.close');
-- DELETE FROM schema_migrations WHERE version = 256;
-- ============================================================
