-- Migration: 144_crd_create_contract_clause_extracted.sql
-- Module: M12 / CR-D — Clause Taxonomy + Two-Stage Extractor
-- Description: CREATE TABLE contract_clause_extracted + 4 indexes (ivfflat, GIN, 2 BTREE)
--              + FORCE RLS + 3 policies + audit trigger + COMMENTs.
--              Requires pgvector (migration 141). Separate from contract_clause LIBRARY table (CF-2).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE contract_clause_extracted (
  id                         BIGSERIAL PRIMARY KEY,
  tenant_id                  UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  contract_id                BIGINT NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,
  contract_version_id        BIGINT NOT NULL REFERENCES contract_version(id) ON DELETE CASCADE,
  clause_type_v2             TEXT NOT NULL,
  parameters                 JSONB NOT NULL DEFAULT '{}'::jsonb,
  text_excerpts              JSONB NOT NULL DEFAULT '{}'::jsonb,
  page_no                    INTEGER,
  source_offset_start        INTEGER,
  source_offset_end          INTEGER,
  confidence                 NUMERIC(5,4)
    CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
  summary_en                 TEXT,
  summary_ar                 TEXT,
  review_status              TEXT NOT NULL DEFAULT 'auto'
    CHECK (review_status IN ('auto','pending_review','reviewed','rejected','pending_extraction')),
  reviewed_by                BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  reviewed_at                TIMESTAMPTZ,
  extraction_model_version   TEXT,
  extraction_prompt_hash     TEXT,
  embedding                  VECTOR(1536),

  data_classification        TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),

  -- Standard 6 audit columns
  created_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by                 BIGINT REFERENCES "user"(id),
  updated_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by                 BIGINT REFERENCES "user"(id),
  is_active                  BOOLEAN NOT NULL DEFAULT TRUE,

  -- Idempotency key for re-extraction — fn_clause_upsert ON CONFLICT DO UPDATE
  CONSTRAINT contract_clause_extracted_idempotency_key
    UNIQUE (tenant_id, contract_version_id, clause_type_v2, source_offset_start)
);

COMMENT ON TABLE contract_clause_extracted IS 'Per-contract LLM-extracted clauses with mandatory text_excerpts (Annex A.1.2 discipline) + per-parameter pgvector embedding for semantic search. Separate from contract_clause LIBRARY (M_parity 058) — that table holds re-usable template clauses for drafting; this one holds extraction outputs per contract version.';
COMMENT ON COLUMN contract_clause_extracted.tenant_id IS 'Tenant FK. Denormalized from app.current_tenant_id GUC at extraction time. RLS scopes reads/writes by this column.';
COMMENT ON COLUMN contract_clause_extracted.contract_id IS 'Parent contract. Cascades to RESTRICT (preserves clause history on soft-delete).';
COMMENT ON COLUMN contract_clause_extracted.contract_version_id IS 'Source document version. Cascades to CASCADE — if a version is hard-deleted (rare) its clauses go too.';
COMMENT ON COLUMN contract_clause_extracted.clause_type_v2 IS 'Closed-taxonomy identifier per Annex A.11. References clause_taxonomy.clause_type_id (logical FK only — cross-tenant safe).';
COMMENT ON COLUMN contract_clause_extracted.parameters IS 'Per-clause-type extracted parameters. Schema lives in clause_taxonomy.parameter_schema. SENSITIVE — redacted from fn_audit_trigger.';
COMMENT ON COLUMN contract_clause_extracted.text_excerpts IS 'Per-parameter verbatim source-text. Every parameter key MUST have a matching text_excerpts key per Annex A.1.2. SENSITIVE — redacted from fn_audit_trigger.';
COMMENT ON COLUMN contract_clause_extracted.confidence IS 'Stage 2 LLM-reported confidence 0..1. < clause.review_confidence_threshold (default 0.70) routes to review queue.';
COMMENT ON COLUMN contract_clause_extracted.review_status IS 'auto = Stage 2 emitted; pending_review = below threshold; reviewed = legal_counsel confirmed; rejected = legal_counsel rejected; pending_extraction = queued by fn_clause_extraction_request (worker has not processed yet).';
COMMENT ON COLUMN contract_clause_extracted.embedding IS 'text-embedding-3-small 1536-dim vector. Generated from clause text + summary. Used by ivfflat semantic search index. NULL if embedding step skipped or failed.';
COMMENT ON COLUMN contract_clause_extracted.extraction_prompt_hash IS 'SHA-256 of canonical Stage 2 prompt. Audit trail for prompt-drift analysis.';

-- Index 1: ivfflat semantic search (pgvector cosine — lists=100 default; CF-8 tunable via system_setting)
CREATE INDEX idx_contract_clause_extracted_embedding_ivfflat
  ON contract_clause_extracted USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);

-- Index 2: GIN on parameters for JSONB path lookups (drives fn_rule_evaluate clause_parameter predicate per OD-1)
CREATE INDEX idx_contract_clause_extracted_parameters_gin
  ON contract_clause_extracted USING GIN (parameters jsonb_path_ops)
  WHERE is_active = TRUE;

-- Index 3: BTREE on tenant/contract/status for fn_clause_review_queue_list filters
CREATE INDEX idx_contract_clause_extracted_tenant_contract_status
  ON contract_clause_extracted (tenant_id, contract_id, review_status)
  WHERE is_active = TRUE;

-- Index 4: Partial BTREE on pending_review rows (small set — drives review queue list)
CREATE INDEX idx_contract_clause_extracted_review_status_pending
  ON contract_clause_extracted (id)
  WHERE review_status = 'pending_review' AND is_active = TRUE;

-- FORCE RLS + 3 policies (M10/M11 pattern)
ALTER TABLE contract_clause_extracted ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_clause_extracted FORCE ROW LEVEL SECURITY;

CREATE POLICY contract_clause_extracted_tenant_select ON contract_clause_extracted
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY contract_clause_extracted_tenant_modify ON contract_clause_extracted
  FOR ALL USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  ) WITH CHECK (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY contract_clause_extracted_deny_direct_delete ON contract_clause_extracted
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger (BIGSERIAL id — default fn_audit_trigger compatible)
CREATE TRIGGER audit_contract_clause_extracted_changes
  AFTER INSERT OR UPDATE OR DELETE ON contract_clause_extracted
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (144, '144_crd_create_contract_clause_extracted', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 144;
-- DROP TRIGGER IF EXISTS audit_contract_clause_extracted_changes ON contract_clause_extracted;
-- DROP TABLE IF EXISTS contract_clause_extracted;
-- ============================================================
