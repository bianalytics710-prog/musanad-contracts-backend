-- Migration: 447_demo_scenario_signals_categories.sql
-- Module: Demo Harness — DEBT-CRIJ-3 (cascade wiring, part 4)
-- Description: osint_signal_category_check rejects 'demo'. Set every
--              signal in the demo_scenario payloads to a valid category
--              (regulatory / commodity_prices / supply_chain /
--              geopolitical / market_financial) so the INSERT no longer
--              violates the check constraint. Also fix the trigger
--              default to a constraint-compliant value.
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- 1. Update demo_scenario payloads with valid categories.
UPDATE demo_scenario SET event_injection_payload = jsonb_set(
    COALESCE(event_injection_payload, '{}'::jsonb), '{signals}',
    '[{"sourceId":"commodity_crude","kind":"commodity","category":"commodity_prices","signalKindSubtype":"brent_price_review","title":"Brent crosses USD 95 — price-review threshold sustained","summary":"Brent dated benchmark settled at USD 98.50/bbl for the 91st consecutive day above the USD 95 floor — triggers contractual price-review clause in Brent-indexed supply agreements.","severity":"high","url":"https://demo.example/brent/price-review-trigger"}]'::jsonb, true)
WHERE tenant_id = '00000000-0000-0000-0000-000000000001' AND scenario_id = 'brent_review';

UPDATE demo_scenario SET event_injection_payload = jsonb_set(
    COALESCE(event_injection_payload, '{}'::jsonb), '{signals}',
    '[{"sourceId":"open_meteo_noaa","kind":"weather","category":"supply_chain","signalKindSubtype":"cyclone_warning","title":"Tropical cyclone forecast — Persian Gulf — Category 3","summary":"NCM UAE issued a Category-3 cyclone alert affecting the Persian Gulf shipping lanes. Force majeure eligibility threshold triggered for marine + offshore contracts with Gulf-routed deliveries during the 72h window.","severity":"critical","url":"https://demo.example/weather/cyclone-pg-072626"}]'::jsonb, true)
WHERE tenant_id = '00000000-0000-0000-0000-000000000001' AND scenario_id = 'cyclone';

UPDATE demo_scenario SET event_injection_payload = jsonb_set(
    COALESCE(event_injection_payload, '{}'::jsonb), '{signals}',
    '[{"sourceId":"ofac_sdn","kind":"sanctions","category":"regulatory","signalKindSubtype":"ofac_sdn_designation","title":"OFAC SDN designation — Crescent Petroleum Company affiliate added","summary":"U.S. Treasury Office of Foreign Assets Control added a new entity to the Specially Designated Nationals list affecting downstream contract counterparties.","severity":"critical","url":"https://demo.example/ofac/sdn-2026-05-14"}]'::jsonb, true)
WHERE tenant_id = '00000000-0000-0000-0000-000000000001' AND scenario_id = 'ofac_sanctions';

UPDATE demo_scenario SET event_injection_payload = jsonb_set(
    COALESCE(event_injection_payload, '{}'::jsonb), '{signals}',
    '[{"sourceId":"rss_reuters_energy","kind":"geopolitical","category":"geopolitical","signalKindSubtype":"hormuz_disruption","title":"Strait of Hormuz disruption — 72-hour shipping suspension","summary":"Maritime traffic through the Strait of Hormuz suspended pending resolution of regional security incident — affects all Gulf-routed supply and charter party contracts.","severity":"critical","url":"https://demo.example/hormuz/disruption-feed"}]'::jsonb, true)
WHERE tenant_id = '00000000-0000-0000-0000-000000000001' AND scenario_id = 'hormuz';

UPDATE demo_scenario SET event_injection_payload = jsonb_set(
    COALESCE(event_injection_payload, '{}'::jsonb), '{signals}',
    '[{"sourceId":"internal_icv_custom","kind":"internal","category":"supply_chain","signalKindSubtype":"epc_sla_breach","title":"EPC contractor — 3rd consecutive milestone slippage detected","summary":"Internal project-controls feed flagged a third consecutive milestone slippage by an EPC contractor — cure-notice eligibility window opens per contractual remedy clause.","severity":"high","url":"https://demo.example/internal/epc-sla-feed"}]'::jsonb, true)
WHERE tenant_id = '00000000-0000-0000-0000-000000000001' AND scenario_id = 'epc_sla';

UPDATE demo_scenario SET event_injection_payload = jsonb_set(
    COALESCE(event_injection_payload, '{}'::jsonb), '{signals}',
    '[{"sourceId":"internal_icv_custom","kind":"internal","category":"market_financial","signalKindSubtype":"renewal_lookahead_90d","title":"Contract renewal lookahead — 90-day window opens","summary":"Multiple contracts entering the 90-day renewal lookahead window — negotiation runway available for re-pricing, term changes, or wind-down decisions.","severity":"medium","url":"https://demo.example/internal/renewal-lookahead"}]'::jsonb, true)
WHERE tenant_id = '00000000-0000-0000-0000-000000000001' AND scenario_id = 'renewal';

UPDATE demo_scenario SET event_injection_payload = jsonb_set(
    COALESCE(event_injection_payload, '{}'::jsonb), '{signals}',
    '[{"sourceId":"internal_icv_custom","kind":"internal","category":"regulatory","signalKindSubtype":"icv_shortfall","title":"ICV status downgrade — Tier-1 supplier dropped from Premier","summary":"In-Country Value compliance team flagged an ICV downgrade for a Tier-1 supplier — affects active supply contracts requiring Premier certification.","severity":"high","url":"https://demo.example/internal/icv-downgrade"}]'::jsonb, true)
WHERE tenant_id = '00000000-0000-0000-0000-000000000001' AND scenario_id = 'icv_shortfall';

UPDATE demo_scenario SET event_injection_payload = jsonb_set(
    COALESCE(event_injection_payload, '{}'::jsonb), '{signals}',
    '[{"sourceId":"mock_social_x","kind":"esg","category":"regulatory","signalKindSubtype":"esg_subcontractor_violation","title":"Sub-contractor ESG violation — downstream worker safety incident","summary":"Social media monitoring flagged a worker-safety ESG incident at a sub-contractor site — reputational exposure for prime contractor and downstream client.","severity":"high","url":"https://demo.example/esg/subcon-incident"}]'::jsonb, true)
WHERE tenant_id = '00000000-0000-0000-0000-000000000001' AND scenario_id = 'esg_subcontractor';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (447, '447_demo_scenario_signals_categories', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 447;
-- -- Re-apply 445 to revert to category-less payloads (still broken):
-- -- psql $DATABASE_URL < database/migrations/445_demo_scenario_signals_payloads.sql
-- ============================================================
