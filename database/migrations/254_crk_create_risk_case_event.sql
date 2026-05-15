-- Migration: 254_crk_create_risk_case_event.sql
-- Module: M19 — CR-K Risk Cases
-- CR: CR-K
-- Date: 2026-05-15
-- Description: Create risk_case_event append-only timeline + FORCE RLS + 4 policies
--              (select, insert, deny_update, deny_delete). Strategy A — NO default
--              audit trigger; in-fn fn_audit_log_record_v2 calls in parent fn bodies.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE risk_case_event (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  risk_case_id  BIGINT NOT NULL REFERENCES risk_case(id) ON DELETE CASCADE,
  event_type    TEXT NOT NULL CHECK (event_type IN ('created', 'assigned', 'status_changed', 'comment_added', 'evidence_uploaded', 'escalated', 'accepted_risk', 'snoozed', 'closed', 'reopened')),
  actor_id      BIGINT NULL REFERENCES "user"(id),
  payload       JSONB NOT NULL DEFAULT '{}',
  occurred_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_risk_case_event_tenant_id ON risk_case_event(tenant_id);
CREATE INDEX idx_risk_case_event_case ON risk_case_event(risk_case_id, occurred_at);
CREATE INDEX idx_risk_case_event_actor_id ON risk_case_event(actor_id) WHERE actor_id IS NOT NULL;

COMMENT ON TABLE risk_case_event IS 'Append-only timeline of risk-case events. Strategy A audit (no default trigger; in-fn fn_audit_log_record_v2). RESTRICTIVE deny-UPDATE+DELETE policies enforce append-only at RLS layer.';
COMMENT ON COLUMN risk_case_event.payload IS 'Event-specific JSONB. Sensitive — redacted in audit_log + Pino via fn_audit_trigger redact-list field name match.';
COMMENT ON COLUMN risk_case_event.actor_id IS 'User id of actor; NULL for system-emitted events (cron escalation, auto-create). S2-20 sentinel coercion: BE passes NULLIF(actor_id, 0).';

ALTER TABLE risk_case_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE risk_case_event FORCE ROW LEVEL SECURITY;

CREATE POLICY risk_case_event_tenant_select ON risk_case_event
  FOR SELECT
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID);

CREATE POLICY risk_case_event_tenant_insert ON risk_case_event
  FOR INSERT
  WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID);

CREATE POLICY risk_case_event_deny_update ON risk_case_event
  AS RESTRICTIVE
  FOR UPDATE
  USING (FALSE)
  WITH CHECK (FALSE);

CREATE POLICY risk_case_event_deny_delete ON risk_case_event
  AS RESTRICTIVE
  FOR DELETE
  USING (FALSE);

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (254, '254_crk_create_risk_case_event', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP TABLE IF EXISTS risk_case_event CASCADE;
-- DELETE FROM schema_migrations WHERE version = 254;
-- ============================================================
