-- Migration: 597_cleanup_test_escalation_risk_cases.sql
-- Module: Test-data cleanup — soft-delete 6 escalation cases created
-- Date: 2026-06-05
--
-- During the Variance & Clauses + Index-Linked escalation flow testing
-- I created 6 risk cases between 2026-06-05 21:49 and 22:00 UTC:
--
--   id 33 — Budget-protection amendment — CRN-296-HERO-002 (Playwright test)
--   id 34 — Trade position TP-MURBAN-KR-JUL26 — renegotiate band (Playwright)
--   id 35..37 — Budget-protection amendment — CRQ-DRL-001 (user repro)
--   id 38 — Trade position TP-MURBAN-KR-JUL26 — renegotiate band (user repro)
--
-- None of these are real escalations; they're scaffolding from testing the
-- one-time-escalate behaviour. Soft-delete via is_active = FALSE so the
-- audit trail is preserved but the rows vanish from the Risk Cases list.

BEGIN;

UPDATE risk_case
   SET is_active = FALSE,
       updated_at = NOW(),
       updated_by = 1
 WHERE id IN (33, 34, 35, 36, 37, 38)
   AND tenant_id = '00000000-0000-0000-0000-000000000001'
   AND is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (597, '597_cleanup_test_escalation_risk_cases', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- UPDATE risk_case SET is_active = TRUE WHERE id IN (33,34,35,36,37,38);
-- DELETE FROM schema_migrations WHERE version = 597;
-- COMMIT;
