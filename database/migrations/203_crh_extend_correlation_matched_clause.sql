-- MIGRATION: 203_crh_extend_correlation_matched_clause.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: EXTEND correlation — ADD COLUMN matched_clause_id BIGINT NULL REFERENCES contract_clause_extracted(id) ON DELETE SET NULL
--              + partial index. Backward-compatible additive (NULL default). Required by AC-S21 parameter substitution.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

ALTER TABLE correlation
  ADD COLUMN IF NOT EXISTS matched_clause_id BIGINT NULL
    REFERENCES contract_clause_extracted(id) ON DELETE SET NULL;

COMMENT ON COLUMN correlation.matched_clause_id IS
  'CR-H additive (M16/203). Nullable FK to contract_clause_extracted.id — populated by correlation_rule kind=regulatory_impact when a contract clause (e.g. force_majeure, cure_notice) is matched alongside the OSINT signal. Used by fn_advisory_draft_generate parameter substitution + UI source-traceability.';

CREATE INDEX IF NOT EXISTS idx_correlation_matched_clause
  ON correlation(matched_clause_id)
  WHERE matched_clause_id IS NOT NULL AND is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (203, '203_crh_extend_correlation_matched_clause', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DROP INDEX IF EXISTS idx_correlation_matched_clause;
-- ALTER TABLE correlation DROP COLUMN IF EXISTS matched_clause_id;
-- DELETE FROM schema_migrations WHERE version = 203;
-- ============================================================
