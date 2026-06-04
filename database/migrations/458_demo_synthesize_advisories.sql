-- Migration: 458_demo_synthesize_advisories.sql
-- Module: Demo Harness — Issue #6 fix (Brent/Cyclone advisory cascade)
-- Description: After Day 2 wired correlation synthesis, Layla's advisory
--              queue still doesn't see new items post-trigger — because
--              the BE advisory-drafter worker only runs as a downstream
--              listener, and that listener isn't wired in dev. The
--              presenter's Act 8 talking point ("Layla sees a new advisory")
--              falls flat.
--              Pragmatic fix: in the same way fn_demo_synthesize_correlations
--              created correlation rows directly, this function takes the
--              freshly-synthesized correlations for a given scenario and
--              creates advisory_draft rows against an appropriate template
--              for each scenario.
--                brent_review     → Budget Variance Cure Notice (id 10)
--                cyclone          → Weather FM Notice           (id 6)
--                hormuz           → Hormuz FM Invocation        (id 1)
--                ofac_sanctions   → Sanctions Hold              (id 2)
--                epc_sla          → Cure Notice                 (id 3)
--                icv_shortfall    → ICV Rectification           (id 5)
--                esg_subcontractor→ ESG Concern Memo            (id 7)
--                renewal          → Insurance Renewal Reminder  (id 8)
--              Each advisory_draft gets approval_status='unapproved' so
--              they appear in Layla's "Pending" queue.
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_demo_synthesize_advisories_for_correlations(
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
  v_template_id    BIGINT;
  v_template_ver   INTEGER;
  v_draft_type     TEXT;
  v_body_en_tpl    TEXT;
  v_body_ar_tpl    TEXT;
  v_correlation    RECORD;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  -- Map scenario → template.
  CASE p_scenario_id
    WHEN 'brent_review'      THEN v_template_id := 10;
    WHEN 'cyclone'           THEN v_template_id := 6;
    WHEN 'hormuz'            THEN v_template_id := 1;
    WHEN 'ofac_sanctions'    THEN v_template_id := 2;
    WHEN 'epc_sla'           THEN v_template_id := 3;
    WHEN 'icv_shortfall'     THEN v_template_id := 5;
    WHEN 'esg_subcontractor' THEN v_template_id := 7;
    WHEN 'renewal'           THEN v_template_id := 8;
    ELSE                          v_template_id := NULL;
  END CASE;

  IF v_template_id IS NULL THEN
    RETURN 0;
  END IF;

  -- Load template version + body + draft_type
  SELECT version, body_template_en, body_template_ar, draft_type
  INTO v_template_ver, v_body_en_tpl, v_body_ar_tpl, v_draft_type
  FROM advisory_template
  WHERE id = v_template_id
    AND tenant_id = v_tenant_id
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  -- For each correlation that landed against this signal, create one advisory_draft.
  FOR v_correlation IN
    SELECT id, contract_id, rule_id, match_reason
    FROM correlation
    WHERE tenant_id = v_tenant_id
      AND signal_id = p_signal_id
      AND status = 'active'
      AND is_active = TRUE
    ORDER BY id DESC
  LOOP
    INSERT INTO advisory_draft (
      tenant_id, correlation_id, contract_id,
      template_id, template_version, draft_type,
      generated_text_en, generated_text_ar,
      template_context, model_version, prompt_hash,
      approval_status, dispatch_recipients,
      data_classification, created_by, updated_by
    ) VALUES (
      v_tenant_id,
      v_correlation.id,
      v_correlation.contract_id,
      v_template_id,
      v_template_ver,
      v_draft_type,
      'Re: Advisory — ' || v_correlation.match_reason || E'\n\nDear counterparty,\n\nFollowing the recent ' || p_scenario_id || ' signal, we are issuing this notice in respect of contract ' || v_correlation.contract_id::text || '. Specific clauses identified by our correlation engine: ' || v_correlation.rule_id || E'.\n\nYours faithfully,\nADNOC Legal',
      'Re: استشارة — ' || v_correlation.match_reason || E'\n\nعزيز الطرف المقابل،\n\nبعد إشارة ' || p_scenario_id || ' الأخيرة، نصدر هذا الإشعار بشأن العقد ' || v_correlation.contract_id::text || E'.\n\nمع خالص التقدير،\nالشؤون القانونية في أدنوك',
      jsonb_build_object(
        'scenarioId', p_scenario_id,
        'correlationId', v_correlation.id,
        'ruleId', v_correlation.rule_id,
        'demoSynthesized', TRUE
      ),
      'gpt-4o-demo-synth',
      encode(digest(p_scenario_id || ':' || v_correlation.id::text, 'sha256'), 'hex'),
      'unapproved',
      '[]'::jsonb,
      'demo',
      p_actor_id,
      p_actor_id
    )
    ON CONFLICT DO NOTHING;
    IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
  END LOOP;

  RETURN v_inserted_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_demo_synthesize_advisories_for_correlations(BIGINT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_synthesize_advisories_for_correlations(BIGINT, TEXT, BIGINT) TO neondb_owner;

-- Wire it into the scenario trigger — call after correlations are synthesized
-- and before the outcome aggregation.

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
  v_synth_advisories   INTEGER := 0;
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
    RETURN jsonb_build_object('runId', v_run_id, 'elapsedMs', v_elapsed_ms, 'success', TRUE, 'prepared', TRUE, 'preparedAt', clock_timestamp(), 'deepLink', '/app/finance/trade-positions', 'recomputeResult', v_prepare_result, 'expectedOutcomes', v_scenario.expected_outcomes, 'note', 'Murban OSP benchmark reset to $110.75/bbl (pre-drop starting state).');
  ELSIF p_scenario_id = 'labor_cascade' THEN
    UPDATE osint_signal SET is_active = TRUE, updated_at = NOW() WHERE tenant_id = v_tenant_id AND dedup_hash = 'mohre_labor|2024-08-30|federal decree-law no. 9 of 2024 — labor relations amendments';
    v_prepared := TRUE;
    v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;
    INSERT INTO demo_scenario_run (tenant_id, demo_scenario_id, triggered_by, triggered_at, outcome, success, elapsed_ms)
    VALUES (v_tenant_id, v_scenario_bigint, p_actor_id, now(), jsonb_build_object('prepared', TRUE, 'signalActive', TRUE), TRUE, v_elapsed_ms) RETURNING id INTO v_run_id;
    PERFORM fn_audit_log_record_v2('demo_scenario_run', v_run_id, 'INSERT', NULL, jsonb_build_object('actionCode', 'DEMO_SCENARIO_TRIGGER', 'scenarioId', p_scenario_id, 'prepared', TRUE, 'elapsedMs', v_elapsed_ms), NULLIF(p_actor_id, 0));
    RETURN jsonb_build_object('runId', v_run_id, 'elapsedMs', v_elapsed_ms, 'success', TRUE, 'prepared', TRUE, 'preparedAt', clock_timestamp(), 'deepLink', '/app/contracts?filter=labor_compliance', 'signalActive', TRUE, 'expectedOutcomes', v_scenario.expected_outcomes, 'note', 'MOHRE Decree-Law signal confirmed active.');
  ELSIF p_scenario_id = 'budget_burn' THEN
    v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;
    INSERT INTO demo_scenario_run (tenant_id, demo_scenario_id, triggered_by, triggered_at, outcome, success, elapsed_ms)
    VALUES (v_tenant_id, v_scenario_bigint, p_actor_id, now(), jsonb_build_object('prepared', TRUE, 'static', TRUE), TRUE, v_elapsed_ms) RETURNING id INTO v_run_id;
    PERFORM fn_audit_log_record_v2('demo_scenario_run', v_run_id, 'INSERT', NULL, jsonb_build_object('actionCode', 'DEMO_SCENARIO_TRIGGER', 'scenarioId', p_scenario_id, 'prepared', TRUE, 'static', TRUE, 'elapsedMs', v_elapsed_ms), NULLIF(p_actor_id, 0));
    RETURN jsonb_build_object('runId', v_run_id, 'elapsedMs', v_elapsed_ms, 'success', TRUE, 'prepared', TRUE, 'preparedAt', clock_timestamp(), 'deepLink', '/app/contracts?filter=budget_burn', 'static', TRUE, 'expectedOutcomes', v_scenario.expected_outcomes, 'note', 'Budget + actuals data pre-seeded.');
  END IF;

  -- Signal injection + correlation + advisory synthesis (8 scenarios)
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
        v_synth_count := v_synth_count + COALESCE(fn_demo_synthesize_correlations_for_signal(v_new_signal_id, p_scenario_id, p_actor_id), 0);
        -- NEW: also synthesize advisory drafts for the correlations.
        v_synth_advisories := v_synth_advisories + COALESCE(fn_demo_synthesize_advisories_for_correlations(v_new_signal_id, p_scenario_id, p_actor_id), 0);
      END IF;
    END IF;
  END LOOP;

  v_outcome := jsonb_build_object(
    'correlationCount',        (SELECT COUNT(*) FROM correlation WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'alertCount',              (SELECT COUNT(*) FROM notification_dispatch_log WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'advisoryDraftCount',      (SELECT COUNT(*) FROM advisory_draft WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'signalCount',             (SELECT COUNT(*) FROM osint_signal WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'synthesizedCorrelations', v_synth_count,
    'synthesizedAdvisories',   v_synth_advisories,
    'note',                    'Synthesized correlations + advisories on injection. Refresh dashboards 5-10s after trigger.'
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
VALUES (458, '458_demo_synthesize_advisories', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 458;
-- DROP FUNCTION IF EXISTS fn_demo_synthesize_advisories_for_correlations(BIGINT, TEXT, BIGINT);
-- ============================================================
