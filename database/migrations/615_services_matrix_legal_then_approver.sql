-- Migration: 615_services_matrix_legal_then_approver.sql
-- Module: Approval matrix — services contracts route Legal → Approver
-- Date: 2026-06-09
--
-- Drafter feedback after the resubmission walk: services contracts
-- currently go straight to the Contract Approver, but Legal Counsel
-- should look at them first. The approval_matrix had a single row for
-- contract_type='services' (id=23, step_order=1, contract_approver),
-- so the chain preview showed one step and skipped legal entirely.
--
-- Rewrite the services matrix to two steps:
--   step_order=1 → legal_counsel   (required)
--   step_order=2 → contract_approver (required)
--
-- Both steps `is_required=TRUE` so the chain is an all-of sequence. The
-- existing chain on contracts already mid-flight is NOT touched —
-- fn_approval_route_init reads the matrix only when a NEW chain starts
-- (i.e. when a drafter submits or resubmits a draft).

BEGIN;

-- Step 1: move existing row's role to legal_counsel (keeps id=23 stable
-- so any downstream references survive). step_order stays at 1.
UPDATE approval_matrix
   SET approver_role = 'legal_counsel',
       updated_at = CURRENT_TIMESTAMP
 WHERE id = 23
   AND contract_type = 'services'
   AND step_order = 1;

-- Step 2: add the Contract Approver step. Idempotent — re-running the
-- migration is a no-op once the row exists.
INSERT INTO approval_matrix (
  contract_type, min_value_aed, max_value_aed,
  step_order, parallel_group, approver_role, is_required,
  escalation_role, escalation_after_hours,
  created_at, updated_at, created_by, updated_by,
  is_active, data_classification
)
SELECT
  'services'::TEXT, 0.00::NUMERIC, NULL::NUMERIC,
  2, NULL, 'contract_approver'::TEXT, TRUE,
  NULL, NULL,
  CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 1, 1,
  TRUE, 'demo'
 WHERE NOT EXISTS (
   SELECT 1 FROM approval_matrix
    WHERE contract_type = 'services'
      AND step_order = 2
      AND approver_role = 'contract_approver'
      AND is_active = TRUE
 );

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (615, '615_services_matrix_legal_then_approver', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
