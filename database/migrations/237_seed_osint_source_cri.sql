-- Migration: 237_seed_osint_source_cri.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: 10 net-new osint_source rows (4 live + 6 RSS + 1 mocked) via fn_osint_source_seed_cri_batch.
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Seed helper function (migration-internal; not exposed as HTTP endpoint)
CREATE OR REPLACE FUNCTION fn_osint_source_seed_cri_batch()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_inserted INTEGER := 0;
  v_tid UUID;
BEGIN
  FOR v_tid IN SELECT id FROM tenant WHERE is_active = TRUE LOOP
    INSERT INTO osint_source (tenant_id, source_id, display_name, display_name_ar, kind, format, refresh_seconds, source_reliability, enabled, metadata, data_classification, is_active, created_at, updated_at)
    VALUES
      (v_tid, 'openweather',           'OpenWeather API',          'واجهة برمجة OpenWeather',       'weather', 'json', 3600,  0.85, TRUE, jsonb_build_object('adapterClass','OpenWeatherAdapter','locations',jsonb_build_array('abu_dhabi','das_island','zirku','mubarraz','ruwais','jebel_dhanna','strait_of_hormuz')), 'demo', TRUE, now(), now()),
      (v_tid, 'ncm_uae',               'UAE NCM Warnings RSS',     'تغذية تحذيرات NCM الإمارات',    'weather', 'rss',  1800,  1.00, TRUE, jsonb_build_object('adapterClass','NcmUaeAdapter','feedUrl','https://ncm.gov.ae/warnings/rss'), 'demo', TRUE, now(), now()),
      (v_tid, 'noaa_gfs',              'Open-Meteo (NOAA proxy)',  'Open-Meteo (وكيل NOAA)',        'weather', 'json', 21600, 0.90, TRUE, jsonb_build_object('adapterClass','OpenMeteoNoaaAdapter','provider','open-meteo','subgrid','persian-gulf-gulf-of-oman'), 'demo', TRUE, now(), now()),
      (v_tid, 'internal:icv_custom',   'ICV Custom Adapter',       'محول ICV المخصص',               'internal','json', 86400,     0.95, TRUE, jsonb_build_object('adapterClass','IcvCustomAdapter','triggerMode','harness-only'), 'demo', TRUE, now(), now()),
      (v_tid, 'rss_the_national',      'The National RSS',         'تغذية The National RSS',        'news',    'rss',  900,   0.80, TRUE, jsonb_build_object('adapterClass','RssAdapter','feedUrl','https://thenationalnews.com/rss'), 'demo', TRUE, now(), now()),
      (v_tid, 'rss_meed',              'MEED RSS',                 'تغذية MEED RSS',                'news',    'rss',  900,   0.80, TRUE, jsonb_build_object('adapterClass','RssAdapter','feedUrl','https://meed.com/rss'), 'demo', TRUE, now(), now()),
      (v_tid, 'rss_energy_voice',      'Energy Voice RSS',         'تغذية Energy Voice RSS',        'news',    'rss',  900,   0.80, TRUE, jsonb_build_object('adapterClass','RssAdapter','feedUrl','https://energyvoice.com/feed'), 'demo', TRUE, now(), now()),
      (v_tid, 'rss_oil_gas_journal',   'Oil & Gas Journal RSS',    'تغذية مجلة النفط والغاز RSS',  'news',    'rss',  900,   0.80, TRUE, jsonb_build_object('adapterClass','RssAdapter','feedUrl','https://www.ogj.com/rss'), 'demo', TRUE, now(), now()),
      (v_tid, 'rss_reuters_sanctions', 'Reuters Sanctions RSS',    'تغذية رويترز للعقوبات RSS',    'news',    'rss',  900,   0.85, TRUE, jsonb_build_object('adapterClass','RssAdapter','feedUrl','https://www.reuters.com/sanctions/rss'), 'demo', TRUE, now(), now()),
      (v_tid, 'rss_uae_gov',           'UAE Government RSS',       'تغذية حكومة الإمارات RSS',     'news',    'rss',  900,   0.90, TRUE, jsonb_build_object('adapterClass','RssAdapter','feedUrl','https://u.ae/rss/news'), 'demo', TRUE, now(), now()),
      (v_tid, 'mock_social_x',         'Mock X Social Adapter',    'محول X الاجتماعي التجريبي',    'news',    'json', 86400,     0.55, TRUE, jsonb_build_object('adapterClass','MockSocialXAdapter','fixturesPath','tests/fixtures/osint/mock_x'), 'demo', TRUE, now(), now())
    ON CONFLICT (tenant_id, source_id) DO NOTHING;
    DECLARE rc INTEGER; BEGIN GET DIAGNOSTICS rc = ROW_COUNT; v_inserted := v_inserted + rc; END;
  END LOOP;

  RETURN jsonb_build_object('inserted', v_inserted);
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_osint_source_seed_cri_batch: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_osint_source_seed_cri_batch() IS 'Migration-internal: idempotent batch seed for 11 CRI osint_source rows per tenant (4 live adapters + 6 RSS + 1 mocked).';
REVOKE EXECUTE ON FUNCTION fn_osint_source_seed_cri_batch() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_osint_source_seed_cri_batch() TO neondb_owner;

-- Execute the seed
SELECT fn_osint_source_seed_cri_batch();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (237, '237_seed_osint_source_cri', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 237;
-- DELETE FROM osint_source WHERE source_id IN ('openweather','ncm_uae','noaa_gfs','internal:icv_custom','rss_the_national','rss_meed','rss_energy_voice','rss_oil_gas_journal','rss_reuters_sanctions','rss_uae_gov','mock_social_x');
-- DROP FUNCTION IF EXISTS fn_osint_source_seed_cri_batch();
-- ============================================================
