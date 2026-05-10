-- Migration: 106_m7_seed_adnoc_sources.sql
-- Module: M7 — OSINT Source Framework + Adapter Protocol (CR-A)
-- Description: Seed 13 ADNOC config-pack osint_source rows (4 sanctions + 6 RSS + 1 commodity + 1 GDELT
--              + 1 FX) plus 2 placeholder source_credential rows (commodity_crude + fx_usd_aed).
--              Idempotent: ON CONFLICT(tenant_id, source_id) DO NOTHING.
-- Rollback: DELETE seeded rows by (tenant_id, source_id).
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ----------------------------------------------------------------
-- 1. Seed 13 osint_source rows for ADNOC tenant
-- ----------------------------------------------------------------
INSERT INTO osint_source (
  tenant_id, source_id, display_name, display_name_ar, kind, url, format,
  refresh_seconds, source_reliability, enabled, rate_limit, severity_mapping,
  geography_filter, licensing_note, metadata, data_classification
) VALUES
-- 4 sanctions adapters (daily pull)
('00000000-0000-0000-0000-000000000001','ofac_sdn','OFAC SDN List','قائمة OFAC SDN','sanctions',
 'https://www.treasury.gov/ofac/downloads/sdn.xml','xml',86400,1.00,TRUE,
 '{"callsPerMinute":1,"burst":1,"minIntervalMs":60000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"programContains":"CAATSA","severity":"critical"},{"programContains":"NSPM-25","severity":"critical"},{"default":"high"}]}'::jsonb,
 NULL,'US Government public domain.',
 '{"adapterClass":"OfacSdnAdapter","diffTracker":true,"severityRules":{"caatsa":"critical","nspm25":"critical","default":"high"}}'::jsonb,
 'demo'),

('00000000-0000-0000-0000-000000000001','eu_consolidated','EU Consolidated Sanctions','العقوبات الموحدة للاتحاد الأوروبي','sanctions',
 'https://webgate.ec.europa.eu/fsd/fsf/public/files/xmlFullSanctionsList_1_1/content','xml',86400,1.00,TRUE,
 '{"callsPerMinute":1,"burst":1,"minIntervalMs":60000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"default":"high"}]}'::jsonb,
 NULL,'Commission Decision 2011/833/EU — free reuse with attribution.',
 '{"adapterClass":"EuConsolidatedAdapter"}'::jsonb,
 'demo'),

('00000000-0000-0000-0000-000000000001','un_security_council','UN Security Council Consolidated','مجلس الأمن للأمم المتحدة الموحد','sanctions',
 'https://scsanctions.un.org/resources/xml/en/consolidated.xml','xml',86400,1.00,TRUE,
 '{"callsPerMinute":1,"burst":1,"minIntervalMs":60000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"default":"high"}]}'::jsonb,
 NULL,'UN information; free public use.',
 '{"adapterClass":"UnSecurityCouncilAdapter"}'::jsonb,
 'demo'),

('00000000-0000-0000-0000-000000000001','uk_hmt','UK HMT Consolidated','العقوبات الموحدة لخزانة المملكة المتحدة','sanctions',
 'https://ofsistorage.blob.core.windows.net/publishlive/2022format/ConList.xml','xml',86400,1.00,TRUE,
 '{"callsPerMinute":1,"burst":1,"minIntervalMs":60000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"default":"high"}]}'::jsonb,
 NULL,'UK Open Government Licence v3.0.',
 '{"adapterClass":"UkHmtAdapter"}'::jsonb,
 'demo'),

