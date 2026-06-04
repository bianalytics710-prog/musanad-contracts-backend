-- Migration: 474_m22_fix_list_records.sql
-- Module: M22 — fix LIMIT+jsonb_agg conflict in fn_migration_batch_list_records
-- Date: 2026-06-02
--
-- The original (mig 467) had `ORDER BY id ASC LIMIT N` AFTER a `jsonb_agg`
-- aggregate, which Postgres rejects with "must appear in GROUP BY". The
-- aggregate already sorts inside; the outer ORDER BY + LIMIT need to be
-- applied via a subquery.

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

  -- LIMIT/OFFSET in subquery, aggregate after — avoids GROUP BY conflict.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', x.id, 'sourceFileId', x.source_file_id, 'sourceFileName', x.source_file_name,
    'sourceFileMime', x.source_file_mime, 'sourceFileSizeBytes', x.source_file_size_bytes,
    'sourceFileModifiedAt', x.source_file_modified_at,
    'sourceFileSha256', x.source_file_sha256, 'status', x.status,
    'duplicateOfRecordId', x.duplicate_of_record_id,
    'contractId', x.contract_id, 'contractVersionId', x.contract_version_id,
    'ingestionReviewQueueId', x.ingestion_review_queue_id,
    'confidenceScoreAvg', x.confidence_score_avg,
    'extractedFieldCount', x.extracted_field_count,
    'errorMessage', x.error_message, 'importedAt', x.imported_at,
    'createdAt', x.created_at
  ) ORDER BY x.id ASC), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM migration_record
    WHERE tenant_id = v_tenant AND migration_batch_id = p_batch_id
      AND (p_status IS NULL OR status = p_status)
    ORDER BY id ASC
    LIMIT p_limit OFFSET p_offset
  ) x;

  RETURN jsonb_build_object('rows', v_rows, 'total', v_total);
END $$;

REVOKE EXECUTE ON FUNCTION fn_migration_batch_list_records(BIGINT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_batch_list_records(BIGINT, TEXT, INTEGER, INTEGER) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_batch_list_records(BIGINT, TEXT, INTEGER, INTEGER) IS
  'M22 (474) — LIMIT/OFFSET applied via subquery so jsonb_agg does not collide with GROUP BY.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (474, '474_m22_fix_list_records', CURRENT_TIMESTAMP);
