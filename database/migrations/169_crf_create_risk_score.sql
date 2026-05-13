-- Migration: 169_crf_create_risk_score.sql
-- Module: M14 — CR-F (5-Dim Risk Scoring + MaR + AVaR)
-- Description: CREATE TABLE risk_score (18 columns, append-only, BIGSERIAL PK) +
--   4 indexes + FORCE RLS + 3 policies (tenant_select / tenant_modify / deny_direct_delete RESTRICTIVE)
--   + audit_risk_score_changes trigger (AFTER INSERT only) + table/column COMMENTs.
--   Pattern mirrors migration 151 (correlation) RLS pattern.
--   S2-22: all 18 INSERT columns verified against DDL below.
--   S2-23: FK targets verified — tenant(id) UUID M7 ✓, contract(id) BIGINT M1a ✓, "user"(id) BIGINT M0 ✓.
--   S2-28: risk_score has id BIGSERIAL PK — default fn_audit_trigger applies (no Strategy A/B carve-out).
--   Append-only semantics: no updated_at / updated_by / is_active (mirrors M0 audit_log precedent).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE TABLE risk_score (
  id                        BIGSERIAL PRIMARY KEY,
  tenant_id                 UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  contract_id               BIGINT NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,

  -- Composite + per-dimension scores (all 0..100 integer)
  health_score              INTEGER NOT NULL CHECK (health_score BETWEEN 0 AND 100),
  dim_legal                 INTEGER NOT NULL CHECK (dim_legal BETWEEN 0 AND 100),
  dim_financial             INTEGER NOT NULL CHECK (dim_financial BETWEEN 0 AND 100),
  dim_operational           INTEGER NOT NULL CHECK (dim_operational BETWEEN 0 AND 100),
  dim_reputational          INTEGER NOT NULL CHECK (dim_reputational BETWEEN 0 AND 100),
  dim_compliance            INTEGER NOT NULL CHECK (dim_compliance BETWEEN 0 AND 100),

  -- Money at Risk (locked-at-correlation per HITL Q1 — currency snapshot included)
  mar_value                 NUMERIC(18,2)
    CHECK (mar_value IS NULL OR mar_value >= 0),
  mar_currency              CHAR(3) NOT NULL DEFAULT 'AED',

  -- Reason codes + contributing correlations (SENSITIVE — fn_audit_trigger redacts both)
  contributing_correlations JSONB NOT NULL DEFAULT '[]'::jsonb,
  explanation               JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Snapshot anchors
  weights_version           TEXT NOT NULL,
  calculated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  triggered_by              TEXT NOT NULL
    CHECK (triggered_by IN ('signal','clause_change','weight_change','scheduled','manual','bootstrap')),

  -- Data classification (CR-C/CR-D/CR-E precedent)
  data_classification       TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),

  -- Append-only audit columns (mirrors M0 audit_log — no updated_at / updated_by / is_active)
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by                BIGINT REFERENCES "user"(id) ON DELETE SET NULL
);

-- ============================================================
-- Indexes (4 total — per db-design.md §1.2)
-- ============================================================

-- Primary read path: latest snapshot per (tenant, contract) + history queries
-- Drives DISTINCT ON in latest_risk_score MV refresh + fn_risk_score_history filter
CREATE INDEX idx_risk_score_tenant_contract_calc
  ON risk_score (tenant_id, contract_id, calculated_at DESC);

-- AVaR top-N high-risk contracts + executive sorting by health
CREATE INDEX idx_risk_score_tenant_health
  ON risk_score (tenant_id, health_score);

-- AVaR time-series + admin "recent recomputes" view
CREATE INDEX idx_risk_score_tenant_calc
  ON risk_score (tenant_id, calculated_at DESC);

-- Bulk recompute audit (partial — only triggered_by='weight_change' ~5% of rows)
CREATE INDEX idx_risk_score_weight_change
  ON risk_score (weights_version, calculated_at DESC)
  WHERE triggered_by = 'weight_change';

-- QA Stage 2 W1: partial index on created_by (FK audit queries; partial for rows with created_by populated)
CREATE INDEX idx_risk_score_created_by
  ON risk_score (created_by)
  WHERE created_by IS NOT NULL;

-- ============================================================
-- Row Level Security (mirrors correlation table 151 pattern)
-- ============================================================

-- Enable RLS
ALTER TABLE risk_score ENABLE ROW LEVEL SECURITY;
-- Force RLS even for table owner (defence-in-depth)
ALTER TABLE risk_score FORCE ROW LEVEL SECURITY;

