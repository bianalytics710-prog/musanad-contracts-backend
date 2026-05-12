-- ============================================================
-- Migration 134 — CRD0 create_ingestion_review_queue
-- ============================================================
-- Module:      M11 — Document Ingestion Pipeline (CR-D0)
-- Description: CREATE TABLE ingestion_review_queue with:
--              - BIGSERIAL id PRIMARY KEY (fn_audit_trigger compatible — A16)
--              - tenant_id UUID NOT NULL FK tenant(id) ON DELETE RESTRICT
--              - contract_version_id BIGINT NOT NULL FK contract_version(id)
--              - per-page OCR data fields (tesseract + gpt4o + final_text)
--              - review lifecycle (review_status enum-of-4)
--              - data_classification enum-of-3 DEFAULT 'demo' (CR-C invariant)
--              - standard 6 audit cols + is_active soft-delete
--              - UNIQUE(tenant_id, contract_version_id, page_no)
--              - 4 indexes (FK + worklist + soft-delete partial)
--              - FORCE RLS + 3 policies (tenant_select / tenant_modify /
--                RESTRICTIVE deny_direct_delete per CR-C audit-immutability)
--              - audit_ingestion_review_queue_changes trigger
-- SOT: §9 CR-D0, §4.9 multi-tenancy, §16 audit immutability.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS ingestion_review_queue (
  id                    BIGSERIAL    PRIMARY KEY,
  tenant_id             UUID         NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  contract_version_id   BIGINT       NOT NULL REFERENCES contract_version(id) ON DELETE RESTRICT,
  page_no               INTEGER      NOT NULL CHECK (page_no >= 1),

  tesseract_confidence  NUMERIC(3,2),
  tesseract_text        TEXT,
  gpt4o_text            TEXT,
  gpt4o_used            BOOLEAN      NOT NULL DEFAULT FALSE,
  final_text            TEXT,
  review_status         TEXT         NOT NULL DEFAULT 'pending_auto'
                          CHECK (review_status IN ('pending_auto','pending_human','resolved','rejected')),
  reviewed_by           BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  reviewed_at           TIMESTAMPTZ,

  data_classification   TEXT         NOT NULL DEFAULT 'demo'
                          CHECK (data_classification IN ('demo','pilot','production')),

  created_at            TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by            BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by            BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active             BOOLEAN      NOT NULL DEFAULT TRUE,

  CONSTRAINT ingestion_review_queue_tenant_version_page_unique
    UNIQUE (tenant_id, contract_version_id, page_no),

  -- Confidence in [0..1] when present.
  CONSTRAINT ingestion_review_queue_confidence_range
    CHECK (tesseract_confidence IS NULL
           OR (tesseract_confidence >= 0.00 AND tesseract_confidence <= 1.00))
);

-- ============================================================
-- Indexes — FK + worklist filter + soft-delete partial
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_ingestion_review_queue_tenant_id
  ON ingestion_review_queue(tenant_id);                                                   -- FK

CREATE INDEX IF NOT EXISTS idx_ingestion_review_queue_contract_version_id
  ON ingestion_review_queue(contract_version_id);                                         -- FK

CREATE INDEX IF NOT EXISTS idx_ingestion_review_queue_active
  ON ingestion_review_queue(id) WHERE is_active = TRUE;                                   -- soft-delete partial

CREATE INDEX IF NOT EXISTS idx_ingestion_review_queue_pending_worklist
  ON ingestion_review_queue(tenant_id, created_at DESC)
  WHERE review_status IN ('pending_auto','pending_human') AND is_active = TRUE;           -- reviewer worklist

-- ============================================================
-- COMMENT ON TABLE + sensitive columns (S2-27 + A4 standards)
-- ============================================================
COMMENT ON TABLE ingestion_review_queue IS
  'CR-D0 §9 — per-page low-confidence review queue. One row per PDF page where Tesseract scored below ocr.confidence_threshold (Q1=0.75) OR where the daily Vision cap (ai.daily_vision_cap_pages, Q2=500) forced human-only routing. Tenant-scoped per §4.9 — RLS GUC = app.current_tenant_id. Tracks both engine outputs + reviewer-confirmed final_text + review lifecycle. Audit trigger via standard fn_audit_trigger (BIGSERIAL id compatible — A16). RESTRICTIVE deny_direct_delete policy enforces audit-immutability (CR-C invariant); soft-delete via is_active.';
