-- Migration: 463_act4_demo_contract_correlations.sql
-- Module: ADNOC demo — Act 4 Aisha approver Risk-tab fixture
-- Date: 2026-06-02
--
-- Problem: the v3.0 script's Act-4 talking point promises rich 5-dimension
-- explainability — "click Legal dimension → 5 contributing correlations
-- with rule_id, match reason, confidence". The walkthrough showed Aisha's
-- queue contracts (25/26/27) had 0 → 5 correlations after migration 459,
-- but their dim scores collapse to 0/4/0/11/0 because fn_risk_score_compute
-- routes a single seed signal through one impact path. Visually that
-- contradicts the explainability pitch.
--
-- Fix: pin the demo to CRQ-GAS-005 ("ADNOC Gas — 25-Year Gas SPA —
-- Shah Gas Field") which already has clean baseline dim scores
-- 60/50/70/68/73 → health 53 (Medium) — the actual numbers the script
-- quotes. Add 4 additional active correlations (it currently has 1) so the
-- drill-down panel surfaces a rich list, and route them through a fresh
-- demo-realistic signal so the "Cross-dimension fixture" pollution does
-- not surface in Aisha's Risk tab.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_tenant     UUID := '00000000-0000-0000-0000-000000000001';
  v_contract   BIGINT := 239;   -- CRQ-GAS-005 = Shah Gas Field 25-yr SPA
  v_src_id     BIGINT;
  v_signal_id  BIGINT;
  v_rule       TEXT;
  v_reason     TEXT;
  v_conf       NUMERIC;
  v_evidence   JSONB;
  v_geo        JSONB;
  v_rule_hash  TEXT;
BEGIN
  -- Sanity: skip if the contract doesn't exist on this branch
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = v_contract AND is_active) THEN
    RAISE NOTICE 'Contract 239 not present — skipping Act-4 fixture seed';
    RETURN;
  END IF;

  -- Use mock_social_x as the source
  SELECT id INTO v_src_id FROM osint_source
   WHERE tenant_id = v_tenant AND source_id = 'mock_social_x' LIMIT 1;
  IF v_src_id IS NULL THEN
    RAISE NOTICE 'mock_social_x source missing — skipping';
    RETURN;
  END IF;

  -- Fresh signal so the Impact-Watch label reads cleanly
  INSERT INTO osint_signal (
    tenant_id, osint_source_id, source_id, source, source_reliability,
    ext_id, dedup_hash,
    kind, signal_kind_subtype, category,
    title, title_en, summary, severity, severity_v2, confidence,
    url, data_classification, raw_payload, fetched_at, is_active, created_at
  ) VALUES (
    v_tenant, v_src_id, 'mock_social_x', 'mock_social_x', 0.92,
    'demo:crq_gas_005_multidim_risk',
    'demo_crqgas005|2026-06-02|multidim risk fixture for Act 4 drill-down',
    'regulatory', 'multi_dimension_pattern', 'regulatory',
    'Gas SPA risk envelope — CRQ-GAS-005 Shah Gas Field',
    'Gas SPA risk envelope — CRQ-GAS-005 Shah Gas Field',
    'Composite multi-dimension risk pattern detected against the 25-year Shah Gas Field SPA — counterparty / commodity / EPC / ESG signals all triggering simultaneously.',
    'high', 'high', 0.92,
    'https://demo.example/risk-envelope/crq-gas-005', 'demo',
    jsonb_build_object('seedFor', 'aisha_act4_demo', 'contracts', ARRAY[v_contract]),
    now(), TRUE, now()
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_signal_id;

  IF v_signal_id IS NULL THEN
    SELECT id INTO v_signal_id FROM osint_signal
     WHERE ext_id = 'demo:crq_gas_005_multidim_risk' AND tenant_id = v_tenant LIMIT 1;
  END IF;

  -- 4 additional correlations across 5 dimensions
  FOR v_rule, v_reason, v_conf, v_evidence, v_geo IN
    SELECT * FROM (VALUES
      (
        'rule.brent.price_review_trigger_high',
        'Brent USD-95 threshold sustained 91 days — price-review clause on Shah Gas SPA',
        0.88::NUMERIC,
        jsonb_build_object('priceUsd', 98.50, 'marker', 'brent', 'sustainDays', 91),
        '["persian_gulf","global_oil_market"]'::JSONB
      ),
      (
        'rule.epc.cure_notice_pattern',
        'EPC sub-contractor Shah field — 3 milestone slippages in 180d',
        0.86::NUMERIC,
        jsonb_build_object('slippages', 3, 'window', '180d', 'cureEligible', TRUE),
        '["uae"]'::JSONB
      ),
      (
        'rule.esg.icv_downgrade',
        'ICV status downgraded — Tier-1 process-engineering supplier',
        0.85::NUMERIC,
        jsonb_build_object('icvStatus', 'downgraded', 'priorTier', 'premier'),
        '["uae"]'::JSONB
      ),
      (
        'rule.sanctions.chain_exposure',
        'OFAC SDN match on logistics sub-contractor — chain depth 2',
        0.79::NUMERIC,
        jsonb_build_object('authority', 'OFAC', 'designation', 'SDN', 'chainDepth', 2),
        '["global"]'::JSONB
      )
    ) AS rules(rule_id, reason, conf, evidence, geo)
  LOOP
    v_rule_hash := substring(encode(digest(v_rule, 'sha256'), 'hex') from 1 for 32);
    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
      confidence, match_reason, match_evidence, match_geographies, match_entities,
      status, data_classification, is_active, created_by, updated_by
    ) VALUES (
      v_tenant, v_signal_id, v_contract, v_rule, v_rule_hash,
      v_conf, v_reason, v_evidence, v_geo, '[]'::JSONB,
      'active', 'demo', TRUE, 1, 1
    ) ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
  END LOOP;
END $$;

REFRESH MATERIALIZED VIEW latest_risk_score;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (463, '463_act4_demo_contract_correlations', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 463;
-- DELETE FROM correlation WHERE signal_id IN
--   (SELECT id FROM osint_signal WHERE ext_id = 'demo:crq_gas_005_multidim_risk');
-- DELETE FROM osint_signal WHERE ext_id = 'demo:crq_gas_005_multidim_risk';
-- ============================================================
