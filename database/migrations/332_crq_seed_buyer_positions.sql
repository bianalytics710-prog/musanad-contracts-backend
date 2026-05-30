-- Migration: 332_crq_seed_buyer_positions.sql
-- Module: CR-Q — ADNOC Data Scale-Up (v1.4 foundation)
-- Description: Adds 4 new buyer trade_positions:
--              - Iraqi Basra Light  (500k bbl/cargo → Ruwais)
--              - US Permian WTI     (600k bbl/cargo → Ruwais)
--              - Caspian Kazakh     (750k bbl/cargo → Ruwais + arbitrage)
--              - Russian Urals      (700k bbl/cargo → Egypt arbitrage)
--              Each: 5 components (crude_purchase + transport + refining + storage + downstream_sale revenue).
--              Bootstrap margin_snapshot via fn_margin_compute(v_actor, pos_id, NULL) — buyer uses downstream_sale.
--              After this migration: total buyer positions = 1 (mig320) + 4 = 5 (meets ≥5 quality bar).
--              Origin supplier party rows seeded with WHERE NOT EXISTS.
--              Idempotent via ON CONFLICT DO NOTHING.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Step 1: Seed origin supplier parties
-- party_type CHECK: 'individual' or 'company'; no metadata/registration_country on party
INSERT INTO party (
  party_type, name_en, name_ar, country, is_seed, is_active, created_at, updated_at
)
SELECT 'company', w.name_en, w.name_ar, w.country, TRUE, TRUE, NOW(), NOW()
FROM (VALUES
  ('Basra Oil Company Iraq',      'شركة نفط البصرة العراق',             'Iraq'),
  ('Permian Basin Resources USA', 'موارد حوض بيرميان الولايات المتحدة', 'United States'),
  ('KazMunayGas National Company','شركة كازموناي غاز الوطنية كازاخستان', 'Kazakhstan'),
  ('Rosneft Trading SA',          'روسنفت للتداول',                      'Russia')
) AS w(name_en, name_ar, country)
WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = w.name_en);

-- Step 2: Seed positions + components + bootstrap
DO $$
DECLARE
  v_actor       BIGINT;
  v_tenant      UUID := '00000000-0000-0000-0000-000000000001';
  v_agt_id      BIGINT;
  v_basra_id    BIGINT;
  v_permian_id  BIGINT;
  v_kmg_id      BIGINT;
  v_rosneft_id  BIGINT;
  v_pos_id      BIGINT;
  v_latest_cnt  INTEGER;
