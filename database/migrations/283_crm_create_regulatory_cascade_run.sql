-- Migration: 283_crm_create_regulatory_cascade_run.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: CREATE regulatory_cascade_run — append-only header for one labor-law cascade
--              execution. Mirrors the risk_score (169) append-only snapshot pattern.
--              FORCE RLS (3 policies) + audit trigger + indexes + COMMENTs.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE TABLE regulatory_cascade_run (
  id                          BIGSERIAL PRIMARY KEY,
  tenant_id                   UUID         NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,

  -- The driving regulation signal (osint_signal is the M7 store; impact_signal is a back-compat VIEW).
  signal_id                   BIGINT       NOT NULL REFERENCES osint_signal(id) ON DELETE RESTRICT,
  regulation_ref              TEXT,        -- denormalized citation snapshot (e.g. 'Federal Decree-Law No. 9 of 2024')

  status                      TEXT         NOT NULL DEFAULT 'completed'
                                CHECK (status IN ('running','completed','failed')),
  summary                     JSONB        NOT NULL DEFAULT '{}'::jsonb,  -- counts + totals (byBand + totals + generatedAt)
  params                      JSONB        NOT NULL DEFAULT '{}'::jsonb,  -- run params snapshot (clauseTypes, bandConfig)
  affected_contractor_count   INTEGER      NOT NULL DEFAULT 0,
  total_penalty_min_aed       NUMERIC(18,2) NOT NULL DEFAULT 0,
  total_penalty_max_aed       NUMERIC(18,2) NOT NULL DEFAULT 0,

  data_classification         TEXT         NOT NULL DEFAULT 'demo'
                                CHECK (data_classification IN ('demo','pilot','production')),

  -- Append-only header: created_* only (mirrors risk_score 169).
  -- updated_* present to allow status running→completed transition within the same fn/tx.
  run_at                      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  created_at                  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at                  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  created_by                  BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by                  BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                   BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE regulatory_cascade_run IS
  'CR-M — header for one labor-law cascade execution (signal fanned across contractors). Append-only audit of each run. summary JSONB carries band breakdown + totals. Soft-delete only; FORCE RLS tenant-scoped.';
COMMENT ON COLUMN regulatory_cascade_run.signal_id IS 'FK -> osint_signal.id (e.g. the seeded Federal Decree-Law No.9/2024 row).';
COMMENT ON COLUMN regulatory_cascade_run.summary IS 'JSONB: {byBand:{...}, totals:{...}, generatedAt}. Not sensitive.';

CREATE INDEX idx_reg_cascade_run_tenant_id     ON regulatory_cascade_run(tenant_id);
CREATE INDEX idx_reg_cascade_run_signal_id     ON regulatory_cascade_run(signal_id);
CREATE INDEX idx_reg_cascade_run_created_by    ON regulatory_cascade_run(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_reg_cascade_run_updated_by    ON regulatory_cascade_run(updated_by) WHERE updated_by IS NOT NULL;
CREATE INDEX idx_reg_cascade_run_active        ON regulatory_cascade_run(id) WHERE is_active = TRUE;
CREATE INDEX idx_reg_cascade_run_tenant_run_at ON regulatory_cascade_run(tenant_id, run_at DESC) WHERE is_active = TRUE;

ALTER TABLE regulatory_cascade_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE regulatory_cascade_run FORCE  ROW LEVEL SECURITY;

CREATE POLICY reg_cascade_run_tenant_select ON regulatory_cascade_run
  FOR SELECT USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('regulatory.cascade.read')
  );

-- Modify policy: DEFINER fn_regulatory_cascade_run INSERT/UPDATE bypass RLS; write gate enforced in fn body.
CREATE POLICY reg_cascade_run_tenant_modify ON regulatory_cascade_run
  FOR ALL USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
  ) WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
  );

CREATE POLICY reg_cascade_run_deny_direct_delete ON regulatory_cascade_run
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger (id BIGSERIAL PK — S2-28)
CREATE TRIGGER audit_regulatory_cascade_run_changes
  AFTER INSERT OR UPDATE OR DELETE ON regulatory_cascade_run
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (283, '283_crm_create_regulatory_cascade_run', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TABLE IF EXISTS regulatory_cascade_run CASCADE;
-- DELETE FROM schema_migrations WHERE version = 283;
-- COMMIT;
-- ============================================================
