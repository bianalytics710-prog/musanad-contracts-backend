-- Migration: 494_trade_cost_components_clean_math.sql
-- Module: Trade Margin — Margin Breakdown waterfall transparency
-- Date: 2026-06-02
--
-- Problem: The Margin Breakdown waterfall reads `position.costComponents`
-- and derives "Revenue" as (margin + costs) when no is_revenue=true row
-- exists. The seeded components for our 7 Murban sell positions include:
--   lifting $1.20, transport_charter $2.10, insurance $0.45, hedge $0.85
-- → costs = $4.60, margin $3.20 → "Revenue" $7.80 (reads as $8 on chart)
--
-- Two issues:
--   (a) `lifting` is upstream's production cost. AGT (the trading desk) does
--       not pay lifting — it buys from upstream at an internal transfer price
--       of OSP. So including lifting under AGT's cost basis is wrong.
--   (b) No revenue row is set, so the chart can't show the realized sale
--       price (OSP + buyer premium) as a separate bar.
--
-- Fix: rewrite cost components per Murban sell position so the math is
-- self-explanatory:
--   - 1 revenue row (component_type='downstream_sale', is_revenue=TRUE)
--     carrying the **buyer premium above OSP** in $/bbl. The chart already
--     uses this as the Revenue bar.
--   - 3 cost rows: transport_charter (route-specific), insurance, hedge.
--     No lifting — AGT didn't pay it.
--   - Recompute margin_snapshot = premium − (transport + insurance + hedge)
--     and refresh latest_margin.

DO $$
DECLARE
  v_tenant   UUID := '00000000-0000-0000-0000-000000000001';
  v_actor    BIGINT := 1;
  v_usd_aed  NUMERIC := 3.67;
  rec        RECORD;
  v_pos_id   BIGINT;
  v_volume   NUMERIC;
  v_margin   NUMERIC;
  v_total_usd NUMERIC;
  v_total_aed NUMERIC;
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::TEXT, true);

  FOR rec IN
    SELECT * FROM (VALUES
      -- position_ref           buyer_premium  freight  insurance  hedge   freight_note
      ('TP-MURBAN-KR-JUN26',     7.65,         3.20,    0.40,      0.85,   'Suezmax UAE → Yeosu, Korea'),
      ('TP-MURBAN-KR-JUL26',     7.25,         3.20,    0.40,      0.85,   'Suezmax UAE → Yeosu, Korea'),
      ('TP-MURBAN-KR-AUG26',     5.95,         3.20,    0.40,      0.85,   'Suezmax UAE → Yeosu, Korea'),
      ('TP-MURBAN-SG-SEP26',     6.20,         2.75,    0.40,      0.85,   'Suezmax UAE → Singapore Jurong'),
      ('TP-MURBAN-IN-OCT26',     7.30,         2.55,    0.40,      0.85,   'Suezmax UAE → Jamnagar, India'),
      ('TP-MURBAN-JP-NOV26',     6.65,         3.35,    0.40,      0.85,   'Suezmax UAE → Kawasaki, Japan'),
      ('TP-MURBAN-SE-DEC26',     4.85,         4.50,    0.40,      0.85,   'Suezmax UAE → Gothenburg, Sweden (Cape route)')
    ) AS t(position_ref, buyer_premium, freight, insurance, hedge, freight_note)
  LOOP
    SELECT id, volume_bbl INTO v_pos_id, v_volume
      FROM trade_position WHERE position_ref = rec.position_ref;
    IF v_pos_id IS NULL THEN CONTINUE; END IF;

    -- (1) Hard-delete existing components for this position (unique-key
    --     prevents reinsertion when a soft-deleted row exists).
    DELETE FROM trade_cost_component WHERE trade_position_id = v_pos_id;

    -- (2) Insert the revenue row (buyer premium above OSP).
    INSERT INTO trade_cost_component (
      tenant_id, trade_position_id, component_type, amount_usd_per_bbl,
      is_revenue, notes, created_by, updated_by, is_active, data_classification
    ) VALUES (
      v_tenant, v_pos_id, 'downstream_sale', rec.buyer_premium,
      TRUE, 'Buyer premium above Murban OSP (term contract)',
      v_actor, v_actor, TRUE, 'demo'
    );

    -- (3) Insert cost rows.
    INSERT INTO trade_cost_component (
      tenant_id, trade_position_id, component_type, amount_usd_per_bbl,
      is_revenue, notes, created_by, updated_by, is_active, data_classification
    ) VALUES (
      v_tenant, v_pos_id, 'transport_charter', rec.freight, FALSE,
      rec.freight_note, v_actor, v_actor, TRUE, 'demo'
    );
    INSERT INTO trade_cost_component (
      tenant_id, trade_position_id, component_type, amount_usd_per_bbl,
      is_revenue, notes, created_by, updated_by, is_active, data_classification
    ) VALUES (
      v_tenant, v_pos_id, 'insurance', rec.insurance, FALSE,
      'War-risk uplift + cargo insurance', v_actor, v_actor, TRUE, 'demo'
    );
    INSERT INTO trade_cost_component (
      tenant_id, trade_position_id, component_type, amount_usd_per_bbl,
      is_revenue, notes, created_by, updated_by, is_active, data_classification
    ) VALUES (
      v_tenant, v_pos_id, 'hedge', rec.hedge, FALSE,
      'LC financing + freight-fuel hedge', v_actor, v_actor, TRUE, 'demo'
    );

    -- (4) Re-derive margin from the components and snapshot it.
    v_margin    := rec.buyer_premium - (rec.freight + rec.insurance + rec.hedge);
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
      103.00 + rec.buyer_premium,
      rec.freight + rec.insurance + rec.hedge,
      v_margin, v_volume, v_total_usd, v_usd_aed, v_total_aed,
      NULL, NOW(), 'manual',
      v_actor, 'demo'
    );
  END LOOP;

  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY latest_margin;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW latest_margin;
  END;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (494, '494_trade_cost_components_clean_math', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;
