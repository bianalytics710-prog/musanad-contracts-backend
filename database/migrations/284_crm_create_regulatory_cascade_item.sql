-- Migration: 284_crm_create_regulatory_cascade_item.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: CREATE regulatory_cascade_item — one row per affected contractor per cascade run.
--              Carries headcount band, affected employment clause ids, penalty-exposure AED range,
--              ICV attachment ids (AD-7 model), remediation lifecycle, optional advisory_draft link.
--              FORCE RLS (3 policies) + audit trigger + indexes + COMMENTs.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE TABLE regulatory_cascade_item (
  id                        BIGSERIAL PRIMARY KEY,
  tenant_id                 UUID         NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  cascade_run_id            BIGINT       NOT NULL REFERENCES regulatory_cascade_run(id) ON DELETE CASCADE,
  party_id                  BIGINT       NOT NULL REFERENCES party(id) ON DELETE RESTRICT,

  headcount_band            TEXT         NOT NULL CHECK (headcount_band IN ('<20','20-49','50+')),
  is_compliant              BOOLEAN      NOT NULL DEFAULT TRUE,
  emiratisation_gap         INTEGER      NOT NULL DEFAULT 0,  -- max(target-actual,0)

  affected_clause_ids       JSONB        NOT NULL DEFAULT '[]'::jsonb,  -- array of contract_clause_extracted.id
  affected_contract_ids     JSONB        NOT NULL DEFAULT '[]'::jsonb,  -- array of contract.id (party's ADNOC contracts)
  icv_attachment_ids        JSONB        NOT NULL DEFAULT '[]'::jsonb,  -- array of contract_attachment.id kind=icv_certificate (AD-7 model)

  penalty_exposure_min_aed  NUMERIC(15,2) NOT NULL DEFAULT 0 CHECK (penalty_exposure_min_aed >= 0),
  penalty_exposure_max_aed  NUMERIC(15,2) NOT NULL DEFAULT 0 CHECK (penalty_exposure_max_aed >= 0),
  penalty_basis             JSONB        NOT NULL DEFAULT '{}'::jsonb,  -- SENSITIVE: {band, emiratisationGap, finePerHeadMin/Max, statutoryFloor/Ceiling}

  remediation_status        TEXT         NOT NULL DEFAULT 'pending'
                              CHECK (remediation_status IN ('pending','in_progress','amended','dismissed','resolved')),
  advisory_draft_id         BIGINT       NULL REFERENCES advisory_draft(id) ON DELETE SET NULL,
  remediation_note          TEXT,        -- SENSITIVE: free-text; redacted by fn_audit_trigger (mig 281)

  data_classification       TEXT         NOT NULL DEFAULT 'demo'
                              CHECK (data_classification IN ('demo','pilot','production')),

  created_at                TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  created_by                BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by                BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                 BOOLEAN      NOT NULL DEFAULT TRUE,

  CONSTRAINT reg_cascade_item_penalty_order
    CHECK (penalty_exposure_max_aed >= penalty_exposure_min_aed),
  CONSTRAINT reg_cascade_item_uq_run_party
    UNIQUE (cascade_run_id, party_id)
);

COMMENT ON TABLE regulatory_cascade_item IS
  'CR-M — one row per affected contractor per cascade run. Carries headcount band snapshot, affected employment clause ids, penalty-exposure AED range, ICV attachment ids (AD-7 model — no icv_certificate table), remediation lifecycle + optional advisory_draft link. FORCE RLS tenant-scoped. advisory_draft_id set post-hoc by fn_regulatory_cascade_item_link_draft.';
COMMENT ON COLUMN regulatory_cascade_item.affected_clause_ids IS 'JSONB array of contract_clause_extracted.id whose clause_type_v2 is labor-relevant (icv_in_country_value/strike_lockout/key_personnel) for this contractor''s ADNOC contracts. Not sensitive (ids only).';
COMMENT ON COLUMN regulatory_cascade_item.icv_attachment_ids IS 'JSONB array of contract_attachment.id (kind=icv_certificate) for affected contracts. Reinterprets brief icv_certificate_ids per AD-7 (no icv_certificate table exists).';
COMMENT ON COLUMN regulatory_cascade_item.advisory_draft_id IS 'Nullable FK -> advisory_draft.id. Set after BE generates the amendment draft via fn_advisory_draft_generate; linked by fn_regulatory_cascade_item_link_draft.';
COMMENT ON COLUMN regulatory_cascade_item.penalty_basis IS 'SENSITIVE — JSONB derivation trace {band, emiratisationGap, finePerHeadMin, finePerHeadMax, statutoryFloor, statutoryCeiling}. Redacted by fn_audit_trigger (mig 281) + Pino.';

CREATE INDEX idx_reg_cascade_item_tenant_id        ON regulatory_cascade_item(tenant_id);
CREATE INDEX idx_reg_cascade_item_run_id           ON regulatory_cascade_item(cascade_run_id);
CREATE INDEX idx_reg_cascade_item_party_id         ON regulatory_cascade_item(party_id);
CREATE INDEX idx_reg_cascade_item_advisory_draft_id ON regulatory_cascade_item(advisory_draft_id) WHERE advisory_draft_id IS NOT NULL;
CREATE INDEX idx_reg_cascade_item_created_by       ON regulatory_cascade_item(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_reg_cascade_item_updated_by       ON regulatory_cascade_item(updated_by) WHERE updated_by IS NOT NULL;
CREATE INDEX idx_reg_cascade_item_active           ON regulatory_cascade_item(id) WHERE is_active = TRUE;
CREATE INDEX idx_reg_cascade_item_run_status       ON regulatory_cascade_item(cascade_run_id, remediation_status) WHERE is_active = TRUE;

ALTER TABLE regulatory_cascade_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE regulatory_cascade_item FORCE  ROW LEVEL SECURITY;

CREATE POLICY reg_cascade_item_tenant_select ON regulatory_cascade_item
  FOR SELECT USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('regulatory.cascade.read')
  );

-- Modify policy: DEFINER fn writes bypass RLS; write gate enforced in fn bodies.
CREATE POLICY reg_cascade_item_tenant_modify ON regulatory_cascade_item
  FOR ALL USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
  ) WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
  );

CREATE POLICY reg_cascade_item_deny_direct_delete ON regulatory_cascade_item
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger (id BIGSERIAL PK — S2-28)
CREATE TRIGGER audit_regulatory_cascade_item_changes
  AFTER INSERT OR UPDATE OR DELETE ON regulatory_cascade_item
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (284, '284_crm_create_regulatory_cascade_item', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TABLE IF EXISTS regulatory_cascade_item CASCADE;
-- DELETE FROM schema_migrations WHERE version = 284;
-- COMMIT;
-- ============================================================
