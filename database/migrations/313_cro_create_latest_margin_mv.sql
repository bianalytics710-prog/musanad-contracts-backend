-- Migration: 313_cro_create_latest_margin_mv.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: CREATE MATERIALIZED VIEW latest_margin — one row per (tenant_id, trade_position_id),
--              the most recent margin_snapshot per position. Mirrors latest_risk_score (mig 170).
--              UNIQUE INDEX (tenant_id, trade_position_id) for future REFRESH CONCURRENTLY upgrade.
--              2 secondary indexes for side-filter + AED sort.
--              REVOKE ALL FROM PUBLIC + GRANT SELECT TO neondb_owner (S2-21 MV trio).
--              CRITICAL A3 CONTRACT: RLS does NOT apply to MV rows. Every SELECT from latest_margin
--              in fn bodies MUST include explicit:
--                WHERE tenant_id = current_setting('app.current_tenant_id', true)::uuid
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE MATERIALIZED VIEW latest_margin AS
SELECT DISTINCT ON (tenant_id, trade_position_id)
  id AS margin_snapshot_id,
  tenant_id, trade_position_id, side,
  benchmark_code_used, benchmark_price_used,
  revenue_per_bbl, cost_per_bbl, margin_per_bbl, volume_bbl,
  total_margin_usd, usd_aed_rate, total_margin_aed,
  recommendation, breakdown, computed_at, triggered_by
FROM margin_snapshot
ORDER BY tenant_id, trade_position_id, computed_at DESC;

-- UNIQUE INDEX: required for REFRESH MATERIALIZED VIEW CONCURRENTLY upgrade path (CR-F lesson)
CREATE UNIQUE INDEX latest_margin_pk ON latest_margin (tenant_id, trade_position_id);

CREATE INDEX idx_latest_margin_tenant_side  ON latest_margin (tenant_id, side);
CREATE INDEX idx_latest_margin_tenant_total ON latest_margin (tenant_id, total_margin_aed DESC NULLS LAST);

-- S2-21 MV access trio: REVOKE ALL FROM PUBLIC + GRANT SELECT TO neondb_owner
REVOKE ALL ON latest_margin FROM PUBLIC;
GRANT SELECT ON latest_margin TO neondb_owner;

COMMENT ON MATERIALIZED VIEW latest_margin IS
  'CR-O (313): One row per (tenant_id, trade_position_id) — the most recent margin_snapshot per position. DISTINCT ON (tenant_id, trade_position_id) ORDER BY computed_at DESC. Projects margin_snapshot_id + 16 cols. Refresh: synchronous inside fn_margin_compute (after INSERT). UNIQUE INDEX latest_margin_pk for future REFRESH CONCURRENTLY upgrade at pilot scale. CRITICAL A3: RLS does NOT apply to MV rows — every SELECT from this MV in fn bodies MUST include explicit WHERE tenant_id = current_setting(''app.current_tenant_id'', true)::uuid. MV access: REVOKE ALL FROM PUBLIC + GRANT SELECT TO neondb_owner (S2-21 MV trio).';

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (313, '313_cro_create_latest_margin_mv', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 313;
-- DROP MATERIALIZED VIEW IF EXISTS latest_margin CASCADE;
-- COMMIT;
-- ============================================================
