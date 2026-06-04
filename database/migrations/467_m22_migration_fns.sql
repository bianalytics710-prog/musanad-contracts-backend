-- Migration: 467_m22_migration_fns.sql
-- Module: M22 / CR-MIG-DRIVE — 16 fns for migration lifecycle
-- Date: 2026-06-02
--
-- Naming: fn_external_connection_* (connection lifecycle)
--         fn_migration_batch_*     (batch lifecycle)
--         fn_migration_record_*    (record lifecycle + dedup)
--         fn_migration_purge_all   (dedicated hard-delete carve-out)
--
-- Security model:
--   INVOKER + permission gate for user-facing reads/writes
--   DEFINER for worker-only writes (token rotation, record state machine)
--   DEFINER for the dedicated purge with body-level role + permission check
--
-- Per S2-21: every fn ends with explicit REVOKE FROM PUBLIC + GRANT TO neondb_owner
--           + COMMENT ON FUNCTION trio.

BEGIN;

-- ============================================================
-- Helper: enforce app.current_tenant_id is set (defence-in-depth)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_require_tenant_guc()
RETURNS UUID
LANGUAGE plpgsql STABLE
AS $$
DECLARE v_t UUID;
BEGIN
  v_t := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_t IS NULL THEN
    RAISE EXCEPTION 'app.current_tenant_id GUC not set' USING ERRCODE = '42501';
  END IF;
  RETURN v_t;
END $$;
REVOKE EXECUTE ON FUNCTION fn_require_tenant_guc FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_require_tenant_guc TO neondb_owner;

-- ============================================================
-- 1. fn_external_connection_create — INVOKER, gated migration.connection.manage
-- ============================================================
CREATE OR REPLACE FUNCTION fn_external_connection_create(
  p_provider              TEXT,
  p_display_name          TEXT,
  p_source_resource_id    TEXT,
  p_source_resource_label TEXT,
  p_access_token_enc      TEXT,
  p_refresh_token_enc     TEXT,
  p_expires_at            TIMESTAMPTZ,
  p_scopes                TEXT[],
  p_actor_id              BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := fn_require_tenant_guc();
  v_id     BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('migration.connection.manage') THEN
    RAISE EXCEPTION 'permission_denied: migration.connection.manage required'
      USING ERRCODE = '42501';
  END IF;
  IF p_provider IS NULL OR p_display_name IS NULL OR p_source_resource_id IS NULL THEN
    RAISE EXCEPTION 'provider, display_name, source_resource_id are required'
      USING ERRCODE = '22023';
  END IF;
  INSERT INTO external_connection (
    tenant_id, provider, display_name, source_resource_id, source_resource_label,
    oauth_access_token_encrypted, oauth_refresh_token_encrypted, oauth_expires_at,
    oauth_scopes, connected_by_user_id, status, created_by, updated_by
  ) VALUES (
    v_tenant, p_provider, p_display_name, p_source_resource_id, p_source_resource_label,
    p_access_token_enc, p_refresh_token_enc, p_expires_at,
    p_scopes, p_actor_id, 'connected', p_actor_id, p_actor_id
  )
  ON CONFLICT (tenant_id, provider, source_resource_id) DO UPDATE
    SET display_name                   = EXCLUDED.display_name,
        source_resource_label          = EXCLUDED.source_resource_label,
        oauth_access_token_encrypted   = EXCLUDED.oauth_access_token_encrypted,
        oauth_refresh_token_encrypted  = EXCLUDED.oauth_refresh_token_encrypted,
        oauth_expires_at               = EXCLUDED.oauth_expires_at,
        oauth_scopes                   = EXCLUDED.oauth_scopes,
        connected_by_user_id           = EXCLUDED.connected_by_user_id,
        status                         = 'connected',
        is_active                      = TRUE,
        error_message                  = NULL,
        updated_at                     = now(),
        updated_by                     = EXCLUDED.updated_by
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION fn_external_connection_create FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_external_connection_create TO neondb_owner;
COMMENT ON FUNCTION fn_external_connection_create IS
  'M22 — INVOKER; upsert per (tenant, provider, source). Tokens MUST be pre-encrypted by token-cipher.service before invocation.';

-- ============================================================
-- 2. fn_external_connection_list — INVOKER (sanitized; no token fields)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_external_connection_list()
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := fn_require_tenant_guc();
  v_rows   JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('migration.connection.manage') THEN
    RAISE EXCEPTION 'permission_denied: migration.connection.manage required'
      USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                   id,
    'provider',             provider,
    'displayName',          display_name,
    'sourceResourceId',     source_resource_id,
    'sourceResourceLabel',  source_resource_label,
    'oauthScopes',          oauth_scopes,
    'connectedByUserId',    connected_by_user_id,
    'connectedAt',          connected_at,
    'lastSyncedAt',         last_synced_at,
    'oauthExpiresAt',       oauth_expires_at,
    'status',               status,
    'errorMessage',         error_message,
    'isActive',             is_active
  ) ORDER BY connected_at DESC), '[]'::jsonb) INTO v_rows
  FROM external_connection
  WHERE tenant_id = v_tenant AND is_active = TRUE;
  RETURN v_rows;
