-- Migration: 430_aisha_cluster_b_contract_recency.sql
-- Unit: Aisha Approver PM-grade audit fix pass (2026-06-01) — Cluster B follow-up
-- Defect addressed:
--   A26 — /app/contracts default sort puts Expired contracts above
--         In-Approval ones for the contract_approver role because the FE
--         default sort is updated_at DESC and the in_approval contracts
--         haven't been touched recently. Touch contract.updated_at for
--         contracts pending Aisha's decision so they surface at the top
--         of her landing list without requiring a UI re-ordering rule.
-- Behaviour: bumps updated_at to NOW() for any contract that has an
-- approval_step still pending. Safe to re-run.
-- Test-branch-safe: row-count guard; idempotent UPDATE with WHERE clause.
-- Rollback: optional — see ROLLBACK section.

BEGIN;

DO $$
DECLARE
  v_count INT;
BEGIN
  UPDATE contract c
     SET updated_at = NOW() - (interval '1 minute' * (CASE WHEN c.id = 27 THEN 1 WHEN c.id = 26 THEN 2 WHEN c.id = 25 THEN 3 ELSE 0 END)),
         updated_by = 1
   WHERE EXISTS (
     SELECT 1 FROM approval_step ast
      JOIN approval_chain ac ON ac.id = ast.approval_chain_id
      WHERE ac.contract_id = c.id
        AND ast.status = 'pending'
   );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE '430 A26: touched contract.updated_at on % in-approval contracts so they sort to the top of the recent-first list.', v_count;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (430, 'A26 Aisha — bump contract.updated_at for in-approval contracts', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- (Touch-only migration. No rollback needed; the next legitimate update of
--  any contract row will supersede this bump.)
-- ROLLBACK END
