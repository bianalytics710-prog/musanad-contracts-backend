-- Migration: 170_crf_create_latest_risk_score_mv.sql
-- Module: M14 — CR-F (5-Dim Risk Scoring + MaR + AVaR)
-- Description: CREATE MATERIALIZED VIEW latest_risk_score (DISTINCT ON tenant_id + contract_id
--   ORDER BY tenant_id, contract_id, calculated_at DESC) — the project's FIRST materialized view.
--   + UNIQUE INDEX (tenant_id, contract_id) — enables future REFRESH MATERIALIZED VIEW CONCURRENTLY.
--   + 2 secondary indexes for executive dashboard top-N + AVaR sort.
--   + REVOKE ALL FROM PUBLIC + GRANT SELECT TO neondb_owner (S2-21 MV access trio).
--   + COMMENT ON MATERIALIZED VIEW documenting tenant-scoping contract (A3 non-negotiable).
--
--   CRITICAL A3 CONTRACT: RLS does NOT apply to MV rows in PostgreSQL. Every SELECT from
--   latest_risk_score in fn bodies MUST include explicit:
--     WHERE tenant_id = current_setting('app.current_tenant_id', true)::uuid
--   Enforced in fn_risk_score_explain (Step 2), fn_avar_aggregate (CTE filtered), fn_risk_score_history
--   (reads risk_score directly, not MV). QA Stage 2 S2-22c check verifies.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE MATERIALIZED VIEW latest_risk_score AS
SELECT DISTINCT ON (tenant_id, contract_id)
  id              AS risk_score_id,
  tenant_id,
  contract_id,
  health_score,
  dim_legal,
  dim_financial,
  dim_operational,
  dim_reputational,
  dim_compliance,
  mar_value,
  mar_currency,
  contributing_correlations,
  explanation,
  weights_version,
  calculated_at,
  triggered_by
FROM risk_score
ORDER BY tenant_id, contract_id, calculated_at DESC;

-- UNIQUE INDEX: required for future REFRESH MATERIALIZED VIEW CONCURRENTLY upgrade path.
-- v1 uses non-concurrent REFRESH (acceptable at < 100 contracts, < 1s per NFR-3).
-- CONCURRENT refresh is safe once this UNIQUE INDEX exists — one-line swap in fn_risk_score_compute Step 14.
CREATE UNIQUE INDEX latest_risk_score_pk
  ON latest_risk_score (tenant_id, contract_id);

-- Drives executive "top-N high risk contracts" widget + fn_avar_aggregate sorting
CREATE INDEX idx_latest_risk_score_tenant_health
  ON latest_risk_score (tenant_id, health_score DESC);

-- Drives fn_avar_aggregate breakdown by MaR
CREATE INDEX idx_latest_risk_score_tenant_mar
  ON latest_risk_score (tenant_id, mar_value DESC NULLS LAST);

-- S2-21 MV access trio: mirror fn_ REVOKE/GRANT pattern extended to MV
REVOKE ALL ON latest_risk_score FROM PUBLIC;
GRANT SELECT ON latest_risk_score TO neondb_owner;

COMMENT ON MATERIALIZED VIEW latest_risk_score IS
  'One row per (tenant_id, contract_id) — the most recent risk_score snapshot per contract. DISTINCT ON (tenant_id, contract_id) ORDER BY calculated_at DESC. Projects 15 cols from risk_score (id aliased risk_score_id). REFRESH strategy: v1 synchronous inside fn_risk_score_compute Step 14 (< 1s at < 100 contracts per NFR-3). Pilot upgrade: REFRESH MATERIALIZED VIEW CONCURRENTLY (UNIQUE INDEX latest_risk_score_pk already in place). CRITICAL A3: RLS does NOT apply to MV rows — every SELECT from this MV in fn bodies MUST include explicit WHERE tenant_id = current_setting(''app.current_tenant_id'', true)::uuid. MV access: REVOKE ALL FROM PUBLIC + GRANT SELECT TO neondb_owner (S2-21 MV trio).';

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (170, '170_crf_create_latest_risk_score_mv', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 170;
-- DROP MATERIALIZED VIEW IF EXISTS latest_risk_score CASCADE;
-- COMMIT;
-- ============================================================
