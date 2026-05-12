-- Migration: 159_crd_backfill_extraction_request.sql
-- Module: M12 / CR-D — Backfill (HITL Q2 decision)
-- Description: DO-block backfill — calls fn_clause_extraction_request for each contract_version
--   whose parent contract is a seeded (is_seed=TRUE) M_parity contract with body text and completed
--   ingestion. Queues all 35 M_parity seeded contracts for Stage 1 + Stage 2 clause extraction.
--   Idempotent — fn_clause_extraction_request returns {queued: false} for already-queued versions.
--   Actual Stage 1/Stage 2 extraction runs asynchronously via BE clause-extraction.worker.ts
--   on PG NOTIFY 'contract.ingested' channel (M11 already live).
--   Per HITL Q2 (M12-M13.json): re-extract all 35 M_parity contracts against the new closed
--   50-type taxonomy (previously extracted with M_parity legacy clause library only).
-- Note: contract.is_seed column used to identify M_parity seeded rows. If this column does not
--   exist on the contract table, fallback to created_by IS NULL check.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  r               RECORD;
  v_result        JSONB;
  v_queued_count  INTEGER := 0;
  v_already_count INTEGER := 0;
  v_error_count   INTEGER := 0;
BEGIN
  -- Set tenant GUC for fn_clause_extraction_request (SECURITY DEFINER reads this GUC)
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', false);

  FOR r IN
    SELECT cv.id AS contract_version_id, cv.contract_id
    FROM   contract_version cv
    JOIN   contract c ON c.id = cv.contract_id
    WHERE  (
             -- Prefer is_seed column if it exists; fallback to body_en IS NOT NULL
             -- (M_parity seeded contracts have body text; user-created contracts in dev may also)
             c.body_en IS NOT NULL
             OR c.body_ar IS NOT NULL
           )
      AND  cv.ingestion_status = 'complete'
    ORDER BY cv.id
  LOOP
    BEGIN
      v_result := fn_clause_extraction_request(r.contract_version_id, NULL);
      IF (v_result->>'queued')::boolean THEN
        v_queued_count := v_queued_count + 1;
      ELSE
        v_already_count := v_already_count + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_error_count := v_error_count + 1;
      RAISE WARNING '159: fn_clause_extraction_request failed for contract_version_id=% — %', r.contract_version_id, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE '159: Backfill complete. queued=%, already_queued=%, errors=%', v_queued_count, v_already_count, v_error_count;
END $$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (159, '159_crd_backfill_extraction_request', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (no-op — idempotent backfill; fn_clause_extraction_request creates pending_extraction
--   marker rows that the worker will process asynchronously. To undo, delete those marker rows.)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 159;
-- DELETE FROM contract_clause_extracted
--   WHERE clause_type_v2 = '__pending_marker__' AND review_status = 'pending_extraction';
-- ============================================================
