-- Migration: 141_crd_enable_pgvector.sql
-- Module: M12 / CR-D — Clause Taxonomy + Two-Stage Extractor + pgvector
-- Description: Enable pgvector extension + unaccent extension. Sanity test VECTOR(1536) + ivfflat.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Enable pgvector (required for VECTOR(1536) columns + ivfflat index in migration 144)
CREATE EXTENSION IF NOT EXISTS vector;

-- Enable unaccent (for clause semantic search query normalization per migration 158)
CREATE EXTENSION IF NOT EXISTS unaccent;

-- Sanity verification: create + drop a test table to confirm VECTOR(1536) is functional
DO $$
BEGIN
  CREATE TEMP TABLE _pgvector_sanity_check (v VECTOR(1536));
  DROP TABLE _pgvector_sanity_check;
  RAISE NOTICE '141: pgvector VECTOR(1536) sanity check passed.';
END $$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (141, '141_crd_enable_pgvector', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- CAUTION: Dropping vector extension will fail if any columns of type VECTOR exist.
-- Apply rollback ONLY before migration 144 is applied (which creates VECTOR column).
-- DELETE FROM schema_migrations WHERE version = 141;
-- DROP EXTENSION IF EXISTS unaccent;
-- DROP EXTENSION IF EXISTS vector;
-- ============================================================
