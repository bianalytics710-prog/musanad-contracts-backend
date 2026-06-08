-- Migration: 601_grant_approver_ai_invoke_contract.sql
-- Module: Permissions — contract approver can see the 5-tab AI Insights panel
-- Date: 2026-06-08
--
-- ContractAIInsightsPanel (Summary / Key terms / Risk flags / Obligations /
-- Regulatory) is gated on permission `ai.invoke.contract`. Today the perm
-- is held by Super Admin / contract_drafter / legal_counsel / platform_admin.
-- The contract approver — who has to read every contract before voting —
-- lacks it, so they only see the static Grounded summary and have to wade
-- through the document to understand risks.
--
-- Grant `ai.invoke.contract` to contract_approver. The five tabs auto-fire
-- on mount so an approver opening a contract gets a parallel render of all
-- five views immediately.
--
-- After this migration the approver user must log out + log in (or wait
-- for the 15-minute access-token TTL) for the JWT permission cache to pick
-- up the new grant.

BEGIN;

INSERT INTO role_permission (role_id, permission_id, created_at, created_by, is_active)
SELECT r.id, p.id, NOW(), 1, TRUE
  FROM role r
  CROSS JOIN permission p
 WHERE r.name = 'contract_approver'
   AND p.code = 'ai.invoke.contract'
   AND r.is_active = TRUE
   AND p.is_active = TRUE
   AND NOT EXISTS (
     SELECT 1 FROM role_permission rp
      WHERE rp.role_id = r.id
        AND rp.permission_id = p.id
        AND rp.is_active = TRUE
   );

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (601, '601_grant_approver_ai_invoke_contract', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- UPDATE role_permission
--    SET is_active = FALSE
--  WHERE role_id = (SELECT id FROM role WHERE name = 'contract_approver')
--    AND permission_id = (SELECT id FROM permission WHERE code = 'ai.invoke.contract');
-- DELETE FROM schema_migrations WHERE version = 601;
-- COMMIT;
