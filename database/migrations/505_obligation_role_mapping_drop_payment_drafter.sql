-- MIGRATION: 505_obligation_role_mapping_drop_payment_drafter.sql
-- Date: 2026-06-03
-- Description: Remove contract_drafter from the payment row in the
--              obligations.escalation.role_mapping setting — drafters don't
--              own payments (finance_treasury does). Drafter's visible
--              obligation types stay: renewal / notice / other (no payment).

BEGIN;

UPDATE system_setting
SET value = jsonb_set(value, '{payment}', '["finance_treasury"]'::jsonb, FALSE),
    updated_at = NOW()
WHERE key = 'obligations.escalation.role_mapping';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (505, '505_obligation_role_mapping_drop_payment_drafter', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
