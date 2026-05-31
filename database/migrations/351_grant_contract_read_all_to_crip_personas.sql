-- Migration: 351_grant_contract_read_all_to_crip_personas.sql
-- Unit: QA Phase 3 autonomous run 2026-05-31 — BUG-009 fix
-- Description: ROLE_MODULES in src/config/sidebar.ts grants "Contracts" sidebar
--              entry to finance_treasury / operations / compliance_esg /
--              procurement_supplier_risk personas. But mig 181 (CR-G) + mig 292
--              (CR-M) never granted these roles any contract.read.* permission.
--              Result: clicking Contracts → /api/v1/contracts returns 403
--              repeatedly (4× retry storm). All 4 CRIP personas legitimately
--              need contract browsing per ADNOC demo narrative (Fatima drills
--              into budget contracts, Khalid drills into cascade contractors,
--              etc.). Grant contract.read.all to all 4 roles.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
  FROM role r
  CROSS JOIN permission p
 WHERE r.name IN ('finance_treasury', 'operations', 'compliance_esg', 'procurement_supplier_risk')
   AND p.code = 'contract.read.all'
ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (351, 'BUG-009 fix grant contract.read.all to 4 CRIP personas (finance/ops/compliance/procurement)', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM role_permission
--   WHERE role_id IN (SELECT id FROM role WHERE name IN ('finance_treasury','operations','compliance_esg','procurement_supplier_risk'))
--     AND permission_id = (SELECT id FROM permission WHERE code = 'contract.read.all');
-- DELETE FROM schema_migrations WHERE version = 351;