BEGIN
  SELECT MIN(id) INTO v_actor FROM "user" WHERE is_active = TRUE;
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', TRUE);
  PERFORM set_config('app.current_user_id', v_actor::text, TRUE);

  SELECT id INTO v_agt_id     FROM party WHERE name_en = 'ADNOC Global Trading'       LIMIT 1;
  SELECT id INTO v_basra_id   FROM party WHERE name_en = 'Basra Oil Company Iraq'      LIMIT 1;
  SELECT id INTO v_permian_id FROM party WHERE name_en = 'Permian Basin Resources USA' LIMIT 1;
  SELECT id INTO v_kmg_id     FROM party WHERE name_en = 'KazMunayGas National Company' LIMIT 1;
  SELECT id INTO v_rosneft_id FROM party WHERE name_en = 'Rosneft Trading SA'           LIMIT 1;

  -- ============================================================
  -- Buyer positions (4 grades → Ruwais / arbitrage)
  -- ============================================================
  INSERT INTO trade_position (
    tenant_id, position_ref, side, grade, counterparty_id, internal_entity_id,
    volume_bbl, pricing_basis, delivery_month, term_or_spot, linked_contract_id,
    status, notes, data_classification, created_at, updated_at, created_by, updated_by, is_active
  )
  -- grade CHECK: 'murban','west_african_x','brent','dubai','wti','other'
  -- Non-standard grades (Basra Light, Permian, Kazakh, Urals) map to 'other'
  SELECT v_tenant, x.position_ref, 'buy', 'other', x.cp_id, v_agt_id,
    x.vol_bbl, 'spot', x.delivery_month, 'spot', NULL,
    'open', x.notes, 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM (VALUES
    ('TP-BASRA-BUY-AUG26',   v_basra_id,   500000.00, '2026-08-01'::date, 'Iraqi Basra Light spot buy — Ruwais refinery'),
    ('TP-PERMIAN-BUY-SEP26', v_permian_id, 600000.00, '2026-09-01'::date, 'US Permian WTI spot buy — Ruwais refinery'),
    ('TP-KAZAKH-BUY-OCT26',  v_kmg_id,     750000.00, '2026-10-01'::date, 'Caspian Kazakh CPC spot buy — Ruwais + Egypt arb'),
    ('TP-URALS-BUY-NOV26',   v_rosneft_id, 700000.00, '2026-11-01'::date, 'Russian Urals spot buy — Egypt arbitrage via AGT')
  ) AS x(position_ref, cp_id, vol_bbl, delivery_month, notes)
  WHERE x.cp_id IS NOT NULL
  ON CONFLICT (tenant_id, position_ref) DO NOTHING;

  -- ============================================================
  -- Cost + revenue components (5 per position × 4 = 20 rows)
  -- Prices reflect each grade's typical market discount vs Murban (~$104)
  -- ============================================================

  -- Basra Light (~$99/bbl purchase; refine margin ~$9; downstream $114)
  INSERT INTO trade_cost_component (tenant_id, trade_position_id, component_type,
    amount_usd_per_bbl, is_revenue, notes, data_classification,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant, p.id, c.comp_type, c.amount, c.is_rev, c.notes, 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM trade_position p
  CROSS JOIN (VALUES
    ('crude_purchase',  99.0000::numeric, FALSE, 'Basra Light spot purchase at market'),
    ('transport',        3.2000::numeric, FALSE, 'Freight: Basra → Ruwais'),
    ('refining',         9.5000::numeric, FALSE, 'Ruwais refining cost / bbl'),
    ('storage',          1.0500::numeric, FALSE, 'Storage cost Ruwais'),
    ('downstream_sale', 117.5000::numeric, TRUE, 'Refined products downstream sale')
  ) AS c(comp_type, amount, is_rev, notes)
  WHERE p.tenant_id = v_tenant AND p.position_ref = 'TP-BASRA-BUY-AUG26' AND p.is_active = TRUE
  ON CONFLICT (tenant_id, trade_position_id, component_type) DO NOTHING;

  -- Permian WTI (~$101/bbl; freight higher; downstream $118)
  INSERT INTO trade_cost_component (tenant_id, trade_position_id, component_type,
    amount_usd_per_bbl, is_revenue, notes, data_classification,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant, p.id, c.comp_type, c.amount, c.is_rev, c.notes, 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM trade_position p
  CROSS JOIN (VALUES
    ('crude_purchase',  101.0000::numeric, FALSE, 'Permian WTI spot purchase at market'),
    ('transport',         4.5000::numeric, FALSE, 'Freight: US Gulf → Ruwais (VLCC)'),
    ('refining',          9.5000::numeric, FALSE, 'Ruwais refining cost / bbl'),
    ('storage',           1.1000::numeric, FALSE, 'Storage cost Ruwais'),
    ('downstream_sale', 120.0000::numeric, TRUE,  'Refined products downstream sale')
  ) AS c(comp_type, amount, is_rev, notes)
  WHERE p.tenant_id = v_tenant AND p.position_ref = 'TP-PERMIAN-BUY-SEP26' AND p.is_active = TRUE
  ON CONFLICT (tenant_id, trade_position_id, component_type) DO NOTHING;

  -- Kazakh CPC (~$103/bbl; freight moderate; downstream $116 via Egypt arb)
  INSERT INTO trade_cost_component (tenant_id, trade_position_id, component_type,
    amount_usd_per_bbl, is_revenue, notes, data_classification,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant, p.id, c.comp_type, c.amount, c.is_rev, c.notes, 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM trade_position p
  CROSS JOIN (VALUES
    ('crude_purchase',  103.0000::numeric, FALSE, 'Kazakh CPC blend spot purchase'),
    ('transport',         3.8000::numeric, FALSE, 'Freight: Novorossiysk → Ruwais/Egypt'),
    ('refining',          9.5000::numeric, FALSE, 'Refining cost / bbl'),
    ('storage',           1.0500::numeric, FALSE, 'Storage + arb logistics'),
    ('downstream_sale', 118.0000::numeric, TRUE,  'Blended products Egypt/India arbitrage')
  ) AS c(comp_type, amount, is_rev, notes)
  WHERE p.tenant_id = v_tenant AND p.position_ref = 'TP-KAZAKH-BUY-OCT26' AND p.is_active = TRUE
  ON CONFLICT (tenant_id, trade_position_id, component_type) DO NOTHING;

  -- Russian Urals (~$83/bbl significant discount; Egypt arbitrage $112 downstream)
  INSERT INTO trade_cost_component (tenant_id, trade_position_id, component_type,
    amount_usd_per_bbl, is_revenue, notes, data_classification,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant, p.id, c.comp_type, c.amount, c.is_rev, c.notes, 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM trade_position p
  CROSS JOIN (VALUES
    ('crude_purchase',   83.0000::numeric, FALSE, 'Russian Urals spot purchase at sanction-discount'),
    ('transport',         5.5000::numeric, FALSE, 'Freight: Black Sea → Egypt/India VLCC'),
    ('refining',          9.5000::numeric, FALSE, 'Refining cost / bbl'),
    ('storage',           1.2000::numeric, FALSE, 'Storage and logistics'),
    ('downstream_sale', 112.0000::numeric, TRUE,  'Egypt / India arbitrage downstream sale')
  ) AS c(comp_type, amount, is_rev, notes)
  WHERE p.tenant_id = v_tenant AND p.position_ref = 'TP-URALS-BUY-NOV26' AND p.is_active = TRUE
  ON CONFLICT (tenant_id, trade_position_id, component_type) DO NOTHING;

  -- ============================================================
  -- Bootstrap snapshots (buyer: p_benchmark_price = NULL)
  -- ============================================================
  FOR v_pos_id IN
    SELECT id FROM trade_position
    WHERE tenant_id = v_tenant
      AND position_ref IN ('TP-BASRA-BUY-AUG26','TP-PERMIAN-BUY-SEP26','TP-KAZAKH-BUY-OCT26','TP-URALS-BUY-NOV26')
      AND is_active = TRUE
    ORDER BY delivery_month
  LOOP
    PERFORM fn_margin_compute(v_actor, v_pos_id, NULL);
  END LOOP;

  SELECT COUNT(*) INTO v_latest_cnt FROM latest_margin WHERE tenant_id = v_tenant;
  RAISE NOTICE '332: Bootstrap complete. latest_margin rows for tenant after mig 332: %', v_latest_cnt;
END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (332, '332_crq_seed_buyer_positions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM margin_snapshot WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--   AND trade_position_id IN (
--     SELECT id FROM trade_position WHERE position_ref IN
--       ('TP-BASRA-BUY-AUG26','TP-PERMIAN-BUY-SEP26','TP-KAZAKH-BUY-OCT26','TP-URALS-BUY-NOV26')
--   );
-- REFRESH MATERIALIZED VIEW latest_margin;
-- DELETE FROM trade_cost_component WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--   AND trade_position_id IN (
--     SELECT id FROM trade_position WHERE position_ref IN
--       ('TP-BASRA-BUY-AUG26','TP-PERMIAN-BUY-SEP26','TP-KAZAKH-BUY-OCT26','TP-URALS-BUY-NOV26')
--   );
-- DELETE FROM trade_position WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--   AND position_ref IN ('TP-BASRA-BUY-AUG26','TP-PERMIAN-BUY-SEP26','TP-KAZAKH-BUY-OCT26','TP-URALS-BUY-NOV26');
-- DELETE FROM party WHERE name_en IN (
--   'Basra Oil Company Iraq','Permian Basin Resources USA',
--   'KazMunayGas National Company','Rosneft Trading SA'
-- );
-- DELETE FROM schema_migrations WHERE version = 332;
-- COMMIT;
-- ============================================================
