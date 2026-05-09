-- Migration: 103_m7_create_osint_source_credential.sql
-- Module: M7 — OSINT Source Framework + Adapter Protocol (CR-A)
-- Description: CREATE TABLE osint_source + source_credential. FORCE RLS + 4 + 2 policies.
--              Audit triggers wired to fn_audit_trigger (which already redacts credential_ref via 102).
--              Indexes per db-design.md §1.2 + §1.3.
-- Rollback: DROP triggers + policies + tables.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ----------------------------------------------------------------
-- 1. CREATE TABLE osint_source
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS osint_source (
  id                  BIGSERIAL    PRIMARY KEY,
  tenant_id           UUID         NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  source_id           TEXT         NOT NULL,
  display_name        VARCHAR(200) NOT NULL,
  display_name_ar     VARCHAR(200),
  kind                TEXT         NOT NULL CHECK (kind IN
                        ('sanctions','news','weather','commodity','fx','social','regulatory','internal')),
  url                 TEXT,
  format              TEXT         NOT NULL CHECK (format IN ('xml','csv','json','rss','api')),
  refresh_seconds     INTEGER      NOT NULL CHECK (refresh_seconds >= 60),
  source_reliability  NUMERIC(3,2) NOT NULL CHECK (source_reliability BETWEEN 0 AND 1),
  enabled             BOOLEAN      NOT NULL DEFAULT TRUE,
  rate_limit          JSONB,
  severity_mapping    JSONB,
  geography_filter    JSONB,
  licensing_note      TEXT,
  metadata            JSONB        NOT NULL DEFAULT '{}'::jsonb,
  data_classification VARCHAR(20)  NOT NULL DEFAULT 'demo'
                        CHECK (data_classification IN ('demo','pilot','production')),
  is_active           BOOLEAN      NOT NULL DEFAULT TRUE,

  created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,

  CONSTRAINT osint_source_tenant_source_id_key UNIQUE (tenant_id, source_id)
);

CREATE INDEX IF NOT EXISTS idx_osint_source_tenant_id      ON osint_source(tenant_id);
CREATE INDEX IF NOT EXISTS idx_osint_source_active         ON osint_source(id) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_osint_source_tenant_kind    ON osint_source(tenant_id, kind);
CREATE INDEX IF NOT EXISTS idx_osint_source_tenant_enabled ON osint_source(tenant_id, enabled, is_active);
CREATE INDEX IF NOT EXISTS idx_osint_source_created_by     ON osint_source(created_by);
CREATE INDEX IF NOT EXISTS idx_osint_source_updated_by     ON osint_source(updated_by);

COMMENT ON TABLE osint_source IS
  'M7 source registry — admin-managed catalogue of external feeds. One row per logical source. Tenant-scoped via app.current_tenant_id GUC. CHECK constraints retained on small fixed enums (kind, format, data_classification) per Architect protocol — these are not user-extensible dropdowns; lookup tables not warranted in CR-A.';
COMMENT ON COLUMN osint_source.source_id IS
  'Stable string handle, e.g. ofac_sdn. Unique per tenant (UNIQUE(tenant_id, source_id)). Immutable post-create — fn_osint_source_update rejects payloads containing sourceId.';
COMMENT ON COLUMN osint_source.refresh_seconds IS
  'Per-source override of adapter-class default. Per Q-NEW4 lock: per-row value ALWAYS wins over adapter default. Worker reads this column at dispatch time; adapter default is a hint only.';
COMMENT ON COLUMN osint_source.url IS
  'SENSITIVE — may embed query-string secrets in some providers. Listed in project.config.json sensitiveFields (AE3). Pino redact + audit_log redact applied.';
COMMENT ON COLUMN osint_source.metadata IS
  'Adapter-specific extra config: sub-feed list for rss_aggregator, currency-pair list for fx, marker list for commodity, ADNOC-relevance filter for gdelt_v2.';

