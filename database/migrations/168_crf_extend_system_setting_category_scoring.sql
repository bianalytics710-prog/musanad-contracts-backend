-- Migration: 168_crf_extend_system_setting_category_scoring.sql
-- Module: M14 — CR-F (5-Dim Risk Scoring + MaR + AVaR)
-- Description: EXTEND system_setting_category_check 8 → 9 categories (add 'scoring').
--   UPSERT 3 net-new scoring config rows: scoring.weights / scoring.exposure_fraction_defaults /
--   scoring.impact_multipliers per SOT §14.1 (ADNOC default pack).
--   Pattern mirrors migration 135 byte-for-byte.
--   S2-22: column existence verified — system_setting columns: key, value, description, category, is_secret.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Widen category CHECK from 8 → 9 values (add 'scoring')
-- Pattern mirrors 135: DROP CONSTRAINT IF EXISTS → ADD CONSTRAINT
ALTER TABLE system_setting DROP CONSTRAINT IF EXISTS system_setting_category_check;

ALTER TABLE system_setting ADD CONSTRAINT system_setting_category_check
  CHECK (category IN (
    'general',
    'uae_pass',
    'branding',
    'security',
    'email',
    'calendar',
    'audit_retention',
    'ai',
    'scoring'    -- 9th category — CR-F
  ));

-- 3 net-new scoring config rows (ADNOC default pack per SOT §14.1)
-- Idempotent via ON CONFLICT (key) DO NOTHING
INSERT INTO system_setting (key, value, description, category, is_secret)
VALUES
  (
    'scoring.weights',
    '{
      "legal": 0.20,
      "financial": 0.30,
      "operational": 0.20,
      "reputational": 0.10,
      "compliance": 0.20,
      "version": "1"
    }'::jsonb,
    'ADNOC default 5-dim weights pack per SOT §14.1. Sum = 1.00 ± 0.001 invariant enforced by fn_scoring_weights_set.',
    'scoring',
    FALSE
  ),
  (
    'scoring.exposure_fraction_defaults',
    '{
      "supply": 0.20,
      "charter": 0.10,
      "epc": 0.15,
      "om_monthly": 0.05,
      "default": 0.10
    }'::jsonb,
    'Per-contract-type exposure fraction defaults. Lookup key = contract.contract_type (case-insensitive normalize); fallback "default" if unmapped. Per SOT §14.1.',
    'scoring',
    FALSE
  ),
  (
    'scoring.impact_multipliers',
    '{
      "single_source_dependency": 1.5,
      "critical_path_impact": 1.4,
      "regulatory_linkage": 1.3,
      "default": 1.0
    }'::jsonb,
    'Cascading-effect multipliers. Composed multiplicatively when multiple flags qualify. Per SOT §14.1.',
    'scoring',
    FALSE
  )
ON CONFLICT (key) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (168, '168_crf_extend_system_setting_category_scoring', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 168;
-- DELETE FROM system_setting WHERE key IN ('scoring.weights','scoring.exposure_fraction_defaults','scoring.impact_multipliers');
-- ALTER TABLE system_setting DROP CONSTRAINT IF EXISTS system_setting_category_check;
-- ALTER TABLE system_setting ADD CONSTRAINT system_setting_category_check
--   CHECK (category IN ('general','uae_pass','branding','security','email','calendar','audit_retention','ai'));
-- COMMIT;
-- ============================================================
