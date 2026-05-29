-- Migration: 309_cro_create_price_benchmark.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: CREATE TABLE price_benchmark — typed time-series table for benchmark price observations.
--              FORCE RLS + 3 policies (finance.margin.read / finance.trade.manage / deny direct DELETE).
--              Audit trigger binding. BIGSERIAL PK → standard fn_audit_trigger applies.
--              NUMERIC(12,4) per-bbl prices; UNIQUE (tenant_id, benchmark_code, price_date) for idempotent re-seed.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE TABLE price_benchmark (
  id              BIGSERIAL PRIMARY KEY,
  tenant_id       UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,

  benchmark_code  TEXT NOT NULL
    CHECK (benchmark_code IN ('murban_osp','brent','dubai','wti','west_african_x','usd_aed')),
  price_date      DATE NOT NULL,
  price_value     NUMERIC(12,4) NOT NULL CHECK (price_value >= 0),
  unit            TEXT NOT NULL DEFAULT 'usd_per_bbl'
    CHECK (unit IN ('usd_per_bbl','aed_per_usd')),
  period_grain    TEXT NOT NULL DEFAULT 'monthly'
    CHECK (period_grain IN ('monthly','daily','spot')),
  source          TEXT NOT NULL DEFAULT 'mock'
    CHECK (source IN ('osp_official','market','mock')),
  notes           TEXT,
  data_classification TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),

  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by      BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by      BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,

  -- One observation per (tenant, benchmark, date) — idempotent re-seed + recompute insert
  CONSTRAINT price_benchmark_idempotency_key UNIQUE (tenant_id, benchmark_code, price_date)
);

COMMENT ON TABLE price_benchmark IS
  'CR-O M21 Financial Intelligence (Trade half) — typed time-series of benchmark price observations. Keyed by (benchmark_code, price_date). Monthly OSP = first of month; spot = trade date. usd_aed row (unit=aed_per_usd) is the FX conversion rate. NUMERIC(12,4) per-bbl / NUMERIC(12,4) FX — never float. Tenant-scoped FORCE RLS. UNIQUE (tenant_id, benchmark_code, price_date) for idempotent upsert.';
COMMENT ON COLUMN price_benchmark.benchmark_code IS 'murban_osp | brent | dubai | wti | west_african_x | usd_aed. usd_aed rows have unit=aed_per_usd; all others usd_per_bbl.';
COMMENT ON COLUMN price_benchmark.price_value IS 'Benchmark price. NUMERIC(12,4). For usd_aed rows: AED per 1 USD (≈3.6725). For crude rows: USD per barrel.';
COMMENT ON COLUMN price_benchmark.period_grain IS 'monthly (first-of-month OSP), daily (market close), spot (trade date).';

-- Indexes
CREATE INDEX idx_price_benchmark_tenant_id    ON price_benchmark(tenant_id);
CREATE INDEX idx_price_benchmark_code_date    ON price_benchmark(tenant_id, benchmark_code, price_date DESC);
CREATE INDEX idx_price_benchmark_created_by   ON price_benchmark(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_price_benchmark_updated_by   ON price_benchmark(updated_by) WHERE updated_by IS NOT NULL;
CREATE INDEX idx_price_benchmark_active       ON price_benchmark(id) WHERE is_active = TRUE;

-- RLS
ALTER TABLE price_benchmark ENABLE ROW LEVEL SECURITY;
ALTER TABLE price_benchmark FORCE  ROW LEVEL SECURITY;

CREATE POLICY price_benchmark_tenant_select ON price_benchmark
  FOR SELECT USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.margin.read')
  );

CREATE POLICY price_benchmark_tenant_modify ON price_benchmark
  FOR ALL USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.trade.manage')
  ) WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('finance.trade.manage')
  );

CREATE POLICY price_benchmark_deny_direct_delete ON price_benchmark
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger — BIGSERIAL id → standard fn_audit_trigger applies (S2-28)
CREATE TRIGGER audit_price_benchmark_changes
  AFTER INSERT OR UPDATE OR DELETE ON price_benchmark
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (309, '309_cro_create_price_benchmark', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_price_benchmark_changes ON price_benchmark;
-- DROP POLICY IF EXISTS price_benchmark_deny_direct_delete ON price_benchmark;
-- DROP POLICY IF EXISTS price_benchmark_tenant_modify ON price_benchmark;
-- DROP POLICY IF EXISTS price_benchmark_tenant_select ON price_benchmark;
-- DROP TABLE IF EXISTS price_benchmark;
-- DELETE FROM schema_migrations WHERE version = 309;
-- COMMIT;
-- ============================================================