-- ----------------------------------------------------------------
-- 2. CREATE TABLE source_credential
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS source_credential (
  id               BIGSERIAL   PRIMARY KEY,
  tenant_id        UUID        NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  osint_source_id  BIGINT      NOT NULL REFERENCES osint_source(id) ON DELETE CASCADE,
  credential_kind  TEXT        NOT NULL CHECK (credential_kind IN
                        ('api_key','oauth_token','basic_auth','none')),
  credential_ref   TEXT,
  last_rotated_at  TIMESTAMPTZ,
  is_active        BOOLEAN     NOT NULL DEFAULT TRUE,

  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by       BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by       BIGINT REFERENCES "user"(id) ON DELETE SET NULL,

  CONSTRAINT source_credential_tenant_source_key UNIQUE (tenant_id, osint_source_id)
);

CREATE INDEX IF NOT EXISTS idx_source_credential_tenant_id        ON source_credential(tenant_id);
CREATE INDEX IF NOT EXISTS idx_source_credential_osint_source_id  ON source_credential(osint_source_id);
CREATE INDEX IF NOT EXISTS idx_source_credential_active           ON source_credential(id) WHERE is_active = TRUE;

COMMENT ON TABLE source_credential IS
  'M7 credential indirection per Q3+Q6 lock. credential_ref stores env-var name (env:VARNAME) or vault path (vault:path) — NEVER plain-text secret. Strict RLS: only platform_admin (source.manage) reads. Q5 flat-permission lock: no separate source.credential.read permission.';
COMMENT ON COLUMN source_credential.credential_kind IS
  'CHECK enum (api_key/oauth_token/basic_auth/none). Small fixed set; lookup table not warranted in CR-A.';
COMMENT ON COLUMN source_credential.credential_ref IS
  'SENSITIVE — KMS-style indirection. Format pattern: env:VARNAME OR vault:path. Plain-text values rejected by fn_source_credential_set with 22023. Listed in project.config.json sensitiveFields (AE3) AND fn_audit_trigger redact list (AE1) — appears as [REDACTED] in both audit_log payloads and Pino logs.';

-- ----------------------------------------------------------------
-- 3. RLS — osint_source (4 policies)
-- ----------------------------------------------------------------
ALTER TABLE osint_source ENABLE ROW LEVEL SECURITY;
ALTER TABLE osint_source FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS osint_source_tenant_select        ON osint_source;
DROP POLICY IF EXISTS osint_source_tenant_modify        ON osint_source;
DROP POLICY IF EXISTS osint_source_deny_direct_delete   ON osint_source;

CREATE POLICY osint_source_tenant_select ON osint_source
  FOR SELECT
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('source.read')
  );

CREATE POLICY osint_source_tenant_modify ON osint_source
  FOR ALL
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('source.manage')
  )
  WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('source.manage')
  );

CREATE POLICY osint_source_deny_direct_delete ON osint_source
  AS RESTRICTIVE FOR DELETE USING (false);

-- ----------------------------------------------------------------
-- 4. RLS — source_credential (2 policies)
-- ----------------------------------------------------------------
ALTER TABLE source_credential ENABLE ROW LEVEL SECURITY;
ALTER TABLE source_credential FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS source_credential_tenant_manage_only   ON source_credential;
DROP POLICY IF EXISTS source_credential_deny_direct_delete   ON source_credential;

CREATE POLICY source_credential_tenant_manage_only ON source_credential
  FOR ALL
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('source.manage')
  )
  WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('source.manage')
  );

CREATE POLICY source_credential_deny_direct_delete ON source_credential
  AS RESTRICTIVE FOR DELETE USING (false);

-- ----------------------------------------------------------------
-- 5. Audit triggers (fn_audit_trigger redacts credential_ref via 102 AE1)
-- ----------------------------------------------------------------
DROP TRIGGER IF EXISTS audit_osint_source_changes      ON osint_source;
CREATE TRIGGER audit_osint_source_changes
  AFTER INSERT OR UPDATE OR DELETE ON osint_source
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

DROP TRIGGER IF EXISTS audit_source_credential_changes ON source_credential;
CREATE TRIGGER audit_source_credential_changes
  AFTER INSERT OR UPDATE OR DELETE ON source_credential
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (103, 'm7_create_osint_source_credential', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_source_credential_changes ON source_credential;
-- DROP TRIGGER IF EXISTS audit_osint_source_changes ON osint_source;
-- DROP TABLE IF EXISTS source_credential CASCADE;
-- DROP TABLE IF EXISTS osint_source CASCADE;
-- DELETE FROM schema_migrations WHERE version = 103;
-- COMMIT;
-- ============================================================
