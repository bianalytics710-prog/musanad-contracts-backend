-- ============================================================
-- Migration 139 — CRD0 fix_mparity_backfill_no_updated_at
-- ============================================================
-- Module:      M11 — Document Ingestion Pipeline (CR-D0)
-- Description: Patch for migration 138 failure.
--              Root cause: 138 included `updated_at = CURRENT_TIMESTAMP` in the
--              UPDATE SET clause, but contract_version is an APPEND-ONLY table
--              (003_m1a_contracts.sql) — it has only created_at / created_by /
--              changed_by columns, NO updated_at or updated_by.
--              This migration repeats the same idempotent UPDATE without updated_at.
--              Migration 138 must remain in the migrations folder (it was partially
--              executed — the UPDATE statement that would have run before the error
--              used an explicit column list that included updated_at, so NO rows were
--              modified). Per feedback_db_impl_report_dont_fix.md protocol: new
--              migration file for the fix; 138 is NOT edited.
-- Classification: DESIGN DEFECT surfaced at apply time (successWithoutPatches=false).
-- ============================================================

BEGIN;

UPDATE contract_version cv
   SET extraction_engine   = 'digital_pdf',
       ocr_used            = FALSE,
       ocr_confidence_avg  = NULL,
       page_count          = 1,
       ingestion_status    = 'pending',
       extracted_text_uri  = NULL
       -- NOTE: No updated_at — contract_version is append-only (no updated_at column per 003_m1a_contracts.sql)
 WHERE cv.id = (
         SELECT id FROM contract_version
          WHERE contract_id = cv.contract_id
          ORDER BY version_number DESC LIMIT 1
       )
   AND (cv.body_en IS NOT NULL OR cv.body_ar IS NOT NULL)
   AND cv.extraction_engine IS NULL          -- idempotency: already set → skip
   AND cv.ingestion_status IN ('pending');   -- default post-migration-132 state

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (139, 'crd0_fix_mparity_backfill_no_updated_at', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- UPDATE contract_version
--    SET extraction_engine   = NULL,
--        ocr_used            = FALSE,
--        ocr_confidence_avg  = NULL,
--        page_count          = NULL,
--        ingestion_status    = 'pending',
--        extracted_text_uri  = NULL,
--        extracted_at        = NULL
--  WHERE extraction_engine = 'digital_pdf'
--    AND ingestion_status IN ('pending')
--    AND extracted_text_uri IS NULL;
-- DELETE FROM schema_migrations WHERE version = 139;
-- COMMIT;
-- ROLLBACK END
