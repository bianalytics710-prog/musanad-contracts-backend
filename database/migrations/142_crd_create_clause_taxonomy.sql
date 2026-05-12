-- Migration: 142_crd_create_clause_taxonomy.sql
-- Module: M12 / CR-D — Clause Taxonomy
-- Description: CREATE TABLE clause_taxonomy + FORCE RLS + 3 policies + audit trigger + COMMENTs + 3 indexes.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE clause_taxonomy (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  clause_type_id           TEXT NOT NULL,
  family                   TEXT NOT NULL
    CHECK (family IN (
      'force_majeure',
      'termination',
      'pricing',
      'performance',
      'indemnity',
      'compliance',
      'governance',
      'operational'
    )),
  display_name_en          TEXT NOT NULL,
  display_name_ar          TEXT NOT NULL,
  definition_en            TEXT NOT NULL,
  definition_ar            TEXT NOT NULL,
  identification_cues_en   TEXT NOT NULL,
  identification_cues_ar   TEXT NOT NULL,
  parameter_schema         JSONB NOT NULL DEFAULT '{}'::jsonb,
  version                  INTEGER NOT NULL DEFAULT 1,
  is_deprecated            BOOLEAN NOT NULL DEFAULT FALSE,
  data_classification      TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),

  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by               BIGINT REFERENCES "user"(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT clause_taxonomy_tenant_type_unique UNIQUE (tenant_id, clause_type_id)
);

COMMENT ON TABLE clause_taxonomy IS 'Closed-vocabulary clause taxonomy per Annex A — 50 ADNOC clause types in 8 families. Drives Stage 2 LLM classification + parameter extraction discipline. Tenant-scoped (future tenants can add additive aviation/banking taxonomies). BIGSERIAL id provides default audit trigger compatibility; UNIQUE(tenant_id, clause_type_id) enforces business key.';
COMMENT ON COLUMN clause_taxonomy.id IS 'Surrogate BIGSERIAL primary key — exists for default fn_audit_trigger NEW.id compatibility (CF-6).';
COMMENT ON COLUMN clause_taxonomy.tenant_id IS 'Tenant FK. Populated by caller via app.current_tenant_id GUC at seed time.';
COMMENT ON COLUMN clause_taxonomy.clause_type_id IS 'Stable snake_case identifier per Annex A.11. Never reused. Referenced by contract_clause_extracted.clause_type_v2.';
COMMENT ON COLUMN clause_taxonomy.family IS 'One of 8 Annex A families. Drives admin viewer grouping.';
COMMENT ON COLUMN clause_taxonomy.display_name_en IS 'Human-readable EN name per Annex A.11 (e.g. "Force Majeure", "Price Review").';
COMMENT ON COLUMN clause_taxonomy.display_name_ar IS 'AR translation. Pilot follow-up: replace [AR] placeholders via Legal SME validation per Annex A.13.4.';
COMMENT ON COLUMN clause_taxonomy.parameter_schema IS 'Per-clause-type parameter definitions consumed by Stage 2 LLM prompt builder. JSONB shape: { paramName: { type, required, enum_values? }, ... }.';
COMMENT ON COLUMN clause_taxonomy.version IS 'Taxonomy revision counter. Bumps on additive parameter-schema extension per Annex A.13.2 (immutable identifier rule preserved).';
COMMENT ON COLUMN clause_taxonomy.is_deprecated IS 'Deprecated types stop being produced by the extractor but historical contract_clause_extracted rows retain them. Annex A.13.3.';
COMMENT ON COLUMN clause_taxonomy.data_classification IS 'CR-C / M10 127 rollout marker. Defaults to demo.';

CREATE INDEX idx_clause_taxonomy_tenant_family ON clause_taxonomy(tenant_id, family) WHERE is_active = TRUE;
CREATE INDEX idx_clause_taxonomy_active ON clause_taxonomy(id) WHERE is_active = TRUE;
CREATE INDEX idx_clause_taxonomy_tenant_active_not_deprecated ON clause_taxonomy(tenant_id, clause_type_id)
  WHERE is_active = TRUE AND is_deprecated = FALSE;

-- FORCE RLS + 3 policies
ALTER TABLE clause_taxonomy ENABLE ROW LEVEL SECURITY;
ALTER TABLE clause_taxonomy FORCE ROW LEVEL SECURITY;

CREATE POLICY clause_taxonomy_tenant_select ON clause_taxonomy
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY clause_taxonomy_tenant_modify ON clause_taxonomy
  FOR ALL USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  ) WITH CHECK (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY clause_taxonomy_deny_direct_delete ON clause_taxonomy
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger (BIGSERIAL id — default fn_audit_trigger compatible per CF-6)
CREATE TRIGGER audit_clause_taxonomy_changes
  AFTER INSERT OR UPDATE OR DELETE ON clause_taxonomy
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (142, '142_crd_create_clause_taxonomy', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 142;
-- DROP TRIGGER IF EXISTS audit_clause_taxonomy_changes ON clause_taxonomy;
-- DROP TABLE IF EXISTS clause_taxonomy;
-- ============================================================
