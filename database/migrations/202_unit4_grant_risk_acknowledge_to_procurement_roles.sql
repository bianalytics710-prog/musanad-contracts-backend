-- Migration: 202_unit4_grant_risk_acknowledge_to_procurement_roles.sql
-- Unit: Unit-4 (R-PROC standalone)
-- Description: Grant `risk.acknowledge` to contract_drafter + contract_approver +
--              platform_admin. M14 mig 175 created the permission and granted it
--              to the 3 CR-G dashboard roles (operations/finance_treasury/
--              compliance_esg) only. R-PROC routes the procurement persona
--              through the existing drafter+approver roles per brief §5.1, so
--              those roles need the same risk.acknowledge gate to invoke
--              vendor/contract action endpoints (activate-alternate, escalate,
--              cure-notice-intent, icv-remediation).
-- Reference: GAP-REPORT-PROCUREMENT.md C1, decisions/R-PROC.json AD-4.
-- Rollback: see ROLLBACK section.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO role_permission (role_id, permission_id, created_at, created_by, is_active)
SELECT r.id, p.id, NOW(), 1, TRUE
FROM role r CROSS JOIN permission p
WHERE p.code = 'risk.acknowledge'
  AND r.name IN ('contract_drafter', 'contract_approver', 'platform_admin', 'Super Admin')
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (202, 'Unit-4 R-PROC: grant risk.acknowledge to drafter+approver+platform_admin+Super Admin for procurement actions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM role_permission
--  WHERE permission_id = (SELECT id FROM permission WHERE code='risk.acknowledge')
--    AND role_id IN (SELECT id FROM role WHERE name IN ('contract_drafter','contract_approver','platform_admin','Super Admin'));
-- DELETE FROM schema_migrations WHERE version = 202;
