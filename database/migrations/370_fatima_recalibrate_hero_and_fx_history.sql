-- Migration: 370_fatima_recalibrate_hero_and_fx_history.sql
-- Unit: Fatima Finance QA Phase 3.5 — verification follow-up
-- Targets:
--   F20/F22  Verification surfaced that mig 367's HERO-001 July-spike
--            reduction (95M → 20M) over-corrected: HERO now reads 89.8%
--            consumed / "On track" / -AED 85.7M variance. The portfolio
--            fn computes projectedOverUnderAed = actual - budget (snapshot,
--            not forward projection), so the 3-state badge never lands on
--            "Trending over" for HERO. Fix: bring July day-rate spike to
--            +AED 50M and re-balance Q2/Q3 actuals so HERO lands at
--            ~104% consumed today (back in the "Over budget" cohort with
--            CRQ-DRL-001) — restores the demo narrative anchor.
--   F13      F&T FX volatility 30d history is still empty because the
--            section reads osint_signal source_id='fx_usd_aed' (NOT the
--            price_benchmark rows mig 365 seeded). Seed 30 osint_signal
--            rows with proper metadata.peg_deviation_bps so the chart
--            populates.

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
  v_hero   BIGINT;
BEGIN
  SELECT id INTO v_hero FROM contract WHERE contract_number = 'CRN-296-HERO-001';
  IF v_hero IS NULL THEN
    RAISE NOTICE 'mig 370: HERO-001 absent, skipping HERO recalibration.';
  ELSE
    -- F20/F22 — Restore HERO to "Over budget" cohort.
    -- Existing mig 367 had set the E13 row to AED 20M; bring it back up
    -- to AED 50M (still well below the original 95M but enough that the
    -- portfolio actuals exceed the FY budget once combined with the rest
    -- of the year).
    UPDATE contract_cost_actual
       SET actual_amount_aed = 50000000.00,
           notes = 'F20/F22 recalibration — Jul-26 spike +50M keeps HERO in Over budget cohort while monthly variance stays under the demo +13% headline.',
           updated_at = NOW()
     WHERE contract_id = v_hero
       AND reference_no = 'E13-HERO-001-JUL26'
       AND period_label = '2026-07'
       AND cost_category = 'day_rate';

    -- Add small May / June bumps so HERO sits at ~104% consumed today.
    -- These are realistic mid-FY variances (≈ +5-7%) per month, not the
    -- catastrophic +95M one-shot from mig 364.
    INSERT INTO contract_cost_actual
      (tenant_id, contract_id, fiscal_year, period_type, period_label,
       cost_category, actual_amount_aed, currency, source, reference_no, recorded_at,
       data_classification, created_by, updated_by, is_active, notes)
    SELECT v_tenant, v_hero, 2026, 'month', s.period_label,
           s.cost_category, s.amount_aed, 'AED', 'manual',
           'F20-HERO-recalibration', NOW(), 'demo', 1, 1, TRUE,
           'F20 recalibration — mid-FY actual bumps so HERO lands ~104% consumed.'
      FROM (VALUES
        ('2026-05', 'day_rate',  18000000.00),
        ('2026-06', 'day_rate',  22000000.00),
        ('2026-08', 'day_rate',  19000000.00)
      ) AS s(period_label, cost_category, amount_aed)
     WHERE NOT EXISTS (
       SELECT 1 FROM contract_cost_actual
        WHERE contract_id = v_hero
          AND reference_no = 'F20-HERO-recalibration'
          AND period_label = s.period_label
          AND cost_category = s.cost_category
     );

    RAISE NOTICE 'mig 370: HERO-001 recalibrated.';
  END IF;

  -- F13 — Seed 30 daily fx_usd_aed osint_signal rows so the FX history
  -- chart populates. Schema mirrors the rule (metadata.peg_deviation_bps
  -- + raw_payload.rate). Peg holds 3.6725 with ±5-10bps jitter.
  INSERT INTO osint_signal (
    ext_id, category, source, severity, title_en, title_ar,
    description_en, description_ar, affected_clause_categories,
    published_date, is_seed, tenant_id, source_id, source_reliability,
    fetched_at, event_date_v2, kind, signal_kind_subtype,
    title, summary, geographies, affected_entities, severity_v2,
    confidence, raw_payload, dedup_hash, metadata, data_classification
  )
  SELECT
    'osint:fx_usd_aed:' || TO_CHAR(observed_at, 'YYYY-MM-DD'),
    'market_financial',
    'fx_feed',
    'low',
    'USD/AED observation — ' || rate::text,
    'مراقبة USD/AED — ' || rate::text,
    'Daily USD/AED rate sample. Peg holds at 3.6725.',
    'مراقبة يومية لسعر صرف الدولار/درهم. التثبيت عند 3.6725.',
    ARRAY['fx_terms']::text[],
    observed_at::date,
    FALSE,
    v_tenant,
    'fx_usd_aed',
    0.99,
    observed_at,
    observed_at,
    'fx',
    'peg_observation',
    'USD/AED ' || rate::text,
    'Daily USD/AED peg observation',
    '[]'::jsonb,
    '[{"identifier":"USD_AED","entityType":"currency_pair"}]'::jsonb,
    'low',
    0.99,
    jsonb_build_object('pair','AED','rate', rate::text),
    md5('fx_usd_aed|' || TO_CHAR(observed_at, 'YYYY-MM-DD')),
    jsonb_build_object('peg_deviation_bps', dev_bps),
    'demo'
  FROM (
    SELECT (NOW() - (d || ' days')::INTERVAL) AS observed_at,
           ROUND((3.6725 + (RANDOM() - 0.5) * 0.0025)::NUMERIC, 4) AS rate,
           ROUND(((RANDOM() - 0.5) * 16)::NUMERIC, 0)::integer AS dev_bps
      FROM generate_series(0, 29) d
  ) d
  ON CONFLICT (tenant_id, dedup_hash) DO NOTHING;

  RAISE NOTICE 'mig 370: fx_usd_aed 30d osint_signal seed complete.';
END $$;
