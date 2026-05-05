-- ============================================================================
-- 049_m5_regulatory_tables.sql
-- ============================================================================
-- Module:    M5 (Regulatory Radar)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   048_m5_regulator_lookup.sql, M1a (contract table), M0 (user, fn_audit_trigger).
-- ----------------------------------------------------------------------------
-- Creates the 4 M5 entities:
--   regulation         — master library (FK -> regulator; self-ref superseded_by_id)
--   impact_category    — taxonomy (id BIGSERIAL + key UNIQUE per Q5)
--   regulatory_update  — radar feed (FK -> impact_category, regulator)
--   regulatory_impact  — G1 reconstituted (FKs -> contract/regulation/regulatory_update;
--                        nullable regulatory_update_id; COALESCE-sentinel UNIQUE per Q7)
--
-- All 4 tables: BIGSERIAL id (M5-CC-2 audit-compatible), STANDARD audit trigger,
-- partial is_active index, FK indexes. Specialised indexes per AC.
-- RLS policies live in 051 (separate migration for clarity).
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. regulation (master library)
-- ============================================================================
CREATE TABLE regulation (
  id                  BIGSERIAL PRIMARY KEY,

  reference_code      VARCHAR(80)  NOT NULL UNIQUE,
  title_en            VARCHAR(500) NOT NULL,
  title_ar            VARCHAR(500),

  issuer_id           BIGINT       NOT NULL REFERENCES regulator(id) ON DELETE RESTRICT,

  regulation_type     VARCHAR(60)  NOT NULL
                        CHECK (regulation_type IN (
                          'federal_decree_law','cabinet_resolution','ministerial_decision',
                          'free_zone_regulation','circular','guideline'
                        )),
  jurisdiction        VARCHAR(40)
                        CHECK (jurisdiction IS NULL OR jurisdiction IN (
                          'uae_federal','dubai','abu_dhabi','sharjah','difc','adgm','dmcc','other'
                        )),
  effective_date      DATE,
  superseded_by_id    BIGINT       REFERENCES regulation(id) ON DELETE SET NULL,
  summary_en          TEXT,
  summary_ar          TEXT,
  source_url          TEXT,
  tags                TEXT[]       NOT NULL DEFAULT '{}'::text[],
  status              VARCHAR(20)  NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','superseded','repealed','draft')),
  is_seed             BOOLEAN      NOT NULL DEFAULT FALSE,

  created_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by          BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN      NOT NULL DEFAULT TRUE,

  CONSTRAINT chk_regulation_no_self_supersede
    CHECK (superseded_by_id IS NULL OR superseded_by_id <> id)
);

COMMENT ON TABLE regulation IS
  'M5 master library of UAE regulatory references. Self-referential supersession chain. Soft-delete only. reference_code is immutable post-create per AC-S4-05.';
COMMENT ON COLUMN regulation.reference_code IS 'Citable code like FED-DL-33-2021. UNIQUE; immutable post-create.';
COMMENT ON COLUMN regulation.tags IS 'Denormalized TEXT[] (production gap; junction deferred to M7+ per Q4).';
COMMENT ON COLUMN regulation.superseded_by_id IS 'Self-reference. When set, fn_regulation_update auto-flips status to superseded.';

CREATE INDEX idx_regulation_issuer_id        ON regulation(issuer_id);
CREATE INDEX idx_regulation_superseded_by_id ON regulation(superseded_by_id);
CREATE INDEX idx_regulation_created_by       ON regulation(created_by);
CREATE INDEX idx_regulation_updated_by       ON regulation(updated_by);
CREATE INDEX idx_regulation_active           ON regulation(id) WHERE is_active = TRUE;

CREATE INDEX idx_regulation_listing
  ON regulation (effective_date DESC NULLS LAST, created_at DESC)
  WHERE is_active = TRUE;

CREATE INDEX idx_regulation_filter_axes
  ON regulation (jurisdiction, regulation_type, status)
  WHERE is_active = TRUE;

