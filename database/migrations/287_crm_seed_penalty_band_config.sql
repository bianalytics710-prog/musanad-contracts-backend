-- Migration: 287_crm_seed_penalty_band_config.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: DEFECT RESOLUTION (Q4 — system_setting category constraint):
--              Live DB CHECK on system_setting.category does NOT include 'regulatory'.
--              Current allowed: general/uae_pass/branding/security/email/calendar/
--                               audit_retention/ai/scoring/risk_case.
--              Step 1: ALTER TABLE to add 'regulatory' to the category CHECK (additive, low-risk).
--              Step 2: INSERT system_setting row for penalty band config.
--              Per decisions CR-M-Q4: "DB Impl confirms live constraint; add 'regulatory' if needed."
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Step 1: Extend system_setting.category CHECK to include 'regulatory'
-- (Live DB CHECK: system_setting_category_check covers 10 categories; 'regulatory' is absent)
ALTER TABLE system_setting DROP CONSTRAINT system_setting_category_check;
ALTER TABLE system_setting ADD CONSTRAINT system_setting_category_check
  CHECK (category = ANY (ARRAY[
    'general','uae_pass','branding','security','email','calendar',
    'audit_retention','ai','scoring','risk_case',
    'regulatory'   -- CR-M addition
  ]));

-- Step 2: INSERT penalty band config row
-- Admin-tunable (Rule 8 — not hardcoded in fn_regulatory_cascade_run).
-- Per Federal Decree-Law No.9/2024 statutory range AED 100k-1M.
INSERT INTO system_setting (key, category, value, description, is_secret, created_at, updated_at, is_active)
VALUES (
  'regulatory.labor_cascade.penalty_bands',
  'regulatory',
  '{
    "<20": {
      "finePerHeadMin": 0,
      "finePerHeadMax": 0,
      "statutoryFloor": 0,
      "statutoryCeiling": 0
    },
    "20-49": {
      "finePerHeadMin": 20000,
      "finePerHeadMax": 50000,
      "statutoryFloor": 100000,
      "statutoryCeiling": 1000000
    },
    "50+": {
      "finePerHeadMin": 20000,
      "finePerHeadMax": 50000,
      "statutoryFloor": 100000,
      "statutoryCeiling": 1000000
    }
  }'::jsonb,
  'Per-band fine range per Federal Decree-Law No.9/2024. AED 100,000-1,000,000 statutory range. Per-head used to scale by emiratisation_gap, clamped to floor/ceiling. Admin-tunable.',
  FALSE,
  NOW(), NOW(), TRUE
)
ON CONFLICT (key) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (287, '287_crm_seed_penalty_band_config', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 287;
-- DELETE FROM system_setting WHERE key = 'regulatory.labor_cascade.penalty_bands';
-- -- Restore CHECK without 'regulatory':
-- ALTER TABLE system_setting DROP CONSTRAINT system_setting_category_check;
-- ALTER TABLE system_setting ADD CONSTRAINT system_setting_category_check
--   CHECK (category = ANY (ARRAY['general','uae_pass','branding','security','email','calendar',
--                                 'audit_retention','ai','scoring','risk_case']));
-- COMMIT;
-- ============================================================
