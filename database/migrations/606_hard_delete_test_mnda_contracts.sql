-- Migration: 606_hard_delete_test_mnda_contracts.sql
-- Module: Demo cleanup — hard-delete 3 test "MNDA TechnipFMC" contracts
-- Date: 2026-06-09
--
-- During the demo dry-run Hala created three throwaway "MNDA TechnipFMC"
-- contracts. They were scaffolding, never went into production, and
-- inflate the drafter pipeline counts during the live walkthrough.
--
-- Contracts to remove:
--   • CT-2026-000025  (id 694)
--   • CT-2026-000026  (id 695)
--   • CT-2026-000027  (id 699)
--
-- Hard-delete cascade order (no soft-delete fallback per user
-- instruction):
--   1. approval_decision → references approval_step
--   2. approval_step     → references approval_chain
--   3. approval_chain    → references contract
--   4. contract_activity → references contract
--   5. contract_version  → references contract
--   6. contract          → root
--
-- Other tables that might reference contract are not used by these
-- particular rows (no signatures, no obligations, no risk cases tied
-- to them — confirmed via probe). Idempotent — running twice is a no-op.

BEGIN;

DO $$
DECLARE
  v_ids BIGINT[] := ARRAY[694, 695, 699]::BIGINT[];
  v_count INT;
BEGIN
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', true);

  -- 1. approval_decision
  DELETE FROM approval_decision
   WHERE approval_step_id IN (
     SELECT s.id FROM approval_step s
     JOIN approval_chain ch ON ch.id = s.approval_chain_id
     WHERE ch.contract_id = ANY(v_ids)
   );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'approval_decision: % rows', v_count;

  -- 2. approval_step
  DELETE FROM approval_step
   WHERE approval_chain_id IN (
     SELECT id FROM approval_chain WHERE contract_id = ANY(v_ids)
   );
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'approval_step: % rows', v_count;

  -- 3. approval_chain
  DELETE FROM approval_chain WHERE contract_id = ANY(v_ids);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'approval_chain: % rows', v_count;

  -- 4. contract_activity
  DELETE FROM contract_activity WHERE contract_id = ANY(v_ids);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'contract_activity: % rows', v_count;

  -- 5. contract_version
  DELETE FROM contract_version WHERE contract_id = ANY(v_ids);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'contract_version: % rows', v_count;

  -- 6. contract
  DELETE FROM contract WHERE id = ANY(v_ids);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'contract: % rows', v_count;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (606, '606_hard_delete_test_mnda_contracts', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- No rollback — hard delete is irreversible per design.
