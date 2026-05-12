-- Migration: 156_cre_system_setting_seed.sql
-- Module: M13 / CR-E — Correlation Rule Engine
-- Description: 2 UPSERT rows on system_setting (category='ai').
--   rule.eval_timeout_seconds + rule.hot_reload_lag_target_seconds.
--   system_setting.category 'ai' enum widened in M11 migration 135. No further CHECK widening required.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- NOTE (schema discovery): system_setting.value is JSONB (not TEXT). Numeric values stored as JSON numbers.
-- No is_editable column. is_secret column exists but defaults safely.
INSERT INTO system_setting (key, value, category, description, created_at, updated_at)
VALUES
  (
    'rule.eval_timeout_seconds',
    '5'::jsonb,
    'ai',
    'Per-rule wall-clock timeout (seconds) for the BE rule-evaluator service. HITL Q1 lock: 5 seconds. Rules exceeding this timeout do NOT fire; logged to correlation_evaluation_error. Increasing beyond 10s not recommended (1000sig x 50rules NFR). Requires BE service restart to take effect.',
    NOW(), NOW()
  ),
  (
    'rule.hot_reload_lag_target_seconds',
    '5'::jsonb,
    'ai',
    'Target latency from rule edit (fn_rule_create / fn_rule_update / fn_rule_delete) to in-memory cache invalidation in BE rule-cache.service.ts. HITL Q3 lock: < 5s. Achieved via PG NOTIFY correlation_rule_changed + 2s poller fallback per AC-S14-03.',
    NOW(), NOW()
  )
ON CONFLICT (key) DO UPDATE SET
  value       = EXCLUDED.value,
  category    = EXCLUDED.category,
  description = EXCLUDED.description,
  updated_at  = NOW();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (156, '156_cre_system_setting_seed', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 156;
-- DELETE FROM system_setting WHERE key IN ('rule.eval_timeout_seconds','rule.hot_reload_lag_target_seconds');
-- ============================================================
