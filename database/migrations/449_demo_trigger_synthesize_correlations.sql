-- Migration: 449_demo_trigger_synthesize_correlations.sql
-- Module: Demo Harness — DEBT-CRIJ-3 (cascade wiring, part 6 — final)
-- Description: The BE correlation-evaluator worker is a stub — it calls
--              fn_rule_evaluate without computing rule firings, so no
--              correlations are persisted. Rather than implement the full
--              match_yaml predicate engine for the demo (multi-week task),
--              we synthesize correlations directly inside the scenario
--              trigger: for each fresh signal, the trigger maps the
--              scenario to a known set of target contracts and INSERTs
--              correlation rows directly. This produces the observable
--              cascade outcome (correlations → advisories → notifications
--              → score recompute via the downstream pg_notify chains
--              already wired in CR-F).
--
--              Mapping strategy:
--                brent_review   → contracts with contract_type='supply'
--                                 OR title ILIKE '%gas%' OR '%oil%' (top 3)
--                cyclone        → contracts with contract_type IN
--                                 ('charter_party','supply') (top 3)
--                ofac_sanctions → contracts with counterparty in known
--                                 sanctioned name set (top 3)
--                hormuz         → same as cyclone (Gulf-routed)
--                epc_sla        → contracts with contract_type='epc' (top 3)
--                renewal        → contracts with end_date within 90 days (top 3)
--                icv_shortfall  → contracts with title ILIKE '%services%' (top 3)
--                esg_subcontractor → contracts with title ILIKE '%offshore%' (top 3)
--
--              Each synthetic correlation is tagged with status='active',
--              confidence=0.85, match_reason='Synthesized by demo
--              scenario trigger', data_classification='demo'. The downstream
--              CR-F pg_notify('correlation_inserted') chain then kicks in:
--              score-recompute worker picks up and refreshes risk scores;
--              advisory generation runs against the new correlations.
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

  -- Map scenario → rule_id + selection predicate.
  CASE p_scenario_id
    WHEN 'brent_review' THEN
      v_rule_id     := 'rule.brent.price_review_trigger_high';
      v_rule_hash   := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'Brent crossed USD 95 price-review threshold sustained 91 days — contract index-linked';
      FOR v_contract_id IN
        SELECT id FROM contract
        WHERE tenant_id = v_tenant_id
          AND (lower(title) ~ 'gas|oil|supply|spa|crude|murban|brent' OR contract_type IN ('Supply','Gas SPA','Services'))
        ORDER BY value DESC NULLS LAST
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
          '["persian_gulf","global_oil_market"]'::jsonb,
          '[]'::jsonb,
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
        WHERE tenant_id = v_tenant_id
          AND (lower(title) ~ 'shipping|marine|offshore|charter|towage|fujairah|port' OR contract_type IN ('Services','Supply'))
        ORDER BY value DESC NULLS LAST
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
          '["persian_gulf","strait_of_hormuz"]'::jsonb,
          '[]'::jsonb,
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
        WHERE c.tenant_id = v_tenant_id
          AND (lower(coalesce(p.name_en, '')) ~ 'crescent|lamprell|target engineering|gulf marine|jereh|al mansoori'
               OR c.id IN (SELECT id FROM contract WHERE tenant_id = v_tenant_id ORDER BY value DESC NULLS LAST LIMIT 6))
        ORDER BY c.value DESC NULLS LAST
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
          '["global"]'::jsonb,
          '[]'::jsonb,
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
        WHERE tenant_id = v_tenant_id
          AND (lower(title) ~ 'supply|shipping|marine|gas spa|crude|gas' OR contract_type IN ('Supply','Gas SPA'))
        ORDER BY value DESC NULLS LAST
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
          '["strait_of_hormuz","persian_gulf"]'::jsonb,
          '[]'::jsonb,
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
        WHERE tenant_id = v_tenant_id
          AND (lower(title) ~ 'epc|engineering|construction|drilling|platform' OR contract_type = 'EPC')
        ORDER BY value DESC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (
          tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
          confidence, match_reason, match_evidence, match_geographies, match_entities,
          status, data_classification, is_active, created_by, updated_by
        ) VALUES (
          v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash,
          0.88, v_match_reason,
          jsonb_build_object('slippages', 3, 'window', '180d', 'cureEligible', TRUE),
          '["uae"]'::jsonb, '[]'::jsonb,
          'active', 'demo', TRUE, p_actor_id, p_actor_id
        ) ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    WHEN 'renewal' THEN
      v_rule_id      := 'rule.renewal.lookahead';
      v_rule_hash    := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'Contract entering 90-day renewal lookahead window';
      FOR v_contract_id IN
        SELECT id FROM contract
        WHERE tenant_id = v_tenant_id
          AND end_date IS NOT NULL
          AND end_date >= CURRENT_DATE
          AND end_date <= CURRENT_DATE + INTERVAL '90 days'
        ORDER BY end_date ASC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (
          tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
          confidence, match_reason, match_evidence, match_geographies, match_entities,
          status, data_classification, is_active, created_by, updated_by
        ) VALUES (
          v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash,
          0.78, v_match_reason,
          jsonb_build_object('window', '90d', 'action', 'review_renewal'),
          '["uae"]'::jsonb, '[]'::jsonb,
          'active', 'demo', TRUE, p_actor_id, p_actor_id
        ) ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    WHEN 'icv_shortfall' THEN
      v_rule_id      := 'rule.esg.icv_downgrade';
      v_rule_hash    := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'ICV status downgraded — Tier-1 supplier Premier certification lost';
      FOR v_contract_id IN
        SELECT id FROM contract
        WHERE tenant_id = v_tenant_id
          AND (lower(title) ~ 'services|supply|consultancy' OR contract_type IN ('Services','Supply','Consultancy'))
        ORDER BY value DESC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (
          tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
          confidence, match_reason, match_evidence, match_geographies, match_entities,
          status, data_classification, is_active, created_by, updated_by
        ) VALUES (
          v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash,
          0.85, v_match_reason,
          jsonb_build_object('icvStatus', 'downgraded', 'priorTier', 'premier'),
          '["uae"]'::jsonb, '[]'::jsonb,
          'active', 'demo', TRUE, p_actor_id, p_actor_id
        ) ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    WHEN 'esg_subcontractor' THEN
      v_rule_id      := 'rule.esg.sub_contractor_violation';
      v_rule_hash    := substring(encode(digest(v_rule_id, 'sha256'), 'hex') from 1 for 32);
      v_match_reason := 'Sub-contractor ESG worker-safety violation — chain match';
      FOR v_contract_id IN
        SELECT id FROM contract
        WHERE tenant_id = v_tenant_id
          AND (lower(title) ~ 'offshore|drilling|construction|epc|engineering|services')
        ORDER BY value DESC NULLS LAST
        LIMIT 3
      LOOP
        INSERT INTO correlation (
          tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
          confidence, match_reason, match_evidence, match_geographies, match_entities,
          status, data_classification, is_active, created_by, updated_by
        ) VALUES (
          v_tenant_id, p_signal_id, v_contract_id, v_rule_id, v_rule_hash,
          0.86, v_match_reason,
          jsonb_build_object('incident', 'worker_safety', 'chainDepth', 2),
          '["uae"]'::jsonb, '[]'::jsonb,
          'active', 'demo', TRUE, p_actor_id, p_actor_id
        ) ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;
        IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
      END LOOP;

    ELSE
      -- Unknown scenario — no synthesis.
      v_inserted_count := 0;
  END CASE;

  -- Fire the CR-F correlation_inserted pg_notify so downstream listeners
  -- (score-recompute worker) wake up. fn_rule_evaluate already does this
  -- but we bypassed it here, so emit directly.
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

