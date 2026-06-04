-- Migration: 495_trade_position_band_restructure_for_demo.sql
-- Module: Trade Margin — Story 5a outside-band scenario mix
-- Date: 2026-06-02
--
-- User feedback: most real contracts negotiate a band, so having 2 of 7
-- positions with NO clause overstates the risk. Restructure so we have
-- exactly 3 outside-band scenarios:
--
--   - 2 positions with a band BUT above ceiling   → escalate = drafter
--     should renegotiate band + revamp pricing
--   - 1 position with NO band                      → escalate = drafter
--     should draft amendment to ADD a price-protection clause
--
-- Per-position changes:
--   TP-MURBAN-KR-JUL26  → tighten ceiling 110 → 102 so OSP $103 breaches
--                         it (above_ceiling, has clause)
--   TP-MURBAN-JP-NOV26  → give it back a band ($95-$108), within
--   TP-MURBAN-SE-DEC26  → unchanged ($97-$102 above ceiling, has clause)
--   TP-MURBAN-SG-SEP26  → unchanged (no band)
--
-- Recompute margins for KR-JUL26 to reflect the tighter band: when buyer
-- can invoke price-review, realized falls toward ceiling so margin
-- compresses (we drop margin_per_bbl from $2.80 to a small positive — the
-- band breach signals the action, not the still-positive margin).

DO $$
DECLARE
  v_tenant   UUID := '00000000-0000-0000-0000-000000000001';
  v_actor    BIGINT := 1;
  v_usd_aed  NUMERIC := 3.67;
  rec        RECORD;
  v_pos_id   BIGINT;
  v_volume   NUMERIC;
  v_premium  NUMERIC;
  v_freight  NUMERIC;
  v_insurance NUMERIC;
  v_hedge    NUMERIC;
  v_margin   NUMERIC;
  v_total_usd NUMERIC;
  v_total_aed NUMERIC;
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::TEXT, true);

  -- (A) KR-JUL26 — tighten ceiling so it breaches.
  UPDATE trade_position
    SET contracted_ceiling_usd_per_bbl = 102.00,
        band_review_clause_ref         = 'Clause 7.3 — Price Review Window (above ceiling)'
    WHERE position_ref = 'TP-MURBAN-KR-JUL26';

  -- (B) JP-NOV26 — restore a band, within.
  UPDATE trade_position
    SET contracted_floor_usd_per_bbl   = 95.00,
        contracted_ceiling_usd_per_bbl = 108.00,
        band_review_clause_ref         = 'Clause 7.3 — Price Review Window'
    WHERE position_ref = 'TP-MURBAN-JP-NOV26';

  -- (C) KR-JUL26 — re-snapshot margin to reflect the breach. Pull the
  -- existing premium/freight/insurance/hedge from the cost_components and
  -- compute realized = min(buyer_premium, ceiling - OSP + buyer_premium).
  -- For demo simplicity: margin = premium - costs - $1.50/bbl (the assumed
  -- realized loss from buyer invoking the price-review window).
  SELECT id, volume_bbl INTO v_pos_id, v_volume
    FROM trade_position WHERE position_ref = 'TP-MURBAN-KR-JUL26';
  SELECT amount_usd_per_bbl::NUMERIC INTO v_premium
    FROM trade_cost_component
    WHERE trade_position_id = v_pos_id AND is_revenue = TRUE AND is_active = TRUE
    LIMIT 1;
  SELECT SUM(amount_usd_per_bbl::NUMERIC) INTO v_freight
    FROM trade_cost_component
    WHERE trade_position_id = v_pos_id AND is_revenue = FALSE AND is_active = TRUE;

  IF v_pos_id IS NOT NULL AND v_premium IS NOT NULL AND v_freight IS NOT NULL THEN
    -- Compressed margin = premium - costs - 1.50 (buyer price-review impact)
    v_margin    := v_premium - v_freight - 1.50;
    v_total_usd := v_margin * v_volume;
    v_total_aed := v_total_usd * v_usd_aed;
    INSERT INTO margin_snapshot (
      tenant_id, trade_position_id, side, benchmark_code_used,
      benchmark_price_used, revenue_per_bbl, cost_per_bbl,
      margin_per_bbl, volume_bbl, total_margin_usd, usd_aed_rate,
      total_margin_aed, recommendation, computed_at, triggered_by,
      created_by, data_classification
    ) VALUES (
      v_tenant, v_pos_id, 'sell', 'murban_osp',
      103.00,
      103.00 + v_premium - 1.50,
      v_freight + 1.50,
      v_margin, v_volume, v_total_usd, v_usd_aed, v_total_aed,
      NULL, NOW(), 'manual',
      v_actor, 'demo'
    );
  END IF;

  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY latest_margin;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW latest_margin;
  END;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (495, '495_trade_position_band_restructure_for_demo', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;
