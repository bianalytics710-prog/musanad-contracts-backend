-- Migration: 301_crn_seed_system_setting_variance_threshold.sql
-- Module: CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half)
-- Description: (1) Widen system_setting.category CHECK constraint to add 'financial'.
--              Existing constraint name verified: system_setting_category_check.
--              Existing categories (from live schema):
--                'general','uae_pass','branding','security','email','calendar',
--                'audit_retention','ai','scoring','risk_case','regulatory'
--              Adding: 'financial'.
--              (2) UPSERT financial.budget.variance_threshold_pct (JSONB string-quoted, mig 149 pattern).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Step 1: Widen system_setting.category CHECK (drop + re-add with 'financial')
ALTER TABLE system_setting
  DROP CONSTRAINT IF EXISTS system_setting_category_check;

ALTER TABLE system_setting
  ADD CONSTRAINT system_setting_category_check
    CHECK (category IN (
      'general', 'uae_pass', 'branding', 'security', 'email',
      'calendar', 'audit_retention', 'ai', 'scoring', 'risk_case',
      'regulatory', 'financial'
    ));

-- Step 2: UPSERT variance threshold setting
INSERT INTO system_setting (key, category, value, description, is_active, created_at, updated_at)
VALUES (
  'financial.budget.variance_threshold_pct',
  'financial',
  '"5"'::jsonb,
  'Variance % threshold above which a (period,category) budget breach is flagged and a cure notice becomes eligible. Rule-8 config-driven. Default 5.',
  TRUE, NOW(), NOW()
)
ON CONFLICT (key) DO UPDATE SET
  value       = EXCLUDED.value,
  description = EXCLUDED.description,
  updated_at  = NOW();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (301, '301_crn_seed_system_setting_variance_threshold', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM system_setting WHERE key = 'financial.budget.variance_threshold_pct';
-- -- Restore previous CHECK (remove 'financial'):
-- ALTER TABLE system_setting DROP CONSTRAINT IF EXISTS system_setting_category_check;
-- ALTER TABLE system_setting ADD CONSTRAINT system_setting_category_check
--   CHECK (category IN ('general','uae_pass','branding','security','email',
--                       'calendar','audit_retention','ai','scoring','risk_case','regulatory'));
-- DELETE FROM schema_migrations WHERE version = 301;
-- COMMIT;
-- ============================================================
