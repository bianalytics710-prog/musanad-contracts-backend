-- MIGRATION: 214_crh_backfill_notification_subscription_defaults.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: Pre-emptive backfill — insert notification_subscription rows for all active users.
--              HITL-Q6 default: advisory × email × priority_min='high' AND advisory × in_app × priority_min='medium'.
--              ON CONFLICT (tenant_id, user_id, notification_kind, channel) DO NOTHING — idempotent.
--              NOTE: user table has no tenant_id column — cross-join with tenant table.
--              Pattern mirrors M15/Unit-2B 14-grant backfill.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- advisory × email × priority_min='high' (HITL-Q6 default: opt-in to high+critical advisory emails)
INSERT INTO notification_subscription
  (tenant_id, user_id, notification_kind, channel, priority_min, enabled, created_at, updated_at, created_by, updated_by, is_active)
SELECT
  t.id AS tenant_id,
  u.id AS user_id,
  'advisory'::text AS notification_kind,
  'email'::text AS channel,
  'high'::text AS priority_min,
  TRUE AS enabled,
  NOW(), NOW(), NULL, NULL, TRUE
FROM "user" u
CROSS JOIN tenant t
WHERE u.is_active = TRUE
ON CONFLICT (tenant_id, user_id, notification_kind, channel) DO NOTHING;

-- advisory × in_app × priority_min='medium' (in-app less restrictive — HITL Q6 nuance)
INSERT INTO notification_subscription
  (tenant_id, user_id, notification_kind, channel, priority_min, enabled, created_at, updated_at, created_by, updated_by, is_active)
SELECT
  t.id AS tenant_id,
  u.id AS user_id,
  'advisory'::text AS notification_kind,
  'in_app'::text AS channel,
  'medium'::text AS priority_min,
  TRUE AS enabled,
  NOW(), NOW(), NULL, NULL, TRUE
FROM "user" u
CROSS JOIN tenant t
WHERE u.is_active = TRUE
ON CONFLICT (tenant_id, user_id, notification_kind, channel) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (214, '214_crh_backfill_notification_subscription_defaults', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM notification_subscription
-- WHERE created_by IS NULL
--   AND notification_kind = 'advisory'
--   AND channel IN ('email','in_app')
--   AND created_at >= '<deploy_window_start>'::timestamptz;
-- DELETE FROM schema_migrations WHERE version = 214;
-- ============================================================
