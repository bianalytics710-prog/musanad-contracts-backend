-- ============================================================
-- Migration 132 — CRD0 extend_contract_version
-- ============================================================
-- Module:      M11 — Document Ingestion Pipeline (CR-D0)
-- Description: ALTER TABLE contract_version ADD 9 columns for OCR / ingestion
--              pipeline (§4.11 OCR strategy). 5 CHECK constraints. 2 partial
--              indexes. 9 COMMENT ON COLUMN statements.
--              Columns: extracted_text_uri, ocr_used, ocr_confidence_avg,
--                        page_count, ingestion_status, ingestion_error,
--                        extraction_engine, extracted_at, ingestion_attempt_count.
-- Backward compatibility: All 9 columns are NULL or have safe DEFAULT values.
--   M1a fn_contract_version_create uses explicit column list → DEFAULTs apply.
--   Net-new contract_version rows enter ingestion_status='pending' automatically.
-- SOT: §4.11, §9 CR-D0, §16 Engineering Safety.
-- ============================================================

BEGIN;

ALTER TABLE contract_version
  ADD COLUMN IF NOT EXISTS extracted_text_uri      TEXT,
  ADD COLUMN IF NOT EXISTS ocr_used                BOOLEAN     NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS ocr_confidence_avg      NUMERIC(3,2),
  ADD COLUMN IF NOT EXISTS page_count              INTEGER,
  ADD COLUMN IF NOT EXISTS ingestion_status        TEXT        NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS ingestion_error         TEXT,
  ADD COLUMN IF NOT EXISTS extraction_engine       TEXT,
  ADD COLUMN IF NOT EXISTS extracted_at            TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ingestion_attempt_count INTEGER     NOT NULL DEFAULT 0;

-- CHECK constraints (enum-of-5 for status + engine; range for confidence + page_count + retry counter)
ALTER TABLE contract_version
  ADD CONSTRAINT contract_version_ingestion_status_check
    CHECK (ingestion_status IN ('pending','extracting','complete','failed','partial')),
  ADD CONSTRAINT contract_version_extraction_engine_check
    CHECK (extraction_engine IS NULL
           OR extraction_engine IN ('digital_pdf','tesseract','gpt4o_vision','mammoth_docx','mixed')),
  ADD CONSTRAINT contract_version_ocr_confidence_avg_range
    CHECK (ocr_confidence_avg IS NULL
           OR (ocr_confidence_avg >= 0.00 AND ocr_confidence_avg <= 1.00)),
  ADD CONSTRAINT contract_version_page_count_nonneg
    CHECK (page_count IS NULL OR page_count >= 0),
  ADD CONSTRAINT contract_version_ingestion_attempt_count_nonneg
    CHECK (ingestion_attempt_count >= 0);

-- Partial index 1: worker pickup loop (pending + extracting rows only)
CREATE INDEX IF NOT EXISTS idx_contract_version_ingestion_pending
  ON contract_version(id)
  WHERE ingestion_status IN ('pending','extracting');

-- Partial index 2: FE Document tab + CR-D pre-flight (rows with extracted text only)
CREATE INDEX IF NOT EXISTS idx_contract_version_extracted_text_uri
  ON contract_version(id)
  WHERE extracted_text_uri IS NOT NULL;

-- COMMENT ON COLUMN (9 — S2-27 + A4 standards)
COMMENT ON COLUMN contract_version.extracted_text_uri IS
  'CR-D0 §4.11. SENSITIVE — Supabase Storage path; signed URLs only, never log raw URI. Listed in fn_audit_trigger redact list (133) AND src/utils/logger.util.ts Pino redact paths (BE A8). Path schema: <tenantId>/<contractId>/v<n>/<uuid>.txt — UUID suffix prevents same-version retry overwrite (N12 / NAMING-CONFLICT-2).';
COMMENT ON COLUMN contract_version.ocr_used IS
  'CR-D0 §4.11. TRUE if Tesseract or gpt-4o Vision was invoked on any page; FALSE for digital_pdf and mammoth_docx paths.';
COMMENT ON COLUMN contract_version.ocr_confidence_avg IS
  'CR-D0 §4.11. NUMERIC(3,2) [0.00..1.00] — arithmetic mean of per-page Tesseract confidence. NULL when ocr_used=FALSE. Validated by fn_contract_version_ingestion_complete + CHECK constraint.';
COMMENT ON COLUMN contract_version.page_count IS
  'CR-D0 §4.11. >= 0 INTEGER. For mammoth_docx: section count or 1 (AC-S4-03/04). For PDF paths: pdfjs-dist page count.';
COMMENT ON COLUMN contract_version.ingestion_status IS
  'CR-D0 §4.11. enum-of-5: pending / extracting / complete / failed / partial. Lifecycle: pending → extracting → (complete | failed | partial). partial reserved for retry-budget exhaustion (Q5 / N5). Worker reads on pickup; FE polls via fn_contract_version_ingestion_status.';
COMMENT ON COLUMN contract_version.ingestion_error IS
  'CR-D0 §4.11. SENSITIVE — may contain partial extracted text or stack traces. Listed in fn_audit_trigger redact list (133) AND Pino redact paths. Capped to 2000 chars by fn_contract_version_ingestion_fail (defensive truncation against large stack traces).';
COMMENT ON COLUMN contract_version.extraction_engine IS
  'CR-D0 §4.11. enum-of-5: digital_pdf / tesseract / gpt4o_vision / mammoth_docx / mixed. Set on completion. mixed = at least one Tesseract page + at least one gpt-4o page (AC-S2-03).';
COMMENT ON COLUMN contract_version.extracted_at IS
  'CR-D0 §4.11. Timestamp of extraction completion (or terminal failure). NULL while pending / extracting.';
COMMENT ON COLUMN contract_version.ingestion_attempt_count IS
  'CR-D0 §4.11 / N15 / Q5. INTEGER >= 0. Worker increments on each retry; fn_contract_version_ingestion_fail reads it and decides terminal failure when attempts >= 2 (retry-2x-then-fail). Survives worker restart.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (132, 'crd0_extend_contract_version', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- ALTER TABLE contract_version
--   DROP CONSTRAINT IF EXISTS contract_version_ingestion_attempt_count_nonneg,
--   DROP CONSTRAINT IF EXISTS contract_version_page_count_nonneg,
--   DROP CONSTRAINT IF EXISTS contract_version_ocr_confidence_avg_range,
--   DROP CONSTRAINT IF EXISTS contract_version_extraction_engine_check,
--   DROP CONSTRAINT IF EXISTS contract_version_ingestion_status_check;
-- DROP INDEX IF EXISTS idx_contract_version_extracted_text_uri;
-- DROP INDEX IF EXISTS idx_contract_version_ingestion_pending;
-- ALTER TABLE contract_version
--   DROP COLUMN IF EXISTS ingestion_attempt_count,
--   DROP COLUMN IF EXISTS extracted_at,
--   DROP COLUMN IF EXISTS extraction_engine,
--   DROP COLUMN IF EXISTS ingestion_error,
--   DROP COLUMN IF EXISTS ingestion_status,
--   DROP COLUMN IF EXISTS page_count,
--   DROP COLUMN IF EXISTS ocr_confidence_avg,
--   DROP COLUMN IF EXISTS ocr_used,
--   DROP COLUMN IF EXISTS extracted_text_uri;
-- DELETE FROM schema_migrations WHERE version = 132;
-- COMMIT;
-- ROLLBACK END