COMMENT ON COLUMN ingestion_review_queue.tenant_id IS
  'Required by §4.9 — every NEW content table in CRIP carries tenant_id NOT NULL. Worker hydrates via SET LOCAL app.current_tenant_id = ADNOC_TENANT_ID before INSERT (N18 / A23). RLS GUC narrows reads.';
COMMENT ON COLUMN ingestion_review_queue.contract_version_id IS
  'FK contract_version(id) ON DELETE RESTRICT. Per OPEN-DECISION-N Path B: re-extraction creates a new contract_version row, so the queue row stays bound to the version it was generated from (auditable provenance).';
COMMENT ON COLUMN ingestion_review_queue.tesseract_confidence IS
  'NUMERIC(3,2) [0.00..1.00] per-page confidence reported by Tesseract.js. NULL when the page was routed directly to gpt-4o (e.g. cap-exhausted pending_human) without first running Tesseract.';
COMMENT ON COLUMN ingestion_review_queue.tesseract_text IS
  'SENSITIVE — confidential contract content (per brief). Pino redact required (BE A8). fn_audit_trigger redact list extended (133).';
COMMENT ON COLUMN ingestion_review_queue.gpt4o_text IS
  'SENSITIVE — confidential contract content. Pino redact + audit redact applied. NULL when gpt4o_used=FALSE.';
COMMENT ON COLUMN ingestion_review_queue.gpt4o_used IS
  'TRUE when the page was routed to gpt-4o Vision. FALSE when Tesseract confidence >= threshold OR daily cap exhausted (review_status=pending_human in cap-exhaust case).';
COMMENT ON COLUMN ingestion_review_queue.final_text IS
  'SENSITIVE — reviewer-confirmed text. Set by fn_ingestion_review_resolve (confirm: COALESCE(gpt4o_text, tesseract_text); correct: p_corrected_text; reject: NULL).';
COMMENT ON COLUMN ingestion_review_queue.review_status IS
  'enum-of-4: pending_auto / pending_human / resolved / rejected. pending_auto = awaiting Tesseract/Vision result; pending_human = Vision unavailable (cap or skipped) — manual review required; resolved = reviewer confirmed/corrected; rejected = reviewer rejected.';
COMMENT ON COLUMN ingestion_review_queue.data_classification IS
  'CR-C invariant — every NEW content table carries data_classification at CREATE-time. demo seed rows from M_parity backfill = ''demo''. demo rows purgeable by fn_demo_data_purge.';

-- ============================================================
-- RLS — FORCE + 3 policies
-- ============================================================
ALTER TABLE ingestion_review_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE ingestion_review_queue FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ingestion_review_queue_tenant_select ON ingestion_review_queue;
CREATE POLICY ingestion_review_queue_tenant_select ON ingestion_review_queue
  FOR SELECT
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND (
      fn_current_user_has_permission('document.review')
      OR fn_current_user_has_permission('ingestion_queue.read')
    )
  );

DROP POLICY IF EXISTS ingestion_review_queue_tenant_modify ON ingestion_review_queue;
CREATE POLICY ingestion_review_queue_tenant_modify ON ingestion_review_queue
  FOR ALL
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('document.review')
  )
  WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('document.review')
  );

DROP POLICY IF EXISTS ingestion_review_queue_deny_direct_delete ON ingestion_review_queue;
CREATE POLICY ingestion_review_queue_deny_direct_delete ON ingestion_review_queue
  AS RESTRICTIVE
  FOR DELETE
  USING (FALSE);

-- ============================================================
-- Audit trigger (standard fn_audit_trigger; BIGSERIAL id compatible — A16 / N11)
-- ============================================================
DROP TRIGGER IF EXISTS audit_ingestion_review_queue_changes ON ingestion_review_queue;
CREATE TRIGGER audit_ingestion_review_queue_changes
  AFTER INSERT OR UPDATE OR DELETE ON ingestion_review_queue
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (134, 'crd0_create_ingestion_review_queue', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP TABLE IF EXISTS ingestion_review_queue CASCADE;
-- DELETE FROM schema_migrations WHERE version = 134;
-- COMMIT;
-- ROLLBACK END
