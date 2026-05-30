-- Migration: 331_crq_seed_seller_positions.sql
-- Module: CR-Q — ADNOC Data Scale-Up (v1.4 foundation)
-- Description: Adds 4 new Murban term seller trade_positions for SEP/OCT/NOV/DEC-26
--              to 4 new refinery counterparties: Singapore Jurong, India Reliance Jamnagar,
--              Japan Showa Shell, Europe Nynas Sweden.
--              Each position: 1,750,000 bbl/month, pricing_basis='murban_osp', side='sell'.
--              4 cost components each: lifting 1.20 + transport_charter 2.10 + insurance 0.45 + hedge 0.85 = $4.60/bbl.
--              Bootstrap margin_snapshot via fn_margin_compute at OSP $104.44.
--              Existing 3 Hanwha seller positions (mig 320) remain; after this migration
--              total seller positions = 3 + 4 = 7 (meets ≥7 quality bar).
--              Party rows seeded with WHERE NOT EXISTS (no tenant_id on party table).
--              Idempotent via ON CONFLICT DO NOTHING on all tables.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Step 1: Seed refinery counterparty parties (shared table, no tenant_id)
-- party_type CHECK: 'individual' or 'company'; no metadata column on party
INSERT INTO party (
  party_type, name_en, name_ar, country, is_seed,
  is_active, created_at, updated_at
)
SELECT 'company', w.name_en, w.name_ar, w.country, TRUE, TRUE, NOW(), NOW()
FROM (VALUES
  ('Singapore Jurong Aromatics Refinery', 'مصفاة جورونج للبتروكيماويات سنغافورة', 'Singapore'),
  ('Reliance Jamnagar Refinery', 'مصفاة رلاينس جامنغار الهند', 'India'),
  ('Showa Shell Sekiyu Japan', 'شوا شيل سيكيو اليابان', 'Japan'),
  ('Nynas Sweden Refinery', 'مصفاة نيناس السويد', 'Sweden')
) AS w(name_en, name_ar, country)
WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = w.name_en);

-- Step 2: Seed positions + components + bootstrap snapshots
DO $$
DECLARE
  v_actor         BIGINT;
  v_tenant        UUID := '00000000-0000-0000-0000-000000000001';
  v_adnoc_t_id    BIGINT;
  v_jurong_id     BIGINT;
  v_reliance_id   BIGINT;
  v_showa_id      BIGINT;
  v_nynas_id      BIGINT;
  v_pos_id        BIGINT;
  v_latest_cnt    INTEGER;
