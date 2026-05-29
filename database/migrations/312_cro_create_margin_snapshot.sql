-- Migration: 312_cro_create_margin_snapshot.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: CREATE TABLE margin_snapshot — append-only computed margin log (mirrors risk_score).
--              NO updated_at / updated_by / is_active — append-only per S2-28 + audit_log precedent.
--              AFTER INSERT audit trigger only. RESTRICTIVE deny-DELETE policy.
--              NUMERIC(12,4) per-bbl; NUMERIC(18,2) totals; NUMERIC(12,4) FX rate.
--              breakdown JSONB: full revenue/cost waterfall (commercially sensitive — redacted in mig 314).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE TABLE margin_snapshot (
  id                   BIGSERIAL PRIMARY KEY,
  tenant_id            UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  trade_position_id    BIGINT NOT NULL REFERENCES trade_position(id) ON DELETE RESTRICT,

  side                 TEXT NOT NULL CHECK (side IN ('sell','buy')),
  benchmark_code_used  TEXT,
  benchmark_price_used NUMERIC(12,4),
  revenue_per_bbl      NUMERIC(12,4) NOT NULL,
  cost_per_bbl         NUMERIC(12,4) NOT NULL,
  margin_per_bbl       NUMERIC(12,4) NOT NULL,
  volume_bbl           NUMERIC(18,2) NOT NULL,
  total_margin_usd     NUMERIC(18,2) NOT NULL,
  usd_aed_rate         NUMERIC(12,4) NOT NULL,
  total_margin_aed     NUMERIC(18,2) NOT NULL,
  recommendation       TEXT CHECK (recommendation IS NULL OR recommendation IN ('buy','hold','sell','review')),
  breakdown            JSONB NOT NULL DEFAULT '{}'::jsonb,
  computed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  triggered_by         TEXT NOT NULL
    CHECK (triggered_by IN ('manual','price_change','worker','bootstrap')),
  data_classification  TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),

  -- Append-only: NO updated_at / updated_by / is_active (mirrors risk_score + audit_log precedent)
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by           BIGINT REFERENCES "user"(id) ON DELETE SET NULL
);

COMMENT ON TABLE margin_snapshot IS
  'CR-O M21 Financial Intelligence (Trade half) — append-only computed margin log. One row per fn_margin_compute call. Mirrors risk_score: no updated_at/updated_by/is_active. Latest per position exposed via latest_margin MV (mig 313). breakdown JSONB holds full revenue/cost waterfall — commercially sensitive, redacted in fn_audit_trigger (mig 314). NUMERIC(12,4) per-bbl; NUMERIC(18,2) totals; NUMERIC(12,4) FX.';
COMMENT ON COLUMN margin_snapshot.breakdown IS 'COMMERCIALLY SENSITIVE — full revenue/cost waterfall per-bbl. Redacted in fn_audit_trigger (mig 314). Contains: revenue[], costs[], totalCostPerBbl, marginPerBbl, fx.';
COMMENT ON COLUMN margin_snapshot.benchmark_code_used IS 'The benchmark code used for revenue (seller). NULL for buyer (revenue from downstream_sale component).';
COMMENT ON COLUMN margin_snapshot.total_margin_aed IS 'NUMERIC(18,2). total_margin_usd × usd_aed_rate. Frozen at compute time — FX is point-in-time.';

-- Indexes
CREATE INDEX idx_margin_snapshot_tenant_position_computed
  ON margin_snapshot(tenant_id, trade_position_id, computed_at DESC);
CREATE INDEX idx_margin_snapshot_tenant_computed
  ON margin_snapshot(tenant_id, computed_at DESC);
CREATE INDEX idx_margin_snapshot_created_by
  ON margin_snapshot(created_by) WHERE created_by IS NOT NULL;

-- RLS
ALTER TABLE margin_snapshot ENABLE ROW LEVEL SECURITY;
ALTER TABLE margin_snapshot FORCE  ROW LEVEL SECURITY;

CREATE POLICY margin_snapshot_tenant_select ON margin_snapshot
  FOR SELECT USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.margin.read')
  );

CREATE POLICY margin_snapshot_tenant_insert ON margin_snapshot
  FOR INSERT WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.margin.read')
  );

CREATE POLICY margin_snapshot_deny_update_delete ON margin_snapshot
  AS RESTRICTIVE FOR UPDATE USING (FALSE);

CREATE POLICY margin_snapshot_deny_direct_delete ON margin_snapshot
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger — AFTER INSERT only (append-only; no UPDATE/DELETE events)
CREATE TRIGGER audit_margin_snapshot_insert
  AFTER INSERT ON margin_snapshot
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (312, '312_cro_create_margin_snapshot', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_margin_snapshot_insert ON margin_snapshot;
-- DROP POLICY IF EXISTS margin_snapshot_deny_direct_delete ON margin_snapshot;
-- DROP POLICY IF EXISTS margin_snapshot_deny_update_delete ON margin_snapshot;
-- DROP POLICY IF EXISTS margin_snapshot_tenant_insert ON margin_snapshot;
-- DROP POLICY IF EXISTS margin_snapshot_tenant_select ON margin_snapshot;
-- DROP TABLE IF EXISTS margin_snapshot;
-- DELETE FROM schema_migrations WHERE version = 312;
-- COMMIT;
-- ============================================================
