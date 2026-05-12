-- ============================================================
-- Migration 135 — CRD0 extend_system_setting_category
-- ============================================================
-- Module:      M11 — Document Ingestion Pipeline (CR-D0)
-- Description: DROP + ADD CHECK on system_setting.category widening from
--              7 categories → 8 (adds 'ai'). OPEN-DECISION-K = widen.
--              The 7 pre-existing categories from CR-C 126 are preserved verbatim:
--                general / uae_pass / branding / security / email / calendar /
--                audit_retention.
--              'ai' is added as the 8th — forward-compatible (CR-D / CR-E / CR-F
--              AI knobs will also go here).
-- Ordering invariant: MUST run BEFORE migration 136 which INSERTs
--              system_setting rows with category='ai'.
-- SOT: §9 CR-D0, §4.11, OPEN-DECISION-K / N20.
-- ============================================================

BEGIN;

-- Drop the existing 7-category CHECK constraint from CR-C 126
ALTER TABLE system_setting DROP CONSTRAINT IF EXISTS system_setting_category_check;

-- Re-add with 8 categories (adds 'ai' as the 8th value)
ALTER TABLE system_setting ADD CONSTRAINT system_setting_category_check
  CHECK (category IN (
    'general',
    'uae_pass',
    'branding',
    'security',
    'email',
    'calendar',
    'audit_retention',
    'ai'
  ));

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (135, 'crd0_extend_system_setting_category', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- -- First, remove any 'ai' category rows inserted by 136 (must cascade before reverting CHECK).
-- -- DELETE FROM system_setting WHERE category = 'ai';
-- ALTER TABLE system_setting DROP CONSTRAINT IF EXISTS system_setting_category_check;
-- ALTER TABLE system_setting ADD CONSTRAINT system_setting_category_check
--   CHECK (category IN (
--     'general', 'uae_pass', 'branding', 'security', 'email', 'calendar', 'audit_retention'
--   ));
-- DELETE FROM schema_migrations WHERE version = 135;
-- COMMIT;
-- ROLLBACK END
