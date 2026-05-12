-- Migration: 149_crd_system_setting_seed.sql
-- Module: M12 / CR-D — Clause Taxonomy + Two-Stage Extractor
-- Description: 3 UPSERT rows on system_setting (category='ai').
--   clause.review_confidence_threshold, clause.embedding_model, clause.ivfflat_lists.
--   system_setting.category 'ai' enum was widened in M11 migration 135 (7 → 8 values).
--   No further CHECK widening required.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- NOTE (schema discovery): system_setting.value is JSONB (not TEXT). String values must be JSON-quoted.
-- No is_editable column. is_secret column exists but defaults safely.
INSERT INTO system_setting (key, value, category, description, created_at, updated_at)
VALUES
  (
    'clause.review_confidence_threshold',
    '"0.70"'::jsonb,
    'ai',
    'Confidence threshold (0.0-1.0) below which Stage 2 extracted clauses route to the legal counsel review queue (/app/clauses/review). HITL Q1 lock. Default: 0.70.',
    NOW(), NOW()
  ),
  (
    'clause.embedding_model',
    '"text-embedding-3-small"'::jsonb,
    'ai',
    'OpenAI embedding model used by BE clause-extraction.service.ts for VECTOR(1536) generation. HITL Q3 lock. Tunable to text-embedding-3-large (BE reads at startup + 5-min refresh). Changing requires ivfflat index rebuild.',
    NOW(), NOW()
  ),
  (
    'clause.ivfflat_lists',
    '"100"'::jsonb,
    'ai',
    'pgvector ivfflat lists parameter for idx_contract_clause_extracted_embedding_ivfflat. CF-8 — default 100 appropriate for pilot corpora. Reduce for <1000 rows (lists=10); increase at scale. Index rebuild required after change.',
    NOW(), NOW()
  )
ON CONFLICT (key) DO UPDATE SET
  value       = EXCLUDED.value,
  category    = EXCLUDED.category,
  description = EXCLUDED.description,
  updated_at  = NOW();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (149, '149_crd_system_setting_seed', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 149;
-- DELETE FROM system_setting WHERE key IN (
--   'clause.review_confidence_threshold',
--   'clause.embedding_model',
--   'clause.ivfflat_lists'
-- );
-- ============================================================