CREATE INDEX idx_regulation_reference_code_trgm
  ON regulation USING GIN (reference_code gin_trgm_ops);

CREATE INDEX idx_regulation_tags_gin
  ON regulation USING GIN (tags);

CREATE TRIGGER audit_regulation_changes
  AFTER INSERT OR UPDATE OR DELETE ON regulation
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();


-- ============================================================================
-- 2. impact_category (taxonomy; id BIGSERIAL + key UNIQUE per Q5)
-- ============================================================================
CREATE TABLE impact_category (
  id                        BIGSERIAL PRIMARY KEY,
  key                       VARCHAR(60) NOT NULL UNIQUE,

  name_en                   VARCHAR(200) NOT NULL,
  name_ar                   VARCHAR(200) NOT NULL,
  description_en            TEXT,
  description_ar            TEXT,
  icon                      VARCHAR(60)  NOT NULL DEFAULT 'shield',
  colour                    VARCHAR(30)  NOT NULL DEFAULT 'slate',
  active                    BOOLEAN      NOT NULL DEFAULT TRUE,
  display_order             INTEGER      NOT NULL DEFAULT 0,
  sources                   JSONB        NOT NULL DEFAULT '[]'::jsonb,
  severity_scale            JSONB        NOT NULL DEFAULT '["low","medium","high","critical"]'::jsonb,
  ai_prompt_context         TEXT,
  default_clause_categories TEXT[]       NOT NULL DEFAULT '{}'::text[],
  is_seed                   BOOLEAN      NOT NULL DEFAULT FALSE,

  created_at                TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at                TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by                BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by                BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                 BOOLEAN      NOT NULL DEFAULT TRUE,

  CONSTRAINT chk_impact_category_severity_scale_array
    CHECK (jsonb_typeof(severity_scale) = 'array')
);

COMMENT ON TABLE impact_category IS
  'M5 configurable categorisation taxonomy. PK = id BIGSERIAL (audit-trigger compatible per Q5/M5-CC-2); key VARCHAR(60) UNIQUE is the upsert match key. active = FE picker visibility; is_active = admin soft-delete.';
COMMENT ON COLUMN impact_category.key IS 'Stable snake_case code. UNIQUE; immutable in fn_impact_category_upsert.';
COMMENT ON COLUMN impact_category.active IS 'FE picker visibility flag (separate from is_active soft-delete).';
COMMENT ON COLUMN impact_category.severity_scale IS 'JSONB array. Default ["low","medium","high","critical"]. CHECK enforces array typeof.';
COMMENT ON COLUMN impact_category.default_clause_categories IS 'Denormalized TEXT[] (junction deferred to M7+ per Q4).';

CREATE INDEX idx_impact_category_created_by ON impact_category(created_by);
CREATE INDEX idx_impact_category_updated_by ON impact_category(updated_by);
CREATE INDEX idx_impact_category_active     ON impact_category(id) WHERE is_active = TRUE;

CREATE INDEX idx_impact_category_display_order
  ON impact_category (display_order ASC, id ASC)
  WHERE is_active = TRUE AND active = TRUE;

CREATE INDEX idx_impact_category_key_active ON impact_category(key) WHERE is_active = TRUE;

CREATE TRIGGER audit_impact_category_changes
  AFTER INSERT OR UPDATE OR DELETE ON impact_category
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();


