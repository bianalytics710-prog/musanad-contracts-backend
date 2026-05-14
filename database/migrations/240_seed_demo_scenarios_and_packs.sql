-- Migration: 240_seed_demo_scenarios_and_packs.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: Seed 8 demo_seed_pack rows + 8 demo_scenario rows (one per hero scenario).
-- Date: 2026-05-14

BEGIN;

-- ============================================================
-- demo_seed_pack — 8 versioned bundles (one per hero scenario)
-- ============================================================
INSERT INTO demo_seed_pack (tenant_id, pack_id, version, description, fixture_path, payload, is_active)
SELECT t.id, x.pack_id, 1, x.description, x.fixture_path, x.payload::JSONB, TRUE
FROM tenant t
CROSS JOIN (VALUES
  ('pack.hormuz',          'Hormuz Strait disruption — geopolitical/logistics signal cascade', 'seeds/adnoc-pack/scenarios/hormuz/',          '{"sources":["rss_lloyds_maritime","openweather"],"contracts":["charter_party"],"clauseTypes":["force_majeure"]}'),
  ('pack.ofac_sanctions',  'OFAC sanctions designation — direct + chain exposure',             'seeds/adnoc-pack/scenarios/ofac_sanctions/',  '{"sources":["ofac_sdn"],"counterparties":["IBM Middle East FZ-LLC","Galadari Brothers Group"]}'),
  ('pack.brent_review',    'Brent price-review trigger — sustained threshold breach',          'seeds/adnoc-pack/scenarios/brent_review/',    '{"sources":["commodity_crude"],"clauseTypes":["price_review","price_indexation"]}'),
  ('pack.epc_sla',         'EPC milestone-slippage cure-notice pattern',                       'seeds/adnoc-pack/scenarios/epc_sla/',         '{"sources":["internal:harness"],"clauseTypes":["sla_performance","cure_period"]}'),
  ('pack.renewal',         'Contract renewal lookahead 90d window',                            'seeds/adnoc-pack/scenarios/renewal/',         '{"sources":["internal:harness"],"clauseTypes":["term_and_renewal"]}'),
  ('pack.cyclone',         'Cyclone weather event — FM-eligible',                              'seeds/adnoc-pack/scenarios/cyclone/',         '{"sources":["ncm_uae","noaa_gfs","openweather"],"contracts":["o_m","drilling","charter_party"],"clauseTypes":["weather","force_majeure"]}'),
  ('pack.icv_shortfall',   'ICV downgrade — supplier remediation pathway',                     'seeds/adnoc-pack/scenarios/icv_shortfall/',   '{"sources":["internal:icv_custom"],"clauseTypes":["icv_in_country_value"]}'),
  ('pack.esg_subcontractor','ESG/labour violation at sub-contractor — chain match',            'seeds/adnoc-pack/scenarios/esg_subcontractor/','{"sources":["mock_social_x","rss_reuters_sanctions"],"counterparties":["sub-contractor chain"]}')
) AS x(pack_id, description, fixture_path, payload)
WHERE t.is_active = TRUE AND t.slug = 'adnoc'
ON CONFLICT (tenant_id, pack_id) DO NOTHING;

-- ============================================================
-- demo_scenario — 8 hero scenarios with expected outcomes
-- ============================================================
INSERT INTO demo_scenario (tenant_id, scenario_id, display_name_en, display_name_ar, description, tier, seed_pack_ref, event_injection_payload, expected_outcomes, is_active)
SELECT t.id, x.scenario_id, x.display_name_en, x.display_name_ar, x.description, x.tier, x.seed_pack_ref, x.event_injection_payload::JSONB, x.expected_outcomes::JSONB, TRUE
FROM tenant t
CROSS JOIN (VALUES
  ('hormuz',          'Hormuz Strait — Force Majeure scenario',           'مضيق هرمز — سيناريو القوة القاهرة',          'Geopolitical/logistics disruption affects charter party contracts routed through the Strait.',    1, 'pack.hormuz',         '{"signalKind":"geopolitical","severity":"high","route":"persian_gulf"}',                            '{"correlations":">=2","alerts":">=2","advisoryDrafts":">=1"}'),
  ('ofac_sanctions',  'OFAC Sanctions — direct + chain exposure',         'عقوبات OFAC — تعرض مباشر + سلسلة',           'Counterparty appears on a sanctions list; chain-exposure rule finds prime contractor.',           1, 'pack.ofac_sanctions', '{"signalKind":"sanctions","authority":"OFAC","designationDate":"2026-05-14"}',                      '{"correlations":">=2","alerts":">=1","advisoryDrafts":">=1"}'),
  ('brent_review',    'Brent Price Review — sustained threshold breach',  'مراجعة سعر برنت — اختراق العتبة',           'Brent crosses price-review threshold for sustained window; renegotiation triggered.',             1, 'pack.brent_review',   '{"signalKind":"commodity","marker":"BRENT","priceUsd":98.5}',                                       '{"correlations":">=1","alerts":">=1"}'),
  ('epc_sla',         'EPC SLA breach — cure-notice pattern',             'انتهاك SLA EPC — نمط إشعار العلاج',         'Internal milestone-slippage signal triggers cure_period clause.',                                 1, 'pack.epc_sla',        '{"signalKind":"internal","subtype":"milestone_slippage","daysLate":21}',                            '{"correlations":">=1","advisoryDrafts":">=1"}'),
  ('renewal',         'Renewal Lookahead — 90 days',                      'النظرة المستقبلية للتجديد — 90 يومًا',       'Calendar timer flags contracts within 90 days of renewal date.',                                 1, 'pack.renewal',        '{"signalKind":"calendar","horizonDays":90}',                                                        '{"correlations":">=1"}'),
  ('cyclone',         'Cyclone — weather FM-eligible',                    'الإعصار — قوة قاهرة بسبب الطقس',            'High-severity weather event in Gulf bbox triggers weather/FM clause eligibility.',                2, 'pack.cyclone',        '{"signalKind":"weather","severity":"critical","geography":"persian_gulf"}',                         '{"correlations":">=1","alerts":">=1","advisoryDrafts":">=1"}'),
  ('icv_shortfall',   'ICV Shortfall — supplier downgrade',               'نقص ICV — تخفيض المورد',                    'ICV custom signal triggers rectification advisory for supplier with ICV clause.',                 2, 'pack.icv_shortfall',  '{"signalKind":"icv_downgraded","currentIcvPct":18,"targetIcvPct":35}',                              '{"correlations":">=1","advisoryDrafts":">=1"}'),
  ('esg_subcontractor','ESG sub-contractor violation — chain match',      'انتهاك المقاول الفرعي ESG — مطابقة السلسلة', 'ESG/news signal title-matches violation regex; chain traversal finds prime contractor.',          2, 'pack.esg_subcontractor','{"signalKind":"news","keywords":["labour","violation"]}',                                          '{"correlations":">=1","advisoryDrafts":"0"}')
) AS x(scenario_id, display_name_en, display_name_ar, description, tier, seed_pack_ref, event_injection_payload, expected_outcomes)
WHERE t.is_active = TRUE AND t.slug = 'adnoc'
ON CONFLICT (tenant_id, scenario_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (240, '240_seed_demo_scenarios_and_packs', CURRENT_TIMESTAMP);

COMMIT;
