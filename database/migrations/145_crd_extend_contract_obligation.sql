-- Migration: 145_crd_extend_contract_obligation.sql
-- Module: M12 / CR-D — Clause Taxonomy + Two-Stage Extractor + Auto-Obligation Derivation
-- Description: (a) Widen contract_obligation_obligation_type_check enum (adds 'cure' + 'certification').
--              (b) ADD COLUMN derived_from_clause_id BIGINT NULL REFERENCES contract_clause_extracted(id).
--              (c) Partial UNIQUE INDEX uq_contract_obligation_derived_from_clause_type (OD-4).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- (a) Widen the obligation_type CHECK enum (CF-5 + HITL Q4)
-- Drop the predecessor constraint then re-add with 2 new values: 'cure', 'certification'
ALTER TABLE contract_obligation DROP CONSTRAINT contract_obligation_obligation_type_check;
ALTER TABLE contract_obligation ADD CONSTRAINT contract_obligation_obligation_type_check
  CHECK (obligation_type IN (
    'payment', 'delivery', 'reporting', 'renewal',
    'compliance', 'notice', 'other',
    'cure',           -- NEW (CF-5; HITL Q4 cure_period clause auto-obligation derivation)
    'certification'   -- NEW (CF-5; HITL Q4 icv_in_country_value clause auto-obligation derivation)
  ));
COMMENT ON CONSTRAINT contract_obligation_obligation_type_check ON contract_obligation IS
  'Widened CR-D migration 145 for cure + certification obligation types per HITL Q4. Predecessor 7-value enum (payment/delivery/reporting/renewal/compliance/notice/other) extended via DROP+ADD pattern.';

-- (b) Add idempotency back-reference column (OD-4)
ALTER TABLE contract_obligation
  ADD COLUMN derived_from_clause_id BIGINT NULL
    REFERENCES contract_clause_extracted(id) ON DELETE SET NULL;
COMMENT ON COLUMN contract_obligation.derived_from_clause_id IS
  'Back-reference to the contract_clause_extracted row that auto-generated this obligation. NULL for manually-created obligations. Idempotency anchor for fn_obligations_derive_from_clause re-extraction.';

-- (c) Partial UNIQUE index — idempotency key for fn_obligations_derive_from_clause (OD-4)
CREATE UNIQUE INDEX uq_contract_obligation_derived_from_clause_type
  ON contract_obligation (derived_from_clause_id, obligation_type)
  WHERE derived_from_clause_id IS NOT NULL AND is_active = TRUE;
COMMENT ON INDEX uq_contract_obligation_derived_from_clause_type IS
  'Idempotency key for fn_obligations_derive_from_clause. Prevents duplicate auto-derived obligations on re-extraction. Pre-existing manually-created obligations (NULL derived_from_clause_id) remain unaffected.';

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (145, '145_crd_extend_contract_obligation', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 145;
-- DROP INDEX IF EXISTS uq_contract_obligation_derived_from_clause_type;
-- ALTER TABLE contract_obligation DROP COLUMN IF EXISTS derived_from_clause_id;
-- ALTER TABLE contract_obligation DROP CONSTRAINT IF EXISTS contract_obligation_obligation_type_check;
-- ALTER TABLE contract_obligation ADD CONSTRAINT contract_obligation_obligation_type_check
--   CHECK (obligation_type IN ('payment','delivery','reporting','renewal','compliance','notice','other'));
-- ============================================================
