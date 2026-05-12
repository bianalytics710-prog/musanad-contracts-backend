-- ============================================================
-- Migration 137 — CRD0 ingestion_functions
-- ============================================================
-- Module:      M11 — Document Ingestion Pipeline (CR-D0)
-- Description: CREATE OR REPLACE 7 net-new fn_'s for document ingestion pipeline.
--              Each carries explicit ERRCODE on every RAISE (S2-25),
--              WHEN OTHERS USING ERRCODE = SQLSTATE (S2-26),
--              COMMENT ON FUNCTION (S2-27), and REVOKE/GRANT trio (B14 / S2-21).
--              ZERO net-new PUBLIC EXECUTE — TWELFTH consecutive clean module.
--
-- Functions (in order):
--   1. fn_contract_version_ingest(BIGINT)          — DEFINER, idempotent queue
--   2. fn_contract_version_ingestion_complete(...)  — DEFINER, marks complete + NOTIFY
--   3. fn_contract_version_ingestion_fail(...)      — DEFINER, marks failed + NOTIFY
--   4. fn_contract_version_ingestion_status(BIGINT) — INVOKER STABLE, status read
--   5. fn_ingestion_review_queue_record(...)         — DEFINER, worker INSERT path
--   6. fn_ingestion_review_queue_list(...)           — INVOKER STABLE, paginated list
--   7. fn_ingestion_review_resolve(...)              — INVOKER, confirm/correct/reject
--
-- Patches applied from QA Stage 3:
--   F-S2-22 patch (patch 1): fn_ingestion_review_queue_list uses c.title_en +
--              c.title_ar (NOT c.title — column does not exist on contract table).
--              JSONB keys: 'contractTitleEn' + 'contractTitleAr'.
--   F-S2-9 patch (patch 2): Applied in 133 (extracted_text_uri added as 5th
--              redact entry, 32 → 37). This migration fn bodies do NOT repeat that.
--
-- SOT: §9 CR-D0, OPEN-DECISION-L Path A, S2-17 (concurrency primitives),
--      S2-21 (zero PUBLIC EXECUTE), S2-22b (JOIN-target column tracing).
-- ============================================================

BEGIN;

-- ============================================================
-- 1. fn_contract_version_ingest(BIGINT) — DEFINER
--    SECURITY: DEFINER (bypasses RLS on contract_version — matches M2 + M4 pattern)
--    PURPOSE: Idempotent state-flip pending|failed|partial → extracting.
--             Returns alreadyInProgress=TRUE when already extracting or complete.
--    STORIES: S1, S6, S7. ACs: AC-S1-01, AC-S1-05, AC-S6-04.
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
  UPDATE contract_version
     SET ingestion_status        = 'extracting',
         ingestion_error         = NULL,
         extracted_at            = NULL,
         ingestion_attempt_count = COALESCE(ingestion_attempt_count, 0) + 1,
         updated_at              = CURRENT_TIMESTAMP
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
  'CR-D0 §9 — DEFINER. Idempotent state-flip pending|failed|partial → extracting on contract_version. Caller must hold document.ingest permission (system-only per OPEN-DECISION-L Path A). Increments ingestion_attempt_count on each call (Q5 retry counter). Returns alreadyInProgress=TRUE when current status IN (extracting, complete) without mutating the row.';
