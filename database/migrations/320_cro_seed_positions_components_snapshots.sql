-- Migration: 320_cro_seed_positions_components_snapshots.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: Seed data migration 2/2.
--   E-3: 3 seller trade_position rows (TP-MURBAN-KR-JUN26/JUL26/AUG26 — 2M bbl/month Murban).
--   E-5: 1 buyer trade_position row (TP-WAF-REFINE-SPOT01 — 1M bbl WAF spot buy-and-refine).
--   E-4: 12 seller trade_cost_component rows (4 components × 3 positions).
--   E-6: 5 buyer trade_cost_component rows (4 cost legs + 1 revenue leg downstream_sale).
--   E-7: Bootstrap snapshots — fn_margin_compute per seed position at $110.75 OSP basis (seller)
--        and at natural component values (buyer). triggered_by='bootstrap'.
--        Populates latest_margin MV so list view + executive dashboard show data on first load.
--   Tenant: 00000000-0000-0000-0000-000000000001 (ADNOC).
--   All rows idempotent (ON CONFLICT DO NOTHING).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_actor       BIGINT;
  v_tenant      UUID := '00000000-0000-0000-0000-000000000001';
  v_hanwha_id   BIGINT;
  v_waf_id      BIGINT;
  v_adnoc_t_id  BIGINT;
  v_agt_id      BIGINT;
  v_jun_id      BIGINT;
  v_jul_id      BIGINT;
  v_aug_id      BIGINT;
  v_waf_pos_id  BIGINT;
  v_pos_id      BIGINT;
  v_latest_cnt  INTEGER;
