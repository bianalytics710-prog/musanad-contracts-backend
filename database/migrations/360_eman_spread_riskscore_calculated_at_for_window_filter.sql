-- Migration: 360_eman_spread_riskscore_calculated_at_for_window_filter.sql
-- Unit: Eman Executive QA Phase 3.3 (2026-05-31)
-- Fix:
--   E2 — Date filter (Last 7 / 30 / 90 days) is a no-op for the 3 top AVaR
--        KPIs. Root cause: fn_avar_aggregate already filters
--        latest_risk_score by `calculated_at >= window_from`, BUT the
--        seeded risk_score rows from mig 355 all have calculated_at within
--        the last ~36 hours, so 7d/30d/90d windows all match.
--
--        Fix: spread the seeded risk_score rows' calculated_at across the
--        full 0..85 day range (using id-modulo bucketing so the
--        distribution is deterministic), then REFRESH the MV. After this,
--        choosing 7d gives the user the most-recent slice, 30d shows ~1/3
--        of rows, 90d shows everything.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
  v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM risk_score WHERE tenant_id = v_tenant;
  IF v_count < 50 THEN
    RAISE NOTICE 'Skipping risk_score timestamp spread — only % rows.', v_count;
    RETURN;
  END IF;

  -- Spread calculated_at across recent past.
  -- For our seeded rows (correlationId between 100000..700000), distribute
  -- across 0..85 days so 7/30/90-day windows show progressively more data.
  UPDATE risk_score rs
    SET calculated_at = NOW() - (((rs.id * 13) % 86) || ' days')::interval
                              - (((rs.id * 7) % 24) || ' hours')::interval
    WHERE rs.tenant_id = v_tenant
      AND jsonb_typeof(rs.contributing_correlations) = 'array'
      AND jsonb_array_length(rs.contributing_correlations) > 0
      AND (rs.contributing_correlations->0->>'correlationId')::bigint >= 100000
      AND (rs.contributing_correlations->0->>'correlationId')::bigint <  700000;

  -- Also push some legacy zero-MAR rows to 60+ days ago to keep the most
  -- recent window populated with non-zero items.
  UPDATE risk_score rs
    SET calculated_at = NOW() - (60 + ((rs.id * 3) % 30) || ' days')::interval
    WHERE rs.tenant_id = v_tenant
      AND rs.mar_value = 0
      AND rs.calculated_at >= NOW() - INTERVAL '7 days';

  REFRESH MATERIALIZED VIEW latest_risk_score;
END $$;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Reset all seeded risk_score rows to a uniform recent timestamp:
--   UPDATE risk_score SET calculated_at = NOW()
--     WHERE tenant_id = '00000000-0000-0000-0000-000000000001';
--   REFRESH MATERIALIZED VIEW latest_risk_score;
-- ============================================================
