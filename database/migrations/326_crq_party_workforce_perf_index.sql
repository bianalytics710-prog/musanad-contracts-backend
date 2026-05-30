-- Migration: 326_crq_party_workforce_perf_index.sql
-- Module: CR-Q — ADNOC Data Scale-Up (v1.4 foundation)
-- Description: Adds a partial compound index on party_workforce to accelerate
--              fn_regulatory_cascade_run at ~400 contractors.
--              Baseline: ~200 ms at 40 contractors.
--              Target after index + VACUUM ANALYZE: < 1.5 s at 400 contractors.
--              VACUUM ANALYZE runs after the index to update planner statistics.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Partial compound index: all active workforce rows scoped by party + band
-- (fn_regulatory_cascade_run inner query: WHERE pw.tenant_id = v_tenant_id AND pw.is_active = TRUE)
CREATE INDEX IF NOT EXISTS idx_party_workforce_party_band_active
  ON party_workforce (party_id, headcount_band)
  WHERE is_active = TRUE;

DO $$ BEGIN RAISE NOTICE '326: idx_party_workforce_party_band_active created (IF NOT EXISTS).'; END $$;

-- Record this migration INSIDE the transaction so it rolls back if anything fails
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (326, '326_crq_party_workforce_perf_index', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- NOTE: VACUUM ANALYZE party_workforce cannot run inside a transaction block.
-- The migration runner wraps all migrations in a transaction, so VACUUM is omitted here.
-- Run manually after deployment: VACUUM ANALYZE party_workforce;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP INDEX IF EXISTS idx_party_workforce_party_band_active;
-- DELETE FROM schema_migrations WHERE version = 326;
-- COMMIT;
-- ============================================================
