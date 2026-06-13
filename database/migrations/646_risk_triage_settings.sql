-- ============================================================================
-- Migration 646 — Phase D: three configurable Risk Triage SLA settings
-- ============================================================================
-- system_setting is the workspace-level catalog Platform Admin edits at
-- /app/admin/config. Today it carries categories like general / email /
-- security / risk_case. Phase D adds a new `risk_triage` category with
-- three knobs driving the badge colors on the Risk Triage queue and the
-- daily auto-escalation cron:
--
--   tier2AmberHours        — age (h) at which a Tier-2 case turns amber
--   tier2RedHours          — age (h) at which a Tier-2 case turns red
--   tier2AutoEscalateDays  — age (days) at which the cron emits an alert
--
-- Idempotent. Values are JSONB integers so the existing /admin/config UI
-- renders them as numeric inputs without any extra wiring.
-- ============================================================================

-- The category column has a whitelist CHECK constraint. Extend it with
-- 'risk_triage' before inserting the new rows.
ALTER TABLE system_setting DROP CONSTRAINT IF EXISTS system_setting_category_check;
ALTER TABLE system_setting
  ADD CONSTRAINT system_setting_category_check
  CHECK (category IN (
    'general', 'uae_pass', 'branding', 'security', 'email', 'calendar',
    'audit_retention', 'ai', 'scoring', 'risk_case', 'regulatory',
    'financial', 'migration', 'risk_triage'
  ));

INSERT INTO system_setting (key, value, description, category, is_secret, is_active)
VALUES
  ('tier2AmberHours',
   to_jsonb(72),
   'Age in hours at which a Tier-2 risk-triage case turns amber on the Risk Triage queue.',
   'risk_triage', false, true),
  ('tier2RedHours',
   to_jsonb(168),
   'Age in hours at which a Tier-2 risk-triage case turns red on the Risk Triage queue. Defaults to 7 days.',
   'risk_triage', false, true),
  ('tier2AutoEscalateDays',
   to_jsonb(14),
   'Age in days at which the daily auto-escalation cron records a tier2_auto_escalated event on a Tier-2 case + alerts platform_admin / executive.',
   'risk_triage', false, true)
ON CONFLICT (key) DO NOTHING;

-- Sanity assertion.
DO $$
DECLARE
  v_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM system_setting
   WHERE category = 'risk_triage' AND is_active = true;
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'mig 646: expected 3 risk_triage settings (got %)', v_count;
  END IF;
END $$;