BEGIN
  SELECT MIN(id) INTO v_actor FROM "user" WHERE is_active = TRUE;

  -- Resolve counterparty + internal entity IDs
  -- NOTE: party is a globally shared table with NO tenant_id column (confirmed mig 285)
  SELECT id INTO v_hanwha_id  FROM party WHERE name_en = 'Hanwha TotalEnergies'       LIMIT 1;
  SELECT id INTO v_waf_id     FROM party WHERE name_en = 'West Africa Crude Supplier' LIMIT 1;
  SELECT id INTO v_adnoc_t_id FROM party WHERE name_en = 'ADNOC Trading'              LIMIT 1;
  SELECT id INTO v_agt_id     FROM party WHERE name_en = 'ADNOC Global Trading'       LIMIT 1;

  IF v_hanwha_id IS NULL THEN
    RAISE EXCEPTION '320: Hanwha TotalEnergies party not found — run mig 319 first'
      USING ERRCODE = 'P0002';
  END IF;
  IF v_waf_id IS NULL THEN
    RAISE EXCEPTION '320: West Africa Crude Supplier party not found — run mig 319 first'
      USING ERRCODE = 'P0002';
  END IF;
  IF v_adnoc_t_id IS NULL THEN
    RAISE NOTICE '320: ADNOC Trading party not found (from mig 285) — internal_entity_id will be NULL for seller positions';
  END IF;
  IF v_agt_id IS NULL THEN
    RAISE NOTICE '320: ADNOC Global Trading party not found (from mig 285) — internal_entity_id will be NULL for buyer position';
  END IF;

  -- ============================================================
  -- E-3: 2a Seller positions (3 Murban cargoes → Hanwha TotalEnergies)
  -- ============================================================
  INSERT INTO trade_position (
    tenant_id, position_ref, side, grade, counterparty_id, internal_entity_id,
    volume_bbl, pricing_basis, delivery_month, term_or_spot, linked_contract_id,
    status, notes, data_classification, created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT v_tenant, x.position_ref, 'sell', 'murban', v_hanwha_id, v_adnoc_t_id,
    2000000.00, 'murban_osp', x.delivery_month, 'term', NULL,
    'open', x.notes, 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM (VALUES
    ('TP-MURBAN-KR-JUN26', '2026-06-01'::date, 'Murban term sell — Jun-26 delivery, Hanwha TotalEnergies'),
    ('TP-MURBAN-KR-JUL26', '2026-07-01'::date, 'Murban term sell — Jul-26 delivery, Hanwha TotalEnergies'),
    ('TP-MURBAN-KR-AUG26', '2026-08-01'::date, 'Murban term sell — Aug-26 delivery, Hanwha TotalEnergies')
  ) AS x(position_ref, delivery_month, notes)
  ON CONFLICT (tenant_id, position_ref) DO NOTHING;

  -- ============================================================
  -- E-5: 2b Buyer position (West-African spot buy-and-refine → AGT)
  -- ============================================================
  INSERT INTO trade_position (
    tenant_id, position_ref, side, grade, counterparty_id, internal_entity_id,
    volume_bbl, pricing_basis, delivery_month, term_or_spot, linked_contract_id,
    status, notes, data_classification, created_at, updated_at, created_by, updated_by, is_active
  )
  VALUES (
    v_tenant, 'TP-WAF-REFINE-SPOT01', 'buy', 'west_african_x', v_waf_id, v_agt_id,
    1000000.00, 'spot', '2026-06-01', 'spot', NULL,
    'open', 'WAF spot buy-and-refine — ADNOC Global Trading, Ruwais target',
    'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  )
  ON CONFLICT (tenant_id, position_ref) DO NOTHING;

  -- Resolve position IDs for FK use
  SELECT id INTO v_jun_id  FROM trade_position WHERE tenant_id = v_tenant AND position_ref = 'TP-MURBAN-KR-JUN26' AND is_active = TRUE;
  SELECT id INTO v_jul_id  FROM trade_position WHERE tenant_id = v_tenant AND position_ref = 'TP-MURBAN-KR-JUL26' AND is_active = TRUE;
  SELECT id INTO v_aug_id  FROM trade_position WHERE tenant_id = v_tenant AND position_ref = 'TP-MURBAN-KR-AUG26' AND is_active = TRUE;
  SELECT id INTO v_waf_pos_id FROM trade_position WHERE tenant_id = v_tenant AND position_ref = 'TP-WAF-REFINE-SPOT01' AND is_active = TRUE;

  -- ============================================================
  -- E-4: Seller cost components (4 × 3 = 12 rows)
  -- ============================================================
  INSERT INTO trade_cost_component (
    tenant_id, trade_position_id, component_type, amount_usd_per_bbl,
    is_revenue, notes, data_classification, created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT v_tenant, pos_id, comp_type, amount, FALSE, comp_notes, 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM
    (VALUES (v_jun_id), (v_jul_id), (v_aug_id)) AS p(pos_id)
    CROSS JOIN (VALUES
      ('lifting',           1.2000::numeric, 'Lifting cost / bbl'),
      ('transport_charter', 2.1000::numeric, 'ADNOC L&S charter to Korea'),
      ('insurance',         0.4500::numeric, 'Cargo insurance / bbl'),
      ('hedge',             0.8500::numeric, 'Simplified hedge cost / bbl')
    ) AS c(comp_type, amount, comp_notes)
  WHERE pos_id IS NOT NULL
  ON CONFLICT (tenant_id, trade_position_id, component_type) DO NOTHING;

  -- ============================================================
  -- E-6: Buyer cost + revenue components (5 rows)
  -- ============================================================
  INSERT INTO trade_cost_component (
    tenant_id, trade_position_id, component_type, amount_usd_per_bbl,
    is_revenue, notes, data_classification, created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT v_tenant, v_waf_pos_id, comp_type, amount, is_rev, comp_notes, 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM (VALUES
    ('crude_purchase',   96.2000::numeric, FALSE, 'WAF grade spot purchase at market price'),
    ('transport',         3.4000::numeric, FALSE, 'Freight: West Africa → Ruwais'),
    ('refining',          9.8000::numeric, FALSE, 'Ruwais refining cost / bbl'),
    ('storage',           1.1000::numeric, FALSE, 'Storage cost at Ruwais'),
    ('downstream_sale', 119.5000::numeric, TRUE,  'Blended diesel/jet target-market downstream sale')
  ) AS c(comp_type, amount, is_rev, comp_notes)
  WHERE v_waf_pos_id IS NOT NULL
  ON CONFLICT (tenant_id, trade_position_id, component_type) DO NOTHING;

  -- ============================================================
  -- E-7: Bootstrap snapshots
  -- Set tenant + user GUC (required by all fn_'s, incl. fn_current_user_has_permission)
  -- v_actor = MIN(id) FROM "user" WHERE is_active = Super Admin (id=1) which has finance.margin.read
  -- ============================================================
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', TRUE);
  PERFORM set_config('app.current_user_id', v_actor::text, TRUE);

  -- Bootstrap 2a seller positions at OSP $110.75 (explicit p_benchmark_price)
  FOR v_pos_id IN
    SELECT id FROM trade_position
    WHERE tenant_id = v_tenant
      AND position_ref IN ('TP-MURBAN-KR-JUN26','TP-MURBAN-KR-JUL26','TP-MURBAN-KR-AUG26')
      AND is_active = TRUE
    ORDER BY delivery_month
  LOOP
    PERFORM fn_margin_compute(v_actor, v_pos_id, 110.75::NUMERIC);
  END LOOP;

  -- Bootstrap 2b buyer position (p_benchmark_price = NULL — buyer uses downstream_sale component)
  SELECT id INTO v_pos_id FROM trade_position
  WHERE tenant_id = v_tenant
    AND position_ref = 'TP-WAF-REFINE-SPOT01'
    AND is_active = TRUE;

  IF v_pos_id IS NOT NULL THEN
    PERFORM fn_margin_compute(v_actor, v_pos_id, NULL);
  END IF;

  -- Post-bootstrap assertion: latest_margin should have 4 rows for this tenant
  SELECT COUNT(*) INTO v_latest_cnt
  FROM latest_margin
  WHERE tenant_id = v_tenant;

  IF v_latest_cnt < 4 THEN
    RAISE WARNING '320: latest_margin has % rows for tenant — expected 4 after bootstrap', v_latest_cnt;
  ELSE
    RAISE NOTICE '320: Bootstrap complete. latest_margin rows for tenant: % (expected 4)', v_latest_cnt;
  END IF;

END $$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (320, '320_cro_seed_positions_components_snapshots', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM margin_snapshot
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--     AND triggered_by = 'bootstrap'
--     AND data_classification = 'demo';
-- REFRESH MATERIALIZED VIEW latest_margin;
-- DELETE FROM trade_cost_component
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--     AND data_classification = 'demo';
-- DELETE FROM trade_position
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--     AND position_ref IN ('TP-MURBAN-KR-JUN26','TP-MURBAN-KR-JUL26','TP-MURBAN-KR-AUG26','TP-WAF-REFINE-SPOT01');
-- DELETE FROM schema_migrations WHERE version = 320;
-- COMMIT;
-- ============================================================
