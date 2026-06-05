-- Migration: 593_fix_kr_jul26_honest_margin.sql
-- Module: Index-Linked Contracts — separate current margin from at-risk margin
-- Date: 2026-06-05
--
-- The original demo seed (mig 495) baked a $1.50/bbl "price-review concession"
-- into the margin row for TP-MURBAN-KR-JUL26, on the assumption that the
-- buyer (Hanwha) would invoke Clause 7.3 since Murban OSP ($103) is above
-- the ceiling ($102). Result: the table showed margin_per_bbl = $1.30 and
-- total_margin_aed = AED 9.5M, which conflated two different things:
--
--   1. The current/realized margin (premium $7.25 - costs $4.45 = $2.80/bbl
--      = AED 20.5M)
--   2. The forward-only exposure if the buyer invokes the clause
--      (AED 7.3M — already surfaced via the new sidecar in mig 592)
--
-- This made the UI confusing: the "Total margin" column was actually
-- "margin AFTER assuming the buyer invokes review", not the headline
-- current-earning number.
--
-- Fix: insert a fresh margin_snapshot row for KR-JUL26 with the honest
-- premium-minus-costs margin. Refresh latest_margin so all downstream
-- consumers (module table, exec rollup, what-if panel) see the honest
-- number. The forward-exposure story is already told by mig 592's
-- outsideBand.marginImpactAed (AED 7.3M) — the two numbers now coexist
-- cleanly:
--
--   Current margin  = AED 20.5M  ("what we earn this month if nothing changes")
--   Margin impact   = AED  7.3M  ("forward exposure if buyer invokes review")

BEGIN;

DO $$
DECLARE
  v_tenant     UUID    := '00000000-0000-0000-0000-000000000001';
  v_actor      BIGINT  := 1;
  v_usd_aed    NUMERIC := 3.67;
  v_pos_id     BIGINT;
  v_volume     NUMERIC;
  v_premium    NUMERIC;
  v_costs      NUMERIC;
  v_margin     NUMERIC;
  v_revenue    NUMERIC;
  v_cost_total NUMERIC;
  v_osp        NUMERIC := 103.00;
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::TEXT, true);

  SELECT id, volume_bbl
    INTO v_pos_id, v_volume
    FROM trade_position
   WHERE position_ref = 'TP-MURBAN-KR-JUL26';
  IF v_pos_id IS NULL THEN
    RAISE NOTICE 'TP-MURBAN-KR-JUL26 not found in this tenant — skipping';
    RETURN;
  END IF;

  -- Sum the cost-component rows: positive (revenue) = premium; negative
  -- (cost) = costs. Both came from the seed, so they're authoritative.
  SELECT
    COALESCE(SUM(amount_usd_per_bbl::NUMERIC) FILTER (WHERE is_revenue = TRUE), 0),
    COALESCE(SUM(amount_usd_per_bbl::NUMERIC) FILTER (WHERE is_revenue = FALSE), 0)
    INTO v_premium, v_costs
    FROM trade_cost_component
   WHERE trade_position_id = v_pos_id AND is_active = TRUE;

  -- Honest margin = premium - costs. No pre-discounting for the clause-
  -- invocation scenario — that's reported separately via the outsideBand
  -- side-car (mig 592).
  v_margin     := v_premium - v_costs;
  v_revenue    := v_osp + v_premium;
  v_cost_total := v_osp + v_costs;

  INSERT INTO margin_snapshot (
    tenant_id, trade_position_id, side, benchmark_code_used,
    benchmark_price_used, revenue_per_bbl, cost_per_bbl,
    margin_per_bbl, volume_bbl, total_margin_usd, usd_aed_rate,
    total_margin_aed, recommendation, computed_at, triggered_by,
    created_by, data_classification
  ) VALUES (
    v_tenant, v_pos_id, 'sell', 'murban_osp',
    v_osp,
    v_revenue,
    v_cost_total,
    v_margin,
    v_volume,
    v_margin * v_volume,
    v_usd_aed,
    v_margin * v_volume * v_usd_aed,
    'review',  -- buyer can invoke price review at this OSP
    NOW(),
    'manual',
    v_actor,
    'demo'
  );

  -- Refresh the materialised view that powers the position list + exec
  -- rollup. CONCURRENTLY first; fall back to plain refresh if the
  -- concurrent path can't acquire (e.g. first refresh after schema change).
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY latest_margin;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW latest_margin;
  END;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (593, '593_fix_kr_jul26_honest_margin', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- -- The pre-mig-593 row from mig 495 is still in margin_snapshot; deactivating
-- -- the row inserted here and refreshing the MV restores the old number.
-- UPDATE margin_snapshot
--    SET is_active = FALSE
--  WHERE trade_position_id = (SELECT id FROM trade_position WHERE position_ref = 'TP-MURBAN-KR-JUL26')
--    AND triggered_by = 'manual'
--    AND created_at >= NOW() - INTERVAL '5 minutes';
-- REFRESH MATERIALIZED VIEW latest_margin;
-- DELETE FROM schema_migrations WHERE version = 593;
-- COMMIT;
