-- Migration: 450_demo_synth_contract_columns_fix.sql
-- Module: Demo Harness — DEBT-CRIJ-3 (cascade wiring, part 7)
-- Description: 449 referenced contract.title / contract.value / contract.tenant_id
--              which don't exist (contract is single-tenant; columns are
--              title_en/value_aed). Rewrite synthesize fn with correct names.
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_demo_synthesize_correlations_for_signal(
  p_signal_id   BIGINT,
  p_scenario_id TEXT,
  p_actor_id    BIGINT
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id      UUID;
  v_inserted_count INTEGER := 0;
  v_contract_id    BIGINT;
  v_rule_id        TEXT;
  v_rule_hash      TEXT;
  v_match_reason   TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  CASE p_scenario_id
    WHEN 'brent_review' THEN
      v_rule_id      := 'rule.brent.price_review_trigger_high';
      v_rule_hash    := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'Brent crossed USD 95 price-review threshold sustained 91 days — contract index-linked';
      FOR v_contract_id IN
        SELECT id FROM contract
        WHERE (lower(coalesce(title_en, '')) ~ 'gas|oil|supply|spa|crude|murban|brent'
               OR contract_type IN ('Supply','Gas SPA','Services'))
          AND is_active = TRUE
        ORDER BY value_aed DESC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (
          tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
          confidence, match_reason, match_evidence, match_geographies, match_entities,
          status, data_classification, is_active, created_by, updated_by
        ) VALUES (
          v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash,
          0.88, v_match_reason,
          jsonb_build_object('priceUsd', 98.50, 'marker', 'brent', 'sustainDays', 91),
          '["persian_gulf","global_oil_market"]'::jsonb, '[]'::jsonb,
          'active', 'demo', TRUE, p_actor_id, p_actor_id
        ) ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    WHEN 'cyclone' THEN
      v_rule_id      := 'rule.hormuz.charter_party_disruption';
      v_rule_hash    := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'Cat-3 cyclone over Persian Gulf — FM eligibility for Gulf-routed marine/offshore';
      FOR v_contract_id IN
        SELECT id FROM contract
        WHERE (lower(coalesce(title_en, '')) ~ 'shipping|marine|offshore|charter|towage|fujairah|port'
               OR contract_type IN ('Services','Supply'))
          AND is_active = TRUE
        ORDER BY value_aed DESC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (
          tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
          confidence, match_reason, match_evidence, match_geographies, match_entities,
          status, data_classification, is_active, created_by, updated_by
        ) VALUES (
          v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash,
          0.91, v_match_reason,
          jsonb_build_object('severity', 'critical', 'eligibility', 'force_majeure', 'windowHours', 72),
          '["persian_gulf","strait_of_hormuz"]'::jsonb, '[]'::jsonb,
          'active', 'demo', TRUE, p_actor_id, p_actor_id
        ) ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    WHEN 'ofac_sanctions' THEN
      v_rule_id      := 'rule.sanctions.direct_counterparty';
      v_rule_hash    := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'OFAC SDN designation hits a contract counterparty';
      FOR v_contract_id IN
        SELECT c.id FROM contract c
        LEFT JOIN party p ON p.id = c.counterparty_id
        WHERE (lower(coalesce(p.name_en, '')) ~ 'crescent|lamprell|target engineering|gulf marine|jereh|al mansoori'
               OR c.id IN (SELECT id FROM contract WHERE is_active = TRUE ORDER BY value_aed DESC NULLS LAST LIMIT 6))
          AND c.is_active = TRUE
        ORDER BY c.value_aed DESC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (
          tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
          confidence, match_reason, match_evidence, match_geographies, match_entities,
          status, data_classification, is_active, created_by, updated_by
        ) VALUES (
          v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash,
          0.95, v_match_reason,
          jsonb_build_object('authority', 'OFAC', 'designation', 'SDN', 'directHit', TRUE),
          '["global"]'::jsonb, '[]'::jsonb,
          'active', 'demo', TRUE, p_actor_id, p_actor_id
        ) ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    WHEN 'hormuz' THEN
      v_rule_id      := 'rule.hormuz.supply_disruption';
      v_rule_hash    := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'Hormuz Strait disruption — supply route impacted';
      FOR v_contract_id IN
        SELECT id FROM contract
        WHERE (lower(coalesce(title_en, '')) ~ 'supply|shipping|marine|gas spa|crude|gas'
               OR contract_type IN ('Supply','Gas SPA'))
          AND is_active = TRUE
        ORDER BY value_aed DESC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (
          tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
          confidence, match_reason, match_evidence, match_geographies, match_entities,
          status, data_classification, is_active, created_by, updated_by
        ) VALUES (
          v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash,
          0.93, v_match_reason,
          jsonb_build_object('disruption', 'closure', 'durationHours', 72),
          '["strait_of_hormuz","persian_gulf"]'::jsonb, '[]'::jsonb,
          'active', 'demo', TRUE, p_actor_id, p_actor_id
        ) ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    WHEN 'epc_sla' THEN
      v_rule_id      := 'rule.epc.cure_notice_pattern';
      v_rule_hash    := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'EPC contractor: 3rd consecutive milestone slippage';
      FOR v_contract_id IN
        SELECT id FROM contract
        WHERE (lower(coalesce(title_en, '')) ~ 'epc|engineering|construction|drilling|platform'
               OR contract_type = 'EPC')
          AND is_active = TRUE
        ORDER BY value_aed DESC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (tenant_id, signal_id, contract_id, rule_id, rule_version_hash, confidence, match_reason, match_evidence, match_geographies, match_entities, status, data_classification, is_active, created_by, updated_by)
        VALUES (v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash, 0.88, v_match_reason,
          jsonb_build_object('slippages', 3, 'window', '180d', 'cureEligible', TRUE),
          '["uae"]'::jsonb, '[]'::jsonb, 'active', 'demo', TRUE, p_actor_id, p_actor_id)
        ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    WHEN 'renewal' THEN
      v_rule_id      := 'rule.renewal.lookahead';
      v_rule_hash    := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'Contract entering 90-day renewal lookahead window';
      FOR v_contract_id IN
        SELECT id FROM contract
        WHERE end_date IS NOT NULL
          AND end_date >= CURRENT_DATE
          AND end_date <= CURRENT_DATE + INTERVAL '90 days'
          AND is_active = TRUE
        ORDER BY end_date ASC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (tenant_id, signal_id, contract_id, rule_id, rule_version_hash, confidence, match_reason, match_evidence, match_geographies, match_entities, status, data_classification, is_active, created_by, updated_by)
        VALUES (v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash, 0.78, v_match_reason,
          jsonb_build_object('window', '90d', 'action', 'review_renewal'),
          '["uae"]'::jsonb, '[]'::jsonb, 'active', 'demo', TRUE, p_actor_id, p_actor_id)
        ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    WHEN 'icv_shortfall' THEN
      v_rule_id      := 'rule.esg.icv_downgrade';
      v_rule_hash    := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'ICV status downgraded — Tier-1 supplier Premier certification lost';
      FOR v_contract_id IN
        SELECT id FROM contract
        WHERE (lower(coalesce(title_en, '')) ~ 'services|supply|consultancy'
               OR contract_type IN ('Services','Supply','Consultancy'))
          AND is_active = TRUE
        ORDER BY value_aed DESC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (tenant_id, signal_id, contract_id, rule_id, rule_version_hash, confidence, match_reason, match_evidence, match_geographies, match_entities, status, data_classification, is_active, created_by, updated_by)
        VALUES (v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash, 0.85, v_match_reason,
          jsonb_build_object('icvStatus', 'downgraded', 'priorTier', 'premier'),
          '["uae"]'::jsonb, '[]'::jsonb, 'active', 'demo', TRUE, p_actor_id, p_actor_id)
        ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    WHEN 'esg_subcontractor' THEN
      v_rule_id      := 'rule.esg.sub_contractor_violation';
      v_rule_hash    := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'Sub-contractor ESG worker-safety violation — chain match';
      FOR v_contract_id IN
        SELECT id FROM contract
        WHERE lower(coalesce(title_en, '')) ~ 'offshore|drilling|construction|epc|engineering|services'
          AND is_active = TRUE
        ORDER BY value_aed DESC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (tenant_id, signal_id, contract_id, rule_id, rule_version_hash, confidence, match_reason, match_evidence, match_geographies, match_entities, status, data_classification, is_active, created_by, updated_by)
        VALUES (v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash, 0.86, v_match_reason,
          jsonb_build_object('incident', 'worker_safety', 'chainDepth', 2),
          '["uae"]'::jsonb, '[]'::jsonb, 'active', 'demo', TRUE, p_actor_id, p_actor_id)
        ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    ELSE
      v_inserted_count := 0;
  END CASE;

  IF v_inserted_count > 0 THEN
    PERFORM pg_notify(
      'correlation_inserted',
      jsonb_build_object('tenantId', v_tenant_id, 'signalId', p_signal_id, 'inserted', v_inserted_count)::text
    );
  END IF;

  RETURN v_inserted_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_demo_synthesize_correlations_for_signal(BIGINT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_synthesize_correlations_for_signal(BIGINT, TEXT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (450, '450_demo_synth_contract_columns_fix', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 450;
-- -- Re-apply 449 to restore the broken column references.
-- ============================================================