-- 6 RSS sub-feeds (15-min cadence)
-- Original ADNOC pack URLs (Reuters / Platts / Argus / Khaleej-with-querystring /
-- Gulf-rss-business) all 401/403/404'd against unauthenticated GETs as of
-- 2026-05-09 — Reuters retired public RSS, Platts/Argus moved behind paid
-- tiers, Khaleej + Gulf changed paths. Replaced with working free public
-- feeds keyed off the same demo theme. Lloyd's URL kept (200 from origin
-- with proper UA header). source_id columns NOT renamed — they are stable
-- catalog identifiers and renaming would break prior signals + history.
('00000000-0000-0000-0000-000000000001','rss_reuters_energy','BBC Business RSS','تغذية أخبار الأعمال — بي بي سي','news',
 'https://feeds.bbci.co.uk/news/business/rss.xml','rss',900,0.95,TRUE,
 '{"callsPerMinute":60,"burst":10,"minIntervalMs":1000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"titleContains":"sanctions","severity":"high"},{"titleContains":"force majeure","severity":"high"},{"titleContains":"port closure","severity":"medium"},{"default":"informational"}]}'::jsonb,
 NULL,'Headline + summary syndication only — no full-text scrape.',
 '{"adapterClass":"RssAdapter"}'::jsonb,
 'demo'),

('00000000-0000-0000-0000-000000000001','rss_sp_platts','OilPrice.com Energy News','أويل برايس — أخبار الطاقة','news',
 'https://oilprice.com/rss/main','rss',900,0.95,TRUE,
 '{"callsPerMinute":60,"burst":10,"minIntervalMs":1000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"titleContains":"sanctions","severity":"high"},{"titleContains":"force majeure","severity":"high"},{"titleContains":"port closure","severity":"medium"},{"default":"informational"}]}'::jsonb,
 NULL,'Headline + summary syndication only.',
 '{"adapterClass":"RssAdapter"}'::jsonb,
 'demo'),

('00000000-0000-0000-0000-000000000001','rss_argus_oil','Guardian Business RSS','الغارديان — الأعمال','news',
 'https://www.theguardian.com/uk/business/rss','rss',900,0.95,TRUE,
 '{"callsPerMinute":60,"burst":10,"minIntervalMs":1000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"titleContains":"sanctions","severity":"high"},{"titleContains":"force majeure","severity":"high"},{"titleContains":"port closure","severity":"medium"},{"default":"informational"}]}'::jsonb,
 NULL,'Headline + summary syndication only.',
 '{"adapterClass":"RssAdapter"}'::jsonb,
 'demo'),

('00000000-0000-0000-0000-000000000001','rss_lloyds_maritime','Lloyd''s List Maritime RSS','تغذية لويدز البحرية','news',
 'https://lloydslist.com/rss/news','rss',900,0.95,TRUE,
 '{"callsPerMinute":60,"burst":10,"minIntervalMs":1000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"titleContains":"sanctions","severity":"high"},{"titleContains":"force majeure","severity":"high"},{"titleContains":"port closure","severity":"medium"},{"default":"informational"}]}'::jsonb,
 NULL,'Headline + summary syndication only.',
 '{"adapterClass":"RssAdapter"}'::jsonb,
 'demo'),

('00000000-0000-0000-0000-000000000001','rss_khaleej_business','Khaleej Times Business RSS','تغذية الخليج تايمز للأعمال','news',
 'https://www.khaleejtimes.com/rss/business','rss',900,0.80,TRUE,
 '{"callsPerMinute":60,"burst":10,"minIntervalMs":1000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"titleContains":"sanctions","severity":"high"},{"titleContains":"force majeure","severity":"high"},{"titleContains":"port closure","severity":"medium"},{"default":"informational"}]}'::jsonb,
 NULL,'Headline + summary syndication only.',
 '{"adapterClass":"RssAdapter"}'::jsonb,
 'demo'),

('00000000-0000-0000-0000-000000000001','rss_gulf_business','Gulf News Business RSS','تغذية جلف نيوز للأعمال','news',
 'https://gulfnews.com/feed','rss',900,0.80,TRUE,
 '{"callsPerMinute":60,"burst":10,"minIntervalMs":1000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"titleContains":"sanctions","severity":"high"},{"titleContains":"force majeure","severity":"high"},{"titleContains":"port closure","severity":"medium"},{"default":"informational"}]}'::jsonb,
 NULL,'Headline + summary syndication only.',
 '{"adapterClass":"RssAdapter"}'::jsonb,
 'demo'),

