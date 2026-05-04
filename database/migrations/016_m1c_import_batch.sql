-- ============================================================================
-- 016_m1c_import_batch.sql — M1c import_batch table + RLS + audit + forward-FK
-- ============================================================================
-- Module:    M1c (Bulk & Manual Import)
-- Owner:     DB Implementation Agent (Agent 6) — applies Agent 4 design verbatim
-- Depends:   001..015 (M0 + M1a + M1b complete; uses fn_audit_trigger,
--            fn_current_user_has_permission, "user" table, role table)
-- ----------------------------------------------------------------------------
-- Creates:
--   1. import_batch table — 17 columns (id + initiated_by + 8 batch state
--      cols + 2 lifecycle ts + 5 audit cols), 2 multi-col CHECK constraints
--      (counter-sum invariant + completed_at-status invariant).
--   2. 7 indexes (active, initiated_by, started_at_desc, status, status_live,
--      created_by, updated_by).
--   3. ENABLE + FORCE ROW LEVEL SECURITY.
--   4. 5 RLS policies (select_role_aware PERMISSIVE, insert_runner PERMISSIVE,
--      update_runner_or_admin PERMISSIVE, deny_direct_is_active_update
--      RESTRICTIVE, deny_direct_delete RESTRICTIVE).
--   5. audit_import_batch_changes trigger -> M0 fn_audit_trigger.
--   6. fk_contract_import_batch_id ON contract.import_batch_id (AE-3 / S9
--      forward-FK closure) wrapped in idempotent DO block.
-- ----------------------------------------------------------------------------
-- Codex lessons applied:
--   - BE-M1b-006: every UPDATE policy WITH CHECK mirrors USING (no TRUE),
--     plus initiated_by anti-reassignment guard pinning the post-image's
--     initiated_by to the pre-image value.
--   - M1a 010 dynamic-rename: forward-FK ALTER wrapped in DO block with
--     pg_constraint lookup so re-running the migration is a no-op.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. import_batch table
-- ============================================================================

CREATE TABLE import_batch (
  id                    BIGSERIAL PRIMARY KEY,

  -- Operator identity (system fact — RESTRICTED reassignment via WITH CHECK)
  initiated_by          BIGINT NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,

  -- Batch defaults JSONB (camelCase keys validated server-side)
  --   { contractType?: string, statusMode: 'active'|'draft'|'auto', defaultCounterpartyId?: number }
  config                JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Up-front file count (immutable after create)
  total_files           INTEGER NOT NULL CHECK (total_files >= 1),

  -- Running counters (incremented via fn_import_batch_update under SELECT FOR UPDATE)
  auto_saved            INTEGER NOT NULL DEFAULT 0 CHECK (auto_saved >= 0),
  review_queue          INTEGER NOT NULL DEFAULT 0 CHECK (review_queue >= 0),
  manual_entry          INTEGER NOT NULL DEFAULT 0 CHECK (manual_entry >= 0),
  duplicates_skipped    INTEGER NOT NULL DEFAULT 0 CHECK (duplicates_skipped >= 0),
  errored               INTEGER NOT NULL DEFAULT 0 CHECK (errored >= 0),
  -- ^ OI-6 resolution: 5th counter required so 'completed' status can be
  --   reached when files fail extraction. AC-S2-04/05 reference all 5.

  -- Lifecycle status (CHECK-enum convention — matches M1a contract.status)
  status                VARCHAR(20) NOT NULL DEFAULT 'in_progress'
                          CHECK (status IN ('in_progress','paused','completed','cancelled')),

  -- Lifecycle timestamps
  started_at            TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at          TIMESTAMP WITH TIME ZONE,

  -- Standard v2.6 audit columns
  created_at            TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by            BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by            BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active             BOOLEAN NOT NULL DEFAULT TRUE,

  -- AC-S2-05 overflow guard (declarative; defense-in-depth alongside fn_)
  CONSTRAINT chk_import_batch_counter_sum
    CHECK (auto_saved + review_queue + manual_entry + duplicates_skipped + errored <= total_files),

  -- Lifecycle invariant: completed_at non-NULL iff status terminal.
  CONSTRAINT chk_import_batch_completed_at_status
    CHECK (
      (status IN ('completed','cancelled') AND completed_at IS NOT NULL)
      OR
      (status IN ('in_progress','paused')  AND completed_at IS NULL)
    )
);

COMMENT ON TABLE import_batch IS
  'M1c bulk-import session tracker. Lifecycle: in_progress -> paused/completed/cancelled. '
  'Cancellation is a status transition, not is_active=false. is_active soft-delete is reserved '
  'for administrative archive (M1a contract precedent). 5 counters (auto_saved + review_queue + '
  'manual_entry + duplicates_skipped + errored) sum-bounded by total_files (AC-S2-05).';

COMMENT ON COLUMN import_batch.config IS
  'Batch defaults JSONB (camelCase): { contractType?, statusMode in (active|draft|auto), defaultCounterpartyId? }. '
  'Validated by fn_import_batch_create.';

COMMENT ON COLUMN import_batch.errored IS
  'OI-6 / Q8 resolution. Counts files that failed extraction or upload entirely. '
  'Without this counter, batches with errors could never reach status=completed because the '
  'auto_saved+review_queue+manual_entry+duplicates_skipped sum would never equal total_files.';