-- ============================================================================
-- 3. regulatory_update (radar feed)
-- ============================================================================
CREATE TABLE regulatory_update (
  id                          BIGSERIAL PRIMARY KEY,

  regulator_id                BIGINT       NOT NULL REFERENCES regulator(id) ON DELETE RESTRICT,

  title_en                    VARCHAR(500) NOT NULL,
  title_ar                    VARCHAR(500),
  summary_en                  TEXT,
  summary_ar                  TEXT,

  reference_number            VARCHAR(120),
  published_date              DATE         NOT NULL,
  effective_date              DATE,
  compliance_deadline         DATE,
  severity                    VARCHAR(20)  NOT NULL DEFAULT 'medium'
                                CHECK (severity IN ('low','medium','high','critical')),
  source_url                  TEXT,
  affected_clause_categories  TEXT[]       NOT NULL DEFAULT '{}'::text[],
  category_id                 BIGINT       REFERENCES impact_category(id) ON DELETE SET NULL,
  sub_source                  VARCHAR(120),
  is_seed                     BOOLEAN      NOT NULL DEFAULT FALSE,

  created_at                  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at                  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by                  BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by                  BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                   BOOLEAN      NOT NULL DEFAULT TRUE,

  CONSTRAINT chk_regulatory_update_effective_date
    CHECK (effective_date IS NULL OR effective_date >= published_date),

  CONSTRAINT chk_regulatory_update_compliance_deadline
    CHECK (compliance_deadline IS NULL OR compliance_deadline >= published_date)
);

COMMENT ON TABLE regulatory_update IS
  'M5 stream of incoming regulatory news. Drives the radar visualisation. M4 already declared regulatory_update + regulatory_update_summary in AiInsightEntityType union — M5 reifies the data plane (M5-CC-3).';
COMMENT ON COLUMN regulatory_update.regulator_id IS 'Q3 = (b) shared regulator lookup. RESTRICT FK.';
COMMENT ON COLUMN regulatory_update.affected_clause_categories IS 'Denormalized TEXT[] (junction deferred to M7+ per Q4).';
COMMENT ON COLUMN regulatory_update.severity IS 'CHECK enum kept inline (closed canonical set; M3/M4 precedent).';

CREATE INDEX idx_regulatory_update_regulator_id ON regulatory_update(regulator_id);
CREATE INDEX idx_regulatory_update_category_id  ON regulatory_update(category_id);
CREATE INDEX idx_regulatory_update_created_by   ON regulatory_update(created_by);
CREATE INDEX idx_regulatory_update_updated_by   ON regulatory_update(updated_by);
CREATE INDEX idx_regulatory_update_active       ON regulatory_update(id) WHERE is_active = TRUE;

CREATE INDEX idx_regulatory_update_radar
  ON regulatory_update (severity, effective_date DESC NULLS LAST, regulator_id, category_id)
  WHERE is_active = TRUE;

CREATE INDEX idx_regulatory_update_published_desc
  ON regulatory_update (published_date DESC, id DESC)
  WHERE is_active = TRUE;

CREATE INDEX idx_regulatory_update_compliance_deadline
  ON regulatory_update (compliance_deadline)
  WHERE is_active = TRUE AND compliance_deadline IS NOT NULL;

CREATE INDEX idx_regulatory_update_clause_categories_gin
  ON regulatory_update USING GIN (affected_clause_categories);

CREATE TRIGGER audit_regulatory_update_changes
  AFTER INSERT OR UPDATE OR DELETE ON regulatory_update
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();


