-- Migration: 466_m22_migration_tables.sql
-- Module: M22 / CR-MIG-DRIVE — Contract Migration + Google Drive Connector
-- Date: 2026-06-02
--
-- Topology: three new tenant-scoped tables (external_connection,
-- migration_batch, migration_record) + one contract column
-- (migration_batch_id) so imported contracts can be tagged for the
-- batch-level rollback + the dedicated migration purge.
--
-- All three tables FORCE RLS + audit triggers. migration_batch + migration_record
-- carry the Strategy-A RESTRICTIVE deny-DELETE policy (M14/M16 precedent);
-- only the dedicated fn_migration_purge_all (mig 467) can hard-delete via
-- DEFINER + SET LOCAL row_security = off.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS + DROP POLICY IF EXISTS.

BEGIN;

-- ============================================================
-- 1. external_connection — per-tenant OAuth-backed source connections
-- ============================================================

CREATE TABLE IF NOT EXISTS external_connection (
  id                         BIGSERIAL PRIMARY KEY,
  tenant_id                  UUID NOT NULL,
  provider                   TEXT NOT NULL
    CHECK (provider IN ('google_drive','sharepoint','onedrive','box','dropbox',
                        'email_imap','sftp','ivalua','sap_ariba')),
  display_name               TEXT NOT NULL,
  source_resource_id         TEXT NOT NULL,
  source_resource_label      TEXT,
  oauth_access_token_encrypted   TEXT,
  oauth_refresh_token_encrypted  TEXT,
  oauth_expires_at           TIMESTAMPTZ,
  oauth_scopes               TEXT[],
  connected_by_user_id       BIGINT REFERENCES "user"(id),
  connected_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_synced_at             TIMESTAMPTZ,
  status                     TEXT NOT NULL DEFAULT 'connecting'
    CHECK (status IN ('connecting','connected','token_expired','disconnected','error')),
  error_message              TEXT,
  data_classification        TEXT NOT NULL DEFAULT 'sensitive',
  created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by                 BIGINT REFERENCES "user"(id),
  updated_by                 BIGINT REFERENCES "user"(id),
  is_active                  BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT uq_external_connection_tenant_provider_resource
    UNIQUE (tenant_id, provider, source_resource_id)
);

CREATE INDEX IF NOT EXISTS idx_external_connection_tenant_status
  ON external_connection (tenant_id, status) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_external_connection_tenant_provider
  ON external_connection (tenant_id, provider) WHERE is_active = TRUE;

ALTER TABLE external_connection ENABLE ROW LEVEL SECURITY;
ALTER TABLE external_connection FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ext_conn_tenant_isolation ON external_connection;
CREATE POLICY ext_conn_tenant_isolation ON external_connection
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid);

COMMENT ON TABLE external_connection IS
  'M22 — per-tenant OAuth-backed source connections (Google Drive Phase 1; SharePoint/OneDrive/Box/Email/SFTP/Ivalua/Ariba Phase 2+). Tokens AES-256-GCM-encrypted; never logged.';
COMMENT ON COLUMN external_connection.oauth_access_token_encrypted IS 'AES-256-GCM ciphertext + IV + auth tag (base64). NEVER logged. Audit redact list.';
COMMENT ON COLUMN external_connection.oauth_refresh_token_encrypted IS 'AES-256-GCM ciphertext (base64). NEVER logged.';
COMMENT ON COLUMN external_connection.source_resource_id IS 'Provider-side ID — e.g. Google Drive folderId, SP siteId, Box folderId.';

-- ============================================================
-- 2. migration_batch — per-sync run log
-- ============================================================

CREATE TABLE IF NOT EXISTS migration_batch (
  id                         BIGSERIAL PRIMARY KEY,
  tenant_id                  UUID NOT NULL,
  external_connection_id     BIGINT NOT NULL REFERENCES external_connection(id),
  triggered_by_user_id       BIGINT REFERENCES "user"(id),
  trigger_kind               TEXT NOT NULL DEFAULT 'manual'
    CHECK (trigger_kind IN ('manual','scheduled','webhook')),
  status                     TEXT NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued','in_progress','completed','completed_with_errors',
                      'rolled_back','failed')),
  files_discovered           INTEGER NOT NULL DEFAULT 0,
  files_imported             INTEGER NOT NULL DEFAULT 0,
  files_review               INTEGER NOT NULL DEFAULT 0,
  files_failed               INTEGER NOT NULL DEFAULT 0,
  files_skipped_duplicate    INTEGER NOT NULL DEFAULT 0,
  started_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at               TIMESTAMPTZ,
  rolled_back_at             TIMESTAMPTZ,
  rolled_back_by_user_id     BIGINT REFERENCES "user"(id),
  rollback_reason            TEXT,
  data_classification        TEXT NOT NULL DEFAULT 'sensitive',
  created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by                 BIGINT REFERENCES "user"(id),
  updated_by                 BIGINT REFERENCES "user"(id),
  is_active                  BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS idx_migration_batch_tenant_status_started
  ON migration_batch (tenant_id, status, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_migration_batch_connection
  ON migration_batch (tenant_id, external_connection_id, started_at DESC);

ALTER TABLE migration_batch ENABLE ROW LEVEL SECURITY;
ALTER TABLE migration_batch FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS migration_batch_tenant_isolation ON migration_batch;
CREATE POLICY migration_batch_tenant_isolation ON migration_batch
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid);

-- Strategy-A deny-DELETE: only fn_migration_purge_all (DEFINER + SET LOCAL
-- row_security = off) can delete from this table.
DROP POLICY IF EXISTS migration_batch_deny_delete ON migration_batch;
CREATE POLICY migration_batch_deny_delete ON migration_batch
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

