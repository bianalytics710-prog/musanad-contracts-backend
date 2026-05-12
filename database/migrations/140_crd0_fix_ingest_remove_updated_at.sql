-- ============================================================
-- Migration 140 — CRD0 fix_ingest_remove_updated_at
-- ============================================================
-- Module:      M11 — Document Ingestion Pipeline (CR-D0)
-- Description: DEFECT-1 patch surfaced by Testing Agent.
--              fn_contract_version_ingest, fn_contract_version_ingestion_complete,
--              and fn_contract_version_ingestion_fail (all in migration 137)
--              referenced `updated_at = CURRENT_TIMESTAMP` / `updated_at = NOW()`
--              in their UPDATE SET lists on contract_version, which does NOT have
--              an updated_at column — it is an append-only table per
--              003_m1a_contracts.sql. Migration 132 (ADD 9 ingestion columns) also
--              did not add updated_at. All three UPDATEs therefore raised
--              PostgreSQL error 42703: column "updated_at" of relation
--              "contract_version" does not exist.
--
--              This migration CREATE OR REPLACEs those three fn_'s with
--              `updated_at = CURRENT_TIMESTAMP,` removed from the UPDATE SET lists.
--              ALL other behaviour — RAISE ERRCODEs, WHEN OTHERS USING ERRCODE =
--              SQLSTATE, COMMENT ON FUNCTION, REVOKE/GRANT trio, SET LOCAL
--              search_path, concurrency locks, idempotency guards, NOTIFY payloads —
--              is preserved byte-for-byte per feedback_fn_rewrites_lose_safety_guards.md.
--
-- Classification: DESIGN DEFECT (not regression). Agent 4 generated UPDATE bodies
--                 referencing a non-existent column on an append-only table.
--                 S2-22 column-existence check targets the inverse direction
--                 (JOIN target → source); this is the mutation target → schema
--                 direction. Captured as S2-22 inverse case lesson.
--
-- Affected functions (3 of 7 from migration 137):
--   1. fn_contract_version_ingest(BIGINT)
--   2. fn_contract_version_ingestion_complete(BIGINT, TEXT, INTEGER, BOOLEAN, NUMERIC, TEXT)
--   3. fn_contract_version_ingestion_fail(BIGINT, TEXT)
--
-- Unaffected functions (4 of 7 from migration 137 — no contract_version UPDATE):
--   4. fn_contract_version_ingestion_status(BIGINT)       — SELECT only
--   5. fn_ingestion_review_queue_record(...)               — UPSERTs ingestion_review_queue (has updated_at)
--   6. fn_ingestion_review_queue_list(...)                 — SELECT only
--   7. fn_ingestion_review_resolve(...)                    — UPDATEs ingestion_review_queue (has updated_at)
--
-- SOT: §9 CR-D0; §16 Engineering Safety (S2-22 inverse case).
-- ============================================================

BEGIN;