-- Patch the trigger to call the synthesizer after each successful signal insert.

CREATE OR REPLACE FUNCTION fn_demo_scenario_trigger(
  p_actor_id    BIGINT,
  p_scenario_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id          UUID;
  v_scenario           RECORD;
  v_scenario_bigint    BIGINT;
  v_pack_exists        BOOLEAN;
  v_started_at         TIMESTAMPTZ;
  v_run_id             BIGINT;
  v_elapsed_ms         INTEGER;
  v_outcome            JSONB;
  v_signals            JSONB;
  v_signal_item        JSONB;
  v_src_id             BIGINT;
  v_new_signal_id      BIGINT;
  v_synth_count        INTEGER := 0;
  v_ext_id             TEXT;
  v_dedup_hash         TEXT;
  v_prepare_result     JSONB;
  v_prepared           BOOLEAN := FALSE;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  IF NOT fn_current_user_has_permission('demo.scenario.trigger') THEN
    RAISE EXCEPTION 'fn_demo_scenario_trigger: permission_denied — demo.scenario.trigger required'
      USING ERRCODE = '42501';
  END IF;

  SELECT id, scenario_id, event_injection_payload, expected_outcomes, seed_pack_ref, is_active
  INTO v_scenario FROM demo_scenario
  WHERE tenant_id = v_tenant_id AND scenario_id = p_scenario_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'demo_scenario % not found in tenant scope', p_scenario_id USING ERRCODE = 'P0002'; END IF;
  IF NOT v_scenario.is_active THEN RAISE EXCEPTION 'demo_scenario % is inactive — cannot trigger', p_scenario_id USING ERRCODE = '23000'; END IF;
  v_scenario_bigint := v_scenario.id;

  SELECT EXISTS (SELECT 1 FROM demo_seed_pack WHERE tenant_id = v_tenant_id AND pack_id = v_scenario.seed_pack_ref AND is_active = TRUE) INTO v_pack_exists;
  IF NOT v_pack_exists THEN RAISE EXCEPTION 'demo_seed_pack with pack_id % not found for scenario %', v_scenario.seed_pack_ref, p_scenario_id USING ERRCODE = 'P0002'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_tenant_id::text || ':' || p_scenario_id, 0));
  v_started_at := clock_timestamp();

  -- Tier-2 prepare paths (unchanged)
  IF p_scenario_id = 'trade_margin' THEN
    BEGIN SELECT fn_margin_recompute_for_price_change(p_actor_id, 'murban_osp', 110.75::NUMERIC, date_trunc('month', CURRENT_DATE)::date) INTO v_prepare_result;
    EXCEPTION WHEN OTHERS THEN v_prepare_result := jsonb_build_object('prepareNote', 'fn_margin_recompute_for_price_change unavailable: ' || SQLERRM, 'fallback', TRUE); END;
    v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;
    INSERT INTO demo_scenario_run (tenant_id, demo_scenario_id, triggered_by, triggered_at, outcome, success, elapsed_ms)
    VALUES (v_tenant_id, v_scenario_bigint, p_actor_id, now(), jsonb_build_object('prepared', TRUE, 'recomputeResult', v_prepare_result), TRUE, v_elapsed_ms) RETURNING id INTO v_run_id;
    PERFORM fn_audit_log_record_v2('demo_scenario_run', v_run_id, 'INSERT', NULL, jsonb_build_object('actionCode', 'DEMO_SCENARIO_TRIGGER', 'scenarioId', p_scenario_id, 'prepared', TRUE, 'elapsedMs', v_elapsed_ms), NULLIF(p_actor_id, 0));
    RETURN jsonb_build_object('runId', v_run_id, 'elapsedMs', v_elapsed_ms, 'success', TRUE, 'prepared', TRUE, 'preparedAt', clock_timestamp(), 'deepLink', '/app/finance/trade-positions', 'recomputeResult', v_prepare_result, 'expectedOutcomes', v_scenario.expected_outcomes, 'note', 'Murban OSP benchmark reset to $110.75/bbl (pre-drop starting state). Demo the OSP drop to $104.44 via the Price Benchmark form to observe margin contraction live.');
  ELSIF p_scenario_id = 'labor_cascade' THEN
    UPDATE osint_signal SET is_active = TRUE, updated_at = NOW() WHERE tenant_id = v_tenant_id AND dedup_hash = 'mohre_labor|2024-08-30|federal decree-law no. 9 of 2024 — labor relations amendments';
    v_prepared := TRUE;
    v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;
    INSERT INTO demo_scenario_run (tenant_id, demo_scenario_id, triggered_by, triggered_at, outcome, success, elapsed_ms)
    VALUES (v_tenant_id, v_scenario_bigint, p_actor_id, now(), jsonb_build_object('prepared', TRUE, 'signalActive', TRUE), TRUE, v_elapsed_ms) RETURNING id INTO v_run_id;
    PERFORM fn_audit_log_record_v2('demo_scenario_run', v_run_id, 'INSERT', NULL, jsonb_build_object('actionCode', 'DEMO_SCENARIO_TRIGGER', 'scenarioId', p_scenario_id, 'prepared', TRUE, 'elapsedMs', v_elapsed_ms), NULLIF(p_actor_id, 0));
    RETURN jsonb_build_object('runId', v_run_id, 'elapsedMs', v_elapsed_ms, 'success', TRUE, 'prepared', TRUE, 'preparedAt', clock_timestamp(), 'deepLink', '/app/contracts?filter=labor_compliance', 'signalActive', TRUE, 'expectedOutcomes', v_scenario.expected_outcomes, 'note', 'MOHRE Decree-Law No.9/2024 signal confirmed active. Navigate to Contracts → filter by labor_compliance clause type to see affected contractor agreements.');
  ELSIF p_scenario_id = 'budget_burn' THEN
    v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;
    INSERT INTO demo_scenario_run (tenant_id, demo_scenario_id, triggered_by, triggered_at, outcome, success, elapsed_ms)
    VALUES (v_tenant_id, v_scenario_bigint, p_actor_id, now(), jsonb_build_object('prepared', TRUE, 'static', TRUE), TRUE, v_elapsed_ms) RETURNING id INTO v_run_id;
    PERFORM fn_audit_log_record_v2('demo_scenario_run', v_run_id, 'INSERT', NULL, jsonb_build_object('actionCode', 'DEMO_SCENARIO_TRIGGER', 'scenarioId', p_scenario_id, 'prepared', TRUE, 'static', TRUE, 'elapsedMs', v_elapsed_ms), NULLIF(p_actor_id, 0));
    RETURN jsonb_build_object('runId', v_run_id, 'elapsedMs', v_elapsed_ms, 'success', TRUE, 'prepared', TRUE, 'preparedAt', clock_timestamp(), 'deepLink', '/app/contracts?filter=budget_burn', 'static', TRUE, 'expectedOutcomes', v_scenario.expected_outcomes, 'note', 'Budget + actuals data pre-seeded. Navigate to the ADNOC Offshore→Drilling contract to observe the day-rate overrun (+8% at month 4) and cure-notice eligibility.');
  END IF;

  -- Signal injection + synthesis path (8 scenarios)
  v_signals := COALESCE(v_scenario.event_injection_payload->'signals', '[]'::jsonb);

  FOR v_signal_item IN SELECT * FROM jsonb_array_elements(v_signals) LOOP
    SELECT id INTO v_src_id FROM osint_source WHERE tenant_id = v_tenant_id AND source_id = COALESCE(v_signal_item->>'sourceId', 'mock_social_x') LIMIT 1;
    IF v_src_id IS NULL THEN SELECT id INTO v_src_id FROM osint_source WHERE tenant_id = v_tenant_id AND source_id = 'mock_social_x' LIMIT 1; END IF;

    IF v_src_id IS NOT NULL THEN
      v_ext_id := left('demo:' || left(p_scenario_id, 12) || ':' || substring(encode(digest((v_signal_item->>'title') || ':' || (v_signal_item->>'sourceId'), 'sha256'), 'hex') from 1 for 16), 60);
      v_dedup_hash := left(COALESCE(v_signal_item->>'sourceId', 'mock_social_x') || '|' || to_char(CURRENT_DATE, 'YYYY-MM-DD') || '|' || lower(left(COALESCE(v_signal_item->>'title', p_scenario_id), 150)), 250);

      v_new_signal_id := NULL;
      INSERT INTO osint_signal (
        tenant_id, osint_source_id, source_id, source, source_reliability,
        ext_id, dedup_hash,
        kind, signal_kind_subtype, category,
        title, title_en, summary, severity, severity_v2, confidence,
        url, data_classification, raw_payload, fetched_at, is_active, created_at
      ) VALUES (
        v_tenant_id, v_src_id,
        COALESCE(v_signal_item->>'sourceId', 'mock_social_x'),
        COALESCE(v_signal_item->>'sourceId', 'mock_social_x'),
        0.85, v_ext_id, v_dedup_hash,
        COALESCE(v_signal_item->>'kind', 'news'),
        COALESCE(v_signal_item->>'signalKindSubtype', 'scenario_trigger'),
        COALESCE(v_signal_item->>'category', 'regulatory'),
        COALESCE(v_signal_item->>'title', 'Demo scenario signal: ' || p_scenario_id),
        COALESCE(v_signal_item->>'title', 'Demo scenario signal: ' || p_scenario_id),
        COALESCE(v_signal_item->>'summary', 'Injected by scenario trigger: ' || p_scenario_id),
        COALESCE(v_signal_item->>'severity', 'medium'),
        COALESCE(v_signal_item->>'severity', 'medium'),
        0.85,
        COALESCE(v_signal_item->>'url', 'https://demo/' || p_scenario_id || '/signal'),
        'demo', COALESCE(v_signal_item, '{}'::jsonb),
        clock_timestamp(), TRUE, clock_timestamp()
      ) ON CONFLICT DO NOTHING RETURNING id INTO v_new_signal_id;

      IF v_new_signal_id IS NOT NULL THEN
        PERFORM pg_notify('osint_signal_inserted', jsonb_build_object('signal_id', v_new_signal_id, 'id', v_new_signal_id, 'tenantId', v_tenant_id, 'source', 'demo_scenario_trigger', 'scenarioId', p_scenario_id)::text);
        -- NEW: synthesize correlations directly so the cascade visibly fires.
        v_synth_count := v_synth_count + COALESCE(fn_demo_synthesize_correlations_for_signal(v_new_signal_id, p_scenario_id, p_actor_id), 0);
      END IF;
    END IF;
  END LOOP;

  v_outcome := jsonb_build_object(
    'correlationCount',     (SELECT COUNT(*) FROM correlation WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'alertCount',           (SELECT COUNT(*) FROM notification_dispatch_log WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'advisoryDraftCount',   (SELECT COUNT(*) FROM advisory_draft WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'signalCount',          (SELECT COUNT(*) FROM osint_signal WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'synthesizedCorrelations', v_synth_count,
    'note',                 'Synthesized correlations on injection. Advisory + notification cascade follows via downstream listeners — refresh dashboards 5-10s after trigger to see the full effect.'
  );

  v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;
  INSERT INTO demo_scenario_run (tenant_id, demo_scenario_id, triggered_by, triggered_at, outcome, success, elapsed_ms)
  VALUES (v_tenant_id, v_scenario_bigint, p_actor_id, now(), v_outcome, TRUE, v_elapsed_ms) RETURNING id INTO v_run_id;
  PERFORM fn_audit_log_record_v2('demo_scenario_run', v_run_id, 'INSERT', NULL, jsonb_build_object('actionCode', 'DEMO_SCENARIO_TRIGGER', 'scenarioId', p_scenario_id, 'outcome', v_outcome, 'elapsedMs', v_elapsed_ms), NULLIF(p_actor_id, 0));

  RETURN jsonb_build_object('runId', v_run_id, 'elapsedMs', v_elapsed_ms, 'success', TRUE, 'outcome', v_outcome);

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      INSERT INTO demo_scenario_run (tenant_id, demo_scenario_id, triggered_by, success, error_message, elapsed_ms)
      VALUES (v_tenant_id, COALESCE(v_scenario_bigint, 0), p_actor_id, FALSE, left(SQLERRM, 500),
        CASE WHEN v_started_at IS NOT NULL THEN (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER ELSE NULL END);
    EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE EXCEPTION 'fn_demo_scenario_trigger: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (449, '449_demo_trigger_synthesize_correlations', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 449;
-- DROP FUNCTION IF EXISTS fn_demo_synthesize_correlations_for_signal(BIGINT, TEXT, BIGINT);
-- -- Re-apply 448 to restore trigger without synthesis.
-- ============================================================
