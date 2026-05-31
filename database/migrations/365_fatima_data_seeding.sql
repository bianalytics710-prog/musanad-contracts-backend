-- Migration: 365_fatima_data_seeding.sql
-- Unit: Fatima Finance QA Phase 3.5 (F1-F80 audit pass)
-- Targets data-sparsity defects on the Finance & Treasury surfaces:
--   F10/F11/F12/F13/F16  Brent/Dubai/Murban current prices + FX 30d history
--   F14/F1               USD-denominated contracts (FX EXPOSURE KPI > 0)
--   F36                  HERO-001 2025-Q4 actuals
--   F42/F56              Trade-position grade 'other' → real grades
--   F43                  WAF counterparty rename
--   F41                  Murban margin per-cargo diversification
--   F50                  Margin snapshot trigger source diversity
--   F51                  Margin snapshot timestamp spread

-- Test-branch guard: skip when osint_signal is empty.

DO $$
DECLARE
  v_tenant      UUID := '00000000-0000-0000-0000-000000000001';
  v_signal_n    INTEGER;
  v_position_n  INTEGER;
  v_have_pb     BOOLEAN;
  v_have_ms     BOOLEAN;
BEGIN
  SELECT COUNT(*) INTO v_signal_n FROM osint_signal WHERE tenant_id = v_tenant;
  IF v_signal_n = 0 THEN
    RAISE NOTICE 'mig 365: osint_signal empty, skipping (likely test branch).';
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_position_n FROM trade_position WHERE tenant_id = v_tenant;
  SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='price_benchmark') INTO v_have_pb;
  SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='margin_snapshot') INTO v_have_ms;

  --------------------------------------------------------------------
  -- F10/F16 — Brent current price observation so the F&T commodity
  -- Brent card has a value (was '—'). Idempotent on (tenant, code, date).
  --------------------------------------------------------------------
  IF v_have_pb THEN
    INSERT INTO price_benchmark
      (tenant_id, benchmark_code, price_date, price_value, unit,
       period_grain, source, notes, data_classification,
       created_by, updated_by, is_active)
    VALUES
      (v_tenant, 'brent', CURRENT_DATE, 96.40, 'usd_per_bbl',
       'spot', 'mock', 'F10/F16 — Brent current price for F&T commodity card', 'demo',
       NULL, NULL, TRUE)
    ON CONFLICT (tenant_id, benchmark_code, price_date) DO UPDATE
      SET price_value = EXCLUDED.price_value, updated_at = NOW();

    INSERT INTO price_benchmark
      (tenant_id, benchmark_code, price_date, price_value, unit,
       period_grain, source, notes, data_classification,
       created_by, updated_by, is_active)
    VALUES
      (v_tenant, 'dubai', CURRENT_DATE, 89.20, 'usd_per_bbl',
       'spot', 'mock', 'F11/F12 — Dubai current price for F&T card', 'demo',
       NULL, NULL, TRUE)
    ON CONFLICT (tenant_id, benchmark_code, price_date) DO UPDATE
      SET price_value = EXCLUDED.price_value, updated_at = NOW();

    INSERT INTO price_benchmark
      (tenant_id, benchmark_code, price_date, price_value, unit,
       period_grain, source, notes, data_classification,
       created_by, updated_by, is_active)
    VALUES
      (v_tenant, 'murban_osp', CURRENT_DATE, 110.75, 'usd_per_bbl',
       'spot', 'mock', 'F11/F12 — Murban OSP current price for F&T card', 'demo',
       NULL, NULL, TRUE)
    ON CONFLICT (tenant_id, benchmark_code, price_date) DO UPDATE
      SET price_value = EXCLUDED.price_value, updated_at = NOW();

    --------------------------------------------------------------------
    -- F13 — 30 daily usd_aed observations so FX volatility 30d chart
    --       has shape (was "Nothing here yet"). Peg holds 3.6725 ±10bps.
    --------------------------------------------------------------------
    INSERT INTO price_benchmark
      (tenant_id, benchmark_code, price_date, price_value, unit,
       period_grain, source, notes, data_classification,
       created_by, updated_by, is_active)
    SELECT v_tenant, 'usd_aed',
           (CURRENT_DATE - (d || ' days')::INTERVAL)::date,
           ROUND((3.6725 + (RANDOM() - 0.5) * 0.0020)::NUMERIC, 4),
           'aed_per_usd', 'daily', 'mock',
           'F13 — 30d FX history seed', 'demo',
           NULL, NULL, TRUE
      FROM generate_series(1, 30) d
    ON CONFLICT (tenant_id, benchmark_code, price_date) DO NOTHING;
  END IF;

  --------------------------------------------------------------------
  -- F14/F1 — Convert 4 existing contracts to USD-denominated so the
  -- FX Exposure KPI is > 0 and the Currency Exposure breakdown has > 1 row.
  --------------------------------------------------------------------
  UPDATE contract
     SET currency = 'USD',
         updated_at = NOW()
   WHERE currency = 'AED'
     AND contract_number IN (
       'MUSANAD-2026-005',
       'MUSANAD-2026-008',
       'MUSANAD-2026-012',
       'MUSANAD-2026-020'
     );

  --------------------------------------------------------------------
  -- F36 — HERO-001 2025-Q4 actuals backfill (was AED 0 → -100%).
  --------------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM contract WHERE contract_number = 'CRN-296-HERO-001') THEN
    INSERT INTO contract_cost_actual
      (tenant_id, contract_id, fiscal_year, period_type, period_label,
       cost_category, actual_amount_aed, currency, source, reference_no, recorded_at,
       data_classification, created_by, updated_by, is_active, notes)
    SELECT v_tenant,
           (SELECT id FROM contract WHERE contract_number = 'CRN-296-HERO-001'),
           2025, 'month', s.period_label,
           s.cost_category, s.amount_aed, 'AED', 'manual', 'F36-HERO-001-Q4-2025',
           NOW(), 'demo', 1, 1, TRUE,
           'F36 backfill — 2025-Q4 actuals to remove -100% variance artefact'
      FROM (VALUES
        ('2025-10', 'day_rate',   58000000.00),
        ('2025-11', 'day_rate',   59000000.00),
        ('2025-12', 'day_rate',   58000000.00),
        ('2025-10', 'manpower',   14000000.00),
        ('2025-11', 'manpower',   14000000.00),
        ('2025-12', 'manpower',   14000000.00)
      ) AS s(period_label, cost_category, amount_aed)
     WHERE NOT EXISTS (
       SELECT 1 FROM contract_cost_actual
        WHERE contract_id = (SELECT id FROM contract WHERE contract_number = 'CRN-296-HERO-001')
          AND reference_no = 'F36-HERO-001-Q4-2025'
          AND period_label = s.period_label
          AND cost_category = s.cost_category
     );
  END IF;

  --------------------------------------------------------------------
  -- F43 — WAF counterparty: rename generic 'West Africa Crude Supplier'
  -- to a real producer/trader name.
  --------------------------------------------------------------------
  UPDATE party
     SET name_en = 'Trafigura West Africa SA',
         updated_at = NOW()
   WHERE name_en = 'West Africa Crude Supplier';

  --------------------------------------------------------------------
  -- F42/F56 — Trade-position grade 'other' → real grade names.
  -- The grade CHECK constraint allows only:
  --   ('murban','west_african_x','brent','dubai','wti','other')
  -- Extend the constraint to admit the realistic grades the audit asked
  -- for, then update the rows.
  --------------------------------------------------------------------
  IF v_position_n > 0 THEN
    -- Defensive: drop the old constraint, replace with extended set.
    ALTER TABLE trade_position
      DROP CONSTRAINT IF EXISTS trade_position_grade_check;

    ALTER TABLE trade_position
      ADD CONSTRAINT trade_position_grade_check
      CHECK (grade IN (
        'murban','west_african_x','brent','dubai','wti','other',
        'basra_light','basra_heavy','permian_light','urals','kebco',
        'bonny_light','forcados'
      ));

    UPDATE trade_position
       SET grade = 'basra_light', updated_at = NOW()
     WHERE position_ref = 'TP-BASRA-BUY-AUG26' AND grade = 'other';

    UPDATE trade_position
       SET grade = 'permian_light', updated_at = NOW()
     WHERE position_ref = 'TP-PERMIAN-BUY-SEP26' AND grade = 'other';

    UPDATE trade_position
       SET grade = 'kebco', updated_at = NOW()
     WHERE position_ref = 'TP-KAZAKH-BUY-OCT26' AND grade = 'other';

    UPDATE trade_position
       SET grade = 'urals', updated_at = NOW()
     WHERE position_ref = 'TP-URALS-BUY-NOV26' AND grade = 'other';
  END IF;

  --------------------------------------------------------------------
  -- F41 — Murban margin per-cargo diversification. Vary
  -- margin_per_bbl on the latest snapshot for each Murban position
  -- to reflect destination charter / hedge cost deltas.
  --------------------------------------------------------------------
  IF v_have_ms AND v_position_n > 0 THEN
    WITH offsets(position_ref, delta_usd) AS (
      VALUES
        ('TP-MURBAN-KR-JUN26', 0.00::NUMERIC),    -- Story 2 anchor, unchanged
        ('TP-MURBAN-KR-JUL26', -0.45::NUMERIC),
        ('TP-MURBAN-KR-AUG26', -0.90::NUMERIC),
        ('TP-MURBAN-SG-SEP26', -1.20::NUMERIC),
        ('TP-MURBAN-IN-OCT26', -2.30::NUMERIC),
        ('TP-MURBAN-JP-NOV26', -0.65::NUMERIC),
        ('TP-MURBAN-SE-DEC26', -3.85::NUMERIC)
    ),
    latest_ms AS (
      SELECT DISTINCT ON (ms.trade_position_id)
             ms.id, ms.trade_position_id, ms.margin_per_bbl, ms.volume_bbl,
             ms.usd_aed_rate, tp.position_ref, o.delta_usd
        FROM margin_snapshot ms
        JOIN trade_position tp ON tp.id = ms.trade_position_id
        JOIN offsets o ON o.position_ref = tp.position_ref
       WHERE tp.tenant_id = v_tenant
         AND o.delta_usd <> 0
       ORDER BY ms.trade_position_id, ms.computed_at DESC
    )
    UPDATE margin_snapshot ms
       SET margin_per_bbl = ROUND((lm.margin_per_bbl + lm.delta_usd)::NUMERIC, 4),
           total_margin_usd = ROUND(((lm.margin_per_bbl + lm.delta_usd) * lm.volume_bbl)::NUMERIC, 2),
           total_margin_aed = ROUND(((lm.margin_per_bbl + lm.delta_usd) * lm.volume_bbl * lm.usd_aed_rate)::NUMERIC, 2)
      FROM latest_ms lm
     WHERE ms.id = lm.id;

    --------------------------------------------------------------------
    -- F50 — Diversify triggered_by on margin_snapshot rows so the
    --       History & Trends "Triggered by" column isn't all "Price change".
    --------------------------------------------------------------------
    WITH targeted AS (
      SELECT id, ROW_NUMBER() OVER (ORDER BY computed_at DESC) AS rn
        FROM margin_snapshot WHERE tenant_id = v_tenant
    )
    UPDATE margin_snapshot ms
       SET triggered_by = CASE
             WHEN t.rn % 7 = 1 THEN 'manual'
             WHEN t.rn % 7 = 3 THEN 'worker'
             WHEN t.rn % 7 = 5 THEN 'bootstrap'
             ELSE ms.triggered_by
           END
      FROM targeted t
     WHERE ms.id = t.id AND t.rn <= 40;

    --------------------------------------------------------------------
    -- F51 — Spread old snapshot timestamps over 2-day intervals so the
    --       History chart's X-axis no longer reads as a seed-time burst.
    --------------------------------------------------------------------
    WITH old_snaps AS (
      SELECT id, ROW_NUMBER() OVER (ORDER BY computed_at DESC) AS rn
        FROM margin_snapshot
       WHERE tenant_id = v_tenant
         AND computed_at < NOW() - INTERVAL '7 hours'
    )
    UPDATE margin_snapshot ms
       SET computed_at = NOW() - (os.rn * INTERVAL '2 days')
      FROM old_snaps os
     WHERE ms.id = os.id AND os.rn <= 30;

    -- Refresh latest_margin MV if present so the list page reflects new values.
    IF EXISTS (SELECT 1 FROM pg_matviews WHERE matviewname = 'latest_margin') THEN
      REFRESH MATERIALIZED VIEW latest_margin;
    END IF;
  END IF;

  RAISE NOTICE 'mig 365: Fatima data seeding complete.';
END $$;

-- ============================================================
-- ROLLBACK (best-effort)
-- ============================================================
-- DELETE FROM contract_cost_actual WHERE reference_no = 'F36-HERO-001-Q4-2025';
-- DELETE FROM price_benchmark WHERE notes LIKE 'F1%' OR notes LIKE 'F13%';
-- UPDATE contract SET currency = 'AED' WHERE contract_number IN ('MUSANAD-2026-005','MUSANAD-2026-008','MUSANAD-2026-012','MUSANAD-2026-020') AND currency = 'USD';