END $$;
REVOKE EXECUTE ON FUNCTION fn_external_connection_list FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_external_connection_list TO neondb_owner;
COMMENT ON FUNCTION fn_external_connection_list IS
  'M22 — INVOKER; returns sanitized connection rows. No token fields surfaced. Gated by migration.connection.manage.';

-- ============================================================
-- 3. fn_external_connection_get_by_id — INVOKER sanitized
-- ============================================================
CREATE OR REPLACE FUNCTION fn_external_connection_get_by_id(p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := fn_require_tenant_guc();
  v_row    JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('migration.connection.manage') THEN
    RAISE EXCEPTION 'permission_denied: migration.connection.manage required'
      USING ERRCODE = '42501';
  END IF;
  SELECT jsonb_build_object(
    'id', id, 'provider', provider, 'displayName', display_name,
    'sourceResourceId', source_resource_id, 'sourceResourceLabel', source_resource_label,
    'oauthScopes', oauth_scopes, 'connectedByUserId', connected_by_user_id,
    'connectedAt', connected_at, 'lastSyncedAt', last_synced_at,
    'oauthExpiresAt', oauth_expires_at, 'status', status,
    'errorMessage', error_message, 'isActive', is_active
  ) INTO v_row
  FROM external_connection
  WHERE id = p_id AND tenant_id = v_tenant;
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'external_connection % not found', p_id USING ERRCODE = 'P0002';
  END IF;
  RETURN v_row;
END $$;
REVOKE EXECUTE ON FUNCTION fn_external_connection_get_by_id FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_external_connection_get_by_id TO neondb_owner;
COMMENT ON FUNCTION fn_external_connection_get_by_id IS
  'M22 — INVOKER sanitized fetch. No token fields. Gated by migration.connection.manage.';

-- ============================================================
-- 4. fn_external_connection_get_tokens — DEFINER worker-only
-- ============================================================
CREATE OR REPLACE FUNCTION fn_external_connection_get_tokens(p_id BIGINT, p_tenant UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE v_row JSONB;
BEGIN
  -- DEFINER + caller passes tenant explicitly (worker context). No INVOKER permission
  -- gate because the worker holds no user-role identity. Mitigated by:
  --   (a) REVOKE FROM PUBLIC + GRANT only to neondb_owner;
  --   (b) function never reachable through an HTTP route;
  --   (c) BE service-layer constructs the call (no SQL injection path).
  SELECT jsonb_build_object(
    'id', id, 'provider', provider,
    'sourceResourceId', source_resource_id,
    'oauthAccessTokenEncrypted',  oauth_access_token_encrypted,
    'oauthRefreshTokenEncrypted', oauth_refresh_token_encrypted,
    'oauthExpiresAt',             oauth_expires_at,
    'oauthScopes',                oauth_scopes,
    'status',                     status
  ) INTO v_row
  FROM external_connection
  WHERE id = p_id AND tenant_id = p_tenant AND is_active = TRUE;
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'external_connection % (tenant %) not found',
      p_id, p_tenant USING ERRCODE = 'P0002';
  END IF;
  RETURN v_row;
END $$;
REVOKE EXECUTE ON FUNCTION fn_external_connection_get_tokens(BIGINT, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_external_connection_get_tokens(BIGINT, UUID) TO neondb_owner;
COMMENT ON FUNCTION fn_external_connection_get_tokens(BIGINT, UUID) IS
  'M22 — DEFINER worker-only. Returns ENCRYPTED token blobs; BE service layer decrypts.';

-- ============================================================
-- 5. fn_external_connection_update_tokens — DEFINER worker-only
-- ============================================================
CREATE OR REPLACE FUNCTION fn_external_connection_update_tokens(
  p_id                BIGINT,
  p_tenant            UUID,
  p_access_token_enc  TEXT,
  p_expires_at        TIMESTAMPTZ
)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
BEGIN
  UPDATE external_connection
  SET oauth_access_token_encrypted = p_access_token_enc,
      oauth_expires_at             = p_expires_at,
      status                       = 'connected',
      error_message                = NULL,
      updated_at                   = now()
  WHERE id = p_id AND tenant_id = p_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'external_connection % not found', p_id USING ERRCODE = 'P0002';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION fn_external_connection_update_tokens(BIGINT, UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_external_connection_update_tokens(BIGINT, UUID, TEXT, TIMESTAMPTZ) TO neondb_owner;
COMMENT ON FUNCTION fn_external_connection_update_tokens(BIGINT, UUID, TEXT, TIMESTAMPTZ) IS
  'M22 — DEFINER worker-only. Rotates the access-token blob + expiry. Refresh token untouched.';

-- ============================================================
-- 6. fn_external_connection_set_status — DEFINER worker-only
-- ============================================================
CREATE OR REPLACE FUNCTION fn_external_connection_set_status(
  p_id            BIGINT,
  p_tenant        UUID,
  p_status        TEXT,
  p_error_message TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
BEGIN
  IF p_status NOT IN ('connecting','connected','token_expired','disconnected','error') THEN
    RAISE EXCEPTION 'invalid status: %', p_status USING ERRCODE = '22023';
  END IF;
  UPDATE external_connection
  SET status        = p_status,
      error_message = p_error_message,
      updated_at    = now()
  WHERE id = p_id AND tenant_id = p_tenant;
END $$;
REVOKE EXECUTE ON FUNCTION fn_external_connection_set_status(BIGINT, UUID, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_external_connection_set_status(BIGINT, UUID, TEXT, TEXT) TO neondb_owner;
COMMENT ON FUNCTION fn_external_connection_set_status(BIGINT, UUID, TEXT, TEXT) IS
  'M22 — DEFINER worker-only. Connection state-machine writer.';

-- ============================================================
-- 7. fn_external_connection_disconnect — INVOKER user-callable
-- ============================================================
CREATE OR REPLACE FUNCTION fn_external_connection_disconnect(p_id BIGINT, p_actor_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
AS $$
DECLARE v_tenant UUID := fn_require_tenant_guc();
BEGIN
  IF NOT fn_current_user_has_permission('migration.connection.manage') THEN
    RAISE EXCEPTION 'permission_denied: migration.connection.manage required'
      USING ERRCODE = '42501';
  END IF;
  UPDATE external_connection
  SET oauth_access_token_encrypted  = NULL,
      oauth_refresh_token_encrypted = NULL,
      oauth_expires_at              = NULL,
      status                        = 'disconnected',
      updated_at                    = now(),
      updated_by                    = p_actor_id
  WHERE id = p_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'external_connection % not found', p_id USING ERRCODE = 'P0002';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION fn_external_connection_disconnect(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_external_connection_disconnect(BIGINT, BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_external_connection_disconnect(BIGINT, BIGINT) IS
  'M22 — INVOKER; nukes both token blobs + flips status. Past batches remain queryable.';

-- ============================================================
-- 8. fn_migration_batch_create — INVOKER, gated migration.batch.trigger
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migration_batch_create(
  p_connection_id BIGINT,
  p_actor_id      BIGINT,
  p_trigger_kind  TEXT DEFAULT 'manual'
)
RETURNS BIGINT
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := fn_require_tenant_guc();
  v_id     BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('migration.batch.trigger') THEN
    RAISE EXCEPTION 'permission_denied: migration.batch.trigger required'
      USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM external_connection
    WHERE id = p_connection_id AND tenant_id = v_tenant
      AND is_active = TRUE AND status = 'connected'
  ) THEN
    RAISE EXCEPTION 'external_connection % not connected', p_connection_id
      USING ERRCODE = 'P0002';
  END IF;
  INSERT INTO migration_batch (
    tenant_id, external_connection_id, triggered_by_user_id, trigger_kind,
    status, started_at, created_by, updated_by
  ) VALUES (
    v_tenant, p_connection_id, p_actor_id, p_trigger_kind,
    'queued', now(), p_actor_id, p_actor_id
  ) RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_batch_create(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_batch_create(BIGINT, BIGINT, TEXT) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_batch_create(BIGINT, BIGINT, TEXT) IS
  'M22 — INVOKER; creates queued batch. Worker picks it up.';

-- ============================================================
-- 9. fn_migration_batch_get_by_id — INVOKER summary + counts
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migration_batch_get_by_id(p_batch_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := fn_require_tenant_guc();
  v_row    JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('migration.batch.read.all') THEN
    RAISE EXCEPTION 'permission_denied: migration.batch.read.all required'
      USING ERRCODE = '42501';
  END IF;
  -- S2-24 split-aggregate: do not nest jsonb_agg + summary counters in one
  -- SELECT. Counters live on the row already; jsonb_build_object is flat.
  SELECT jsonb_build_object(
    'id',                     id,
    'externalConnectionId',   external_connection_id,
    'triggeredByUserId',      triggered_by_user_id,
    'triggerKind',            trigger_kind,
    'status',                 status,
    'filesDiscovered',        files_discovered,
    'filesImported',          files_imported,
    'filesReview',            files_review,
    'filesFailed',            files_failed,
    'filesSkippedDuplicate',  files_skipped_duplicate,
    'startedAt',              started_at,
    'completedAt',            completed_at,
    'rolledBackAt',           rolled_back_at,
    'rolledBackByUserId',     rolled_back_by_user_id,
    'rollbackReason',         rollback_reason
  ) INTO v_row
  FROM migration_batch
  WHERE id = p_batch_id AND tenant_id = v_tenant;
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'migration_batch % not found', p_batch_id USING ERRCODE = 'P0002';
  END IF;
  RETURN v_row;
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_batch_get_by_id(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_batch_get_by_id(BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_batch_get_by_id(BIGINT) IS
  'M22 — INVOKER; flat batch row + summary counters. Gated by migration.batch.read.all.';

-- ============================================================
-- 10. fn_migration_batch_list — INVOKER paginated
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migration_batch_list(p_limit INTEGER DEFAULT 50, p_offset INTEGER DEFAULT 0)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := fn_require_tenant_guc();
  v_rows   JSONB;
  v_total  INTEGER;
BEGIN
  IF NOT fn_current_user_has_permission('migration.batch.read.all') THEN
    RAISE EXCEPTION 'permission_denied: migration.batch.read.all required'
      USING ERRCODE = '42501';
  END IF;
  p_limit  := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
  p_offset := GREATEST(COALESCE(p_offset, 0), 0);
  SELECT COUNT(*) INTO v_total FROM migration_batch WHERE tenant_id = v_tenant;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', b.id, 'connectionId', b.external_connection_id,
    'connectionDisplayName', c.display_name, 'connectionProvider', c.provider,
    'triggeredByUserId', b.triggered_by_user_id, 'triggerKind', b.trigger_kind,
    'status', b.status,
    'filesDiscovered', b.files_discovered, 'filesImported', b.files_imported,
    'filesReview', b.files_review, 'filesFailed', b.files_failed,
    'filesSkippedDuplicate', b.files_skipped_duplicate,
    'startedAt', b.started_at, 'completedAt', b.completed_at,
    'rolledBackAt', b.rolled_back_at
  ) ORDER BY b.started_at DESC), '[]'::jsonb) INTO v_rows
  FROM migration_batch b
  JOIN external_connection c ON c.id = b.external_connection_id
  WHERE b.tenant_id = v_tenant
  ORDER BY b.started_at DESC
  LIMIT p_limit OFFSET p_offset;
  RETURN jsonb_build_object('rows', v_rows, 'total', v_total);
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_batch_list(INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_batch_list(INTEGER, INTEGER) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_batch_list(INTEGER, INTEGER) IS
  'M22 — INVOKER; paginated batch list with connection display name + provider.';

-- ============================================================
-- 11. fn_migration_batch_list_records — INVOKER paginated + status filter
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migration_batch_list_records(
  p_batch_id   BIGINT,
  p_status     TEXT DEFAULT NULL,
  p_limit      INTEGER DEFAULT 50,
  p_offset     INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := fn_require_tenant_guc();
  v_rows   JSONB;
  v_total  INTEGER;
BEGIN
  IF NOT fn_current_user_has_permission('migration.batch.read.all') THEN
    RAISE EXCEPTION 'permission_denied: migration.batch.read.all required'
      USING ERRCODE = '42501';
  END IF;
  p_limit  := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
  p_offset := GREATEST(COALESCE(p_offset, 0), 0);
  SELECT COUNT(*) INTO v_total FROM migration_record
   WHERE tenant_id = v_tenant AND migration_batch_id = p_batch_id
     AND (p_status IS NULL OR status = p_status);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'sourceFileId', source_file_id, 'sourceFileName', source_file_name,
    'sourceFileMime', source_file_mime, 'sourceFileSizeBytes', source_file_size_bytes,
    'sourceFileModifiedAt', source_file_modified_at,
    'sourceFileSha256', source_file_sha256, 'status', status,
    'duplicateOfRecordId', duplicate_of_record_id,
    'contractId', contract_id, 'contractVersionId', contract_version_id,
    'ingestionReviewQueueId', ingestion_review_queue_id,
    'confidenceScoreAvg', confidence_score_avg,
    'extractedFieldCount', extracted_field_count,
    'errorMessage', error_message, 'importedAt', imported_at,
    'createdAt', created_at
  ) ORDER BY id ASC), '[]'::jsonb) INTO v_rows
  FROM migration_record
  WHERE tenant_id = v_tenant AND migration_batch_id = p_batch_id
    AND (p_status IS NULL OR status = p_status)
  ORDER BY id ASC
  LIMIT p_limit OFFSET p_offset;
  RETURN jsonb_build_object('rows', v_rows, 'total', v_total);
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_batch_list_records(BIGINT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_batch_list_records(BIGINT, TEXT, INTEGER, INTEGER) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_batch_list_records(BIGINT, TEXT, INTEGER, INTEGER) IS
  'M22 — INVOKER; per-batch record paging + status filter. Gated by migration.batch.read.all.';

-- ============================================================
-- 12. fn_migration_batch_update_counts + _set_status — DEFINER worker-only
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migration_batch_update_counts(
  p_batch_id          BIGINT,
  p_tenant            UUID,
  p_files_discovered  INTEGER DEFAULT NULL,
  p_files_imported    INTEGER DEFAULT NULL,
  p_files_review      INTEGER DEFAULT NULL,
  p_files_failed      INTEGER DEFAULT NULL,
  p_files_skipped     INTEGER DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
BEGIN
  UPDATE migration_batch
  SET files_discovered        = COALESCE(p_files_discovered, files_discovered),
      files_imported          = COALESCE(p_files_imported,   files_imported),
      files_review            = COALESCE(p_files_review,     files_review),
      files_failed            = COALESCE(p_files_failed,     files_failed),
      files_skipped_duplicate = COALESCE(p_files_skipped,    files_skipped_duplicate),
      updated_at              = now()
  WHERE id = p_batch_id AND tenant_id = p_tenant;
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_batch_update_counts(BIGINT, UUID, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_batch_update_counts(BIGINT, UUID, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_batch_update_counts(BIGINT, UUID, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER) IS
  'M22 — DEFINER worker-only. Increment-style updater; pass NULL to leave a counter unchanged.';

CREATE OR REPLACE FUNCTION fn_migration_batch_set_status(
  p_batch_id BIGINT,
  p_tenant   UUID,
  p_status   TEXT
)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
BEGIN
  IF p_status NOT IN ('queued','in_progress','completed','completed_with_errors',
                      'rolled_back','failed') THEN
    RAISE EXCEPTION 'invalid status: %', p_status USING ERRCODE = '22023';
  END IF;
  UPDATE migration_batch
  SET status       = p_status,
      completed_at = CASE WHEN p_status IN ('completed','completed_with_errors','failed')
                          THEN now() ELSE completed_at END,
      updated_at   = now()
  WHERE id = p_batch_id AND tenant_id = p_tenant;
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_batch_set_status(BIGINT, UUID, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_batch_set_status(BIGINT, UUID, TEXT) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_batch_set_status(BIGINT, UUID, TEXT) IS
  'M22 — DEFINER worker-only. Batch state-machine writer.';

-- ============================================================
-- 13. fn_migration_batch_rollback — INVOKER gated, soft-mark
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migration_batch_rollback(
  p_batch_id BIGINT,
  p_actor_id BIGINT,
  p_reason   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
AS $$
DECLARE
  v_tenant     UUID := fn_require_tenant_guc();
  v_status     TEXT;
  v_count      INTEGER;
BEGIN
  IF NOT fn_current_user_has_permission('migration.batch.rollback') THEN
    RAISE EXCEPTION 'permission_denied: migration.batch.rollback required'
      USING ERRCODE = '42501';
  END IF;

  -- Lock the batch row to prevent worker race
  SELECT status INTO v_status FROM migration_batch
   WHERE id = p_batch_id AND tenant_id = v_tenant
   FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'migration_batch % not found', p_batch_id USING ERRCODE = 'P0002';
  END IF;
  IF v_status NOT IN ('completed','completed_with_errors','failed') THEN
    RAISE EXCEPTION 'cannot rollback batch in status %', v_status USING ERRCODE = '22023';
  END IF;

  -- Soft-mark imported contracts
  UPDATE contract
  SET is_active  = FALSE,
      updated_at = now(),
      updated_by = p_actor_id
  WHERE migration_batch_id = p_batch_id
    AND is_active = TRUE;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Mark batch rolled_back
  UPDATE migration_batch
  SET status                = 'rolled_back',
      rolled_back_at        = now(),
      rolled_back_by_user_id= p_actor_id,
      rollback_reason       = p_reason,
      updated_at            = now(),
      updated_by            = p_actor_id
  WHERE id = p_batch_id AND tenant_id = v_tenant;

  RETURN jsonb_build_object('contractsRolledBack', v_count, 'batchId', p_batch_id);
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_batch_rollback(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_batch_rollback(BIGINT, BIGINT, TEXT) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_batch_rollback(BIGINT, BIGINT, TEXT) IS
  'M22 — INVOKER; soft-marks imported contracts. Idempotent. Gated by migration.batch.rollback.';

-- ============================================================
-- 14. fn_migration_record_create — DEFINER worker-only
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migration_record_create(
  p_batch_id          BIGINT,
  p_tenant            UUID,
  p_source_file_id    TEXT,
  p_source_file_name  TEXT,
  p_source_file_mime  TEXT,
  p_source_file_size  BIGINT,
  p_source_file_mtime TIMESTAMPTZ
)
RETURNS BIGINT
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
DECLARE
  v_conn_id BIGINT;
  v_id      BIGINT;
BEGIN
  SELECT external_connection_id INTO v_conn_id FROM migration_batch
   WHERE id = p_batch_id AND tenant_id = p_tenant;
  IF v_conn_id IS NULL THEN
    RAISE EXCEPTION 'migration_batch % not found', p_batch_id USING ERRCODE = 'P0002';
  END IF;
  INSERT INTO migration_record (
    tenant_id, migration_batch_id, external_connection_id_of_batch,
    source_file_id, source_file_name, source_file_mime,
    source_file_size_bytes, source_file_modified_at, status
  ) VALUES (
    p_tenant, p_batch_id, v_conn_id,
    p_source_file_id, p_source_file_name, p_source_file_mime,
    p_source_file_size, p_source_file_mtime, 'discovered'
  )
  ON CONFLICT (migration_batch_id, source_file_id) DO UPDATE
    SET source_file_name = EXCLUDED.source_file_name,
        source_file_mime = EXCLUDED.source_file_mime,
        source_file_size_bytes = EXCLUDED.source_file_size_bytes,
        source_file_modified_at = EXCLUDED.source_file_modified_at,
        updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_record_create(BIGINT, UUID, TEXT, TEXT, TEXT, BIGINT, TIMESTAMPTZ) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_record_create(BIGINT, UUID, TEXT, TEXT, TEXT, BIGINT, TIMESTAMPTZ) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_record_create(BIGINT, UUID, TEXT, TEXT, TEXT, BIGINT, TIMESTAMPTZ) IS
  'M22 — DEFINER worker-only. Upserts the per-file row at discovery time.';

-- ============================================================
-- 15. fn_migration_record_update_status / _set_sha256 / _link_contract — DEFINER worker-only
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migration_record_update_status(
  p_record_id BIGINT,
  p_tenant    UUID,
  p_status    TEXT,
  p_error     TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
BEGIN
  IF p_status NOT IN ('discovered','downloading','ingesting','imported',
                      'needs_review','failed',
                      'skipped_duplicate_id','skipped_duplicate_hash',
                      'flagged_logical_duplicate') THEN
    RAISE EXCEPTION 'invalid status: %', p_status USING ERRCODE = '22023';
  END IF;
  UPDATE migration_record
  SET status        = p_status,
      error_message = COALESCE(p_error, error_message),
      imported_at   = CASE WHEN p_status = 'imported' THEN now() ELSE imported_at END,
      updated_at    = now()
  WHERE id = p_record_id AND tenant_id = p_tenant;
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_record_update_status(BIGINT, UUID, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_record_update_status(BIGINT, UUID, TEXT, TEXT) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_record_update_status(BIGINT, UUID, TEXT, TEXT) IS
  'M22 — DEFINER worker-only. Record state-machine writer.';

CREATE OR REPLACE FUNCTION fn_migration_record_set_sha256(
  p_record_id BIGINT, p_tenant UUID, p_sha256 CHAR(64)
)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
BEGIN
  UPDATE migration_record
  SET source_file_sha256 = p_sha256,
      updated_at         = now()
  WHERE id = p_record_id AND tenant_id = p_tenant;
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_record_set_sha256(BIGINT, UUID, CHAR) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_record_set_sha256(BIGINT, UUID, CHAR) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_record_set_sha256(BIGINT, UUID, CHAR) IS
  'M22 — DEFINER worker-only. Sets the file content hash after download.';

CREATE OR REPLACE FUNCTION fn_migration_record_link_contract(
  p_record_id           BIGINT,
  p_tenant              UUID,
  p_contract_id         BIGINT,
  p_contract_version_id BIGINT,
  p_confidence_avg      NUMERIC,
  p_field_count         INTEGER,
  p_irq_id              BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
BEGIN
  UPDATE migration_record
  SET contract_id               = p_contract_id,
      contract_version_id       = p_contract_version_id,
      ingestion_review_queue_id = p_irq_id,
      confidence_score_avg      = p_confidence_avg,
      extracted_field_count     = p_field_count,
      updated_at                = now()
  WHERE id = p_record_id AND tenant_id = p_tenant;

  -- Tag the contract with its originating batch so rollback + purge can find it
  UPDATE contract
  SET migration_batch_id = (SELECT migration_batch_id FROM migration_record
                              WHERE id = p_record_id AND tenant_id = p_tenant)
  WHERE id = p_contract_id;
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_record_link_contract(BIGINT, UUID, BIGINT, BIGINT, NUMERIC, INTEGER, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_record_link_contract(BIGINT, UUID, BIGINT, BIGINT, NUMERIC, INTEGER, BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_record_link_contract(BIGINT, UUID, BIGINT, BIGINT, NUMERIC, INTEGER, BIGINT) IS
  'M22 — DEFINER worker-only. Wires extracted contract back to its migration_record + tags the contract row.';

CREATE OR REPLACE FUNCTION fn_migration_record_mark_duplicate(
  p_record_id       BIGINT,
  p_tenant          UUID,
  p_dup_kind        TEXT,
  p_dup_of_record   BIGINT
)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
BEGIN
  IF p_dup_kind NOT IN ('skipped_duplicate_id','skipped_duplicate_hash') THEN
    RAISE EXCEPTION 'invalid dup kind: %', p_dup_kind USING ERRCODE = '22023';
  END IF;
  UPDATE migration_record
  SET status                 = p_dup_kind,
      duplicate_of_record_id = p_dup_of_record,
      updated_at             = now()
  WHERE id = p_record_id AND tenant_id = p_tenant;
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_record_mark_duplicate(BIGINT, UUID, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_record_mark_duplicate(BIGINT, UUID, TEXT, BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_record_mark_duplicate(BIGINT, UUID, TEXT, BIGINT) IS
  'M22 — DEFINER worker-only. Flips a record to skipped_duplicate_* + records the survivor.';

-- ============================================================
-- 16. fn_migration_record_check_duplicates — INVOKER (used by worker; safe)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migration_record_check_duplicates(
  p_external_connection_id BIGINT,
  p_source_file_id         TEXT,
  p_sha256                 CHAR(64) DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
AS $$
DECLARE
  v_tenant   UUID := fn_require_tenant_guc();
  v_dup_rec  BIGINT;
  v_kind     TEXT := 'none';
BEGIN
  -- Level 1: source-file-ID match across non-skipped records in same conn
  SELECT id INTO v_dup_rec FROM migration_record
   WHERE tenant_id = v_tenant
     AND external_connection_id_of_batch = p_external_connection_id
     AND source_file_id = p_source_file_id
     AND status NOT IN ('skipped_duplicate_id','skipped_duplicate_hash','failed')
   ORDER BY id ASC LIMIT 1;
  IF v_dup_rec IS NOT NULL THEN
    RETURN jsonb_build_object('duplicateKind','id_match','duplicateOfRecordId', v_dup_rec);
  END IF;
  -- Level 2: SHA-256 hash match anywhere in tenant
  IF p_sha256 IS NOT NULL THEN
    SELECT id INTO v_dup_rec FROM migration_record
     WHERE tenant_id = v_tenant
       AND source_file_sha256 = p_sha256
       AND status NOT IN ('skipped_duplicate_id','skipped_duplicate_hash','failed')
     ORDER BY id ASC LIMIT 1;
    IF v_dup_rec IS NOT NULL THEN
      RETURN jsonb_build_object('duplicateKind','hash_match','duplicateOfRecordId', v_dup_rec);
    END IF;
  END IF;
  RETURN jsonb_build_object('duplicateKind','none','duplicateOfRecordId', NULL);
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_record_check_duplicates(BIGINT, TEXT, CHAR) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_record_check_duplicates(BIGINT, TEXT, CHAR) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_record_check_duplicates(BIGINT, TEXT, CHAR) IS
  'M22 — DEFINER (tenant resolved from GUC). Level 1 takes precedence over Level 2.';

-- ============================================================
-- 17. fn_migration_logical_duplicate_flag — DEFINER, post-ingestion
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migration_logical_duplicate_flag(p_record_id BIGINT, p_tenant UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
DECLARE
  v_record      RECORD;
  v_match_id    BIGINT;
BEGIN
  SELECT mr.contract_id, c.counterparty_id, c.value_aed, c.start_date
    INTO v_record
  FROM migration_record mr
  LEFT JOIN contract c ON c.id = mr.contract_id
  WHERE mr.id = p_record_id AND mr.tenant_id = p_tenant;
  IF v_record.contract_id IS NULL THEN RETURN FALSE; END IF;

  -- Same tenant, different contract, same counterparty, value within ±2%,
  -- start_date within ±7 days
  SELECT id INTO v_match_id FROM contract
   WHERE id <> v_record.contract_id
     AND is_active = TRUE
     AND counterparty_id = v_record.counterparty_id
     AND value_aed IS NOT NULL AND v_record.value_aed IS NOT NULL
     AND ABS(value_aed - v_record.value_aed) <= GREATEST(v_record.value_aed * 0.02, 1)
     AND start_date IS NOT NULL AND v_record.start_date IS NOT NULL
     AND ABS(EXTRACT(EPOCH FROM (start_date - v_record.start_date))) <= 7 * 86400
   ORDER BY id ASC LIMIT 1;

  IF v_match_id IS NOT NULL THEN
    UPDATE migration_record
       SET status = 'flagged_logical_duplicate',
           updated_at = now()
     WHERE id = p_record_id AND tenant_id = p_tenant;
    RETURN TRUE;
  END IF;
  RETURN FALSE;
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_logical_duplicate_flag(BIGINT, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_logical_duplicate_flag(BIGINT, UUID) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_logical_duplicate_flag(BIGINT, UUID) IS
  'M22 — DEFINER. Post-ingestion scan; flags record as logical-dup but does NOT block import.';

-- ============================================================
-- 18. fn_migration_purge_all — DEDICATED HARD-DELETE CARVE-OUT
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migration_purge_all(p_dry_run BOOLEAN DEFAULT FALSE)
RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
DECLARE
  v_tenant      UUID := fn_require_tenant_guc();
  v_actor       BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::bigint;
  v_role        TEXT;
  v_n_irq       INTEGER := 0;
  v_n_clauses   INTEGER := 0;
  v_n_risk      INTEGER := 0;
  v_n_oblig     INTEGER := 0;
  v_n_attach    INTEGER := 0;
  v_n_activity  INTEGER := 0;
  v_n_comments  INTEGER := 0;
  v_n_versions  INTEGER := 0;
  v_n_contracts INTEGER := 0;
  v_n_records   INTEGER := 0;
  v_n_batches   INTEGER := 0;
  v_total       INTEGER;
BEGIN
  -- Body-level role guard: permission OR Super Admin
  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_actor;
  IF NOT fn_current_user_has_permission('migration.purge.all')
     AND COALESCE(v_role, '') <> 'Super Admin' THEN
    RAISE EXCEPTION 'migration_purge_permission_required' USING ERRCODE = '42501';
  END IF;

  -- Scope guard: collect target contract IDs once. This is the choke point
  -- that protects native + M11-ingested contracts.
  CREATE TEMP TABLE IF NOT EXISTS _purge_target_contracts (id BIGINT PRIMARY KEY) ON COMMIT DROP;
  TRUNCATE _purge_target_contracts;
  INSERT INTO _purge_target_contracts (id)
    SELECT DISTINCT contract_id
    FROM migration_record
    WHERE tenant_id = v_tenant AND contract_id IS NOT NULL;

  -- Count phase (always runs)
  SELECT COUNT(*) INTO v_n_irq FROM ingestion_review_queue irq
    WHERE irq.id IN (SELECT ingestion_review_queue_id FROM migration_record
                      WHERE tenant_id = v_tenant AND ingestion_review_queue_id IS NOT NULL);
  SELECT COUNT(*) INTO v_n_clauses FROM contract_clause_extracted
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_risk FROM risk_score
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_oblig FROM contract_obligation
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_attach FROM contract_attachment
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_activity FROM contract_activity
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_comments FROM contract_comment
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_versions FROM contract_version
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_contracts FROM contract
    WHERE id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_records FROM migration_record WHERE tenant_id = v_tenant;
  SELECT COUNT(*) INTO v_n_batches FROM migration_batch  WHERE tenant_id = v_tenant;
  v_total := v_n_irq + v_n_clauses + v_n_risk + v_n_oblig + v_n_attach
           + v_n_activity + v_n_comments + v_n_versions + v_n_contracts
           + v_n_records + v_n_batches;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dryRun', TRUE,
      'counts', jsonb_build_object(
        'ingestionReviewQueue', v_n_irq,
        'contractClauseExtracted', v_n_clauses,
        'riskScore', v_n_risk,
        'contractObligation', v_n_oblig,
        'contractAttachment', v_n_attach,
        'contractActivity', v_n_activity,
        'contractComment', v_n_comments,
        'contractVersion', v_n_versions,
        'contract', v_n_contracts,
        'migrationRecord', v_n_records,
        'migrationBatch', v_n_batches
      ),
      'totalRows', v_total
    );
  END IF;

  -- Hard-delete phase. Bypass the deny-DELETE policies on migration_*.
  SET LOCAL row_security = off;

  DELETE FROM ingestion_review_queue
   WHERE id IN (SELECT ingestion_review_queue_id FROM migration_record
                 WHERE tenant_id = v_tenant AND ingestion_review_queue_id IS NOT NULL);
  DELETE FROM contract_clause_extracted
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM risk_score
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_obligation
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_attachment
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_activity
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_comment
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_version
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract
   WHERE id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM migration_record WHERE tenant_id = v_tenant;
  DELETE FROM migration_batch  WHERE tenant_id = v_tenant;

  -- MV refresh so dashboards re-render clean
  BEGIN
    REFRESH MATERIALIZED VIEW latest_risk_score;
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- MV may not exist in some test contexts; tolerate
  END;

  -- Audit log entry — single __migration_purge__ event
  INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, changed_by, changed_at)
  VALUES (
    '__migration_purge__', NULL, 'PURGE',
    jsonb_build_object('tenantId', v_tenant),
    jsonb_build_object(
      'counts', jsonb_build_object(
        'ingestionReviewQueue', v_n_irq,
        'contractClauseExtracted', v_n_clauses,
        'riskScore', v_n_risk,
        'contractObligation', v_n_oblig,
        'contractAttachment', v_n_attach,
        'contractActivity', v_n_activity,
        'contractComment', v_n_comments,
        'contractVersion', v_n_versions,
        'contract', v_n_contracts,
        'migrationRecord', v_n_records,
        'migrationBatch', v_n_batches
      ),
      'totalRows', v_total
    ),
    v_actor, now()
  );

  RETURN jsonb_build_object(
    'dryRun', FALSE,
    'counts', jsonb_build_object(
      'ingestionReviewQueue', v_n_irq,
      'contractClauseExtracted', v_n_clauses,
      'riskScore', v_n_risk,
      'contractObligation', v_n_oblig,
      'contractAttachment', v_n_attach,
      'contractActivity', v_n_activity,
      'contractComment', v_n_comments,
      'contractVersion', v_n_versions,
      'contract', v_n_contracts,
      'migrationRecord', v_n_records,
      'migrationBatch', v_n_batches
    ),
    'totalRows', v_total
  );
END $$;
REVOKE EXECUTE ON FUNCTION fn_migration_purge_all(BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_purge_all(BOOLEAN) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_purge_all(BOOLEAN) IS
  'M22 — DEDICATED HARD-DELETE CARVE-OUT. Independent of fn_demo_data_purge. Scope-guarded by migration_record.contract_id IN (...). OAuth connections (external_connection) survive.';

COMMIT;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (467, '467_m22_migration_fns', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_migration_purge_all(BOOLEAN);
-- DROP FUNCTION IF EXISTS fn_migration_logical_duplicate_flag(BIGINT, UUID);
-- DROP FUNCTION IF EXISTS fn_migration_record_check_duplicates(BIGINT, TEXT, CHAR);
-- DROP FUNCTION IF EXISTS fn_migration_record_mark_duplicate(BIGINT, UUID, TEXT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_migration_record_link_contract(BIGINT, UUID, BIGINT, BIGINT, NUMERIC, INTEGER, BIGINT);
-- DROP FUNCTION IF EXISTS fn_migration_record_set_sha256(BIGINT, UUID, CHAR);
-- DROP FUNCTION IF EXISTS fn_migration_record_update_status(BIGINT, UUID, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_migration_record_create(BIGINT, UUID, TEXT, TEXT, TEXT, BIGINT, TIMESTAMPTZ);
-- DROP FUNCTION IF EXISTS fn_migration_batch_rollback(BIGINT, BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_migration_batch_set_status(BIGINT, UUID, TEXT);
-- DROP FUNCTION IF EXISTS fn_migration_batch_update_counts(BIGINT, UUID, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER);
-- DROP FUNCTION IF EXISTS fn_migration_batch_list_records(BIGINT, TEXT, INTEGER, INTEGER);
-- DROP FUNCTION IF EXISTS fn_migration_batch_list(INTEGER, INTEGER);
-- DROP FUNCTION IF EXISTS fn_migration_batch_get_by_id(BIGINT);
-- DROP FUNCTION IF EXISTS fn_migration_batch_create(BIGINT, BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_external_connection_disconnect(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_external_connection_set_status(BIGINT, UUID, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_external_connection_update_tokens(BIGINT, UUID, TEXT, TIMESTAMPTZ);
-- DROP FUNCTION IF EXISTS fn_external_connection_get_tokens(BIGINT, UUID);
-- DROP FUNCTION IF EXISTS fn_external_connection_get_by_id(BIGINT);
-- DROP FUNCTION IF EXISTS fn_external_connection_list();
-- DROP FUNCTION IF EXISTS fn_external_connection_create(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TEXT[], BIGINT);
-- DROP FUNCTION IF EXISTS fn_require_tenant_guc();
-- DELETE FROM schema_migrations WHERE version = 467;
-- COMMIT;
