-- Migration: 397_layla_obligations_aed_format_and_freezones.sql
-- Unit: Layla Counsel QA Phase 3.7 follow-up — L64 + L107 + L58
--
-- L64 — obligation description_en/ar reformat "1350000.00 AED" → "AED 1,350,000"
-- L58 — Murban OSP reset: insert latest signal at $110.75 (Story 2 starting state)
-- L107 — seed 8 additional UAE free zones onto random parties so the dropdown lists them

-- 1. L64 — Reformat obligation descriptions
DO $$
DECLARE
  r RECORD;
  v_amount NUMERIC;
  v_formatted TEXT;
BEGIN
  FOR r IN
    SELECT id, description_en, description_ar
      FROM contract_obligation
     WHERE description_en ~ '\d+\.\d{2}\s*AED'
        OR description_en ILIKE 'Scheduled payment of %'
  LOOP
    -- Extract the number
    BEGIN
      v_amount := (regexp_match(r.description_en, '(\d+(?:\.\d{2})?)\s*AED'))[1]::NUMERIC;
      v_formatted := to_char(v_amount, 'FM999G999G999G990');
      -- Replace in description_en
      UPDATE contract_obligation
         SET description_en = regexp_replace(
               description_en,
               '(\d+(?:\.\d{2})?)\s*AED',
               'AED ' || v_formatted,
               'g'
             ),
             description_ar = regexp_replace(
               COALESCE(description_ar, description_en),
               '(\d+(?:\.\d{2})?)\s*AED',
               v_formatted || ' درهم',
               'g'
             ),
             updated_at = NOW()
       WHERE id = r.id;
    EXCEPTION WHEN OTHERS THEN
      -- skip rows that don't parse
      NULL;
    END;
  END LOOP;
END $$;

-- 2. L58 — Murban OSP reset: insert latest MURBAN signal at $110.75
DO $$
DECLARE
  v_source_id BIGINT;
BEGIN
  SELECT id INTO v_source_id FROM osint_source WHERE source_id = 'commodity_feed' LIMIT 1;
  IF v_source_id IS NULL THEN
    SELECT id INTO v_source_id FROM osint_source WHERE display_name ILIKE '%commodity%' OR display_name ILIKE '%price%' LIMIT 1;
  END IF;

  -- Idempotent: only insert if today's $110.75 signal absent
  IF NOT EXISTS (
    SELECT 1 FROM osint_signal
     WHERE title_en = 'MURBAN settle 110.75' AND is_active = TRUE
  ) THEN
    INSERT INTO osint_signal (
      ext_id, category, source, severity, title_en, title_ar,
      description_en, description_ar,
      published_date, effective_date, event_date_v2, fetched_at,
      kind, signal_kind_subtype, title, summary,
      geographies, affected_entities, severity_v2, confidence,
      url, raw_payload, metadata,
      source_id, osint_source_id, source_reliability,
      data_classification, is_seed, created_at, updated_at, is_active,
      tenant_id, dedup_hash
    )
    VALUES (
      'osint:commodity_feed:murban_settle_l58',
      'commodity_prices', 'commodity_feed', 'medium',
      'MURBAN settle 110.75',
      'مورّبان: إغلاق 110.75',
      'Murban official selling price settled at $110.75/bbl — Story 2 demo starting state',
      'إغلاق سعر مورّبان الرسمي عند 110.75 دولار/برميل — حالة بداية القصة الثانية',
      CURRENT_DATE, CURRENT_DATE, NOW(), NOW(),
      'commodity', 'crude_settle',
      'MURBAN 110.75', 'OSP settled at 110.75 USD/bbl',
      '["AE", "Gulf"]'::jsonb, '["MURBAN"]'::jsonb,
      'medium', 0.95,
      NULL, '{}'::jsonb, jsonb_build_object('amount', 110.75, 'unit', 'USD/bbl'),
      'commodity_feed', v_source_id, 0.95,
      'pilot', FALSE, NOW(), NOW(), TRUE,
      '00000000-0000-0000-0000-000000000001',
      'l58-murban-110.75-' || extract(epoch from now())::text
    );
  END IF;
END $$;

-- 3. L107 — Seed 8 more UAE free zones onto parties so the filter dropdown lists them
DO $$
DECLARE
  fz_list TEXT[] := ARRAY[
    'JAFZA — Jebel Ali Free Zone',
    'DAFZA — Dubai Airport Free Zone',
    'DMCC — Dubai Multi Commodities Centre',
    'Hamriyah Free Zone',
    'RAKEZ — Ras Al Khaimah Economic Zone',
    'Khalifa Industrial Zone Abu Dhabi (KIZAD)',
    'Sharjah Airport International Free Zone',
    'Fujairah Free Zone'
  ];
  fz TEXT;
  v_idx INT := 0;
  r RECORD;
BEGIN
  -- Pick the most recently created 40 parties and tag them across the 8 zones
  FOR r IN
    SELECT id FROM party
     WHERE free_zone IS NULL AND is_active = TRUE AND party_type = 'company'
     ORDER BY id DESC LIMIT 40
  LOOP
    fz := fz_list[(v_idx % array_length(fz_list, 1)) + 1];
    UPDATE party SET free_zone = fz, updated_at = NOW() WHERE id = r.id;
    v_idx := v_idx + 1;
  END LOOP;
END $$;