-- ============================================================================
-- 4. regulatory_impact (G1 reconstituted)
-- ============================================================================
CREATE TABLE regulatory_impact (
  id                    BIGSERIAL PRIMARY KEY,

  contract_id           BIGINT       NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
  regulation_id         BIGINT       NOT NULL REFERENCES regulation(id) ON DELETE RESTRICT,
  regulatory_update_id  BIGINT       REFERENCES regulatory_update(id) ON DELETE CASCADE,

  impact_score          INTEGER
                          CHECK (impact_score IS NULL OR impact_score BETWEEN 0 AND 100),

  impact_note_en        TEXT,
  impact_note_ar        TEXT,
  impact_summary_en     TEXT,
  impact_summary_ar     TEXT,

  detected_at           TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  resolved              BOOLEAN      NOT NULL DEFAULT FALSE,
  resolution_action     VARCHAR(40)
                          CHECK (resolution_action IS NULL OR resolution_action IN
                                 ('amended','waived','out_of_scope','pending')),
  resolution_note       TEXT,

  is_seed               BOOLEAN      NOT NULL DEFAULT FALSE,

  created_at            TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by            BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by            BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active             BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE regulatory_impact IS
  'M5 G1-reconstituted per HITL Gate 1 decisions.md. Per-contract impact analysis when a regulatory_update affects a contract. Idempotent inserts via UNIQUE INDEX (Q7 COALESCE-sentinel).';
COMMENT ON COLUMN regulatory_impact.regulatory_update_id IS 'NULLABLE. Distinguishes structural impacts (column IS NULL) from update-driven impacts. fn_ bodies use IS NOT DISTINCT FROM (S2-18).';
COMMENT ON COLUMN regulatory_impact.impact_note_en IS 'Short-form tag (radar tooltip; AC-S6 surface). Q6 — note != summary.';
COMMENT ON COLUMN regulatory_impact.impact_summary_en IS 'AI-generated long-form executive summary (BulkAmendmentSheet, RegulatoryImpactBanner).';
COMMENT ON COLUMN regulatory_impact.resolution_action IS 'CHECK kept inline — closed canonical set.';
COMMENT ON COLUMN regulatory_impact.resolution_note IS 'Q8 ADD column. Admin-bounded free text; NOT redacted.';
COMMENT ON COLUMN regulatory_impact.created_by IS 'Nullable for system-actor sentinel paths (reserved for future regulatory feed cron).';

-- Q7 COALESCE-sentinel UNIQUE INDEX — partial WHERE is_active = TRUE
CREATE UNIQUE INDEX idx_regulatory_impact_unique_active
  ON regulatory_impact (
    contract_id,
    regulation_id,
    COALESCE(regulatory_update_id, 0::BIGINT)
  )
  WHERE is_active = TRUE;

CREATE INDEX idx_regulatory_impact_contract_id          ON regulatory_impact(contract_id);
CREATE INDEX idx_regulatory_impact_regulation_id        ON regulatory_impact(regulation_id);
CREATE INDEX idx_regulatory_impact_regulatory_update_id ON regulatory_impact(regulatory_update_id);
CREATE INDEX idx_regulatory_impact_created_by           ON regulatory_impact(created_by);
CREATE INDEX idx_regulatory_impact_updated_by           ON regulatory_impact(updated_by);
CREATE INDEX idx_regulatory_impact_active               ON regulatory_impact(id) WHERE is_active = TRUE;

CREATE INDEX idx_regulatory_impact_detected_desc
  ON regulatory_impact (detected_at DESC)
  WHERE is_active = TRUE;

CREATE INDEX idx_regulatory_impact_update_id_detected_at
  ON regulatory_impact (regulatory_update_id, detected_at)
  WHERE is_active = TRUE AND regulatory_update_id IS NOT NULL;

CREATE INDEX idx_regulatory_impact_contract_resolved
  ON regulatory_impact (contract_id, resolved, detected_at DESC)
  WHERE is_active = TRUE;

CREATE TRIGGER audit_regulatory_impact_changes
  AFTER INSERT OR UPDATE OR DELETE ON regulatory_impact
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (49, 'm5_regulatory_tables', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP TRIGGER IF EXISTS audit_regulatory_impact_changes  ON regulatory_impact;
DROP TRIGGER IF EXISTS audit_regulatory_update_changes  ON regulatory_update;
DROP TRIGGER IF EXISTS audit_impact_category_changes    ON impact_category;
DROP TRIGGER IF EXISTS audit_regulation_changes         ON regulation;
DROP TABLE IF EXISTS regulatory_impact;
DROP TABLE IF EXISTS regulatory_update;
DROP TABLE IF EXISTS impact_category;
DROP TABLE IF EXISTS regulation;
DELETE FROM schema_migrations WHERE version = 49;
COMMIT;
-- ROLLBACK END
