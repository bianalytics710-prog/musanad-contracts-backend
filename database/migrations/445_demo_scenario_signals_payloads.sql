-- Migration: 445_demo_scenario_signals_payloads.sql
-- Module: Demo Harness — DEBT-CRIJ-3 (cascade wiring, part 2)
-- Description: The fn_demo_scenario_trigger signal-injection loop iterates
--              event_injection_payload.signals. Existing rows stored flat
--              metadata (signalKind/priceUsd/severity) with no signals
--              array, so the loop never executed — zero-count outcome.
--              This migration UPDATEs the 8 signal-injection scenarios to
--              include a real `signals` array (1-3 signals each) so the
--              cascade (signal → correlation → advisory → notification →
--              score recompute) actually fires when the trigger runs.
--
--              Tier-2 prepare-only scenarios (trade_margin/labor_cascade/
--              budget_burn) are NOT modified — their trigger paths skip
--              the loop and have their own honest prepare logic.
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
BEGIN

  -- brent_review — Brent crosses upward price-review threshold
  UPDATE demo_scenario
  SET event_injection_payload = jsonb_set(
        COALESCE(event_injection_payload, '{}'::jsonb),
        '{signals}',
        '[
          {
            "sourceId": "commodity_crude",
            "kind": "commodity_price",
            "signalKindSubtype": "brent_price_review",
            "title": "Brent crosses USD 95 — price-review threshold sustained",
            "summary": "Brent dated benchmark settled at USD 98.50/bbl for the 91st consecutive day above the USD 95 floor — triggers contractual price-review clause in Brent-indexed supply agreements.",
            "severity": "high",
            "url": "https://demo.example/brent/price-review-trigger"
          }
        ]'::jsonb,
        true
      )
  WHERE tenant_id = v_tenant AND scenario_id = 'brent_review';

  -- cyclone — Persian Gulf weather FM eligibility
  UPDATE demo_scenario
  SET event_injection_payload = jsonb_set(
        COALESCE(event_injection_payload, '{}'::jsonb),
        '{signals}',
        '[
          {
            "sourceId": "open_meteo_noaa",
            "kind": "weather",
            "signalKindSubtype": "cyclone_warning",
            "title": "Tropical cyclone forecast — Persian Gulf — Category 3",
            "summary": "NCM UAE issued a Category-3 cyclone alert affecting the Persian Gulf shipping lanes. Force majeure eligibility threshold triggered for marine + offshore contracts with Gulf-routed deliveries during the 72h window.",
            "severity": "critical",
            "url": "https://demo.example/weather/cyclone-pg-072626"
          }
        ]'::jsonb,
        true
      )
  WHERE tenant_id = v_tenant AND scenario_id = 'cyclone';

  -- ofac_sanctions — direct + chain exposure
  UPDATE demo_scenario
  SET event_injection_payload = jsonb_set(
        COALESCE(event_injection_payload, '{}'::jsonb),
        '{signals}',
        '[
          {
            "sourceId": "ofac_sdn",
            "kind": "sanctions",
            "signalKindSubtype": "ofac_sdn_designation",
            "title": "OFAC SDN designation — Crescent Petroleum Company affiliate added",
            "summary": "U.S. Treasury Office of Foreign Assets Control added a new entity to the Specially Designated Nationals list affecting downstream contract counterparties.",
            "severity": "critical",
            "url": "https://demo.example/ofac/sdn-2026-05-14"
          }
        ]'::jsonb,
        true
      )
  WHERE tenant_id = v_tenant AND scenario_id = 'ofac_sanctions';

  -- hormuz — Strait disruption affecting supply + charter contracts
  UPDATE demo_scenario
  SET event_injection_payload = jsonb_set(
        COALESCE(event_injection_payload, '{}'::jsonb),
        '{signals}',
        '[
          {
            "sourceId": "rss_reuters_energy",
            "kind": "geopolitical",
            "signalKindSubtype": "hormuz_disruption",
            "title": "Strait of Hormuz disruption — 72-hour shipping suspension",
            "summary": "Maritime traffic through the Strait of Hormuz suspended pending resolution of regional security incident — affects all Gulf-routed supply and charter party contracts.",
            "severity": "critical",
            "url": "https://demo.example/hormuz/disruption-feed"
          }
        ]'::jsonb,
        true
      )
  WHERE tenant_id = v_tenant AND scenario_id = 'hormuz';

  -- epc_sla — EPC contractor repeated milestone slippage
  UPDATE demo_scenario
  SET event_injection_payload = jsonb_set(
        COALESCE(event_injection_payload, '{}'::jsonb),
        '{signals}',
        '[
          {
            "sourceId": "internal_icv_custom",
            "kind": "internal",
            "signalKindSubtype": "epc_sla_breach",
            "title": "EPC contractor — 3rd consecutive milestone slippage detected",
            "summary": "Internal project-controls feed flagged a third consecutive milestone slippage by an EPC contractor — cure-notice eligibility window opens per contractual remedy clause.",
            "severity": "high",
            "url": "https://demo.example/internal/epc-sla-feed"
          }
        ]'::jsonb,
        true
      )
  WHERE tenant_id = v_tenant AND scenario_id = 'epc_sla';

  -- renewal — 90-day renewal lookahead
  UPDATE demo_scenario
  SET event_injection_payload = jsonb_set(
        COALESCE(event_injection_payload, '{}'::jsonb),
        '{signals}',
        '[
          {
            "sourceId": "internal_icv_custom",
            "kind": "internal",
            "signalKindSubtype": "renewal_lookahead_90d",
            "title": "Contract renewal lookahead — 90-day window opens",
            "summary": "Multiple contracts entering the 90-day renewal lookahead window — negotiation runway available for re-pricing, term changes, or wind-down decisions.",
            "severity": "medium",
            "url": "https://demo.example/internal/renewal-lookahead"
          }
        ]'::jsonb,
        true
      )
  WHERE tenant_id = v_tenant AND scenario_id = 'renewal';

  -- icv_shortfall — ICV status downgrade for a supplier
  UPDATE demo_scenario
  SET event_injection_payload = jsonb_set(
        COALESCE(event_injection_payload, '{}'::jsonb),
        '{signals}',
        '[
          {
            "sourceId": "internal_icv_custom",
            "kind": "internal",
            "signalKindSubtype": "icv_shortfall",
            "title": "ICV status downgrade — Tier-1 supplier dropped from Premier",
            "summary": "In-Country Value compliance team flagged an ICV downgrade for a Tier-1 supplier — affects active supply contracts requiring Premier certification.",
            "severity": "high",
            "url": "https://demo.example/internal/icv-downgrade"
          }
        ]'::jsonb,
        true
      )
  WHERE tenant_id = v_tenant AND scenario_id = 'icv_shortfall';

  -- esg_subcontractor — ESG chain violation
  UPDATE demo_scenario
  SET event_injection_payload = jsonb_set(
        COALESCE(event_injection_payload, '{}'::jsonb),
        '{signals}',
        '[
          {
            "sourceId": "mock_social_x",
            "kind": "esg",
            "signalKindSubtype": "esg_subcontractor_violation",
            "title": "Sub-contractor ESG violation — downstream worker safety incident",
            "summary": "Social media monitoring flagged a worker-safety ESG incident at a sub-contractor site — reputational exposure for prime contractor and downstream client.",
            "severity": "high",
            "url": "https://demo.example/esg/subcon-incident"
          }
        ]'::jsonb,
        true
      )
  WHERE tenant_id = v_tenant AND scenario_id = 'esg_subcontractor';

END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (445, '445_demo_scenario_signals_payloads', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 445;
-- UPDATE demo_scenario SET event_injection_payload = event_injection_payload - 'signals'
-- WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--   AND scenario_id IN ('brent_review','cyclone','ofac_sanctions','hormuz','epc_sla',
--                       'renewal','icv_shortfall','esg_subcontractor');
-- ============================================================
