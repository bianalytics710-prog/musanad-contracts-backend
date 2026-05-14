-- MIGRATION: 206_crh_create_advisory_dispatch_log.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: CREATE advisory_dispatch_log append-only table + 3 indexes + 4 RLS policies (FORCE RLS + RESTRICTIVE deny-UPDATE + deny-DELETE).
--              Strategy A in-fn audit inserts via fn_audit_log_record_v2 (no default trigger — S2-28).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE IF NOT EXISTS advisory_dispatch_log (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  advisory_draft_id        BIGINT NOT NULL REFERENCES advisory_draft(id) ON DELETE RESTRICT,
  channel                  TEXT NOT NULL
    CHECK (channel IN ('email','teams_capture','slack_capture')),
  recipient_address        TEXT,
  rendered_payload         JSONB NOT NULL,
  status                   TEXT NOT NULL
    CHECK (status IN ('sent','failed','captured_only','pending_retry','final_failed')),
  delivery_attempted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  delivery_completed_at    TIMESTAMPTZ,
  error_message            TEXT,
  retry_count              INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  data_classification      TEXT NOT NULL DEFAULT 'sensitive'
    CHECK (data_classification IN ('demo','pilot','production','sensitive')),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE advisory_dispatch_log IS
  'M16/CR-H. Append-only per-channel dispatch audit for advisory_draft. No UPDATE/DELETE — RESTRICTIVE RLS policies enforce immutability. Strategy A in-fn audit via fn_audit_log_record_v2 inside fn_advisory_dispatch.';

CREATE INDEX IF NOT EXISTS idx_advisory_dispatch_log_draft
  ON advisory_dispatch_log(advisory_draft_id, delivery_attempted_at DESC);

CREATE INDEX IF NOT EXISTS idx_advisory_dispatch_log_tenant_status
  ON advisory_dispatch_log(tenant_id, status, delivery_attempted_at DESC);

CREATE INDEX IF NOT EXISTS idx_advisory_dispatch_log_channel
  ON advisory_dispatch_log(tenant_id, channel, delivery_attempted_at DESC);

-- RLS (append-only — RESTRICTIVE deny-UPDATE + deny-DELETE)
ALTER TABLE advisory_dispatch_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE advisory_dispatch_log FORCE ROW LEVEL SECURITY;

CREATE POLICY advisory_dispatch_log_tenant_select ON advisory_dispatch_log
  FOR SELECT USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

CREATE POLICY advisory_dispatch_log_tenant_insert ON advisory_dispatch_log
  FOR INSERT WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

CREATE POLICY advisory_dispatch_log_deny_direct_update ON advisory_dispatch_log
  AS RESTRICTIVE FOR UPDATE USING (FALSE);

CREATE POLICY advisory_dispatch_log_deny_direct_delete ON advisory_dispatch_log
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- NO default audit trigger — Strategy A (in-fn audit inserts via fn_advisory_dispatch / fn_audit_log_record_v2)

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (206, '206_crh_create_advisory_dispatch_log', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP POLICY IF EXISTS advisory_dispatch_log_deny_direct_delete ON advisory_dispatch_log;
-- DROP POLICY IF EXISTS advisory_dispatch_log_deny_direct_update ON advisory_dispatch_log;
-- DROP POLICY IF EXISTS advisory_dispatch_log_tenant_insert ON advisory_dispatch_log;
-- DROP POLICY IF EXISTS advisory_dispatch_log_tenant_select ON advisory_dispatch_log;
-- DROP INDEX IF EXISTS idx_advisory_dispatch_log_channel;
-- DROP INDEX IF EXISTS idx_advisory_dispatch_log_tenant_status;
-- DROP INDEX IF EXISTS idx_advisory_dispatch_log_draft;
-- DROP TABLE IF EXISTS advisory_dispatch_log;
-- DELETE FROM schema_migrations WHERE version = 206;
-- ============================================================
