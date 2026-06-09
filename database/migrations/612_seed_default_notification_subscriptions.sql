-- Migration: 612_seed_default_notification_subscriptions.sql
-- Module: Default in-app notification subscriptions per kind
-- Date: 2026-06-09
--
-- Smoke test of mig 611 wrote a notification_dispatch_log row but with
-- status='suppressed_by_preference'. Root cause: fn_notification_send's
-- subscription gate (lines 89..105) reads from notification_subscription
-- per (user_id, notification_kind, channel). Only 'advisory' kind has
-- subscription rows seeded today. Every other kind — approval_request,
-- alert, signature_request, system, risk_case, report — has NO rows,
-- so every recipient gets suppressed at the gate.
--
-- This migration backfills opt-in subscriptions per active user for the
-- 6 missing kinds × in_app channel × priority_min='low'. Users can
-- still tighten their preferences via /app/profile/notification-
-- preferences (mig 215 surface). What we're seeding is the "sensible
-- default" so the system actually delivers in-app notifications until
-- the user opts out. Idempotent — ON CONFLICT DO NOTHING.
--
-- Why low priority_min: the dispatcher passes priority='high' for
-- request_resubmission / reject and 'normal' for approve. Both pass
-- the 'low' threshold. Conservative — users opt down, not up.

BEGIN;

INSERT INTO notification_subscription (
  tenant_id, user_id, notification_kind, channel, priority_min,
  enabled, created_at, updated_at, is_active
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid AS tenant_id,
  u.id AS user_id,
  kind AS notification_kind,
  'in_app' AS channel,
  'low' AS priority_min,
  TRUE AS enabled,
  CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, TRUE
FROM "user" u
CROSS JOIN (VALUES
  ('approval_request'),
  ('signature_request'),
  ('alert'),
  ('system'),
  ('risk_case'),
  ('report')
) AS kinds(kind)
WHERE u.is_active = TRUE
ON CONFLICT DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (612, '612_seed_default_notification_subscriptions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