BEGIN
  SELECT MIN(id) INTO v_actor FROM "user" WHERE is_active = TRUE;
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', TRUE);
  PERFORM set_config('app.current_user_id', v_actor::text, TRUE);

  SELECT id INTO v_adnoc_t_id FROM party WHERE name_en = 'ADNOC Trading' LIMIT 1;
  SELECT id INTO v_jurong_id   FROM party WHERE name_en = 'Singapore Jurong Aromatics Refinery' LIMIT 1;
  SELECT id INTO v_reliance_id FROM party WHERE name_en = 'Reliance Jamnagar Refinery' LIMIT 1;
  SELECT id INTO v_showa_id    FROM party WHERE name_en = 'Showa Shell Sekiyu Japan' LIMIT 1;
  SELECT id INTO v_nynas_id    FROM party WHERE name_en = 'Nynas Sweden Refinery' LIMIT 1;

  -- ============================================================
  -- Seller positions (4 × Murban term, SEP/OCT/NOV/DEC-26)
  -- ============================================================
  INSERT INTO trade_position (
    tenant_id, position_ref, side, grade, counterparty_id, internal_entity_id,
    volume_bbl, pricing_basis, delivery_month, term_or_spot, linked_contract_id,
    status, notes, data_classification, created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT v_tenant, x.position_ref, 'sell', 'murban', x.cp_id, v_adnoc_t_id,
    1750000.00, 'murban_osp', x.delivery_month, 'term', NULL,
    'open', x.notes, 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM (VALUES
    ('TP-MURBAN-SG-SEP26',  v_jurong_id,   '2026-09-01'::date, 'Murban term sell — Sep-26, Singapore Jurong Aromatics'),
    ('TP-MURBAN-IN-OCT26',  v_reliance_id, '2026-10-01'::date, 'Murban term sell — Oct-26, Reliance Jamnagar India'),
    ('TP-MURBAN-JP-NOV26',  v_showa_id,    '2026-11-01'::date, 'Murban term sell — Nov-26, Showa Shell Japan'),
    ('TP-MURBAN-SE-DEC26',  v_nynas_id,    '2026-12-01'::date, 'Murban term sell — Dec-26, Nynas Sweden')
  ) AS x(position_ref, cp_id, delivery_month, notes)
  WHERE x.cp_id IS NOT NULL
  ON CONFLICT (tenant_id, position_ref) DO NOTHING;

  -- ============================================================
  -- Cost components (4 per position × 4 positions = 16 rows)
  -- ============================================================
  INSERT INTO trade_cost_component (
    tenant_id, trade_position_id, component_type, amount_usd_per_bbl,
    is_revenue, notes, data_classification, created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT v_tenant, p.id, c.comp_type, c.amount, FALSE, c.comp_notes,
    'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  FROM trade_position p
  CROSS JOIN (VALUES
    ('lifting',           1.2000::numeric, 'Lifting cost / bbl'),
    ('transport_charter', 2.1000::numeric, 'ADNOC L&S charter to destination'),
    ('insurance',         0.4500::numeric, 'Cargo insurance / bbl'),
    ('hedge',             0.8500::numeric, 'Simplified hedge cost / bbl')
  ) AS c(comp_type, amount, comp_notes)
  WHERE p.tenant_id = v_tenant
    AND p.position_ref IN ('TP-MURBAN-SG-SEP26','TP-MURBAN-IN-OCT26','TP-MURBAN-JP-NOV26','TP-MURBAN-SE-DEC26')
    AND p.is_active = TRUE
  ON CONFLICT (tenant_id, trade_position_id, component_type) DO NOTHING;

  -- ============================================================
  -- Bootstrap snapshots at OSP $104.44
  -- ============================================================
  FOR v_pos_id IN
    SELECT id FROM trade_position
    WHERE tenant_id = v_tenant
      AND position_ref IN ('TP-MURBAN-SG-SEP26','TP-MURBAN-IN-OCT26','TP-MURBAN-JP-NOV26','TP-MURBAN-SE-DEC26')
      AND is_active = TRUE
    ORDER BY delivery_month
  LOOP
    PERFORM fn_margin_compute(v_actor, v_pos_id, 104.44::NUMERIC);
  END LOOP;

  -- Post-bootstrap check
  SELECT COUNT(*) INTO v_latest_cnt FROM latest_margin WHERE tenant_id = v_tenant;
  RAISE NOTICE '331: Bootstrap complete. latest_margin rows for tenant after mig 331: %', v_latest_cnt;
END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (331, '331_crq_seed_seller_positions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM margin_snapshot WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--   AND trade_position_id IN (
--     SELECT id FROM trade_position WHERE position_ref IN
--       ('TP-MURBAN-SG-SEP26','TP-MURBAN-IN-OCT26','TP-MURBAN-JP-NOV26','TP-MURBAN-SE-DEC26')
--   );
-- REFRESH MATERIALIZED VIEW latest_margin;
-- DELETE FROM trade_cost_component WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--   AND trade_position_id IN (
--     SELECT id FROM trade_position WHERE position_ref IN
--       ('TP-MURBAN-SG-SEP26','TP-MURBAN-IN-OCT26','TP-MURBAN-JP-NOV26','TP-MURBAN-SE-DEC26')
--   );
-- DELETE FROM trade_position WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--   AND position_ref IN ('TP-MURBAN-SG-SEP26','TP-MURBAN-IN-OCT26','TP-MURBAN-JP-NOV26','TP-MURBAN-SE-DEC26');
-- DELETE FROM party WHERE name_en IN (
--   'Singapore Jurong Aromatics Refinery','Reliance Jamnagar Refinery',
--   'Showa Shell Sekiyu Japan','Nynas Sweden Refinery'
-- );
-- DELETE FROM schema_migrations WHERE version = 331;
-- COMMIT;
-- ============================================================
