-- Migration: 260_crl_create_report_template.sql
-- Module: M20 — CR-L Reports & Briefings
-- CR: CR-L
-- Date: 2026-05-15
-- Description: Create report_template master + indexes + FORCE RLS + 3 policies
--              + default fn_audit_trigger (Strategy B).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE report_template (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  template_id          TEXT NOT NULL CHECK (length(trim(template_id)) > 0),
  display_name_en      TEXT NOT NULL CHECK (length(trim(display_name_en)) > 0),
  display_name_ar      TEXT NULL,
  description          TEXT NULL,
  report_kind          TEXT NOT NULL CHECK (report_kind IN ('excel', 'pdf', 'both')),
  data_source          TEXT NOT NULL CHECK (length(trim(data_source)) > 0),
  parameter_schema     JSONB NOT NULL DEFAULT '{}',
  assigned_roles       JSONB NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(assigned_roles) = 'array'),
  is_scheduled         BOOLEAN NOT NULL DEFAULT FALSE,
  schedule_cron        TEXT NULL,
  schedule_recipients  JSONB NULL CHECK (schedule_recipients IS NULL OR jsonb_typeof(schedule_recipients) = 'array'),
  last_run_at          TIMESTAMPTZ NULL,
  enabled              BOOLEAN NOT NULL DEFAULT TRUE,
  data_classification  TEXT NOT NULL DEFAULT 'internal' CHECK (data_classification IN ('public', 'internal', 'restricted', 'sensitive')),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by           BIGINT NULL REFERENCES "user"(id),
  updated_by           BIGINT NULL REFERENCES "user"(id),
  is_active            BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT report_template_schedule_cron_required CHECK (
    (is_scheduled = FALSE) OR (is_scheduled = TRUE AND schedule_cron IS NOT NULL AND length(trim(schedule_cron)) > 0)
  )
);

CREATE UNIQUE INDEX uq_report_template_tenant_template_id ON report_template(tenant_id, template_id);
CREATE INDEX idx_report_template_tenant_id ON report_template(tenant_id);
CREATE INDEX idx_report_template_scheduled ON report_template(is_scheduled, enabled) WHERE is_scheduled = TRUE AND enabled = TRUE AND is_active = TRUE;
CREATE INDEX idx_report_template_active ON report_template(id) WHERE is_active = TRUE;

COMMENT ON TABLE report_template IS 'Report template definitions per tenant. Drives /app/reports library. data_source slug maps to fn_report_data_<slug>. Soft delete via is_active=false; report_run history preserved.';
COMMENT ON COLUMN report_template.data_source IS 'Stable slug — validated by fn_report_template_create/_update via pg_proc EXISTS check against fn_report_data_<data_source>.';
COMMENT ON COLUMN report_template.assigned_roles IS 'JSONB array of role names. Users whose roles intersect with this array can run the report.';
COMMENT ON COLUMN report_template.schedule_cron IS '5-field cron expression in UTC. BE+FE validates with node-cron parser; DB enforces NOT NULL when is_scheduled=TRUE via CHECK.';

ALTER TABLE report_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE report_template FORCE ROW LEVEL SECURITY;

CREATE POLICY report_template_tenant_select ON report_template
  FOR SELECT
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID);

CREATE POLICY report_template_tenant_modify ON report_template
  FOR ALL
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID);

CREATE POLICY report_template_deny_direct_delete ON report_template
  AS RESTRICTIVE
  FOR DELETE
  USING (FALSE);

CREATE TRIGGER audit_report_template_changes
  AFTER INSERT OR UPDATE OR DELETE ON report_template
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (260, '260_crl_create_report_template', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP TABLE IF EXISTS report_template CASCADE;
-- DELETE FROM schema_migrations WHERE version = 260;
-- ============================================================
