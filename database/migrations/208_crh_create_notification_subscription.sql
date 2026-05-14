-- MIGRATION: 208_crh_create_notification_subscription.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: CREATE notification_subscription table + UNIQUE constraint + 2 indexes + 3 RLS policies + audit trigger.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE IF NOT EXISTS notification_subscription (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  user_id                  BIGINT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  notification_kind        TEXT NOT NULL
    CHECK (notification_kind IN (
      'alert','advisory','approval_request','signature_request',
      'system','risk_case','report'
    )),
  channel                  TEXT NOT NULL
    CHECK (channel IN ('email','in_app','teams_capture','slack_capture')),
  priority_min             TEXT NOT NULL DEFAULT 'high'
    CHECK (priority_min IN ('low','medium','high','critical')),
  enabled                  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id),
  updated_by               BIGINT REFERENCES "user"(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT notification_subscription_uq
    UNIQUE (tenant_id, user_id, notification_kind, channel)
);

COMMENT ON TABLE notification_subscription IS
  'M16/CR-H. Per-user notification preference grid (7 kinds × 4 channels = 28 cells). Missing rows synthesised by fn_notification_subscription_list as enabled=true, priorityMin=high (HITL-Q6 default).';

CREATE INDEX IF NOT EXISTS idx_notification_subscription_user
  ON notification_subscription(tenant_id, user_id)
  WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_notification_subscription_lookup
  ON notification_subscription(tenant_id, user_id, notification_kind, channel)
  WHERE is_active = TRUE;

-- RLS (self-read/self-modify; admin override for read)
ALTER TABLE notification_subscription ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_subscription FORCE ROW LEVEL SECURITY;

CREATE POLICY notification_subscription_self_select ON notification_subscription
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
    AND (
      user_id = current_setting('app.current_user_id', true)::bigint
      OR EXISTS (
        SELECT 1 FROM "user" u
        JOIN role r ON r.id = u.role_id
        WHERE u.id = current_setting('app.current_user_id', true)::bigint
          AND r.name IN ('Super Admin', 'platform_admin')
      )
    )
  );

CREATE POLICY notification_subscription_self_modify ON notification_subscription
  FOR ALL USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
    AND user_id = current_setting('app.current_user_id', true)::bigint
  )
  WITH CHECK (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
    AND user_id = current_setting('app.current_user_id', true)::bigint
  );

-- Audit trigger (default — table has id BIGSERIAL PK per S2-28 strategy)
CREATE TRIGGER audit_notification_subscription_changes
  AFTER INSERT OR UPDATE OR DELETE ON notification_subscription
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (208, '208_crh_create_notification_subscription', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP TRIGGER IF EXISTS audit_notification_subscription_changes ON notification_subscription;
-- DROP POLICY IF EXISTS notification_subscription_self_modify ON notification_subscription;
-- DROP POLICY IF EXISTS notification_subscription_self_select ON notification_subscription;
-- DROP INDEX IF EXISTS idx_notification_subscription_lookup;
-- DROP INDEX IF EXISTS idx_notification_subscription_user;
-- DROP TABLE IF EXISTS notification_subscription;
-- DELETE FROM schema_migrations WHERE version = 208;
-- ============================================================
