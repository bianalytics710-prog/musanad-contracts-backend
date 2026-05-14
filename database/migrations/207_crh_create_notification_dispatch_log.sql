-- MIGRATION: 207_crh_create_notification_dispatch_log.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: CREATE notification_dispatch_log append-only universal table + 5 indexes + 4 RLS policies.
--              Strategy A in-fn audit. retry worker claim index on (status, next_retry_at).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE IF NOT EXISTS notification_dispatch_log (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  notification_template_id BIGINT REFERENCES notification_template(id) ON DELETE SET NULL,
  notification_kind        TEXT NOT NULL
    CHECK (notification_kind IN (
      'alert','advisory','approval_request','signature_request',
      'system','risk_case','report'
    )),
  priority                 TEXT NOT NULL DEFAULT 'medium'
    CHECK (priority IN ('low','medium','high','critical')),
  channel                  TEXT NOT NULL
    CHECK (channel IN ('email','in_app','teams_capture','slack_capture')),
  recipient_user_id        BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  recipient_address        TEXT,
  subject                  TEXT,
  body_rendered            TEXT NOT NULL,
  context_payload          JSONB NOT NULL DEFAULT '{}'::jsonb,
  status                   TEXT NOT NULL
    CHECK (status IN ('sent','failed','captured_only','pending_retry','final_failed','suppressed_by_preference')),
  delivery_attempted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  delivery_completed_at    TIMESTAMPTZ,
  error_message            TEXT,
  retry_count              INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0 AND retry_count <= 5),
  next_retry_at            TIMESTAMPTZ,
  advisory_draft_id        BIGINT REFERENCES advisory_draft(id) ON DELETE SET NULL,
  data_classification      TEXT NOT NULL DEFAULT 'sensitive'
    CHECK (data_classification IN ('demo','pilot','production','sensitive')),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT notification_dispatch_log_recipient_present
    CHECK (recipient_user_id IS NOT NULL OR recipient_address IS NOT NULL)
);

COMMENT ON TABLE notification_dispatch_log IS
  'M16/CR-H. Universal notification dispatch log — one row per delivery attempt per channel per recipient. Append-only; retry-worker updates status via fn_notification_dispatch_update_retry_outcome (DEFINER). Strategy A in-fn audit.';

-- Worker claim index: WHERE status=''pending_retry'' AND next_retry_at <= NOW() ORDER BY next_retry_at ASC FOR UPDATE SKIP LOCKED
CREATE INDEX IF NOT EXISTS idx_notification_dispatch_log_retry_due
  ON notification_dispatch_log(next_retry_at ASC)
  WHERE status = 'pending_retry' AND next_retry_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notification_dispatch_log_tenant_attempted
  ON notification_dispatch_log(tenant_id, delivery_attempted_at DESC);

CREATE INDEX IF NOT EXISTS idx_notification_dispatch_log_recipient
  ON notification_dispatch_log(tenant_id, recipient_user_id, delivery_attempted_at DESC)
  WHERE recipient_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notification_dispatch_log_advisory
  ON notification_dispatch_log(advisory_draft_id)
  WHERE advisory_draft_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_notification_dispatch_log_status_kind
  ON notification_dispatch_log(tenant_id, status, notification_kind, delivery_attempted_at DESC);

-- RLS (append-only — RESTRICTIVE deny-UPDATE + deny-DELETE)
ALTER TABLE notification_dispatch_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_dispatch_log FORCE ROW LEVEL SECURITY;

CREATE POLICY notification_dispatch_log_tenant_select ON notification_dispatch_log
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
    AND (
      recipient_user_id = current_setting('app.current_user_id', true)::bigint
      OR EXISTS (
        SELECT 1 FROM "user" u
        JOIN role r ON r.id = u.role_id
        WHERE u.id = current_setting('app.current_user_id', true)::bigint
          AND r.name IN ('Super Admin', 'platform_admin')
      )
    )
  );

CREATE POLICY notification_dispatch_log_tenant_insert ON notification_dispatch_log
  FOR INSERT WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

CREATE POLICY notification_dispatch_log_deny_direct_update ON notification_dispatch_log
  AS RESTRICTIVE FOR UPDATE USING (FALSE);

CREATE POLICY notification_dispatch_log_deny_direct_delete ON notification_dispatch_log
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- NO default audit trigger — Strategy A (in-fn audit via fn_notification_send + fn_notification_dispatch_update_retry_outcome)

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (207, '207_crh_create_notification_dispatch_log', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP POLICY IF EXISTS notification_dispatch_log_deny_direct_delete ON notification_dispatch_log;
-- DROP POLICY IF EXISTS notification_dispatch_log_deny_direct_update ON notification_dispatch_log;
-- DROP POLICY IF EXISTS notification_dispatch_log_tenant_insert ON notification_dispatch_log;
-- DROP POLICY IF EXISTS notification_dispatch_log_tenant_select ON notification_dispatch_log;
-- DROP INDEX IF EXISTS idx_notification_dispatch_log_status_kind;
-- DROP INDEX IF EXISTS idx_notification_dispatch_log_advisory;
-- DROP INDEX IF EXISTS idx_notification_dispatch_log_recipient;
-- DROP INDEX IF EXISTS idx_notification_dispatch_log_tenant_attempted;
-- DROP INDEX IF EXISTS idx_notification_dispatch_log_retry_due;
-- DROP TABLE IF EXISTS notification_dispatch_log;
-- DELETE FROM schema_migrations WHERE version = 207;
-- ============================================================
