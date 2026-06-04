-- Migration: 493_trade_position_realistic_margins.sql
-- Module: Trade Margin — Executive demo Story 5a polish
-- Date: 2026-06-02
--
-- Two fixes:
--
-- (A) Margin snapshots seeded with the realized sale price (~$103-$106/bbl)
-- where they should carry the realized TRADING margin — i.e. sale price minus
-- all-in landed cost (lifting + freight + insurance + financing). Industry
-- typical for a marketer like AGT is $0.50-$5/bbl on term crude sales.
--
-- Re-seed margin_snapshot for the 7 Murban sell positions with realistic
-- numbers, then refresh latest_margin so list view + KPIs reflect them.
--
-- (B) Tighten SE-DEC26 ceiling to $102 so today's Murban OSP ($103) breaches
-- it. Gives the demo a concrete "above_ceiling — escalate" row alongside the
-- two no-band rows. Story beat: "if OSP stays at $103, Nynas can invoke
-- their price-review window — AED X margin compression on this position".

DO $$
DECLARE
  v_tenant   UUID := '00000000-0000-0000-0000-000000000001';
  v_actor    BIGINT := 1;
  v_usd_aed  NUMERIC := 3.67;
  rc         RECORD;
  v_margin   NUMERIC;
  v_total_usd NUMERIC;
  v_total_aed NUMERIC;
  v_pos      RECORD;
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::TEXT, true);

  -- (B) Tighten SE-DEC26 ceiling so OSP $103 breaches it.
  UPDATE trade_position
    SET contracted_ceiling_usd_per_bbl = 102.00,
        band_review_clause_ref         = 'Clause 7.3 — Price Review Window (above ceiling)'
    WHERE position_ref = 'TP-MURBAN-SE-DEC26';

  -- (A) Realistic margin snapshots per position. Margin $/bbl chosen to
  -- reflect the relative band tightness + the position's term-vs-spot mix.
  FOR rc IN
    SELECT position_ref, margin_per_bbl
      FROM (
        VALUES
          ('TP-MURBAN-KR-JUN26', 3.20),
          ('TP-MURBAN-KR-JUL26', 2.80),
          ('TP-MURBAN-KR-AUG26', 1.50),  -- floor active → compressed
          ('TP-MURBAN-SG-SEP26', 2.20),  -- no band
          ('TP-MURBAN-IN-OCT26', 3.50),  -- wide band, best margin
          ('TP-MURBAN-JP-NOV26', 2.10),  -- no band
          ('TP-MURBAN-SE-DEC26', -0.80)  -- ABOVE CEILING → buyer review → negative margin
      ) AS v(position_ref, margin_per_bbl)
  LOOP
    SELECT id, volume_bbl INTO v_pos
      FROM trade_position WHERE position_ref = rc.position_ref;
    IF v_pos.id IS NULL THEN CONTINUE; END IF;

    v_margin    := rc.margin_per_bbl;
    v_total_usd := v_margin * v_pos.volume_bbl;
    v_total_aed := v_total_usd * v_usd_aed;

    -- Insert a fresh snapshot. The latest_margin MV reads MAX(computed_at).
    INSERT INTO margin_snapshot (
      tenant_id, trade_position_id, side, benchmark_code_used,
      benchmark_price_used, revenue_per_bbl, cost_per_bbl,
      margin_per_bbl, volume_bbl, total_margin_usd, usd_aed_rate,
      total_margin_aed, recommendation, computed_at, triggered_by,
      created_by, data_classification
    ) VALUES (
      v_tenant, v_pos.id, 'sell', 'murban_osp',
      103.00, 103.50 + v_margin, 103.50,
      v_margin, v_pos.volume_bbl, v_total_usd, v_usd_aed,
      v_total_aed, NULL, NOW(), 'manual',
      v_actor, 'demo'
    );
  END LOOP;

  -- Refresh the materialised view so list + KPIs pick up the new snapshots.
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY latest_margin;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW latest_margin;
  END;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (493, '493_trade_position_realistic_margins', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;