COMMENT ON COLUMN import_batch.initiated_by IS
  'Operator identity. ON DELETE RESTRICT (operator deletion forbidden while owned batches exist). '
  'WITH CHECK on RLS update policy blocks reassignment (Codex BE-M1b-006 lesson).';

-- ============================================================================
-- 2. Indexes
-- ============================================================================

CREATE INDEX idx_import_batch_active
  ON import_batch(id) WHERE is_active = TRUE;

CREATE INDEX idx_import_batch_initiated_by
  ON import_batch(initiated_by) WHERE is_active = TRUE;

CREATE INDEX idx_import_batch_started_at_desc
  ON import_batch(started_at DESC, id DESC) WHERE is_active = TRUE;

CREATE INDEX idx_import_batch_status
  ON import_batch(status) WHERE is_active = TRUE;

CREATE INDEX idx_import_batch_status_live
  ON import_batch(id) WHERE status IN ('in_progress','paused') AND is_active = TRUE;

CREATE INDEX idx_import_batch_created_by
  ON import_batch(created_by) WHERE created_by IS NOT NULL;

CREATE INDEX idx_import_batch_updated_by
  ON import_batch(updated_by) WHERE updated_by IS NOT NULL;

-- ============================================================================
-- 3. Audit trigger binding (reuses M0 fn_audit_trigger)
-- ============================================================================

DROP TRIGGER IF EXISTS audit_import_batch_changes ON import_batch;

CREATE TRIGGER audit_import_batch_changes
  AFTER INSERT OR UPDATE OR DELETE ON import_batch
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ============================================================================
-- 4. Enable RLS + 5 policies
-- ============================================================================

ALTER TABLE import_batch ENABLE ROW LEVEL SECURITY;
ALTER TABLE import_batch FORCE ROW LEVEL SECURITY;

-- Policy 1 — SELECT: role-aware visibility
CREATE POLICY import_batch_select_role_aware ON import_batch
  FOR SELECT
  USING (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
          INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin', 'legal_counsel', 'executive', 'Super Admin')
      )
      OR initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
    )
  );

-- Policy 2 — INSERT: caller has import.run AND post-image initiated_by = current user
CREATE POLICY import_batch_insert_runner ON import_batch
  FOR INSERT
  WITH CHECK (
    fn_current_user_has_permission('import.run')
    AND initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
  );

-- Policy 3 — UPDATE: privileged role OR initiator; WITH CHECK mirrors USING
-- + initiated_by anti-reassignment (Codex BE-M1b-006).
CREATE POLICY import_batch_update_runner_or_admin ON import_batch
  FOR UPDATE
  USING (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
          INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin', 'legal_counsel', 'Super Admin')
      )
      OR initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
    )
  )
  WITH CHECK (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
          INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin', 'legal_counsel', 'Super Admin')
      )
      OR initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
    )
    AND initiated_by = (SELECT b.initiated_by FROM import_batch b WHERE b.id = import_batch.id)
  );

-- Policy 4 — RESTRICTIVE: block any direct UPDATE that flips is_active.
-- M1c has no fn_ that toggles is_active (cancellation = status='cancelled').
CREATE POLICY import_batch_deny_direct_is_active_update ON import_batch
  AS RESTRICTIVE
  FOR UPDATE
  USING (TRUE)
  WITH CHECK (
    is_active = (SELECT b.is_active FROM import_batch b WHERE b.id = import_batch.id)
  );

-- Policy 5 — RESTRICTIVE: hard-delete forbidden universally.
CREATE POLICY import_batch_deny_direct_delete ON import_batch
  AS RESTRICTIVE
  FOR DELETE
  USING (FALSE);

-- ============================================================================
-- 5. AE-3 / S9 — Forward-FK closure on contract.import_batch_id
-- ----------------------------------------------------------------------------
-- The column already exists on M1a contract (BIGINT NULL, partial idx). This
-- adds the FK constraint deferred from M1a. ON DELETE SET NULL preserves
-- contract rows when a batch is hard-deleted in test fixtures. Idempotent via
-- DO block per AC-S9-03.
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
      WHERE conname = 'fk_contract_import_batch_id' AND conrelid = 'contract'::regclass
  ) THEN
    ALTER TABLE contract
      ADD CONSTRAINT fk_contract_import_batch_id
      FOREIGN KEY (import_batch_id) REFERENCES import_batch(id) ON DELETE SET NULL;
  END IF;
END$$;

-- ============================================================================
-- 6. Record migration
-- ============================================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (16, 'm1c_import_batch', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 016_m1c_import_batch.sql
-- ============================================================================
-- ROLLBACK BEGIN
BEGIN;
  -- Drop forward-FK first (so the contract column reverts to forward-ref state)
  ALTER TABLE contract DROP CONSTRAINT IF EXISTS fk_contract_import_batch_id;

  -- Drop policies, trigger, table
  DROP POLICY IF EXISTS import_batch_deny_direct_delete             ON import_batch;
  DROP POLICY IF EXISTS import_batch_deny_direct_is_active_update   ON import_batch;
  DROP POLICY IF EXISTS import_batch_update_runner_or_admin         ON import_batch;
  DROP POLICY IF EXISTS import_batch_insert_runner                  ON import_batch;
  DROP POLICY IF EXISTS import_batch_select_role_aware              ON import_batch;
  DROP TRIGGER IF EXISTS audit_import_batch_changes ON import_batch;
  DROP TABLE IF EXISTS import_batch CASCADE;

  DELETE FROM schema_migrations WHERE version = 16;
COMMIT;
-- ROLLBACK END
