-- Migration: 596_grant_executive_risk_case_create.sql
-- Module: Permissions — executive can open risk cases from dashboards
-- Date: 2026-06-05
--
-- The "executive" role today holds risk.case.accept_risk + close + escalate
-- — i.e. they can react to existing cases but cannot OPEN new ones. The
-- recently-shipped Contract Spend Health → Variance & Clauses "Escalate
-- to drafter" button and the Index-Linked Contracts EscalateBandDialog
-- both go through POST /api/v1/risk-cases which requires risk.case.create.
-- Executives hit a 403 ("You don't have permission to perform this
-- action") when trying to use either feature, even though escalating to
-- the drafter is the whole point of those flows for that persona.
--
-- Fix: grant risk.case.create to the executive role. Aligns the permission
-- set with the new workflows. Executives can open cases; the case body
-- still routes through fn_risk_case_create which enforces visibility
-- (contract scope, assignable role) inside the fn.

BEGIN;

INSERT INTO role_permission (role_id, permission_id, created_at, created_by, is_active)
SELECT r.id, p.id, NOW(), 1, TRUE
  FROM role r
  CROSS JOIN permission p
 WHERE r.name = 'executive'
   AND p.code = 'risk.case.create'
   AND r.is_active = TRUE
   AND p.is_active = TRUE
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp
      WHERE rp.role_id = r.id
        AND rp.permission_id = p.id
        AND rp.is_active = TRUE
   );

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (596, '596_grant_executive_risk_case_create', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- UPDATE role_permission
--    SET is_active = FALSE
--  WHERE role_id = (SELECT id FROM role WHERE name = 'executive')
--    AND permission_id = (SELECT id FROM permission WHERE code = 'risk.case.create');
-- DELETE FROM schema_migrations WHERE version = 596;
-- COMMIT;