-- Commodity (5-min cadence)
('00000000-0000-0000-0000-000000000001','commodity_crude','Commodity Crude (Brent / Dubai / Murban / WTI)','النفط الخام (برنت / دبي / مربان / WTI)','commodity',
 'https://api.oilpriceapi.com/v1/prices/latest','json',300,0.90,TRUE,
 '{"callsPerMinute":12,"burst":2,"minIntervalMs":5000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"absChangePctGte":5,"severity":"high"},{"absChangePctGte":2,"severity":"medium"},{"default":"informational"}]}'::jsonb,
 NULL,'oilpriceapi.com free tier — provider ToS applies.',
 '{"adapterClass":"CommodityCrudeAdapter","markers":["BRENT","DUBAI","MURBAN","WTI"],"provider":"oilpriceapi.com","credentialKind":"api_key"}'::jsonb,
 'demo'),

-- GDELT (15-min cadence with ADNOC-relevance filter)
('00000000-0000-0000-0000-000000000001','gdelt_v2','GDELT 2.0','GDELT 2.0','news',
 'http://data.gdeltproject.org/gdeltv2/lastupdate.txt','csv',900,0.65,TRUE,
 '{"callsPerMinute":60,"burst":10,"minIntervalMs":1000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"default":"informational"}]}'::jsonb,
 '{"countryIn":["ARE","SAU","OMN","QAT","BHR","KWT","IRN","IRQ"],"themeIn":["ENERGY","MARITIME","SANCTIONS"]}'::jsonb,
 'Free for research and commercial use; attribution required.',
 '{"adapterClass":"GdeltAdapter","adnocRelevanceFilter":{"countryIn":["ARE","SAU","OMN","QAT","BHR","KWT","IRN","IRQ"],"themeIn":["ENERGY","MARITIME","SANCTIONS"]}}'::jsonb,
 'demo'),

-- FX (5-min cadence)
('00000000-0000-0000-0000-000000000001','fx_usd_aed','USD/AED FX','سعر صرف الدولار/الدرهم','fx',
 'https://api.exchangerate.host/latest','json',300,0.85,TRUE,
 '{"callsPerMinute":12,"burst":2,"minIntervalMs":5000,"respectRetryAfter":true}'::jsonb,
 '{"rules":[{"pegDeviationPctGte":0.5,"severity":"high"},{"pegDeviationPctGte":0.25,"severity":"medium"},{"default":"informational"}]}'::jsonb,
 NULL,'Free for commercial use (exchangerate.host primary).',
 '{"adapterClass":"FxAdapter","primary":"exchangerate.host","fallback":"open.er-api.com","pairs":["USD/AED","USD/EUR","USD/GBP","USD/INR"],"pegBase":3.6725}'::jsonb,
 'demo')
ON CONFLICT (tenant_id, source_id) DO NOTHING;

-- ----------------------------------------------------------------
-- 2. Seed 2 placeholder source_credential rows (commodity_crude + fx_usd_aed)
-- ----------------------------------------------------------------
INSERT INTO source_credential (tenant_id, osint_source_id, credential_kind, credential_ref, last_rotated_at)
SELECT s.tenant_id, s.id, c.credential_kind, c.credential_ref, now()
FROM (VALUES
  ('commodity_crude', 'api_key', 'env:COMMODITY_API_KEY'),
  ('fx_usd_aed',      'none',    'env:FX_API_KEY')
) AS c(source_id, credential_kind, credential_ref)
JOIN osint_source s
  ON s.tenant_id = '00000000-0000-0000-0000-000000000001'
  AND s.source_id = c.source_id
ON CONFLICT (tenant_id, osint_source_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (106, 'm7_seed_adnoc_sources', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM source_credential
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--     AND osint_source_id IN (SELECT id FROM osint_source WHERE source_id IN ('commodity_crude','fx_usd_aed'));
-- DELETE FROM osint_source
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--     AND source_id IN (
--       'ofac_sdn','eu_consolidated','un_security_council','uk_hmt',
--       'rss_reuters_energy','rss_sp_platts','rss_argus_oil','rss_lloyds_maritime',
--       'rss_khaleej_business','rss_gulf_business','commodity_crude','gdelt_v2','fx_usd_aed'
--     );
-- DELETE FROM schema_migrations WHERE version = 106;
-- COMMIT;
-- ============================================================
