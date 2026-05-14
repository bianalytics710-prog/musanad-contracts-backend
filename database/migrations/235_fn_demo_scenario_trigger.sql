-- Migration: 235_fn_demo_scenario_trigger.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: fn_demo_scenario_trigger DEFINER VOLATILE — pg_advisory_xact_lock + idempotent event injection
--              + outcome capture + Strategy A audit.
-- Date: 2026-05-14

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
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  -- Permission check
  IF NOT fn_current_user_has_permission('demo.scenario.trigger') THEN
    RAISE EXCEPTION 'fn_demo_scenario_trigger: permission_denied — demo.scenario.trigger required'
      USING ERRCODE = '42501';
  END IF;

  -- Lookup scenario
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

  -- S2-23: Validate soft FK seed_pack_ref
  SELECT EXISTS (
    SELECT 1 FROM demo_seed_pack
    WHERE tenant_id = v_tenant_id AND pack_id = v_scenario.seed_pack_ref AND is_active = TRUE
  ) INTO v_pack_exists;

  IF NOT v_pack_exists THEN
    RAISE EXCEPTION 'demo_seed_pack with pack_id % not found for scenario %', v_scenario.seed_pack_ref, p_scenario_id
      USING ERRCODE = 'P0002';
  END IF;

  -- S2-17: Advisory lock — block+queue concurrent calls for same (tenant, scenario_id)
  -- Cross-tenant and cross-scenario triggers proceed in parallel
  PERFORM pg_advisory_xact_lock(
    hashtextextended(v_tenant_id::text || ':' || p_scenario_id, 0)
  );

  v_started_at := clock_timestamp();

  -- Inject signals from event_injection_payload.signals array (idempotent ON CONFLICT DO NOTHING)
  v_signals := COALESCE(v_scenario.event_injection_payload->'signals', '[]'::jsonb);

  FOR v_signal_item IN SELECT * FROM jsonb_array_elements(v_signals) LOOP
    -- Look up source_id for the signal
    SELECT id INTO v_src_id
    FROM osint_source
    WHERE tenant_id = v_tenant_id
      AND source_id = COALESCE(v_signal_item->>'sourceId', 'mock_social_x')
    LIMIT 1;

    IF v_src_id IS NULL THEN
      -- Fall back to mock_social_x
      SELECT id INTO v_src_id FROM osint_source
      WHERE tenant_id = v_tenant_id AND source_id = 'mock_social_x' LIMIT 1;
    END IF;

    IF v_src_id IS NOT NULL THEN
      INSERT INTO osint_signal (
        tenant_id, osint_source_id, source_id, kind, signal_kind_subtype,
        title, summary, severity_v2, url, data_classification, is_active, created_at
      ) VALUES (
        v_tenant_id,
        v_src_id,
        COALESCE(v_signal_item->>'sourceId', 'mock_social_x'),
        COALESCE(v_signal_item->>'kind', 'news'),
        COALESCE(v_signal_item->>'signalKindSubtype', 'scenario_trigger'),
        COALESCE(v_signal_item->>'title', 'Demo scenario signal: ' || p_scenario_id),
        COALESCE(v_signal_item->>'summary', 'Injected by scenario trigger: ' || p_scenario_id),
        COALESCE(v_signal_item->>'severity', 'medium'),
        COALESCE(v_signal_item->>'url', 'https://demo/' || p_scenario_id || '/signal'),
        'demo',
        TRUE,
        clock_timestamp()
      )
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  -- Capture post-trigger outcome (window-snapshot from v_started_at for determinism AC-S16)
  v_outcome := jsonb_build_object(
    'correlationCount',     (SELECT COUNT(*) FROM correlation WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'alertCount',           (SELECT COUNT(*) FROM notification_dispatch_log WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'advisoryDraftCount',   (SELECT COUNT(*) FROM advisory_draft WHERE tenant_id = v_tenant_id AND created_at >= v_started_at),
    'signalCount',          (SELECT COUNT(*) FROM osint_signal WHERE tenant_id = v_tenant_id AND created_at >= v_started_at)
  );

  v_elapsed_ms := (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER;

  -- INSERT run record (Strategy A — append-only, no trigger)
  INSERT INTO demo_scenario_run (
    tenant_id, demo_scenario_id, triggered_by, triggered_at, outcome, success, elapsed_ms
  ) VALUES (
    v_tenant_id, v_scenario_bigint, p_actor_id, now(), v_outcome, TRUE, v_elapsed_ms
  ) RETURNING id INTO v_run_id;

  -- Strategy A audit INSERT
  PERFORM fn_audit_log_record_v2(
    'demo_scenario_run',
    v_run_id,
    'INSERT',
    NULL,
    jsonb_build_object(
      'actionCode',   'DEMO_SCENARIO_TRIGGER',
      'scenarioId',   p_scenario_id,
      'outcome',      v_outcome,
      'elapsedMs',    v_elapsed_ms
    ),
    NULLIF(p_actor_id, 0)
  );

  RETURN jsonb_build_object(
    'runId',     v_run_id,
    'elapsedMs', v_elapsed_ms,
    'success',   TRUE,
    'outcome',   v_outcome
  );

EXCEPTION
  WHEN OTHERS THEN
    -- Record failure run (best-effort; if demo_scenario_run INSERT also fails, outer RAISE propagates)
    BEGIN
      INSERT INTO demo_scenario_run (
        tenant_id, demo_scenario_id, triggered_by, success, error_message, elapsed_ms
      ) VALUES (
        v_tenant_id,
        COALESCE(v_scenario_bigint, 0),
        p_actor_id,
        FALSE,
        left(SQLERRM, 500),
        CASE WHEN v_started_at IS NOT NULL
          THEN (extract(epoch from clock_timestamp() - v_started_at) * 1000)::INTEGER
          ELSE NULL
        END
      );
    EXCEPTION WHEN OTHERS THEN NULL; END;

    RAISE EXCEPTION 'fn_demo_scenario_trigger: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) IS 'DEFINER: trigger demo scenario with concurrent-safe pg_advisory_xact_lock block+queue + deterministic idempotent event injection + outcome capture. Requires demo.scenario.trigger permission.';
REVOKE EXECUTE ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (235, '235_fn_demo_scenario_trigger', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 235;
-- DROP FUNCTION IF EXISTS fn_demo_scenario_trigger(BIGINT, TEXT);
-- ============================================================
