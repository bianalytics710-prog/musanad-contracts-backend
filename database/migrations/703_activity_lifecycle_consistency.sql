-- ============================================================================
-- Migration 703 — Contract Activity feed: lifecycle consistency cleanup
-- ============================================================================
-- The contract "Activity" tab surfaced two seed-data inconsistencies:
--
--  (1) Duplicate "created" events — some contracts carry a second, empty
--      `created` activity row stamped at the seed-import instant, which sorts
--      to the TOP of the (newest-first) feed and reads as a phantom event.
--      A contract is created once; keep the earliest `created`, drop the rest.
--
--  (2) Signature events on contracts that never reached signing — a few seed
--      "highlight reel" contracts (e.g. OQOOD-2026-001) have
--      sent_for_signature / signer_signed / fully_executed activity even though
--      their current status is still in approval. A contract that is draft /
--      in_review / in_approval / rejected / resubmission_requested / approved
--      has by definition NOT been sent for signature, signed, or executed, so
--      those rows are contradictory. Remove them so the feed matches the
--      contract's real lifecycle stage.
--
-- Reversible soft delete (is_active = FALSE). contract_activity has no audit
-- trigger and no updated_* columns, so a plain flag flip is sufficient.
-- ============================================================================

BEGIN;

-- (1) De-duplicate `created` — keep the earliest active row per contract.
WITH dups AS (
  SELECT id
  FROM (
    SELECT id,
           row_number() OVER (PARTITION BY contract_id ORDER BY created_at, id) AS rn
    FROM contract_activity
    WHERE is_active = TRUE AND activity_type = 'created'
  ) s
  WHERE rn > 1
)
UPDATE contract_activity
   SET is_active = FALSE
 WHERE id IN (SELECT id FROM dups);

-- (2) Strip signature-stage activity from contracts that have not reached the
--     signing stage (status is still pre-signature).
UPDATE contract_activity ca
   SET is_active = FALSE
  FROM contract ct
 WHERE ct.id = ca.contract_id
   AND ca.is_active = TRUE
   AND ca.activity_type IN (
         'sent_for_signature', 'signer_signed', 'signer_viewed',
         'signer_declined', 'fully_executed', 'signature_invalidated')
   AND ct.status IN (
         'draft', 'in_review', 'in_approval', 'rejected',
         'resubmission_requested', 'approved');

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (703, 'activity_lifecycle_consistency', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- Soft-deleted rows can be restored by flipping is_active back, but the exact
-- set is not separately recorded. Targeted manual restore only.
-- DELETE FROM schema_migrations WHERE version = 703;
-- ROLLBACK END
