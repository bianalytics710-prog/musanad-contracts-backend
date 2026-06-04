-- Migration: 451_ai_risk_assistant_open_to_all_personas.sql
-- Module: AI Risk Assistant — A11-G1 fix (demo coverage)
-- Description: ai_risk_assistant is gated to 7 roles. Demo Act 11 needs it
--              for executive (already allowed) but Layla (legal_counsel)
--              and Hala (contract_drafter) also reasonably ask questions
--              like "which contracts have force majeure that don't cover
--              sanctions?" Add both roles to default_role_codes and to any
--              per-tenant role_module_access overrides that exist.
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- 1. Open default_role_codes to include legal + drafter.
UPDATE product_module
SET default_role_codes = (
  SELECT jsonb_agg(DISTINCT value)
  FROM jsonb_array_elements(
    default_role_codes ||
    '["legal_counsel","contract_drafter","contract_approver","contract_recipient"]'::jsonb
  )
)::jsonb
WHERE key = 'ai_risk_assistant';

-- 2. Mirror to role_module_access overrides so any per-tenant denial gets
--    flipped to allowed for the new roles. role.name carries the role code
--    in this schema.
INSERT INTO role_module_access (tenant_id, role_id, module_key, is_allowed, reason, created_by, updated_by)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  r.id,
  'ai_risk_assistant',
  TRUE,
  'Opened for demo coverage — Act 11 + cross-persona Q&A',
  1, 1
FROM role r
WHERE r.name IN ('legal_counsel','contract_drafter','contract_approver','contract_recipient')
ON CONFLICT (tenant_id, role_id, module_key) DO UPDATE
SET is_allowed = TRUE,
    reason     = 'Opened for demo coverage — Act 11 + cross-persona Q&A',
    updated_at = now();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (451, '451_ai_risk_assistant_open_to_all_personas', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 451;
-- UPDATE product_module SET default_role_codes =
--   default_role_codes - 'legal_counsel' - 'contract_drafter'
--                      - 'contract_approver' - 'contract_recipient'
-- WHERE key = 'ai_risk_assistant';
-- DELETE FROM role_module_access
-- WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
--   AND module_key = 'ai_risk_assistant'
--   AND reason ILIKE 'Opened for demo coverage%';
-- ============================================================
