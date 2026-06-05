-- Migration: 598_cleanup_test_escalation_risk_cases_pt2.sql
-- Module: Test-data cleanup — soft-delete 2 verification-walk risk cases
-- Date: 2026-06-05
--
-- After mig 597 cleaned up the first round of test escalations (33..38),
-- two more cases were opened during the final Playwright verification
-- of the one-shot-escalation badge pattern (see mig 596 + FE commit
-- c82a1ce). Both are scaffolding from the verification walk, not real
-- escalations.
--
--   id 39 — Budget-protection amendment — CRN-296-HERO-002 (contract 53)
--           opened via the Variance & Clauses "Escalate to drafter"
--           button verification.
--
--   id 40 — Trade position TP-MURBAN-KR-JUL26 — renegotiate band
--           opened via the Index-Linked "Escalate" button verification.
--
-- Soft-delete via is_active = FALSE preserves the audit trail while
-- removing them from the Risk Cases list.

BEGIN;

UPDATE risk_case
   SET is_active = FALSE,
       updated_at = NOW(),
       updated_by = 1
 WHERE id IN (39, 40)
   AND tenant_id = '00000000-0000-0000-0000-000000000001'
   AND is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (598, '598_cleanup_test_escalation_risk_cases_pt2', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- UPDATE risk_case SET is_active = TRUE WHERE id IN (39, 40);
-- DELETE FROM schema_migrations WHERE version = 598;
-- COMMIT;
