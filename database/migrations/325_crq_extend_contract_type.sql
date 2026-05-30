-- Migration: 325_crq_extend_contract_type.sql
-- Module: CR-Q — ADNOC Data Scale-Up (v1.4 foundation)
-- Description: Extend the existing contract.contract_type column with a CHECK constraint
--              restricting to the CR-Q enum: services / epc / gas_spa / concession /
--              term_sale / spot_purchase / vessel_charter.
--              Also backfills any existing row whose contract_type is not in the new enum
--              to 'services' (the safe default) — prevents constraint violation on add.
--              Spot-check: existing hero contracts 'CRN-296-HERO-001/002/003' already
--              carry contract_type = 'services' (seeded in migration 303 verbatim) so
--              the backfill touches zero rows in a clean DB.
--              Existing SELECT * fns are unaffected — the column existed before this mig;
--              only the CHECK is new.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Step 1: Backfill any out-of-enum values to 'services' (idempotent; no-op on clean DB)
UPDATE contract
SET    contract_type = 'services',
       updated_at    = NOW()
WHERE  contract_type NOT IN (
         'services','epc','gas_spa','concession',
         'term_sale','spot_purchase','vessel_charter'
       );

-- Step 2: Add CHECK constraint (IF NOT EXISTS idiom via DO block)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'chk_contract_contract_type'
      AND conrelid = 'contract'::regclass
  ) THEN
    ALTER TABLE contract
      ADD CONSTRAINT chk_contract_contract_type
      CHECK (contract_type IN (
        'services','epc','gas_spa','concession',
        'term_sale','spot_purchase','vessel_charter'
      ));
  END IF;
END;
$$;

-- Step 3: Verify — count rows outside enum should be 0
DO $$
DECLARE v_bad INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_bad
  FROM contract
  WHERE contract_type NOT IN (
    'services','epc','gas_spa','concession',
    'term_sale','spot_purchase','vessel_charter'
  );
  IF v_bad > 0 THEN
    RAISE EXCEPTION '325: % rows with out-of-enum contract_type after backfill — aborting', v_bad
      USING ERRCODE = 'P0001';
  ELSE
    RAISE NOTICE '325: contract_type CHECK constraint applied; 0 out-of-enum rows.';
  END IF;
END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (325, '325_crq_extend_contract_type', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- ALTER TABLE contract DROP CONSTRAINT IF EXISTS chk_contract_contract_type;
-- DELETE FROM schema_migrations WHERE version = 325;
-- COMMIT;
-- ============================================================
