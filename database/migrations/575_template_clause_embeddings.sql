-- Migration: 575_template_clause_embeddings.sql
-- Module: Template / Clause similarity matching (Drafter enhancement, phase 1 of 4)
-- Date: 2026-06-05
--
-- Goal: extend the LIBRARY tables (contract_template + contract_clause) with
-- text-embedding-3-small (1536-dim) embeddings so the "New Template — from a
-- contract" flow can:
--   (1) compute the candidate template's similarity to existing templates
--       and surface near-duplicates / extend candidates;
--   (2) cross-check each extracted clause against the clause library and
--       offer the new ones for one-click add (mirrors the existing
--       clauses/new-from-contract flow).
--
-- Per-contract extractions already have embeddings (mig 144,
-- contract_clause_extracted.embedding); this migration adds the same
-- column shape + ivfflat index to the LIBRARY rows.
--
-- pgvector extension is already enabled (mig 141). No table renames, no
-- destructive column changes — purely additive.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. contract_template.body_embedding ──────────────────────
ALTER TABLE contract_template
  ADD COLUMN IF NOT EXISTS body_embedding VECTOR(1536);

COMMENT ON COLUMN contract_template.body_embedding IS
  'text-embedding-3-small 1536-dim vector of the redacted body_en. Used by '
  'fn_template_match_candidates for similarity search on upload. NULL until '
  'the row is embedded (one-shot backfill + auto-embed on create).';

-- ivfflat cosine search index. lists=20 is fine for <1k templates.
CREATE INDEX IF NOT EXISTS idx_contract_template_body_embedding_ivfflat
  ON contract_template USING ivfflat (body_embedding vector_cosine_ops)
  WITH (lists = 20);

-- ── 2. contract_clause.body_embedding ────────────────────────
ALTER TABLE contract_clause
  ADD COLUMN IF NOT EXISTS body_embedding VECTOR(1536);

COMMENT ON COLUMN contract_clause.body_embedding IS
  'text-embedding-3-small 1536-dim vector of body_en. Used by '
  'fn_clause_library_match_each so the template-upload flow can flag '
  'clauses that are NOT already in the library.';

CREATE INDEX IF NOT EXISTS idx_contract_clause_body_embedding_ivfflat
  ON contract_clause USING ivfflat (body_embedding vector_cosine_ops)
  WITH (lists = 50);

-- ── 3. System settings — similarity thresholds ───────────────
-- Stored in system_setting so Platform Admin can tune later without code change.
-- 'general' category is the default catch-all.
INSERT INTO system_setting (key, value, category, description, is_secret)
VALUES
  ('template.similarity.exact_threshold',  '0.95'::jsonb, 'general',
   'Cosine similarity threshold above which an uploaded template is treated as an exact duplicate of an existing one (link instead of save).',
   FALSE),
  ('template.similarity.extend_threshold', '0.50'::jsonb, 'general',
   'Cosine similarity threshold above which an uploaded template is offered as an "extend existing" candidate.',
   FALSE),
  ('clause.similarity.match_threshold',    '0.85'::jsonb, 'general',
   'Cosine similarity above which an extracted clause is considered "already in the library" (vs. offered as a new clause to add).',
   FALSE)
ON CONFLICT (key) DO NOTHING;

-- Record migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (575, '575_template_clause_embeddings', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP INDEX IF EXISTS idx_contract_clause_body_embedding_ivfflat;
-- DROP INDEX IF EXISTS idx_contract_template_body_embedding_ivfflat;
-- ALTER TABLE contract_clause   DROP COLUMN IF EXISTS body_embedding;
-- ALTER TABLE contract_template DROP COLUMN IF EXISTS body_embedding;
-- DELETE FROM system_setting WHERE key IN (
--   'template.similarity.exact_threshold',
--   'template.similarity.extend_threshold',
--   'clause.similarity.match_threshold'
-- );
-- DELETE FROM schema_migrations WHERE version = 575;
-- COMMIT;
-- ============================================================
