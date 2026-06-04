-- MIGRATION: 527_approval_matrix_reseed.sql
-- Date: 2026-06-03
-- Description:
--   Drop platform_admin from escalation_role everywhere (tech role should
--   never appear in the approval chain UI).
--
--   Reshape the two-step rules (msa, vendor, consulting) to PARALLEL pairs —
--   legal_counsel + contract_approver fire concurrently at step 1, both
--   required. Avoids the legal-first-vs-business-first ordering debate
--   and minimises cycle time.
--
--   Widen the chk_approval_matrix_contract_type CHECK to cover the actual
--   ADNOC contract types in use (services, epc, master_services, gas_spa,
--   concession, vessel_charter, term_sale) so fn_approval_route_init can
--   actually match the contracts in the system.
--
--   Add matrix rules for those ADNOC types: heavy-negotiation contracts
--   (epc / master_services / gas_spa / concession) get the parallel pair;
--   services contracts get contract_approver only (templated, low ceremony);
--   vessel_charter / term_sale get the parallel pair.
--
--   For any contract type at value >= 5M AED, append a sequential executive
--   approval step.

BEGIN;

-- ============================================================
-- 1. Widen contract_type CHECK to cover real ADNOC types.
-- ============================================================
ALTER TABLE approval_matrix
  DROP CONSTRAINT IF EXISTS chk_approval_matrix_contract_type;

ALTER TABLE approval_matrix
  ADD CONSTRAINT chk_approval_matrix_contract_type
  CHECK (contract_type IN (
    'employment','msa','sow','nda','vendor','partnership','consulting','other',
    'services','epc','master_services','gas_spa','concession',
    'vessel_charter','term_sale'
  ));

-- ============================================================
-- 2. Drop ALL existing matrix rules (clean reseed).
-- ============================================================
-- Soft-delete by setting is_active = FALSE so any in-flight chains keep
-- their matrix_snapshot reference intact; new chains pick from the new set.
UPDATE approval_matrix
   SET is_active = FALSE,
       updated_at = CURRENT_TIMESTAMP,
       updated_by = 1
 WHERE is_active = TRUE;

-- ============================================================
-- 3. Reseed — parallel approver pairs by contract type.
-- ============================================================
-- Pattern:
--   NDA              → legal_counsel only (compliance gate, no business cost)
--   SOW < 500k AED   → contract_approver only (templated, low-risk)
--   SOW ≥ 500k AED   → parallel(legal_counsel, contract_approver)
--   Services         → contract_approver only (high volume, templated)
--   MSA / Vendor /
--   Consulting /
--   EPC / GasSPA /
--   MasterServices /
--   Concession /
--   VesselCharter /
--   TermSale         → parallel(legal_counsel, contract_approver)
--   Any type, ≥5M    → + sequential executive step (step_order = 2)
--
-- escalation_role and escalation_after_hours intentionally left NULL.
-- Platform admin is a tech-ops role and must not appear in approval UIs.

-- NDA — legal counsel only
INSERT INTO approval_matrix
  (contract_type, min_value_aed, max_value_aed, step_order, parallel_group, approver_role, is_required, escalation_role, escalation_after_hours, created_by, updated_by, is_active, data_classification)
VALUES
  ('nda', 0, NULL, 1, NULL, 'legal_counsel', TRUE, NULL, NULL, 1, 1, TRUE, 'demo');

-- SOW
INSERT INTO approval_matrix
  (contract_type, min_value_aed, max_value_aed, step_order, parallel_group, approver_role, is_required, escalation_role, escalation_after_hours, created_by, updated_by, is_active, data_classification)
VALUES
  ('sow', 0,       500000, 1, NULL, 'contract_approver', TRUE, NULL, NULL, 1, 1, TRUE, 'demo'),
  ('sow', 500000,  NULL,   1, 1,    'legal_counsel',     TRUE, NULL, NULL, 1, 1, TRUE, 'demo'),
  ('sow', 500000,  NULL,   1, 1,    'contract_approver', TRUE, NULL, NULL, 1, 1, TRUE, 'demo');

-- Services (templated, business-only)
INSERT INTO approval_matrix
  (contract_type, min_value_aed, max_value_aed, step_order, parallel_group, approver_role, is_required, escalation_role, escalation_after_hours, created_by, updated_by, is_active, data_classification)
VALUES
  ('services', 0, NULL, 1, NULL, 'contract_approver', TRUE, NULL, NULL, 1, 1, TRUE, 'demo');

-- Parallel pair: legal + business at step 1, both required.
-- Heavy-negotiation contract types.
WITH heavy_types AS (
  SELECT unnest(ARRAY[
    'msa','vendor','consulting','epc','master_services',
    'gas_spa','concession','vessel_charter','term_sale'
  ]) AS ct
)
INSERT INTO approval_matrix
  (contract_type, min_value_aed, max_value_aed, step_order, parallel_group, approver_role, is_required, escalation_role, escalation_after_hours, created_by, updated_by, is_active, data_classification)
SELECT ct, 0, NULL, 1, 1, role, TRUE, NULL, NULL, 1, 1, TRUE, 'demo'
  FROM heavy_types,
  LATERAL (VALUES ('legal_counsel'), ('contract_approver')) AS roles(role);

-- Executive approval as a sequential step 2 when value >= 5M AED.
-- Applies to all heavy-negotiation types + sow.
WITH high_value_types AS (
  SELECT unnest(ARRAY[
    'msa','vendor','consulting','epc','master_services',
    'gas_spa','concession','vessel_charter','term_sale','sow'
  ]) AS ct
)
INSERT INTO approval_matrix
  (contract_type, min_value_aed, max_value_aed, step_order, parallel_group, approver_role, is_required, escalation_role, escalation_after_hours, created_by, updated_by, is_active, data_classification)
SELECT ct, 5000000, NULL, 2, NULL, 'executive', TRUE, NULL, NULL, 1, 1, TRUE, 'demo'
  FROM high_value_types;

-- ============================================================
-- 4. Schema migration registry entry.
-- ============================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (527, 'approval_matrix_reseed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