-- ============================================================
-- 1. fn_contract_version_ingest(BIGINT) — DEFINER
--    FIX: Removed `updated_at = CURRENT_TIMESTAMP,` from UPDATE SET (line ~87 in 137).
--         contract_version is append-only (003_m1a_contracts.sql); no updated_at column.
--    All else: identical to migration 137 body.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_contract_version_ingest(
  p_contract_version_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id            BIGINT;
  v_status        TEXT;
  v_extracted_at  TIMESTAMPTZ;
BEGIN
  -- 1. Permission gate (S2-21 + OPEN-DECISION-L Path A)
  IF NOT fn_current_user_has_permission('document.ingest') THEN
    RAISE EXCEPTION 'fn_contract_version_ingest: permission_denied: document.ingest required'
      USING ERRCODE = '42501';
  END IF;

  -- 2. FK pre-validation + concurrency lock (S2-23 + S2-17 SELECT FOR UPDATE)
  SELECT id, ingestion_status, extracted_at
    INTO v_id, v_status, v_extracted_at
    FROM contract_version
   WHERE id = p_contract_version_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_version_ingest: contract_version not found (id=%)', p_contract_version_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 3. Idempotency — already in flight or done
  IF v_status IN ('extracting','complete') THEN
    RETURN jsonb_build_object(
      'contractVersionId', v_id,
      'ingestionStatus',   v_status,
      'queuedAt',          v_extracted_at,
      'alreadyInProgress', TRUE
    );
  END IF;

  -- 4. Advance state (S2-22 — columns verified in migration 132)
  --    FIX: updated_at removed — contract_version is append-only (no updated_at column).
  UPDATE contract_version
     SET ingestion_status        = 'extracting',
         ingestion_error         = NULL,
         extracted_at            = NULL,
         ingestion_attempt_count = COALESCE(ingestion_attempt_count, 0) + 1
   WHERE id = p_contract_version_id;

  -- 5. Return
  RETURN jsonb_build_object(
    'contractVersionId', p_contract_version_id,
    'ingestionStatus',   'extracting',
    'queuedAt',          CURRENT_TIMESTAMP,
    'alreadyInProgress', FALSE
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_contract_version_ingest: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_contract_version_ingest(BIGINT) IS
  'CR-D0 §9 — DEFINER. Idempotent state-flip pending|failed|partial → extracting on contract_version. Caller must hold document.ingest permission (system-only per OPEN-DECISION-L Path A). Increments ingestion_attempt_count on each call (Q5 retry counter). Returns alreadyInProgress=TRUE when current status IN (extracting, complete) without mutating the row. Patched by migration 140: updated_at removed from UPDATE (contract_version is append-only).';
REVOKE EXECUTE ON FUNCTION fn_contract_version_ingest(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_version_ingest(BIGINT) TO neondb_owner;

-- ============================================================
-- 2. fn_contract_version_ingestion_complete(BIGINT, TEXT, INTEGER, BOOLEAN, NUMERIC, TEXT)
--    FIX: Removed `updated_at = CURRENT_TIMESTAMP,` from UPDATE SET (line ~196 in 137).
--         contract_version is append-only (003_m1a_contracts.sql); no updated_at column.
--    All else: identical to migration 137 body.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_contract_version_ingestion_complete(
  p_contract_version_id BIGINT,
  p_extracted_text_uri  TEXT,
  p_page_count          INTEGER,
  p_ocr_used            BOOLEAN,
  p_ocr_confidence_avg  NUMERIC,
  p_extraction_engine   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id            BIGINT;
  v_tenant_id     UUID;
  v_notify_emitted BOOLEAN := FALSE;
BEGIN
  -- 1. Permission gate
  IF NOT fn_current_user_has_permission('document.ingest') THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_complete: permission_denied: document.ingest required'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Input validation (S2-22 + S2-25)
  IF p_extracted_text_uri IS NULL OR length(trim(p_extracted_text_uri)) = 0 THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_complete: extractedTextUri:required'
      USING ERRCODE = '22023';
  END IF;

  IF p_page_count IS NULL OR p_page_count < 0 THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_complete: pageCount:must be >= 0'
      USING ERRCODE = '22023';
  END IF;

  IF p_extraction_engine NOT IN ('digital_pdf','tesseract','gpt4o_vision','mammoth_docx','mixed') THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_complete: extractionEngine:invalid extraction_engine value'
      USING ERRCODE = '22023';
  END IF;

  IF p_ocr_used IS TRUE AND p_ocr_confidence_avg IS NULL THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_complete: ocrConfidenceAvg:ocr_used=true requires ocr_confidence_avg'
      USING ERRCODE = '22023';
  END IF;

  IF p_ocr_confidence_avg IS NOT NULL
     AND (p_ocr_confidence_avg < 0.00 OR p_ocr_confidence_avg > 1.00) THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_complete: ocrConfidenceAvg:ocr_confidence_avg out of range'
      USING ERRCODE = '22023';
  END IF;

  -- 3. FK pre-validation (S2-23)
  SELECT id INTO v_id
    FROM contract_version
   WHERE id = p_contract_version_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_complete: contract_version not found (id=%)', p_contract_version_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 4. Hydrate tenant_id from GUC for NOTIFY payload (A24 / N18)
  BEGIN
    v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_tenant_id := NULL;
  END;

  -- 5. UPDATE — explicit column list (S2-19 + S2-22)
  --    FIX: updated_at removed — contract_version is append-only (no updated_at column).
  UPDATE contract_version
     SET extracted_text_uri  = p_extracted_text_uri,
         page_count          = p_page_count,
         ocr_used            = p_ocr_used,
         ocr_confidence_avg  = p_ocr_confidence_avg,
         extraction_engine   = p_extraction_engine,
         ingestion_status    = 'complete',
         ingestion_error     = NULL,
         extracted_at        = CURRENT_TIMESTAMP
   WHERE id = p_contract_version_id;

  -- 6. PG NOTIFY (consistent payload shape per S2-19)
  PERFORM pg_notify(
    'contract_ingested',
    (jsonb_build_object(
       'contractVersionId', p_contract_version_id,
       'tenantId',          v_tenant_id
     ))::text
  );
  v_notify_emitted := TRUE;

  -- 7. Return
  RETURN jsonb_build_object(
    'contractVersionId', p_contract_version_id,
    'ingestionStatus',   'complete',
    'extractedAt',       CURRENT_TIMESTAMP,
    'notifyEmitted',     v_notify_emitted
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_complete: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_contract_version_ingestion_complete(BIGINT, TEXT, INTEGER, BOOLEAN, NUMERIC, TEXT) IS
  'CR-D0 §9 — DEFINER. Marks contract_version ingestion complete + records artifact URI + per-engine telemetry. Emits pg_notify(''contract_ingested'') with {contractVersionId, tenantId} for CR-D consumer. CHECK constraint on extraction_engine enforced (digital_pdf/tesseract/gpt4o_vision/mammoth_docx/mixed); ocr_confidence_avg required when ocr_used=TRUE. Patched by migration 140: updated_at removed from UPDATE (contract_version is append-only).';
REVOKE EXECUTE ON FUNCTION fn_contract_version_ingestion_complete(BIGINT, TEXT, INTEGER, BOOLEAN, NUMERIC, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_version_ingestion_complete(BIGINT, TEXT, INTEGER, BOOLEAN, NUMERIC, TEXT) TO neondb_owner;

-- ============================================================
-- 3. fn_contract_version_ingestion_fail(BIGINT, TEXT) — DEFINER
--    FIX: Removed `updated_at = CURRENT_TIMESTAMP,` from UPDATE SET (line ~282 in 137).
--         contract_version is append-only (003_m1a_contracts.sql); no updated_at column.
--    All else: identical to migration 137 body.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_contract_version_ingestion_fail(
  p_contract_version_id BIGINT,
  p_error_message       TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id            BIGINT;
  v_attempt_count INTEGER;
  v_error         TEXT;
BEGIN
  -- 1. Permission gate
  IF NOT fn_current_user_has_permission('document.ingest') THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_fail: permission_denied: document.ingest required'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Input validation
  IF p_error_message IS NULL OR length(trim(p_error_message)) = 0 THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_fail: errorMessage:required'
      USING ERRCODE = '22023';
  END IF;

  -- 3. FK pre-validation + concurrency lock (S2-23 + S2-17)
  SELECT id, ingestion_attempt_count
    INTO v_id, v_attempt_count
    FROM contract_version
   WHERE id = p_contract_version_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_fail: contract_version not found (id=%)', p_contract_version_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 4. Truncate error to 2000 chars (defensive vs. large stack traces — SENSITIVE field)
  v_error := LEFT(p_error_message, 2000);

  -- 5. UPDATE
  --    FIX: updated_at removed — contract_version is append-only (no updated_at column).
  UPDATE contract_version
     SET ingestion_status = 'failed',
         ingestion_error  = v_error,
         extracted_at     = CURRENT_TIMESTAMP
   WHERE id = p_contract_version_id;

  -- 6. NOTIFY (BE listens for admin-notification rendering — Q5 retry-budget exhaustion)
  PERFORM pg_notify(
    'ingestion_failed',
    (jsonb_build_object(
       'contractVersionId', p_contract_version_id,
       'tenantId',          NULLIF(current_setting('app.current_tenant_id', true), '')::uuid,
       'attemptCount',      v_attempt_count
     ))::text
  );

  -- 7. Return
  RETURN jsonb_build_object(
    'contractVersionId', p_contract_version_id,
    'ingestionStatus',   'failed',
    'failedAt',          CURRENT_TIMESTAMP,
    'attemptCount',      v_attempt_count
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_fail: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_contract_version_ingestion_fail(BIGINT, TEXT) IS
  'CR-D0 §9 — DEFINER. Marks ingestion failed + records SENSITIVE error message (truncated to 2000 chars). Emits pg_notify(''ingestion_failed'') for admin-notification rendering. Q5 retry policy: service layer reads attemptCount and decides whether to re-queue or terminal-fail (>=2 = terminal). Patched by migration 140: updated_at removed from UPDATE (contract_version is append-only).';
REVOKE EXECUTE ON FUNCTION fn_contract_version_ingestion_fail(BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_version_ingestion_fail(BIGINT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (140, 'crd0_fix_ingest_remove_updated_at', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BLOCK
-- ============================================================
-- Note: Rolling back this migration would re-introduce the DEFECT-1 bug.
-- The correct rollback is to re-apply migration 137 (the source-of-truth body
-- minus this patch). No DROP is needed — CREATE OR REPLACE handles replacement.
-- Provided for documentation completeness only; do not execute in production.
--
-- BEGIN;
-- -- Re-apply migration 137 fn bodies (with the buggy updated_at lines) — not recommended.
-- DELETE FROM schema_migrations WHERE version = 140;
-- COMMIT;
-- ROLLBACK END
