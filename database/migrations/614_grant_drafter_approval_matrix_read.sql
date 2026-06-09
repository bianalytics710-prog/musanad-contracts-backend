-- Migration: 614_grant_drafter_approval_matrix_read.sql
-- Module: Drafter permission — read the approval matrix for chain preview
-- Date: 2026-06-09
--
-- Resubmit-for-approval failed with 403 for Hala. Root cause: the
-- POST /contracts/:id/approval-chain/preview route is gated on
-- approval.matrix.read (so the drafter can SEE which approvers the
-- contract will route to before submitting). contract_drafter had only
-- approval.submit_for_review, so the preview call was rejected and the
-- SubmitForApprovalDialog rendered "Couldn't preview the approval
-- chain."
--
-- The drafter genuinely needs to see the preview — the chain the
-- contract is about to enter is part of what they're confirming. Grant
-- approval.matrix.read to contract_drafter.

BEGIN;

INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, CURRENT_TIMESTAMP, TRUE
  FROM role r, permission p
 WHERE r.name = 'contract_drafter'
   AND p.code = 'approval.matrix.read'
ON CONFLICT (role_id, permission_id) DO UPDATE
  SET is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (614, '614_grant_drafter_approval_matrix_read', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
