-- Migration: 261_crl_create_report_run.sql
-- Module: M20 — CR-L Reports & Briefings
-- CR: CR-L
-- Date: 2026-05-15
-- Description: Create report_run append-only + FORCE RLS + 4 policies
--              (select, insert, deny_update, deny_delete). Strategy A audit
--              (no default trigger; in-fn fn_audit_log_record_v2 emits).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE report_run (
  id                    BIGSERIAL PRIMARY KEY,
  tenant_id             UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  report_template_id    BIGINT NOT NULL REFERENCES report_template(id) ON DELETE RESTRICT,
  triggered_by          TEXT NOT NULL CHECK (triggered_by IN ('manual', 'scheduled')),
  triggered_by_user_id  BIGINT NULL REFERENCES "user"(id),
  parameters            JSONB NOT NULL DEFAULT '{}',
  format                TEXT NOT NULL CHECK (format IN ('excel', 'pdf')),
  output_uri            TEXT NULL,
  output_size_bytes     BIGINT NULL CHECK (output_size_bytes IS NULL OR output_size_bytes >= 0),
  status                TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'generating', 'complete', 'failed')),
  error_message         TEXT NULL,
  started_at            TIMESTAMPTZ NULL,
  completed_at          TIMESTAMPTZ NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT report_run_manual_requires_user CHECK (
    (triggered_by = 'scheduled') OR (triggered_by = 'manual' AND triggered_by_user_id IS NOT NULL)
  )
);

CREATE INDEX idx_report_run_tenant_id ON report_run(tenant_id);
CREATE INDEX idx_report_run_template_id ON report_run(report_template_id);
CREATE INDEX idx_report_run_user_id ON report_run(triggered_by_user_id) WHERE triggered_by_user_id IS NOT NULL;
CREATE INDEX idx_report_run_pending ON report_run(id, report_template_id) WHERE status = 'pending';
CREATE INDEX idx_report_run_status ON report_run(status);

COMMENT ON TABLE report_run IS 'Append-only record of report generations. Strategy A audit (no default trigger; in-fn fn_audit_log_record_v2 at status transitions). RESTRICTIVE deny-UPDATE+DELETE policies enforce append-only at RLS layer; DEFINER fns bypass for lifecycle UPDATEs.';
COMMENT ON COLUMN report_run.parameters IS 'User-supplied parameters at trigger time. Sensitive — redacted in audit_log + Pino.';
COMMENT ON COLUMN report_run.output_uri IS 'Supabase Storage path. Sensitive — redacted. BE mints signed URL (TTL 60s) for download.';

ALTER TABLE report_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE report_run FORCE ROW LEVEL SECURITY;

CREATE POLICY report_run_tenant_select ON report_run
  FOR SELECT
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID);

CREATE POLICY report_run_tenant_insert ON report_run
  FOR INSERT
  WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID);

CREATE POLICY report_run_deny_update ON report_run
  AS RESTRICTIVE
  FOR UPDATE
  USING (FALSE)
  WITH CHECK (FALSE);

CREATE POLICY report_run_deny_delete ON report_run
  AS RESTRICTIVE
  FOR DELETE
  USING (FALSE);

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (261, '261_crl_create_report_run', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP TABLE IF EXISTS report_run CASCADE;
-- DELETE FROM schema_migrations WHERE version = 261;
-- ============================================================
