-- Migration: 255_crk_create_risk_case_attachment.sql
-- Module: M19 — CR-K Risk Cases
-- CR: CR-K
-- Date: 2026-05-15
-- Description: Create risk_case_attachment + FORCE RLS + 3 policies + default audit trigger.
--              Mirrors contract_attachment pattern. 50MB cap. Soft delete only.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE risk_case_attachment (
  id            BIGSERIAL PRIMARY KEY,
  tenant_id     UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  risk_case_id  BIGINT NOT NULL REFERENCES risk_case(id) ON DELETE RESTRICT,
  file_uri      TEXT NOT NULL,
  file_name     TEXT NOT NULL,
  file_mime     TEXT NOT NULL,
  file_bytes    BIGINT NOT NULL CHECK (file_bytes > 0 AND file_bytes <= 52428800),
  uploaded_by   BIGINT NOT NULL REFERENCES "user"(id),
  uploaded_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_risk_case_attachment_tenant_id ON risk_case_attachment(tenant_id);
CREATE INDEX idx_risk_case_attachment_case ON risk_case_attachment(risk_case_id) WHERE is_active = TRUE;
CREATE INDEX idx_risk_case_attachment_uploaded_by ON risk_case_attachment(uploaded_by);
CREATE INDEX idx_risk_case_attachment_active ON risk_case_attachment(id) WHERE is_active = TRUE;

COMMENT ON TABLE risk_case_attachment IS 'Evidence attachments for risk cases. Mirrors contract_attachment pattern; file bodies live in Supabase Storage. 50MB cap. Soft delete via is_active=false; no hard delete (forensic).';
COMMENT ON COLUMN risk_case_attachment.file_uri IS 'Supabase Storage path. Sensitive — redacted in audit_log + Pino. BE mints signed URL (TTL 60s) for download.';

ALTER TABLE risk_case_attachment ENABLE ROW LEVEL SECURITY;
ALTER TABLE risk_case_attachment FORCE ROW LEVEL SECURITY;

CREATE POLICY risk_case_attachment_tenant_select ON risk_case_attachment
  FOR SELECT
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID);

CREATE POLICY risk_case_attachment_tenant_modify ON risk_case_attachment
  FOR ALL
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::UUID);

CREATE POLICY risk_case_attachment_deny_direct_delete ON risk_case_attachment
  AS RESTRICTIVE
  FOR DELETE
  USING (FALSE);

CREATE TRIGGER audit_risk_case_attachment_changes
  AFTER INSERT OR UPDATE OR DELETE ON risk_case_attachment
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (255, '255_crk_create_risk_case_attachment', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP TABLE IF EXISTS risk_case_attachment CASCADE;
-- DELETE FROM schema_migrations WHERE version = 255;
-- ============================================================
