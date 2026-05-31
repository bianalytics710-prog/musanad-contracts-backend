-- Migration: 352_grant_procurement_role_insights_perm.sql
-- Unit: QA Phase 3 autonomous run 2026-05-31 — BUG-011 fix
-- Description: CR-G mig 188 granted insights.procurement_supplier_risk to
--              drafter / approver / platform_admin / Super Admin. But the
--              procurement_supplier_risk role itself was added later (CR-M
--              mig 292) and never received the perm needed to view its own
--              dashboard. Result: Pari Procurement logging in → 403 on
--              /api/v1/dashboards/procurement. Also grant insights.executive
--              superset perms commonly needed on procurement workflows.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
  FROM role r
  CROSS JOIN permission p
 WHERE r.name = 'procurement_supplier_risk'
   AND p.code IN (
     'insights.procurement_supplier_risk',
     'signal.read.all',
     'correlation.read',
     'score.read',
     'risk.acknowledge',
     'ai.invoke.risk_assistant'
   )
ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (352, 'BUG-011 fix grant insights.procurement_supplier_risk + 5 supporting perms to procurement_supplier_risk role', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM role_permission
--   WHERE role_id = (SELECT id FROM role WHERE name = 'procurement_supplier_risk')
--     AND permission_id IN (SELECT id FROM permission WHERE code IN ('insights.procurement_supplier_risk','signal.read.all','correlation.read','score.read','risk.acknowledge','ai.invoke.risk_assistant'));
-- DELETE FROM schema_migrations WHERE version = 352;
