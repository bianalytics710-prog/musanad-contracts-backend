-- ============================================================
-- Migration 126 — CRC extend_system_setting
-- ============================================================
-- Module:      M10 — CR-C
-- Description: Widen system_setting.category CHECK constraint from 3 categories
--              (general/uae_pass/branding) to 7 (adds security/email/calendar/
--              audit_retention). UPSERT 21 net-new keys (email.* 11 + security.* 5
--              + calendar.* 4 + audit.retention_days 1). Branding additions are
--              seeded by 131 (separation kept per Agent 4 plan).
-- Decisions:   Idempotent ON CONFLICT (key) DO NOTHING. Wrapping the constraint
--              swap in a single TX (the runner gives us one) keeps the table
--              consistent if any seed row would otherwise violate.
-- ============================================================

BEGIN;

-- 1. Widen category CHECK constraint (drop + re-add atomically)
ALTER TABLE system_setting DROP CONSTRAINT IF EXISTS system_setting_category_check;
ALTER TABLE system_setting ADD  CONSTRAINT system_setting_category_check
  CHECK (category IN (
    'general',
    'uae_pass',
    'branding',
    'security',
    'email',
    'calendar',
    'audit_retention'
  ));

-- 2. UPSERT 21 net-new keys (idempotent)
--    Email category (11 keys; auth_pass_ref is_secret=true)
INSERT INTO system_setting (key, value, description, category, is_secret) VALUES
  ('email.smtp.host',          '""'::jsonb,             'SMTP server hostname.',                                                       'email',           FALSE),
  ('email.smtp.port',          '587'::jsonb,            'SMTP server port (1..65535).',                                                'email',           FALSE),
  ('email.smtp.encryption',    '"tls"'::jsonb,          'SMTP encryption: none/tls/ssl/starttls.',                                     'email',           FALSE),
  ('email.smtp.auth_user',     '""'::jsonb,             'SMTP auth username.',                                                         'email',           FALSE),
  ('email.smtp.auth_pass_ref', '""'::jsonb,             'KMS-style env-var indirection for SMTP password (e.g. env:SMTP_PASSWORD).',   'email',           TRUE),
  ('email.from_address',       '""'::jsonb,             'From address for outgoing notifications.',                                    'email',           FALSE),
  ('email.from_name_en',       '""'::jsonb,             'From display name (English).',                                                'email',           FALSE),
  ('email.from_name_ar',       '""'::jsonb,             'From display name (Arabic).',                                                 'email',           FALSE),
  ('email.reply_to',           '""'::jsonb,             'Reply-to address.',                                                           'email',           FALSE),
  ('email.daily_send_limit',   '5000'::jsonb,           'Max emails per day (1..1000000).',                                            'email',           FALSE),
  ('email.enabled',            'false'::jsonb,          'Master switch: when false, no SMTP send is attempted.',                       'email',           FALSE),
  -- Security category (5 keys)
  ('security.session_timeout_min',            '60'::jsonb,    'Session timeout in minutes (1..1440).',     'security',        FALSE),
  ('security.password_policy_min_length',     '12'::jsonb,    'Minimum password length (8..128).',         'security',        FALSE),
  ('security.password_policy_require_special','true'::jsonb,  'Require special character in passwords.',   'security',        FALSE),
  ('security.mfa_required',                   'false'::jsonb, 'MFA required for all users.',               'security',        FALSE),
  ('security.ip_allowlist',                   '[]'::jsonb,    'Optional IP allowlist (CIDR strings).',     'security',        FALSE),
  -- Calendar category (4 keys)
  ('calendar.weekend_days',        '["Friday","Saturday"]'::jsonb, 'Workweek weekend days.',                                   'calendar',        FALSE),
  ('calendar.working_hours_start', '"08:00"'::jsonb,               'Start of working day (HH:MM).',                            'calendar',        FALSE),
  ('calendar.working_hours_end',   '"17:00"'::jsonb,               'End of working day (HH:MM).',                              'calendar',        FALSE),
  ('calendar.holidays',            '[]'::jsonb,                    'List of holiday dates (YYYY-MM-DD strings).',              'calendar',        FALSE),
  -- Audit retention (1 key)
  ('audit.retention_days', '365'::jsonb, 'Audit log retention in days (default 365 demo / 2555 = 7 years pilot).', 'audit_retention', FALSE)
ON CONFLICT (key) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (126, 'crc_extend_system_setting', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DELETE FROM system_setting WHERE key IN (
--   'email.smtp.host','email.smtp.port','email.smtp.encryption','email.smtp.auth_user','email.smtp.auth_pass_ref',
--   'email.from_address','email.from_name_en','email.from_name_ar','email.reply_to','email.daily_send_limit','email.enabled',
--   'security.session_timeout_min','security.password_policy_min_length','security.password_policy_require_special',
--   'security.mfa_required','security.ip_allowlist',
--   'calendar.weekend_days','calendar.working_hours_start','calendar.working_hours_end','calendar.holidays',
--   'audit.retention_days'
-- );
-- ALTER TABLE system_setting DROP CONSTRAINT IF EXISTS system_setting_category_check;
-- ALTER TABLE system_setting ADD  CONSTRAINT system_setting_category_check
--   CHECK (category IN ('general','uae_pass','branding'));
-- DELETE FROM schema_migrations WHERE version = 126;
-- COMMIT;
-- ROLLBACK END
