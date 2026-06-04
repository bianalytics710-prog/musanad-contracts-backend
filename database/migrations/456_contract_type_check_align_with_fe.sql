-- Migration: 456_contract_type_check_align_with_fe.sql
-- Module: Compose Wizard — E2E walkthrough Issue #2 fix
-- Description: Step 4 "Create contract" returns 409 because the contract
--              table's chk_contract_contract_type constraint only allows
--              7 values (services, epc, gas_spa, concession, term_sale,
--              spot_purchase, vessel_charter) but the FE Compose Wizard
--              exposes 11 (master_services, employment, consultancy,
--              advisory, nda, sow, supply also). Hala picks MSA in the
--              demo → 409. Expand the check to cover the full FE set so
--              every wizard contractType option is accepted.
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

ALTER TABLE contract DROP CONSTRAINT IF EXISTS chk_contract_contract_type;

ALTER TABLE contract ADD CONSTRAINT chk_contract_contract_type
  CHECK (contract_type IN (
    'services',
    'epc',
    'gas_spa',
    'concession',
    'term_sale',
    'spot_purchase',
    'vessel_charter',
    'master_services',
    'employment',
    'consultancy',
    'advisory',
    'nda',
    'sow',
    'supply'
  ));

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (456, '456_contract_type_check_align_with_fe', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 456;
-- ALTER TABLE contract DROP CONSTRAINT IF EXISTS chk_contract_contract_type;
-- ALTER TABLE contract ADD CONSTRAINT chk_contract_contract_type
--   CHECK (contract_type IN ('services','epc','gas_spa','concession',
--                            'term_sale','spot_purchase','vessel_charter'));
-- ============================================================
