-- Migration: 444_demo_scenario_trigger_notify_cascade.sql
-- Module: Demo Harness — DEBT-CRIJ-3 (cascade wiring)
-- Description: fn_demo_scenario_trigger inserts signals directly into osint_signal
--              (instead of via fn_osint_signal_upsert), so the existing
--              'osint_signal_inserted' pg_notify channel never fires for
--              scenario-injected signals. The correlation-evaluator worker
--              listens on that channel; without a notify it never picks up
--              the new signal, so no correlations, advisories, notifications,
--              or risk-score recomputes happen downstream. Scenario triggers
--              return zero-count outcomes — the symptom logged as DEBT-CRIJ-3.
--
--              Fix: emit pg_notify('osint_signal_inserted', ...) for every
--              newly inserted signal inside the trigger's loop. ON CONFLICT
--              DO NOTHING means RETURNING id only yields a non-null id on a
--              fresh insert, so we only fire the cascade once per signal.
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

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
  v_prepare_result     JSONB;
  v_prepared           BOOLEAN := FALSE;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  IF NOT fn_current_user_has_permission('demo.scenario.trigger') THEN
    RAISE EXCEPTION 'fn_demo_scenario_trigger: permission_denied — demo.scenario.trigger required'
      USING ERRCODE = '42501';
  END IF;

  SELECT id, scenario_id, event_injection_payload, expected_outcomes, seed_pack_ref, is_active
  INTO v_scenario
  FROM demo_scenario
  WHERE tenant_id = v_tenant_id AND scenario_id = p_scenario_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'demo_scenario % not found in tenant scope', p_scenario_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT v_scenario.is_active THEN
    RAISE EXCEPTION 'demo_scenario % is inactive — cannot trigger', p_scenario_id
      USING ERRCODE = '23000';
  END IF;

  v_scenario_bigint := v_scenario.id;

  SELECT EXISTS (
    SELECT 1 FROM demo_seed_pack
    WHERE tenant_id = v_tenant_id AND pack_id = v_scenario.seed_pack_ref AND is_active = TRUE
  ) INTO v_pack_exists;

  IF NOT v_pack_exists THEN
    RAISE EXCEPTION 'demo_seed_pack with pack_id % not found for scenario %', v_scenario.seed_pack_ref, p_scenario_id
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(v_tenant_id::text || ':' || p_scenario_id, 0)
  );

  v_started_at := clock_timestamp();

  -- ============================================================
  -- ADNOC TIER-2 PREPARE BLOCK (unchanged from migration 324)
  -- ============================================================

  IF p_scenario_id = 'trade_margin' THEN
    BEGIN
      SELECT fn_margin_recompute_for_price_change(
        p_actor_id,
        'murban_osp',
        110.75::NUMERIC,
        date_trunc('month', CURRENT_DATE)::date
      ) INTO v_prepare_result;
    EXCEPTION WHEN OTHERS THEN
      v_prepare_result := jsonb_build_object(
        'prepareNote', 'fn_margin_recompute_for_price_change unavailable: ' || SQLERRM,
        'fallback', TRUE
      );
    END;

    v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;

    INSERT INTO demo_scenario_run (
      tenant_id, demo_scenario_id, triggered_by, triggered_at, outcome, success, elapsed_ms
    ) VALUES (
      v_tenant_id, v_scenario_bigint, p_actor_id, now(),
      jsonb_build_object('prepared', TRUE, 'recomputeResult', v_prepare_result),
      TRUE, v_elapsed_ms
    ) RETURNING id INTO v_run_id;

    PERFORM fn_audit_log_record_v2(
      'demo_scenario_run', v_run_id, 'INSERT', NULL,
      jsonb_build_object('actionCode', 'DEMO_SCENARIO_TRIGGER',
        'scenarioId', p_scenario_id, 'prepared', TRUE, 'elapsedMs', v_elapsed_ms),
      NULLIF(p_actor_id, 0)
    );

    RETURN jsonb_build_object(
      'runId', v_run_id, 'elapsedMs', v_elapsed_ms, 'success', TRUE,
      'prepared', TRUE, 'preparedAt', clock_timestamp(),
      'deepLink', '/app/finance/trade-positions',
      'recomputeResult', v_prepare_result,
      'expectedOutcomes', v_scenario.expected_outcomes,
      'note', 'Murban OSP benchmark reset to $110.75/bbl (pre-drop starting state). Demo the OSP drop to $104.44 via the Price Benchmark form to observe margin contraction live.'
    );

  ELSIF p_scenario_id = 'labor_cascade' THEN
    UPDATE osint_signal
    SET    is_active  = TRUE,
           updated_at = NOW()
    WHERE  tenant_id  = v_tenant_id
      AND  dedup_hash = 'mohre_labor|2024-08-30|federal decree-law no. 9 of 2024 — labor relations amendments';

    v_prepared := TRUE;
    v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;

    INSERT INTO demo_scenario_run (
      tenant_id, demo_scenario_id, triggered_by, triggered_at, outcome, success, elapsed_ms
    ) VALUES (
      v_tenant_id, v_scenario_bigint, p_actor_id, now(),
      jsonb_build_object('prepared', TRUE, 'signalActive', TRUE),
      TRUE, v_elapsed_ms
    ) RETURNING id INTO v_run_id;

    PERFORM fn_audit_log_record_v2(
      'demo_scenario_run', v_run_id, 'INSERT', NULL,
      jsonb_build_object('actionCode', 'DEMO_SCENARIO_TRIGGER',
        'scenarioId', p_scenario_id, 'prepared', TRUE, 'elapsedMs', v_elapsed_ms),
      NULLIF(p_actor_id, 0)
    );

    RETURN jsonb_build_object(
      'runId', v_run_id, 'elapsedMs', v_elapsed_ms, 'success', TRUE,
      'prepared', TRUE, 'preparedAt', clock_timestamp(),
      'deepLink', '/app/contracts?filter=labor_compliance',
      'signalActive', TRUE,
      'expectedOutcomes', v_scenario.expected_outcomes,
      'note', 'MOHRE Decree-Law No.9/2024 signal confirmed active. Navigate to Contracts → filter by labor_compliance clause type to see affected contractor agreements.'
    );

  ELSIF p_scenario_id = 'budget_burn' THEN
    v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;

    INSERT INTO demo_scenario_run (
      tenant_id, demo_scenario_id, triggered_by, triggered_at, outcome, success, elapsed_ms
    ) VALUES (
      v_tenant_id, v_scenario_bigint, p_actor_id, now(),
      jsonb_build_object('prepared', TRUE, 'static', TRUE),
      TRUE, v_elapsed_ms
    ) RETURNING id INTO v_run_id;

    PERFORM fn_audit_log_record_v2(
      'demo_scenario_run', v_run_id, 'INSERT', NULL,
      jsonb_build_object('actionCode', 'DEMO_SCENARIO_TRIGGER',
        'scenarioId', p_scenario_id, 'prepared', TRUE, 'static', TRUE, 'elapsedMs', v_elapsed_ms),
      NULLIF(p_actor_id, 0)
    );

    RETURN jsonb_build_object(
      'runId', v_run_id, 'elapsedMs', v_elapsed_ms, 'success', TRUE,
      'prepared', TRUE, 'preparedAt', clock_timestamp(),
      'deepLink', '/app/contracts?filter=budget_burn',
      'static', TRUE,
      'expectedOutcomes', v_scenario.expected_outcomes,
      'note', 'Budget + actuals data pre-seeded. Navigate to the ADNOC Offshore→Drilling contract to observe the day-rate overrun (+8% at month 4) and cure-notice eligibility.'
    );

  END IF;

  -- ============================================================
  -- ORIGINAL SIGNAL-INJECTION PATH (existing 8 scenarios)
  -- DEBT-CRIJ-3 FIX (this migration): emit pg_notify after every fresh
  -- INSERT so the correlation-evaluator worker picks up the signal and
  -- drives the cascade (correlation → advisory → notification → score
  -- recompute). RETURNING id gives a non-null value only on actual inserts.
  -- ============================================================

  v_signals := COALESCE(v_scenario.event_injection_payload->'signals', '[]'::jsonb);

  FOR v_signal_item IN SELECT * FROM jsonb_array_elements(v_signals) LOOP
    SELECT id INTO v_src_id
    FROM osint_source
    WHERE tenant_id = v_tenant_id
      AND source_id = COALESCE(v_signal_item->>'sourceId', 'mock_social_x')
    LIMIT 1;

    IF v_src_id IS NULL THEN
      SELECT id INTO v_src_id FROM osint_source
      WHERE tenant_id = v_tenant_id AND source_id = 'mock_social_x' LIMIT 1;
    END IF;

    IF v_src_id IS NOT NULL THEN
      v_new_signal_id := NULL;
      INSERT INTO osint_signal (
        tenant_id, osint_source_id, source_id, kind, signal_kind_subtype,
        title, summary, severity_v2, url, data_classification, is_active, created_at
      ) VALUES (
        v_tenant_id, v_src_id,
        COALESCE(v_signal_item->>'sourceId', 'mock_social_x'),
        COALESCE(v_signal_item->>'kind', 'news'),
        COALESCE(v_signal_item->>'signalKindSubtype', 'scenario_trigger'),
        COALESCE(v_signal_item->>'title', 'Demo scenario signal: ' || p_scenario_id),
        COALESCE(v_signal_item->>'summary', 'Injected by scenario trigger: ' || p_scenario_id),
        COALESCE(v_signal_item->>'severity', 'medium'),
        COALESCE(v_signal_item->>'url', 'https://demo/' || p_scenario_id || '/signal'),
        'demo', TRUE, clock_timestamp()
      )
      ON CONFLICT DO NOTHING
      RETURNING id INTO v_new_signal_id;

      -- Drive the cascade only for fresh inserts (RETURNING id is NULL on conflict-skip).
      IF v_new_signal_id IS NOT NULL THEN
        PERFORM pg_notify(
          'osint_signal_inserted',
          jsonb_build_object(
            'signal_id', v_new_signal_id,
            'id',        v_new_signal_id,
            'tenantId',  v_tenant_id,
            'source',    'demo_scenario_trigger',
            'scenarioId', p_scenario_id
          )::text
        );
      END IF;
    END IF;
  END LOOP;

  v_outcome := jsonb_build_object(
    'correlationCount',     (SELECT COUNT(*) FROM correlation WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'alertCount',           (SELECT COUNT(*) FROM notification_dispatch_log WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'advisoryDraftCount',   (SELECT COUNT(*) FROM advisory_draft WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'signalCount',          (SELECT COUNT(*) FROM osint_signal WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'note',                 'Counts captured immediately after signal injection. The correlation/advisory/notification/score cascade is asynchronous — refresh the relevant dashboards 5-10s after trigger to see the full effect.'
  );

  v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;

  INSERT INTO demo_scenario_run (
    tenant_id, demo_scenario_id, triggered_by, triggered_at, outcome, success, elapsed_ms
  ) VALUES (
    v_tenant_id, v_scenario_bigint, p_actor_id, now(), v_outcome, TRUE, v_elapsed_ms
  ) RETURNING id INTO v_run_id;

  PERFORM fn_audit_log_record_v2(
    'demo_scenario_run', v_run_id, 'INSERT', NULL,
    jsonb_build_object('actionCode', 'DEMO_SCENARIO_TRIGGER',
      'scenarioId', p_scenario_id, 'outcome', v_outcome, 'elapsedMs', v_elapsed_ms),
    NULLIF(p_actor_id, 0)
  );

  RETURN jsonb_build_object(
    'runId', v_run_id, 'elapsedMs', v_elapsed_ms, 'success', TRUE, 'outcome', v_outcome
  );

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      INSERT INTO demo_scenario_run (
        tenant_id, demo_scenario_id, triggered_by, success, error_message, elapsed_ms
      ) VALUES (
        v_tenant_id, COALESCE(v_scenario_bigint, 0), p_actor_id, FALSE, left(SQLERRM, 500),
        CASE WHEN v_started_at IS NOT NULL
          THEN (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER
          ELSE NULL END
      );
    EXCEPTION WHEN OTHERS THEN NULL; END;

    RAISE EXCEPTION 'fn_demo_scenario_trigger: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) IS
  'DEBT-CRIJ-3 FIX (was 324, 235): DEFINER VOLATILE. After each fresh signal INSERT, emits pg_notify(osint_signal_inserted) so the correlation-evaluator worker drives the cascade (correlation → advisory → notification → score recompute). Outcome counts captured synchronously remain valid for ADNOC tier-2 prepare-only scenarios; counts for signal-injection scenarios will be zero immediately and populate as the async cascade completes. S2-21: REVOKE PUBLIC + GRANT neondb_owner. ERRCODE on every RAISE.';
REVOKE EXECUTE ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (444, '444_demo_scenario_trigger_notify_cascade', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 444;
-- -- Re-apply migration 324 to restore prior behavior (no pg_notify in trigger loop):
-- -- psql $DATABASE_URL < database/migrations/324_crp_extend_fn_demo_scenario_trigger.sql
-- ============================================================
