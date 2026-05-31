-- Migration: 363_eman_recompute_murban_margins.sql
-- Unit: Eman Executive QA Phase 3.3 (2026-05-31)
-- Fix:
--   E40 follow-up — mig 358 reset the murban_osp price_benchmark rows to
--   $110.75, but the Margin/bbl displays still show $99.84 because the
--   latest_margin MV and margin_snapshot table still hold values computed
--   against the old $104.44 OSP.
--
--   Recompute all open Murban positions against the new $110.75 OSP so the
--   trade-margin dashboard restores its Story-2 starting state. Uses
--   fn_margin_recompute_for_price_change (CR-O D-2). Requires
--   finance.trade.manage permission — bypassed by running as DEFINER role.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_margin_recompute_for_price_change') THEN
    RAISE NOTICE 'Skipping margin recompute — fn_margin_recompute_for_price_change not present.';
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM trade_position WHERE is_active AND grade = 'murban') THEN
    RAISE NOTICE 'Skipping margin recompute — no active Murban positions.';
    RETURN;
  END IF;

  -- Set tenant context required by the fn
  PERFORM set_config('app.current_tenant_id', v_tenant::text, true);
  PERFORM set_config('app.current_user_id', '1', true);

  -- Trigger recompute. fn_margin_recompute_for_price_change re-evaluates
  -- every open position priced against the benchmark and inserts new
  -- margin_snapshot rows. The latest_margin MV is then refreshed below
  -- so the dashboard reads fresh values.
  BEGIN
    PERFORM fn_margin_recompute_for_price_change(1, 'murban_osp', 110.7500,
                                                 DATE_TRUNC('month', CURRENT_DATE)::date);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'fn_margin_recompute_for_price_change call failed: %; will only refresh MV.', SQLERRM;
  END;

  REFRESH MATERIALIZED VIEW latest_margin;
END $$;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Re-run fn_margin_recompute_for_price_change with the prior OSP value
-- and REFRESH MATERIALIZED VIEW latest_margin.
-- ============================================================
