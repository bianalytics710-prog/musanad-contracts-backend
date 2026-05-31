-- Migration: 379_layla_cluster_a_permissions.sql
-- Unit: Layla Counsel QA Phase 3.7 (2026-05-31)
-- Closes Layla audit findings:
--   L37 — HERO-001 contract detail shows empty parties (FE checks `party.read.all`; perm did not exist at all)
--   L48 — Budget Burn 403 for legal_counsel despite sidebar entry (Story 1 cure-notice surface)
--   L91 — Compose 403 sidebar leak (resolved in FE — sidebar entry removed; no grant here)
--
-- Strategy:
--   1. Create `party.read.all` permission (currently missing entirely)
--   2. Grant party.read.all to roles that already have contract.read.all
--   3. Grant finance.budget.read to legal_counsel for Budget Burn access

-- 1. Create party.read.all if missing
INSERT INTO permission (code, module, action, description, is_active, created_at)
SELECT 'party.read.all', 'party', 'read', 'Read all parties in the tenant (used by contract detail to show our_party + counterparty)', TRUE, NOW()
WHERE NOT EXISTS (SELECT 1 FROM permission WHERE code = 'party.read.all');

-- 2. Grant party.read.all to roles that read contracts across the tenant
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
  FROM role r
  CROSS JOIN permission p
 WHERE r.name IN (
        'legal_counsel',
        'executive',
        'finance_treasury',
        'compliance_esg',
        'operations',
        'procurement_supplier_risk',
        'contract_drafter',
        'contract_approver',
        'platform_admin'
       )
   AND p.code = 'party.read.all'
ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = TRUE;

-- 3. Grant finance.budget.read to legal_counsel (Budget Burn — Story 1 cure-notice hand-off surface)
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
  FROM role r
  CROSS JOIN permission p
 WHERE r.name = 'legal_counsel'
   AND p.code = 'finance.budget.read'
ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = TRUE;