REVOKE EXECUTE ON FUNCTION fn_contract_version_ingest(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_version_ingest(BIGINT) TO neondb_owner;

-- ============================================================
-- 2. fn_contract_version_ingestion_complete(BIGINT, TEXT, INTEGER, BOOLEAN, NUMERIC, TEXT)
--    SECURITY: DEFINER
--    PURPOSE: Marks ingestion complete. Records artifact URI + telemetry.
--             Emits pg_notify('contract_ingested').
--    STORIES: S1, S2, S3, S4, S5, S7.
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
  UPDATE contract_version
     SET extracted_text_uri  = p_extracted_text_uri,
         page_count          = p_page_count,
         ocr_used            = p_ocr_used,
         ocr_confidence_avg  = p_ocr_confidence_avg,
         extraction_engine   = p_extraction_engine,
         ingestion_status    = 'complete',
         ingestion_error     = NULL,
         extracted_at        = CURRENT_TIMESTAMP,
         updated_at          = CURRENT_TIMESTAMP
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
  'CR-D0 §9 — DEFINER. Marks contract_version ingestion complete + records artifact URI + per-engine telemetry. Emits pg_notify(''contract_ingested'') with {contractVersionId, tenantId} for CR-D consumer. CHECK constraint on extraction_engine enforced (digital_pdf/tesseract/gpt4o_vision/mammoth_docx/mixed); ocr_confidence_avg required when ocr_used=TRUE.';
REVOKE EXECUTE ON FUNCTION fn_contract_version_ingestion_complete(BIGINT, TEXT, INTEGER, BOOLEAN, NUMERIC, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_version_ingestion_complete(BIGINT, TEXT, INTEGER, BOOLEAN, NUMERIC, TEXT) TO neondb_owner;

-- ============================================================
-- 3. fn_contract_version_ingestion_fail(BIGINT, TEXT) — DEFINER
--    SECURITY: DEFINER
--    PURPOSE: Marks ingestion failed. Records SENSITIVE error message (truncated).
--             Emits pg_notify('ingestion_failed').
--    STORIES: S6. ACs: AC-S6-01, AC-S6-02, AC-S6-05.
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
  UPDATE contract_version
     SET ingestion_status = 'failed',
         ingestion_error  = v_error,
         extracted_at     = CURRENT_TIMESTAMP,
         updated_at       = CURRENT_TIMESTAMP
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
  'CR-D0 §9 — DEFINER. Marks ingestion failed + records SENSITIVE error message (truncated to 2000 chars). Emits pg_notify(''ingestion_failed'') for admin-notification rendering. Q5 retry policy: service layer reads attemptCount and decides whether to re-queue or terminal-fail (>=2 = terminal).';
REVOKE EXECUTE ON FUNCTION fn_contract_version_ingestion_fail(BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_version_ingestion_fail(BIGINT, TEXT) TO neondb_owner;

-- ============================================================
-- 4. fn_contract_version_ingestion_status(BIGINT) — INVOKER STABLE
--    SECURITY: INVOKER (RLS via M1a contract_version_select_parent_aware)
--    PURPOSE: Returns current ingestion status for a single contract_version.
--             Returns NULL on not-found/RLS-invisible (controller maps to 404).
--    STORIES: S1, S6, S7, S8, S9.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_contract_version_ingestion_status(
  p_contract_version_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row RECORD;
  v_low_confidence_count INTEGER;
BEGIN
  -- S2-24: subquery for lowConfidencePageCount — NOT nested aggregate inside jsonb_build_object.
  SELECT
    cv.id,
    cv.ingestion_status,
    cv.ingestion_error,
    cv.page_count,
    cv.ocr_used,
    cv.ocr_confidence_avg,
    cv.extraction_engine,
    cv.extracted_at,
    cv.extracted_text_uri,
    (SELECT COUNT(*)::INTEGER
       FROM ingestion_review_queue q
      WHERE q.contract_version_id = cv.id
        AND q.review_status IN ('pending_auto','pending_human')
        AND q.is_active = TRUE) AS low_confidence_page_count
    INTO v_row
    FROM contract_version cv
   WHERE cv.id = p_contract_version_id;

  IF NOT FOUND THEN
    RETURN NULL;  -- controller returns 404 (graceful, no P0002)
  END IF;

  RETURN jsonb_build_object(
    'contractVersionId',      v_row.id,
    'ingestionStatus',        v_row.ingestion_status,
    'ingestionError',         v_row.ingestion_error,
    'pageCount',              v_row.page_count,
    'ocrUsed',                v_row.ocr_used,
    'ocrConfidenceAvg',       v_row.ocr_confidence_avg,
    'extractionEngine',       v_row.extraction_engine,
    'extractedAt',            v_row.extracted_at,
    'extractedTextUri',       v_row.extracted_text_uri,
    'lowConfidencePageCount', v_row.low_confidence_page_count
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_contract_version_ingestion_status: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_contract_version_ingestion_status(BIGINT) IS
  'CR-D0 §9 — INVOKER STABLE. Returns ingestion status for a contract_version. RLS via M1a contract_version_select_parent_aware + 134 ingestion_review_queue_tenant_select. Returns NULL on not-found / RLS-invisible (controller maps to 404). Permission inherited via contract.read.* ladder (caller already sees the parent contract).';
REVOKE EXECUTE ON FUNCTION fn_contract_version_ingestion_status(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_contract_version_ingestion_status(BIGINT) TO neondb_owner;

-- ============================================================
-- 5. fn_ingestion_review_queue_record(UUID, BIGINT, INTEGER, NUMERIC, TEXT, TEXT, BOOLEAN, TEXT)
--    SECURITY: DEFINER (system-context worker INSERT under document.ingest gate)
--    PURPOSE: Worker INSERT path into ingestion_review_queue. Bypasses FORCE RLS.
--             Idempotent on UNIQUE(tenant_id, contract_version_id, page_no).
--    STORIES: S2, S3 (worker INSERT path).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_ingestion_review_queue_record(
  p_tenant_id             UUID,
  p_contract_version_id   BIGINT,
  p_page_no               INTEGER,
  p_tesseract_confidence  NUMERIC,
  p_tesseract_text        TEXT,
  p_gpt4o_text            TEXT,
  p_gpt4o_used            BOOLEAN,
  p_initial_review_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id       BIGINT;
  v_cv_id    BIGINT;
  v_page     INTEGER;
  v_status   TEXT;
  v_created  TIMESTAMPTZ;
BEGIN
  -- 1. Permission gate (system-context only)
  IF NOT fn_current_user_has_permission('document.ingest') THEN
    RAISE EXCEPTION 'fn_ingestion_review_queue_record: permission_denied: document.ingest required'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Input validation
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_ingestion_review_queue_record: tenantId:required'
      USING ERRCODE = '22023';
  END IF;

  IF p_initial_review_status NOT IN ('pending_auto','pending_human') THEN
    RAISE EXCEPTION 'fn_ingestion_review_queue_record: initialReviewStatus:invalid — must be pending_auto or pending_human'
      USING ERRCODE = '22023';
  END IF;

  -- 3. FK pre-validation (S2-23 — both tenant + version)
  PERFORM 1 FROM tenant WHERE id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_ingestion_review_queue_record: tenantId:tenant not found'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM 1 FROM contract_version WHERE id = p_contract_version_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_ingestion_review_queue_record: contractVersionId:contract_version not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- 4. UPSERT on UNIQUE(tenant_id, contract_version_id, page_no)
  INSERT INTO ingestion_review_queue (
    tenant_id, contract_version_id, page_no,
    tesseract_confidence, tesseract_text, gpt4o_text, gpt4o_used,
    review_status, data_classification
  ) VALUES (
    p_tenant_id, p_contract_version_id, p_page_no,
    p_tesseract_confidence, p_tesseract_text, p_gpt4o_text, p_gpt4o_used,
    p_initial_review_status,
    'demo'  -- worker default; service layer can later promote
  )
  ON CONFLICT (tenant_id, contract_version_id, page_no) DO UPDATE
    SET tesseract_confidence = EXCLUDED.tesseract_confidence,
        tesseract_text       = EXCLUDED.tesseract_text,
        gpt4o_text           = EXCLUDED.gpt4o_text,
        gpt4o_used           = EXCLUDED.gpt4o_used,
        review_status        = EXCLUDED.review_status,
        updated_at           = CURRENT_TIMESTAMP
  RETURNING id, contract_version_id, page_no, review_status, created_at
  INTO v_id, v_cv_id, v_page, v_status, v_created;

  -- 5. Return
  RETURN jsonb_build_object(
    'id',               v_id,
    'contractVersionId', v_cv_id,
    'pageNo',           v_page,
    'reviewStatus',     v_status,
    'createdAt',        v_created
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_ingestion_review_queue_record: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_ingestion_review_queue_record(UUID, BIGINT, INTEGER, NUMERIC, TEXT, TEXT, BOOLEAN, TEXT) IS
  'CR-D0 §9 — DEFINER worker INSERT path. Bypasses FORCE RLS for system-context queue writes. Idempotent on UNIQUE(tenant_id, contract_version_id, page_no) — duplicate worker calls UPDATE in place. Permission: document.ingest (system-only).';
REVOKE EXECUTE ON FUNCTION fn_ingestion_review_queue_record(UUID, BIGINT, INTEGER, NUMERIC, TEXT, TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_ingestion_review_queue_record(UUID, BIGINT, INTEGER, NUMERIC, TEXT, TEXT, BOOLEAN, TEXT) TO neondb_owner;

-- ============================================================
-- 6. fn_ingestion_review_queue_list(INTEGER, INTEGER, TEXT, BIGINT, BOOLEAN)
--    SECURITY: INVOKER STABLE (RLS narrows by tenant_id GUC)
--    PURPOSE: Paginated reviewer worklist + admin monitor.
--    PATCH F-S2-22: contractTitleEn + contractTitleAr (NOT contractTitle).
--             JOIN: ingestion_review_queue → contract_version → contract.title_en / title_ar
--             (contract_version has NO title column — S2-22b).
--    STORIES: S9, S11.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_ingestion_review_queue_list(
  p_page                INTEGER  DEFAULT 1,
  p_limit               INTEGER  DEFAULT 20,
  p_review_status       TEXT     DEFAULT NULL,
  p_contract_version_id BIGINT   DEFAULT NULL,
  p_gpt4o_used          BOOLEAN  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_page   INTEGER;
  v_limit  INTEGER;
  v_offset INTEGER;
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  -- 1. Permission gate (defence-in-depth on top of RLS)
  IF NOT (fn_current_user_has_permission('document.review')
       OR fn_current_user_has_permission('ingestion_queue.read')) THEN
    RAISE EXCEPTION 'fn_ingestion_review_queue_list: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Input clamping
  v_page  := GREATEST(1, COALESCE(p_page, 1));
  v_limit := LEAST(100, GREATEST(1, COALESCE(p_limit, 20)));
  v_offset := (v_page - 1) * v_limit;

  -- 3. COUNT total (RLS narrows automatically)
  SELECT COUNT(*) INTO v_total
    FROM ingestion_review_queue q
   WHERE q.is_active = TRUE
     AND (p_review_status       IS NULL OR q.review_status       = p_review_status)
     AND (p_contract_version_id IS NULL OR q.contract_version_id = p_contract_version_id)
     AND (p_gpt4o_used          IS NULL OR q.gpt4o_used          = p_gpt4o_used);

  -- 4. SELECT page — S2-22b: JOIN-target column tracing.
  --    contract_version has NO 'title' column.
  --    Path: ingestion_review_queue → contract_version → contract.title_en / title_ar.
  --    F-S2-22 patch: JSONB keys are 'contractTitleEn' + 'contractTitleAr'.
  --    S2-24: jsonb_agg over inner subquery (NOT nested aggregate).
  SELECT jsonb_agg(
           jsonb_build_object(
             'id',                  q.id,
             'contractVersionId',   q.contract_version_id,
             'contractTitleEn',     c.title_en,
             'contractTitleAr',     c.title_ar,
             'pageNo',              q.page_no,
             'tesseractConfidence', q.tesseract_confidence,
             'gpt4oUsed',           q.gpt4o_used,
             'reviewStatus',        q.review_status,
             'reviewedByName',      concat_ws(' ', NULLIF(u.first_name,''), NULLIF(u.last_name,'')),
             'reviewedAt',          q.reviewed_at,
             'createdAt',           q.created_at,
             'dataClassification',  q.data_classification,
             'tenantId',            q.tenant_id
           )
           ORDER BY
             CASE q.review_status
               WHEN 'pending_auto'  THEN 1
               WHEN 'pending_human' THEN 2
               WHEN 'resolved'      THEN 3
               WHEN 'rejected'      THEN 4
             END,
             q.created_at DESC
         ) INTO v_data
    FROM (
           SELECT q2.*
             FROM ingestion_review_queue q2
            WHERE q2.is_active = TRUE
              AND (p_review_status       IS NULL OR q2.review_status       = p_review_status)
              AND (p_contract_version_id IS NULL OR q2.contract_version_id = p_contract_version_id)
              AND (p_gpt4o_used          IS NULL OR q2.gpt4o_used          = p_gpt4o_used)
            ORDER BY
              CASE q2.review_status
                WHEN 'pending_auto'  THEN 1
                WHEN 'pending_human' THEN 2
                WHEN 'resolved'      THEN 3
                WHEN 'rejected'      THEN 4
              END,
              q2.created_at DESC
            LIMIT  v_limit
            OFFSET v_offset
         ) q
    LEFT JOIN contract_version cv ON cv.id = q.contract_version_id
    LEFT JOIN contract         c  ON c.id  = cv.contract_id
    LEFT JOIN "user"           u  ON u.id  = q.reviewed_by;

  -- 5. Return
  RETURN jsonb_build_object(
    'data',       COALESCE(v_data, '[]'::jsonb),
    'pagination', jsonb_build_object(
                    'total',      v_total,
                    'page',       v_page,
                    'limit',      v_limit,
                    'totalPages', CASE WHEN v_limit = 0 THEN 0
                                       ELSE CEIL(v_total::NUMERIC / v_limit)::INTEGER
                                  END
                  )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_ingestion_review_queue_list: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_ingestion_review_queue_list(INTEGER, INTEGER, TEXT, BIGINT, BOOLEAN) IS
  'CR-D0 §9 — INVOKER STABLE. Paginated reviewer worklist + admin monitor view of ingestion_review_queue. Default sort: pending_auto > pending_human > resolved > rejected, then created_at DESC. RLS narrows by tenant_id GUC; permission gate document.review OR ingestion_queue.read. F-S2-22 patch: contractTitleEn + contractTitleAr sourced via JOIN contract_version → contract.title_en/title_ar (contract_version has no title column — S2-22b).';
REVOKE EXECUTE ON FUNCTION fn_ingestion_review_queue_list(INTEGER, INTEGER, TEXT, BIGINT, BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_ingestion_review_queue_list(INTEGER, INTEGER, TEXT, BIGINT, BOOLEAN) TO neondb_owner;

-- ============================================================
-- 7. fn_ingestion_review_resolve(BIGINT, TEXT, TEXT, BIGINT) — INVOKER
--    SECURITY: INVOKER (RLS narrows by tenant_id GUC + permission)
--    PURPOSE: Reviewer (legal_counsel/platform_admin) confirms/corrects/rejects
--             a low-confidence page.
--    STORIES: S10, S11. ACs: AC-S10-01..07, AC-S11-02.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_ingestion_review_resolve(
  p_queue_id       BIGINT,
  p_action         TEXT,
  p_corrected_text TEXT,
  p_actor_id       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id         BIGINT;
  v_status     TEXT;
  v_tesseract  TEXT;
  v_gpt4o      TEXT;
  v_is_active  BOOLEAN;
  v_final      TEXT;
BEGIN
  -- 1. Permission gate (explicit check for clean error — RLS handles narrowing separately)
  IF NOT fn_current_user_has_permission('document.review') THEN
    RAISE EXCEPTION 'fn_ingestion_review_resolve: permission_denied: document.review required'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Action allowlist (S2-25)
  IF p_action NOT IN ('confirm','correct','reject') THEN
    RAISE EXCEPTION 'fn_ingestion_review_resolve: action:invalid action — must be confirm, correct, or reject'
      USING ERRCODE = '22023';
  END IF;

  -- 3. Action-specific input validation
  IF p_action = 'correct' AND (p_corrected_text IS NULL OR length(trim(p_corrected_text)) = 0) THEN
    RAISE EXCEPTION 'fn_ingestion_review_resolve: correctedText:corrected_text required for correct action'
      USING ERRCODE = '22023';
  END IF;

  -- 4. FK pre-validation + RLS-narrow lookup (S2-23 + S2-22b)
  --    SELECT under RLS automatically narrows by tenant_id; if invisible, NOT FOUND fires.
  SELECT q.id, q.review_status, q.tesseract_text, q.gpt4o_text, q.is_active
    INTO v_id, v_status, v_tesseract, v_gpt4o, v_is_active
    FROM ingestion_review_queue q
   WHERE q.id = p_queue_id
  FOR UPDATE;

  IF NOT FOUND OR v_is_active = FALSE THEN
    RAISE EXCEPTION 'fn_ingestion_review_resolve: queueId:review queue item not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- 5. State guard (already-resolved → 409 via BE "reviewStatus:" prefix translation)
  IF v_status NOT IN ('pending_auto','pending_human') THEN
    RAISE EXCEPTION 'fn_ingestion_review_resolve: reviewStatus:queue item already resolved'
      USING ERRCODE = '22023';
  END IF;

  -- 6. Resolve — set final_text + new review_status
  IF p_action = 'confirm' THEN
    v_final  := COALESCE(v_gpt4o, v_tesseract);
    v_status := 'resolved';
  ELSIF p_action = 'correct' THEN
    v_final  := p_corrected_text;
    v_status := 'resolved';
  ELSIF p_action = 'reject' THEN
    v_final  := NULL;
    v_status := 'rejected';
  END IF;

  -- 7. UPDATE (RLS WITH CHECK enforces tenant_id+permission on write)
  UPDATE ingestion_review_queue
     SET final_text    = v_final,
         review_status = v_status,
         reviewed_by   = p_actor_id,
         reviewed_at   = CURRENT_TIMESTAMP,
         updated_by    = p_actor_id,
         updated_at    = CURRENT_TIMESTAMP
   WHERE id = p_queue_id;

  -- 8. Return
  RETURN jsonb_build_object(
    'queueId',      p_queue_id,
    'reviewStatus', v_status,
    'finalText',    v_final,
    'reviewedAt',   CURRENT_TIMESTAMP
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_ingestion_review_resolve: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_ingestion_review_resolve(BIGINT, TEXT, TEXT, BIGINT) IS
  'CR-D0 §9 — INVOKER. Reviewer-driven resolution of an ingestion_review_queue page (confirm/correct/reject). Permission: document.review (legal_counsel/platform_admin). RLS narrows visibility by tenant. P0002 fires on RLS-invisible IDs (tenant isolation). Already-resolved rows raise 22023 with "reviewStatus:" prefix → BE translates to HTTP 409.';
REVOKE EXECUTE ON FUNCTION fn_ingestion_review_resolve(BIGINT, TEXT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_ingestion_review_resolve(BIGINT, TEXT, TEXT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (137, 'crd0_ingestion_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_ingestion_review_resolve(BIGINT, TEXT, TEXT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_ingestion_review_queue_list(INTEGER, INTEGER, TEXT, BIGINT, BOOLEAN);
-- DROP FUNCTION IF EXISTS fn_ingestion_review_queue_record(UUID, BIGINT, INTEGER, NUMERIC, TEXT, TEXT, BOOLEAN, TEXT);
-- DROP FUNCTION IF EXISTS fn_contract_version_ingestion_status(BIGINT);
-- DROP FUNCTION IF EXISTS fn_contract_version_ingestion_fail(BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_contract_version_ingestion_complete(BIGINT, TEXT, INTEGER, BOOLEAN, NUMERIC, TEXT);
-- DROP FUNCTION IF EXISTS fn_contract_version_ingest(BIGINT);
-- DELETE FROM schema_migrations WHERE version = 137;
-- COMMIT;
-- ROLLBACK END
