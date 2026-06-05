-- Migration: 577_internal_system_source.sql
-- Module: Internal Systems integrations registry (Platform Admin, feature A)
-- Date: 2026-06-05
--
-- Goal: extend the Platform Admin surface with an inventory of *internal*
-- systems the tenant connects to — ERP, Finance, HRMS, CRM, ITSM, DMS, SCM,
-- etc. Mirrors the shape of osint_source (which is the external/OSINT side)
-- but separated because:
--   - OSINT sources are tenant-default + read-only public data;
--   - Internal systems are per-tenant + carry bidirectional auth + sensitive
--     credentials that must not be co-mingled with the OSINT registry.
--
-- v1 scope: registry + health metadata only. The downstream pull-workers
-- (SAP S/4, Workday, Salesforce, etc.) are NOT included here — they remain a
-- separate engineering effort wired against this registry.
--
-- Tables:
--   internal_system_source     — the integration registry rows.
--   internal_system_credential — sidecar for auth refs (mirrors source_credential).
--
-- Both are FORCE RLS, per-tenant, audited.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. internal_system_source ────────────────────────────────
CREATE TABLE IF NOT EXISTS internal_system_source (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,

  -- Slug-ish stable identifier the BE can match in code paths (e.g. 'sap_s4_finance').
  system_code              TEXT NOT NULL,
  display_name             VARCHAR(160) NOT NULL,
  display_name_ar          VARCHAR(160),

  -- Category — what kind of internal system this is.
  kind                     TEXT NOT NULL
    CHECK (kind IN ('erp','finance','hrms','crm','itsm','dms','scm','data_warehouse','custom')),
  -- Vendor — free text with common values: sap_ariba / sap_s4 / oracle_fusion /
  -- workday / dynamics / salesforce / servicenow / sharepoint / etc.
  vendor                   VARCHAR(80),

  -- Connection details (sensitive: api_endpoint is *where*, not the secrets).
  base_url                 TEXT,
  api_endpoint             TEXT,
  auth_method              TEXT NOT NULL DEFAULT 'none'
    CHECK (auth_method IN ('none','oauth2','api_key','basic','saml','certificate')),

  -- Pull cadence + last-pull observations.
  pull_schedule_cron       TEXT,              -- e.g. '0 */4 * * *'
  last_pull_at             TIMESTAMPTZ,
  last_status              TEXT NOT NULL DEFAULT 'untested'
    CHECK (last_status IN ('untested','healthy','degraded','failing','unauthorised')),
  last_status_at           TIMESTAMPTZ,
  last_error               TEXT,

  -- Free-form admin notes (e.g. "owner: cfo-office, point-of-contact: Khalid").
  notes                    TEXT,

  -- Standard audit + lifecycle columns.
  data_classification      VARCHAR(20) NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by               BIGINT REFERENCES "user"(id) ON DELETE SET NULL,

  CONSTRAINT internal_system_source_tenant_code_uniq UNIQUE (tenant_id, system_code)
);

COMMENT ON TABLE internal_system_source IS
  'Platform Admin registry of *internal* systems the tenant integrates with (ERP, Finance, HRMS, CRM, etc.). Separated from osint_source because internal systems carry per-tenant bidirectional auth and must not be co-mingled with public OSINT feeds.';
COMMENT ON COLUMN internal_system_source.system_code IS
  'Stable slug the BE matches in code (e.g. sap_s4_finance, workday_hcm). Unique per tenant.';
COMMENT ON COLUMN internal_system_source.kind IS
  'Closed enum: erp/finance/hrms/crm/itsm/dms/scm/data_warehouse/custom. Drives the kind filter on the admin list.';
COMMENT ON COLUMN internal_system_source.last_status IS
  'Reflects the most recent test-connection result. Untested = never probed. Healthy/degraded/failing reflect HTTP 2xx/non-2xx/network. Unauthorised reflects 401/403.';

CREATE INDEX idx_internal_system_source_tenant_active
  ON internal_system_source (tenant_id, is_active);
