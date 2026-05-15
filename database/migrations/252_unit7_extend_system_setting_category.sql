-- Migration: 252_unit7_extend_system_setting_category.sql
-- Module: M19 — CR-K Risk Cases
-- CR: CR-K
-- Date: 2026-05-15
-- Description: Extend system_setting.category CHECK to add 10th value 'risk_case'.
--              Mirrors mig 168 (CR-F) pattern that added 'scoring' as the 9th value.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

ALTER TABLE system_setting DROP CONSTRAINT system_setting_category_check;
ALTER TABLE system_setting ADD CONSTRAINT system_setting_category_check
  CHECK (category IN ('general','uae_pass','branding','security','email','calendar','audit_retention','ai','scoring','risk_case'));

COMMENT ON COLUMN system_setting.category IS
  'Logical group: general | uae_pass | branding | security | email | calendar | audit_retention | ai | scoring | risk_case (Unit-7 mig 252 added risk_case for CR-K matrices).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (252, '252_unit7_extend_system_setting_category', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- ALTER TABLE system_setting DROP CONSTRAINT system_setting_category_check;
-- ALTER TABLE system_setting ADD CONSTRAINT system_setting_category_check
--   CHECK (category IN ('general','uae_pass','branding','security','email','calendar','audit_retention','ai','scoring'));
-- DELETE FROM schema_migrations WHERE version = 252;
-- ============================================================
