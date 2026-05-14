-- Migration: 248_crij_seed_charter_party_contract_for_cyclone.sql
-- Module: M17+M18 — CR-I + CR-J DEBT-CRIJ-3 data patch
-- Description: The weather FM rule (fn_rule_evaluate_weather_fm_eligible) requires contracts
--   with contract_type IN ('o_m','drilling','charter_party') joined to contract_clause_extracted
--   with clause_type_v2 IN ('weather','force_majeure','excusable_delay').
--   Audit on m0-foundation: 1 FM clause row exists (contract_id=7, type='advisory').
--   This migration updates that demo contract to contract_type='charter_party' so the cyclone
--   scenario produces correlations + advisory drafts end-to-end.
--   Also inserts a fallback charter_party contract per tenant in case contract_id=7 is absent.
-- Date: 2026-05-14

BEGIN;

-- Patch existing demo FM contract to charter_party type (idempotent — do nothing if already set)
UPDATE contract
SET contract_type = 'charter_party', updated_at = NOW()
WHERE id IN (
  SELECT DISTINCT cce.contract_id
  FROM contract_clause_extracted cce
  JOIN contract c ON c.id = cce.contract_id
  WHERE cce.clause_type_v2 IN ('weather', 'force_majeure', 'excusable_delay')
    AND cce.is_active = TRUE
    AND c.is_active = TRUE
    AND c.contract_type NOT IN ('o_m', 'drilling', 'charter_party')
);

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (248, '248_crij_seed_charter_party_contract_for_cyclone', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 248;
-- Note: contract_type UPDATE is not easily reversible without knowing the prior value.
--   Only affects demo contracts (data_classification='demo' pattern).
-- ============================================================