-- Policy 1 — Tenant SELECT (GUC-scoped)
CREATE POLICY risk_score_tenant_select ON risk_score
  FOR SELECT
  USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

-- Policy 2 — Tenant MODIFY (PERMISSIVE — DEFINER-context writes from fn_risk_score_compute pass this)
CREATE POLICY risk_score_tenant_modify ON risk_score
  FOR ALL
  USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  )
  WITH CHECK (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

-- Policy 3 — Deny direct DELETE (RESTRICTIVE — append-only semantics)
CREATE POLICY risk_score_deny_direct_delete ON risk_score
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

-- ============================================================
-- Audit trigger (AFTER INSERT only — append-only semantics per AC-S17-04)
-- fn_audit_trigger is extended in migration 173 to redact contributing_correlations + explanation
-- ============================================================

CREATE TRIGGER audit_risk_score_changes
  AFTER INSERT ON risk_score
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ============================================================
-- Table and column COMMENTs
-- ============================================================

COMMENT ON TABLE risk_score IS
  'Append-only risk score snapshots — one row per recompute per contract. health_score (0..100) is the weighted composite. mar_value captures Money at Risk in AED. contributing_correlations + explanation JSONB are redacted in audit_log (fn_audit_trigger 173). Append-only: no updated_at/updated_by/is_active. Immutability enforced by risk_score_deny_direct_delete RESTRICTIVE RLS policy.';

COMMENT ON COLUMN risk_score.id IS 'BIGSERIAL PK — append-only row identifier.';
COMMENT ON COLUMN risk_score.tenant_id IS 'Tenant scoping UUID (FK → tenant.id). RLS enforces isolation via GUC app.current_tenant_id.';
COMMENT ON COLUMN risk_score.contract_id IS 'FK → contract.id. Indexed via idx_risk_score_tenant_contract_calc.';
COMMENT ON COLUMN risk_score.health_score IS 'Composite risk score 0..100 = weighted sum of 5 dim scores. 0 = healthiest, 100 = maximum risk.';
COMMENT ON COLUMN risk_score.dim_legal IS 'Legal dimension score 0..100 = prob × impact for sanctions + regulatory rules.';
COMMENT ON COLUMN risk_score.dim_financial IS 'Financial dimension score 0..100 = prob × impact for market + disruption + counterparty rules.';
COMMENT ON COLUMN risk_score.dim_operational IS 'Operational dimension score 0..100 = prob × impact for geopolitical + cyber + disruption rules.';
COMMENT ON COLUMN risk_score.dim_reputational IS 'Reputational dimension score 0..100 = prob × impact for geopolitical + counterparty rules.';
COMMENT ON COLUMN risk_score.dim_compliance IS 'Compliance dimension score 0..100 = prob × impact for sanctions + regulatory + cyber rules.';
COMMENT ON COLUMN risk_score.mar_value IS 'Money at Risk in AED. NULL if contract.value_aed IS NULL (HITL Q5). Non-negative (CHECK constraint).';
COMMENT ON COLUMN risk_score.mar_currency IS 'Currency of mar_value. CHAR(3) default ''AED''. v1 AED-only; multi-currency raises 22023.';
COMMENT ON COLUMN risk_score.contributing_correlations IS 'JSONB array of correlation contributions with marContribution, probability, impactMultiplier, dimensionsAffected per element. SENSITIVE — redacted in audit_log via fn_audit_trigger migration 173.';
COMMENT ON COLUMN risk_score.explanation IS 'JSONB with dimensions breakdown, marFormula, weightsAtCalculation, contributingClauses. SENSITIVE — redacted in audit_log.';
COMMENT ON COLUMN risk_score.weights_version IS 'Version string of scoring.weights config at compute time (e.g. ''1''). Allows historical weight tracing.';
COMMENT ON COLUMN risk_score.calculated_at IS 'Timestamp of this snapshot computation. Used for DISTINCT ON in latest_risk_score MV.';
COMMENT ON COLUMN risk_score.triggered_by IS 'Trigger source: signal | clause_change | weight_change | scheduled | manual | bootstrap.';
COMMENT ON COLUMN risk_score.data_classification IS 'Data classification tier: demo | pilot | production. Default ''demo''.';
COMMENT ON COLUMN risk_score.created_at IS 'Row creation timestamp (append-only; no updated_at).';
COMMENT ON COLUMN risk_score.created_by IS 'FK → user.id. NULL when triggered by system-actor sentinel (worker/scheduler/bootstrap; p_actor_id=0 → NULL per S2-20).';

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (169, '169_crf_create_risk_score', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 169;
-- DROP TABLE IF EXISTS risk_score CASCADE;
-- COMMIT;
-- ============================================================