COMMENT ON TABLE migration_batch IS
  'M22 — append-only per-sync run log. Status mutations via DEFINER fns only. Hard-delete only via fn_migration_purge_all.';

-- ============================================================
-- 3. migration_record — per-file row inside a batch
-- ============================================================

CREATE TABLE IF NOT EXISTS migration_record (
  id                              BIGSERIAL PRIMARY KEY,
  tenant_id                       UUID NOT NULL,
  migration_batch_id              BIGINT NOT NULL REFERENCES migration_batch(id),
  -- Denormalised to avoid a JOIN in the cross-batch dedup unique index
  external_connection_id_of_batch BIGINT NOT NULL REFERENCES external_connection(id),
  source_file_id                  TEXT NOT NULL,
  source_file_name                TEXT,
  source_file_mime                TEXT,
  source_file_size_bytes          BIGINT,
  source_file_modified_at         TIMESTAMPTZ,
  source_file_sha256              CHAR(64),
  status                          TEXT NOT NULL DEFAULT 'discovered'
    CHECK (status IN ('discovered','downloading','ingesting','imported',
                      'needs_review','failed',
                      'skipped_duplicate_id','skipped_duplicate_hash',
                      'flagged_logical_duplicate')),
  duplicate_of_record_id          BIGINT REFERENCES migration_record(id),
  contract_id                     BIGINT REFERENCES contract(id),
  contract_version_id             BIGINT REFERENCES contract_version(id),
  ingestion_review_queue_id       BIGINT REFERENCES ingestion_review_queue(id),
  confidence_score_avg            NUMERIC(5,2),
  extracted_field_count           INTEGER,
  error_message                   TEXT,
  imported_at                     TIMESTAMPTZ,
  data_classification             TEXT NOT NULL DEFAULT 'sensitive',
  created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by                      BIGINT REFERENCES "user"(id),
  updated_by                      BIGINT REFERENCES "user"(id),
  is_active                       BOOLEAN NOT NULL DEFAULT TRUE
);

-- per-batch uniqueness (drives "list records" queries)
CREATE UNIQUE INDEX IF NOT EXISTS uq_migration_record_batch_source_file
  ON migration_record (migration_batch_id, source_file_id);

-- cross-batch dedup (level 1: source-file-ID) — only against non-skipped rows
CREATE UNIQUE INDEX IF NOT EXISTS uq_migration_record_active_source_file_per_conn
  ON migration_record (tenant_id, external_connection_id_of_batch, source_file_id)
  WHERE status NOT IN ('skipped_duplicate_id','skipped_duplicate_hash','failed');

-- cross-batch dedup (level 2: SHA-256 content hash) lookup index
CREATE INDEX IF NOT EXISTS idx_migration_record_tenant_sha256
  ON migration_record (tenant_id, source_file_sha256)
  WHERE source_file_sha256 IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_migration_record_batch_status
  ON migration_record (migration_batch_id, status);

ALTER TABLE migration_record ENABLE ROW LEVEL SECURITY;
ALTER TABLE migration_record FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS migration_record_tenant_isolation ON migration_record;
CREATE POLICY migration_record_tenant_isolation ON migration_record
  USING (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid)
  WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid);

DROP POLICY IF EXISTS migration_record_deny_delete ON migration_record;
CREATE POLICY migration_record_deny_delete ON migration_record
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

COMMENT ON TABLE migration_record IS
  'M22 — per-file row inside a migration_batch. Strategy-A append-only; hard-delete only via fn_migration_purge_all.';
COMMENT ON COLUMN migration_record.source_file_sha256 IS 'SHA-256 of downloaded bytes — drives content-hash dedup (level 2).';
COMMENT ON COLUMN migration_record.duplicate_of_record_id IS 'Set when status is skipped_duplicate_id or skipped_duplicate_hash — points at the surviving record.';

-- ============================================================
-- 4. Tag contract rows with their originating batch (rollback + purge scope)
-- ============================================================

ALTER TABLE contract
  ADD COLUMN IF NOT EXISTS migration_batch_id BIGINT REFERENCES migration_batch(id);

CREATE INDEX IF NOT EXISTS idx_contract_migration_batch
  ON contract (migration_batch_id) WHERE migration_batch_id IS NOT NULL;

COMMENT ON COLUMN contract.migration_batch_id IS
  'M22 — set on contracts imported via the migration pipeline. Allows batch-level rollback (soft-mark) and the dedicated migration purge (hard-delete only via fn_migration_purge_all).';

-- ============================================================
-- 5. Audit triggers — append-only insight on all three tables
-- ============================================================

DROP TRIGGER IF EXISTS audit_external_connection_changes ON external_connection;
CREATE TRIGGER audit_external_connection_changes
  AFTER INSERT OR UPDATE OR DELETE ON external_connection
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

DROP TRIGGER IF EXISTS audit_migration_batch_changes ON migration_batch;
CREATE TRIGGER audit_migration_batch_changes
  AFTER INSERT OR UPDATE OR DELETE ON migration_batch
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

DROP TRIGGER IF EXISTS audit_migration_record_changes ON migration_record;
CREATE TRIGGER audit_migration_record_changes
  AFTER INSERT OR UPDATE OR DELETE ON migration_record
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (466, '466_m22_migration_tables', CURRENT_TIMESTAMP);

COMMIT;

-- ============================================================
-- ROLLBACK (manual)
-- ============================================================
-- BEGIN;
-- DROP TABLE IF EXISTS migration_record CASCADE;
-- DROP TABLE IF EXISTS migration_batch CASCADE;
-- DROP TABLE IF EXISTS external_connection CASCADE;
-- ALTER TABLE contract DROP COLUMN IF EXISTS migration_batch_id;
-- DELETE FROM schema_migrations WHERE version = 466;
-- COMMIT;
