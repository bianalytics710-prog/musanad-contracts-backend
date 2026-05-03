-- ============================================================================
-- 009_m1b_payment_schedule.sql — M1b payment_schedule table + RLS + audit
-- ============================================================================
-- Module:    M1b (Contracts: Compose Wizard, Payment Schedules & Exports)
-- Owner:     Agent 4 — DB Architect
-- Depends:   001..008 (M0 + M1a complete)
-- ----------------------------------------------------------------------------
-- Creates payment_schedule table (14 Lovable cols + 4 v2.6 audit cols, is_seed
-- dropped), 7 indexes (FK + soft-delete + due_date + status + UNIQUE + audit FKs),
-- COMMENT ON COLUMN docs for milestone label/name pairs (Q6), audit trigger
-- binding via M0 fn_audit_trigger, ENABLE ROW LEVEL SECURITY + 4 policies.
-- ----------------------------------------------------------------------------

BEGIN;

-- 1. Table
CREATE TABLE payment_schedule (
  id                  BIGSERIAL PRIMARY KEY,
  contract_id         BIGINT       NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
  milestone_label_en  VARCHAR(255) NOT NULL,
  milestone_label_ar  VARCHAR(255),
  milestone_name_en   VARCHAR(500),
  milestone_name_ar   VARCHAR(500),
  amount_aed          NUMERIC(15,2) NOT NULL CHECK (amount_aed >= 0),
  due_date            DATE,
  paid_at             TIMESTAMPTZ,
  status              VARCHAR(20)   NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','due','paid','overdue','waived','cancelled')),
  recurrence          VARCHAR(20)
                        CHECK (recurrence IS NULL OR recurrence IN ('once','monthly','quarterly','annually')),
  invoice_ref         VARCHAR(100),
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by          BIGINT        REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT        REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN       NOT NULL DEFAULT TRUE,
  CONSTRAINT chk_payment_schedule_paid_at_status
    CHECK (paid_at IS NULL OR status = 'paid')
);

COMMENT ON TABLE  payment_schedule IS 'M1b per-contract milestone payment schedule. Reconstituted from Lovable per HITL G1.';
COMMENT ON COLUMN payment_schedule.milestone_label_en IS 'Short display tag (e.g. "Milestone 1") — kept alongside milestone_name_en per Q6.';
COMMENT ON COLUMN payment_schedule.milestone_label_ar IS 'Arabic counterpart of milestone_label_en.';
COMMENT ON COLUMN payment_schedule.milestone_name_en  IS 'Descriptive title — distinct from milestone_label_en per Q6.';
COMMENT ON COLUMN payment_schedule.milestone_name_ar  IS 'Arabic counterpart of milestone_name_en.';
COMMENT ON COLUMN payment_schedule.amount_aed         IS 'Milestone payment amount in AED, NUMERIC(15,2). Must be >= 0.';
COMMENT ON COLUMN payment_schedule.status             IS 'Milestone lifecycle state. CHECK enum: pending|due|paid|overdue|waived|cancelled.';
COMMENT ON COLUMN payment_schedule.recurrence         IS 'Recurrence mode: once|monthly|quarterly|annually (nullable).';
COMMENT ON COLUMN payment_schedule.invoice_ref        IS 'External invoice reference (free text).';
COMMENT ON COLUMN payment_schedule.is_active          IS 'Soft-delete flag. Direct DELETE forbidden via RESTRICTIVE policy.';

-- 2. Indexes
CREATE INDEX idx_payment_schedule_contract_id ON payment_schedule(contract_id);
CREATE INDEX idx_payment_schedule_active      ON payment_schedule(id) WHERE is_active = TRUE;
CREATE INDEX idx_payment_schedule_due_date    ON payment_schedule(due_date)
  WHERE is_active = TRUE AND due_date IS NOT NULL;
CREATE INDEX idx_payment_schedule_status      ON payment_schedule(status) WHERE is_active = TRUE;
CREATE UNIQUE INDEX uq_payment_schedule_contract_label_active
  ON payment_schedule(contract_id, milestone_label_en) WHERE is_active = TRUE;
CREATE INDEX idx_payment_schedule_created_by  ON payment_schedule(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_payment_schedule_updated_by  ON payment_schedule(updated_by) WHERE updated_by IS NOT NULL;

-- 3. Audit trigger binding (reuses M0 fn_audit_trigger)
DROP TRIGGER IF EXISTS audit_payment_schedule_changes ON payment_schedule;
CREATE TRIGGER audit_payment_schedule_changes
  AFTER INSERT OR UPDATE OR DELETE ON payment_schedule
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- 4. Enable RLS + Policies
ALTER TABLE payment_schedule ENABLE ROW LEVEL SECURITY;

CREATE POLICY payment_schedule_select_parent_aware ON payment_schedule
  FOR SELECT USING (
    is_active = TRUE
    AND EXISTS (SELECT 1 FROM contract c WHERE c.id = payment_schedule.contract_id)
  );

CREATE POLICY payment_schedule_insert_parent_writable ON payment_schedule
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM contract c WHERE c.id = payment_schedule.contract_id AND c.is_active = TRUE)
    AND (
      fn_current_user_has_permission('contract.edit')
      OR (
        fn_current_user_has_permission('contract.draft')
        AND EXISTS (
          SELECT 1 FROM contract c
          WHERE c.id = payment_schedule.contract_id
            AND c.is_active = TRUE
            AND c.drafted_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND c.status IN ('draft','resubmission_requested')
        )
      )
    )
  );

CREATE POLICY payment_schedule_update_parent_writable ON payment_schedule
  FOR UPDATE USING (
    is_active = TRUE
    AND EXISTS (SELECT 1 FROM contract c WHERE c.id = payment_schedule.contract_id AND c.is_active = TRUE)
    AND (
      fn_current_user_has_permission('contract.edit')
      OR (
        fn_current_user_has_permission('contract.draft')
        AND EXISTS (
          SELECT 1 FROM contract c
          WHERE c.id = payment_schedule.contract_id
            AND c.drafted_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND c.status IN ('draft','resubmission_requested')
        )
      )
    )
  )
  WITH CHECK (TRUE);

CREATE POLICY payment_schedule_deny_direct_delete ON payment_schedule
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- 5. Record migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (9, 'm1b_payment_schedule', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 009_m1b_payment_schedule.sql
-- ============================================================================
-- ROLLBACK BEGIN
BEGIN;
  DROP POLICY IF EXISTS payment_schedule_deny_direct_delete       ON payment_schedule;
  DROP POLICY IF EXISTS payment_schedule_update_parent_writable   ON payment_schedule;
  DROP POLICY IF EXISTS payment_schedule_insert_parent_writable   ON payment_schedule;
  DROP POLICY IF EXISTS payment_schedule_select_parent_aware      ON payment_schedule;
  DROP TRIGGER IF EXISTS audit_payment_schedule_changes ON payment_schedule;
  DROP TABLE IF EXISTS payment_schedule CASCADE;
  DELETE FROM schema_migrations WHERE version = 9;
COMMIT;
-- ROLLBACK END
