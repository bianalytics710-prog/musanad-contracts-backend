-- Migration: 459_seed_correlations_aisha_queue.sql
-- Module: Aisha Approver Dashboard — E2E walkthrough Issue #4 fix
-- Description: Aisha's approval queue currently shows contracts 25/26/27
--              (OQOOD-2026-027, -026, -025) which have ZERO contributing
--              correlations across all 5 risk dimensions. When the demo
--              presenter clicks any dimension on the Risk tab, the
--              drill-down shows the empty-state copy ("No active
--              correlations are currently driving this dimension") — not
--              the rich rule + reason + confidence content the Act 4
--              talking point promises.
--
--              Seed contributing correlations against these 3 contracts so
--              every dimension has data to surface. Use a representative
--              mix of rules across all 5 dimensions:
--                Legal       → rule.sanctions.direct_counterparty
--                Financial   → rule.brent.price_review_trigger_high
--                Operational → rule.epc.cure_notice_pattern
--                Reputational→ rule.esg.sub_contractor_violation
--                Compliance  → rule.esg.icv_downgrade
--
--              Each correlation gets active status, demo classification,
--              and an OSINT signal that ties it to a realistic narrative.
--              The signal is also created here (shared across the 3
--              contracts) so the correlation rows have valid FK targets.
-- Date: 2026-06-02

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_tenant      UUID := '00000000-0000-0000-0000-000000000001';
  v_src_id      BIGINT;
  v_signal_id   BIGINT;
  v_contract    BIGINT;
  v_rule        TEXT;
  v_rule_hash   TEXT;
  v_match_reason TEXT;
  v_evidence    JSONB;
  v_geo         JSONB;
  v_confidence  NUMERIC;
BEGIN
  -- Use the mock_social_x source for the seed signal
  SELECT id INTO v_src_id FROM osint_source
  WHERE tenant_id = v_tenant AND source_id = 'mock_social_x' LIMIT 1;

  IF v_src_id IS NULL THEN
    RAISE NOTICE 'mock_social_x source not found — skipping seed';
    RETURN;
  END IF;

  -- Create a single seed signal that all 3 contracts × 5 rules reference
  INSERT INTO osint_signal (
    tenant_id, osint_source_id, source_id, source, source_reliability,
    ext_id, dedup_hash,
    kind, signal_kind_subtype, category,
    title, title_en, summary, severity, severity_v2, confidence,
    url, data_classification, raw_payload, fetched_at, is_active, created_at
  ) VALUES (
    v_tenant, v_src_id,
    'mock_social_x', 'mock_social_x', 0.85,
    'seed:aisha_queue_correlations_v1',
    'seed_aisha|2026-06-02|aisha approval queue cross-dimension fixture',
    'news', 'cross_dimension_fixture', 'regulatory',
    'Cross-dimension risk fixture — Aisha approval queue',
    'Cross-dimension risk fixture — Aisha approval queue',
    'Synthetic signal seeded to populate Aisha approval queue contracts with contributing correlations across all 5 risk dimensions for demo purposes.',
    'medium', 'medium', 0.85,
    'https://demo.example/seed/aisha-queue', 'demo',
    jsonb_build_object('seedFor', 'aisha_approval_queue', 'contracts', ARRAY[25, 26, 27]),
    now(), TRUE, now()
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_signal_id;

  IF v_signal_id IS NULL THEN
    SELECT id INTO v_signal_id FROM osint_signal
    WHERE ext_id = 'seed:aisha_queue_correlations_v1' AND tenant_id = v_tenant LIMIT 1;
  END IF;

  -- For each of the 3 queue contracts × 5 rules, insert a correlation.
  FOREACH v_contract IN ARRAY ARRAY[25, 26, 27]::BIGINT[] LOOP
    FOR v_rule, v_match_reason, v_confidence, v_evidence, v_geo IN
      SELECT * FROM (VALUES
        (
          'rule.sanctions.direct_counterparty',
          'OFAC SDN list entry intersects counterparty registry — direct match',
          0.93::NUMERIC,
          jsonb_build_object('authority', 'OFAC', 'designation', 'SDN', 'designationDate', '2026-05-30'),
          '["global"]'::JSONB
        ),
        (
          'rule.brent.price_review_trigger_high',
          'Brent crossed USD 95 sustained 91 days — price-review clause triggers contract recompute',
          0.88::NUMERIC,
          jsonb_build_object('priceUsd', 98.50, 'marker', 'brent', 'sustainDays', 91),
          '["persian_gulf","global_oil_market"]'::JSONB
        ),
        (
          'rule.epc.cure_notice_pattern',
          'EPC contractor — 3 milestone slippages in 180 days — cure notice eligibility',
          0.86::NUMERIC,
          jsonb_build_object('slippages', 3, 'window', '180d', 'cureEligible', TRUE),
          '["uae"]'::JSONB
        ),
        (
          'rule.esg.sub_contractor_violation',
          'Sub-contractor ESG worker-safety incident reported — chain depth 2',
          0.84::NUMERIC,
          jsonb_build_object('incident', 'worker_safety', 'chainDepth', 2),
          '["uae"]'::JSONB
        ),
        (
          'rule.esg.icv_downgrade',
          'ICV status downgraded — Tier-1 supplier Premier certification lost',
          0.85::NUMERIC,
          jsonb_build_object('icvStatus', 'downgraded', 'priorTier', 'premier'),
          '["uae"]'::JSONB
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
        v_confidence, v_match_reason, v_evidence, v_geo, '[]'::JSONB,
        'active', 'demo', TRUE, 1, 1
      ) ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
    END LOOP;
  END LOOP;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (459, '459_seed_correlations_aisha_queue', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 459;
-- DELETE FROM correlation WHERE signal_id IN
--   (SELECT id FROM osint_signal WHERE ext_id = 'seed:aisha_queue_correlations_v1');
-- DELETE FROM osint_signal WHERE ext_id = 'seed:aisha_queue_correlations_v1';
-- ============================================================
