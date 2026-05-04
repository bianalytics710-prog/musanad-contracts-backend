-- ============================================================================
-- 023_m2_extend_contract_status_check.sql — Extend contract.status CHECK 14 -> 16
-- ============================================================================
-- Module:    M2 (Approval Workflows)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   003_m1a_contracts.sql (anonymous CHECK on contract.status)
-- ----------------------------------------------------------------------------
-- AE-3 / OI-1 / MD-1 — CRITICAL FIRST M2 MIGRATION.
--
-- M1a created the contract.status CHECK constraint inline in CREATE TABLE,
-- which produced an anonymous constraint name. Every M2 fn_ that writes
-- contract.status to 'in_approval' or 'cancelled' fails until the CHECK
-- is extended. We use the same pg_constraint dynamic lookup pattern that
-- M1b 010 used for contract_activity_activity_type_check, then re-create
-- the constraint with a stable name (contract_status_check) so future
-- modules can ALTER by name.
--
-- 14 existing values preserved verbatim; 2 new values appended:
--   - in_approval   (M2 — chain in flight)
--   - cancelled     (M2 — admin-cancelled non-terminal)
-- ----------------------------------------------------------------------------

BEGIN;

DO $$
DECLARE
  v_constraint_name TEXT;
BEGIN
  SELECT con.conname INTO v_constraint_name
    FROM pg_constraint con
    INNER JOIN pg_class      c ON c.oid = con.conrelid
    INNER JOIN pg_attribute  a ON a.attrelid = c.oid AND a.attnum = ANY(con.conkey)
    WHERE c.relname = 'contract'
      AND a.attname = 'status'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%draft%'
    LIMIT 1;

  IF v_constraint_name IS NULL THEN
    RAISE EXCEPTION
      'M2 023: cannot find existing CHECK constraint on contract.status; was M1a 003 applied?'
      USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('ALTER TABLE contract DROP CONSTRAINT %I', v_constraint_name);
END;
$$;

ALTER TABLE contract
  ADD CONSTRAINT contract_status_check
  CHECK (status IN (
    'draft','in_review','approved',
    'awaiting_signature_employer','awaiting_signature_counterparty','fully_signed',
    'active','expiring_soon','expired',
    'amended','renewed','terminated',
    'rejected','resubmission_requested',
    'in_approval','cancelled'
  ));

COMMENT ON CONSTRAINT contract_status_check ON contract IS
  'M2 023 stable name. 16-state enum (M1a 14 + M2 in_approval + cancelled). Future modules extend by DROP + ADD CONSTRAINT contract_status_check.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (23, 'm2_extend_contract_status_check', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
ALTER TABLE contract DROP CONSTRAINT IF EXISTS contract_status_check;
ALTER TABLE contract
  ADD CONSTRAINT contract_status_check
  CHECK (status IN (
    'draft','in_review','approved',
    'awaiting_signature_employer','awaiting_signature_counterparty','fully_signed',
    'active','expiring_soon','expired',
    'amended','renewed','terminated',
    'rejected','resubmission_requested'
  ));
DELETE FROM schema_migrations WHERE version = 23;
COMMIT;
-- ROLLBACK END