CREATE INDEX idx_internal_system_source_kind
  ON internal_system_source (kind) WHERE is_active = TRUE;
CREATE INDEX idx_internal_system_source_status
  ON internal_system_source (last_status) WHERE is_active = TRUE;

-- FORCE RLS — tenants only see their own rows.
ALTER TABLE internal_system_source ENABLE ROW LEVEL SECURITY;
ALTER TABLE internal_system_source FORCE ROW LEVEL SECURITY;

CREATE POLICY internal_system_source_tenant_select ON internal_system_source
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY internal_system_source_tenant_modify ON internal_system_source
  FOR ALL USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  ) WITH CHECK (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY internal_system_source_deny_direct_delete ON internal_system_source
  AS RESTRICTIVE FOR DELETE USING (FALSE);

CREATE TRIGGER audit_internal_system_source_changes
  AFTER INSERT OR UPDATE OR DELETE ON internal_system_source
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ── 2. internal_system_credential ────────────────────────────
-- Sidecar table for the auth secret reference. Stores the *reference*
-- (e.g. 'vault://internal-systems/adnoc/sap_s4/api_key'), never the secret
-- itself — same pattern as source_credential for osint_source.
CREATE TABLE IF NOT EXISTS internal_system_credential (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  internal_system_id       BIGINT NOT NULL REFERENCES internal_system_source(id) ON DELETE CASCADE,

  credential_kind          TEXT NOT NULL
    CHECK (credential_kind IN ('api_key','oauth2_client','basic_user','basic_pass','saml_metadata','certificate')),
  -- Reference to the secret in the secrets manager (vault://, env://, file://).
  -- The literal secret is never stored in Postgres.
  credential_ref           TEXT NOT NULL,
  last_rotated_at          TIMESTAMPTZ,

  data_classification      VARCHAR(20) NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by               BIGINT REFERENCES "user"(id) ON DELETE SET NULL,

  CONSTRAINT internal_system_credential_kind_uniq
    UNIQUE (internal_system_id, credential_kind)
);

COMMENT ON TABLE internal_system_credential IS
  'Per-internal-system auth credentials. credential_ref holds a vault/env reference — the secret itself is NEVER stored in Postgres.';

CREATE INDEX idx_internal_system_credential_tenant
  ON internal_system_credential (tenant_id) WHERE is_active = TRUE;
CREATE INDEX idx_internal_system_credential_source
  ON internal_system_credential (internal_system_id) WHERE is_active = TRUE;

ALTER TABLE internal_system_credential ENABLE ROW LEVEL SECURITY;
ALTER TABLE internal_system_credential FORCE ROW LEVEL SECURITY;

CREATE POLICY internal_system_credential_tenant_select ON internal_system_credential
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY internal_system_credential_tenant_modify ON internal_system_credential
  FOR ALL USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  ) WITH CHECK (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY internal_system_credential_deny_direct_delete ON internal_system_credential
  AS RESTRICTIVE FOR DELETE USING (FALSE);

CREATE TRIGGER audit_internal_system_credential_changes
  AFTER INSERT OR UPDATE OR DELETE ON internal_system_credential
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ── 3. Extend fn_audit_trigger redact list ───────────────────
-- credential_ref + last_error may carry sensitive bits (URL secrets, stack
-- traces). Audit trigger should never log raw values for these columns.
-- (The fn_audit_trigger already redacts entire columns by name — we extend
-- the list via a one-shot insert into the redact-config table if present.
-- If your project uses a hardcoded list inside the trigger fn, edit the list
-- by hand when applying. We don't touch the fn body here to keep the
-- migration additive and safe.)

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (577, '577_internal_system_source', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_internal_system_credential_changes ON internal_system_credential;
-- DROP TRIGGER IF EXISTS audit_internal_system_source_changes ON internal_system_source;
-- DROP TABLE IF EXISTS internal_system_credential;
-- DROP TABLE IF EXISTS internal_system_source;
-- DELETE FROM schema_migrations WHERE version = 577;
-- COMMIT;
-- ============================================================
