-- Migration: 188_crg_seed_role_permission_dashboard_grants.sql
-- Module: M15 — CR-G (Executive Decision Support Evolution + 4 Persona Dashboards + AI Risk Assistant)
-- Description: Final permission grants for CR-G
--              Block A: insights.procurement_supplier_risk → contract_drafter / contract_approver / platform_admin / Super Admin
--              Block B: ai.invoke.risk_assistant → 9 roles
--                       (executive, legal_counsel, operations, finance_treasury, compliance_esg,
--                        contract_drafter, contract_approver, platform_admin, Super Admin)
--              All ON CONFLICT DO NOTHING — fully idempotent
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Block A: insights.procurement_supplier_risk → drafter / approver / platform_admin / Super Admin
WITH r AS (
  SELECT id, name FROM role
  WHERE name IN ('contract_drafter', 'contract_approver', 'platform_admin', 'Super Admin')
),
p AS (
  SELECT id FROM permission WHERE code = 'insights.procurement_supplier_risk'
)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM r CROSS JOIN p
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Block B: ai.invoke.risk_assistant → all 9 dashboard-touching roles
WITH r AS (
  SELECT id, name FROM role
  WHERE name IN (
    'executive',
    'legal_counsel',
    'operations',
    'finance_treasury',
    'compliance_esg',
    'contract_drafter',
    'contract_approver',
    'platform_admin',
    'Super Admin'
  )
),
p AS (
  SELECT id FROM permission WHERE code = 'ai.invoke.risk_assistant'
)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id FROM r CROSS JOIN p
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (188, '188_crg_seed_role_permission_dashboard_grants', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 188;
-- DELETE FROM role_permission
--   WHERE permission_id IN (
--     SELECT id FROM permission WHERE code IN (
--       'insights.procurement_supplier_risk',
--       'ai.invoke.risk_assistant'
--     )
--   )
--   AND role_id IN (
--     SELECT id FROM role WHERE name IN (
--       'executive','legal_counsel','operations','finance_treasury','compliance_esg',
--       'contract_drafter','contract_approver','platform_admin','Super Admin'
--     )
--   );
-- ============================================================
