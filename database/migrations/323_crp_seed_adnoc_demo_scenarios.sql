-- Migration: 323_crp_seed_adnoc_demo_scenarios.sql
-- Module: CR-P — ADNOC Demo Wiring
-- Description: Seed 3 demo_seed_pack rows + 3 demo_scenario rows for the ADNOC
--              tier-2 stories (labor_cascade / budget_burn / trade_margin).
--              Matches migration 240 pattern exactly:
--                - CROSS JOIN with (VALUES ...) for all columns
--                - WHERE t.is_active = TRUE AND t.slug = 'adnoc'
--                - ON CONFLICT (tenant_id, pack_id/scenario_id) DO NOTHING — idempotent
--                - JSONB shapes mirror migration 240 expected_outcomes + event_injection_payload
--              Verified expected_outcomes from CR-M / CR-N / CR-O delivery reports.
-- Date: 2026-05-29

BEGIN;

-- ============================================================
-- demo_seed_pack — 3 versioned bundles (one per ADNOC tier-2 scenario)
-- ============================================================
INSERT INTO demo_seed_pack (tenant_id, pack_id, version, description, fixture_path, payload, is_active)
SELECT t.id, x.pack_id, 1, x.description, x.fixture_path, x.payload::JSONB, TRUE
FROM tenant t
CROSS JOIN (VALUES
  (
    'pack.labor_cascade',
    'Federal Decree-Law No.9/2024 labor-law cascade — ADNOC contractor exposure (CR-M)',
    'seeds/adnoc-pack/scenarios/labor_cascade/',
    '{"sources":["mohre_labor"],"contractTypes":["service_agreement","staffing"],"clauseTypes":["emiratisation","labor_compliance"]}'
  ),
  (
    'pack.budget_burn',
    'ADNOC Offshore→Drilling AED 4.22B services contract budget burn — cure notice (CR-N)',
    'seeds/adnoc-pack/scenarios/budget_burn/',
    '{"sources":["internal:harness"],"clauseTypes":["rate_card","cure_period","variation_order"]}'
  ),
  (
    'pack.trade_margin',
    'Murban OSP price drop — oil-trade margin impact seller + buyer (CR-O)',
    'seeds/adnoc-pack/scenarios/trade_margin/',
    '{"sources":["commodity_crude"],"benchmarkCode":"murban_osp","clauseTypes":["price_indexation","margin_protection"]}'
  )
) AS x(pack_id, description, fixture_path, payload)
WHERE t.is_active = TRUE AND t.slug = 'adnoc'
ON CONFLICT (tenant_id, pack_id) DO NOTHING;

-- ============================================================
-- demo_scenario — 3 ADNOC tier-2 scenarios with verified expected outcomes
-- ============================================================
INSERT INTO demo_scenario (
  tenant_id, scenario_id, display_name_en, display_name_ar, description,
  tier, seed_pack_ref, event_injection_payload, expected_outcomes, is_active
)
SELECT
  t.id,
  x.scenario_id,
  x.display_name_en,
  x.display_name_ar,
  x.description,
  x.tier,
  x.seed_pack_ref,
  x.event_injection_payload::JSONB,
  x.expected_outcomes::JSONB,
  TRUE
FROM tenant t
CROSS JOIN (VALUES
  (
    -- CR-M: Labor-Law Cascade
    'labor_cascade',
    'Labor-Law Cascade — Federal Decree-Law No.9/2024',
    'تسلسل قانون العمل — المرسوم الاتحادي بقانون رقم 9 لسنة 2024',
    'Federal Decree-Law No.9/2024 labor-law cascade across ADNOC contractors: ~16 contractors in Emiratisation non-compliance band, aggregate penalty exposure AED 1.6M–1.7M, amendment drafts triggered for affected service agreements.',
    2,
    'pack.labor_cascade',
    '{"signalKind":"regulatory","subtype":"labor_law_decree","sourceId":"mohre_labor","decreeRef":"Federal Decree-Law No. 9 of 2024","effectiveDate":"2024-08-30","severity":"high","geography":"AE","dedupHash":"mohre_labor|2024-08-30|federal decree-law no. 9 of 2024 — labor relations amendments"}',
    '{"contractsAffected":"~16","penaltyExposureAed":"1,600,000–1,700,000","advisoryDraftCount":">=16","alertCount":">=1","note":"Decree signal is pre-seeded (migration 288); trigger ensures is_active=true + returns outcomes. advisoryDrafts = one per non-compliant contractor."}'
  ),
  (
    -- CR-N: Budget Burn
    'budget_burn',
    'Budget Burn — AED 4.22B Offshore Drilling Services Contract',
    'حرق الميزانية — عقد خدمات الحفر البحري بقيمة 4.22 مليار درهم',
    'ADNOC Offshore→Drilling AED 4.22B services contract budget burn: day-rate overrun +8% at month 4 triggers cure-notice clause; year-end projection +1.3% over approved budget.',
    2,
    'pack.budget_burn',
    '{"signalKind":"internal","subtype":"budget_overrun","contractRef":"ADNOC-DRILLSVC-2026","dayRateVariancePct":8.0,"month":4,"yearEndProjectionVariancePct":1.3,"severity":"high"}',
    '{"contractsAffected":1,"dayRateVariancePct":"+8%","dayRateBreachMonth":4,"yearEndProjectionOverrunPct":"+1.3%","cureNoticeEligible":true,"advisoryDraftCount":">=1","note":"Budget + actuals data is seeded (migrations 303-304). Trigger is static — data already in place; returns outcomes."}'
  ),
  (
    -- CR-O: Trade Margin
    'trade_margin',
    'Trade Margin — Murban OSP Drop (Seller + Buyer)',
    'هامش التداول — انخفاض السعر الرسمي لمربان (البائع والمشتري)',
    'Murban OSP drop $110.75→$104.44/bbl — seller margin contracts $106.15→$99.84/bbl; −AED 139M across 3 cargoes; buyer margin improves +$9/bbl on downstream sale.',
    2,
    'pack.trade_margin',
    '{"signalKind":"commodity","marker":"MURBAN_OSP","benchmarkCode":"murban_osp","priorPriceUsd":110.75,"newPriceUsd":104.44,"priceDropUsd":6.31,"severity":"high"}',
    '{"sellerMarginBefore_usdPerBbl":"106.15","sellerMarginAfter_usdPerBbl":"99.84","sellerMarginDelta_usdPerBbl":"-6.31","totalImpactAed":"-139,000,000","cargoes":3,"buyerMarginImprovement_usdPerBbl":"+9.00","note":"Trigger resets murban_osp benchmark to 110.75 (pre-drop starting state) and recomputes margins so operator can demo the drop live."}'
  )
) AS x(
  scenario_id, display_name_en, display_name_ar, description,
  tier, seed_pack_ref, event_injection_payload, expected_outcomes
)
WHERE t.is_active = TRUE AND t.slug = 'adnoc'
ON CONFLICT (tenant_id, scenario_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (323, '323_crp_seed_adnoc_demo_scenarios', CURRENT_TIMESTAMP);

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 323;
-- -- Note: demo_scenario + demo_seed_pack have audit triggers; use soft-delete if RLS blocks DELETE.
-- -- Direct DELETE is permitted for neondb_owner (DEFINER context bypasses RLS).
-- -- DELETE FROM demo_scenario   WHERE scenario_id IN ('labor_cascade','budget_burn','trade_margin');
-- -- DELETE FROM demo_seed_pack  WHERE pack_id     IN ('pack.labor_cascade','pack.budget_burn','pack.trade_margin');
-- COMMIT;
-- ============================================================
