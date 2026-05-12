-- ============================================================
-- Migration 138 — CRD0 mparity_backfill_prep
-- ============================================================
-- Module:      M11 — Document Ingestion Pipeline (CR-D0)
-- Description: OPEN-DECISION-M sub-option (b) — SQL-side prep ONLY.
--              Marks the 35 M_parity contracts' current contract_version row with:
--                extraction_engine   = 'digital_pdf'
--                ocr_used            = FALSE
--                ocr_confidence_avg  = NULL
--                page_count          = 1
--                ingestion_status    = 'pending'    ← TS script flips to 'complete'
--                extracted_text_uri  = NULL         ← TS script populates with Storage URI
--              Idempotency guard: only touches rows where
--                extraction_engine IS NULL AND ingestion_status IN ('pending').
--              The TS post-deploy script (src/scripts/backfill-m_parity-extracted-text.ts)
--              does the actual Storage upload + fn_contract_version_ingestion_complete call.
--
-- Survives clean-test-branch first-run AND repeated runs from any partial state
-- (per feedback_validate_runner_on_clean_db.md / X4).
--
-- SOT: §9 CR-D0, OPEN-DECISION-M, §7.5 seed data.
-- ============================================================

BEGIN;

UPDATE contract_version cv
   SET extraction_engine   = 'digital_pdf',
       ocr_used            = FALSE,
       ocr_confidence_avg  = NULL,
       page_count          = 1,
       ingestion_status    = 'pending',
       extracted_text_uri  = NULL,
       updated_at          = CURRENT_TIMESTAMP
 WHERE cv.id = (
         SELECT id FROM contract_version
          WHERE contract_id = cv.contract_id
          ORDER BY version_number DESC LIMIT 1
       )
   AND (cv.body_en IS NOT NULL OR cv.body_ar IS NOT NULL)
   AND cv.extraction_engine IS NULL          -- idempotency: already set → skip
   AND cv.ingestion_status IN ('pending');   -- default post-migration-132 state

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (138, 'crd0_mparity_backfill_prep', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- Manual reverse (no single safe rollback SQL — TS post-deploy script may have
-- already run and set ingestion_status='complete' on some rows):
-- BEGIN;
-- UPDATE contract_version
--    SET extraction_engine   = NULL,
--        ocr_used            = FALSE,
--        ocr_confidence_avg  = NULL,
--        page_count          = NULL,
--        ingestion_status    = 'pending',
--        extracted_text_uri  = NULL,
--        extracted_at        = NULL,
--        updated_at          = CURRENT_TIMESTAMP
--  WHERE extraction_engine = 'digital_pdf'
--    AND ingestion_status IN ('pending','complete')
--    AND extracted_text_uri IS NULL;   -- only rows TS script has NOT yet completed
-- DELETE FROM schema_migrations WHERE version = 138;
-- COMMIT;
-- ROLLBACK END
