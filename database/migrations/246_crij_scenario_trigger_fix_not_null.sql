-- Migration: 246_crij_scenario_trigger_fix_not_null.sql
-- Module: M17+M18 — CR-I + CR-J DEBT-CRIJ-3 fix
-- Description: Fix fn_demo_scenario_trigger: supply required NOT NULL columns
--   (ext_id, category, source, severity, title_en, dedup_hash) in all osint_signal INSERTs.
--   All 6 signal INSERT blocks updated. No logic changes from migration 245.
--   S2-21: REVOKE/GRANT/COMMENT trio preserved.
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
  -- signal injection
  v_src_id             BIGINT;
  v_src_code           TEXT;
  v_signal_id          BIGINT;
  v_ext_id             TEXT;
  v_dedup_hash         TEXT;
  -- advisory draft
  v_correlation_id     BIGINT;
  v_template_id        BIGINT;
  v_first_contract_id  BIGINT;
  -- weather rule result
  v_weather_result     JSONB;
  -- esg pick
  v_esg_signal_id      BIGINT;
  v_esg_corr_id        BIGINT;
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
  PERFORM pg_advisory_xact_lock(
    hashtextextended(v_tenant_id::text || ':' || p_scenario_id, 0)
  );

  v_started_at := clock_timestamp();

  -- ================================================================
  -- PER-SCENARIO EVENT INJECTION
  -- ================================================================
  CASE p_scenario_id

    -- ----------------------------------------------------------------
    -- hormuz: geopolitical signal via rss_lloyds_maritime (or openweather fallback)
    -- Correlations left to cron (no dedicated rule fn for geopolitical yet).
    -- ----------------------------------------------------------------
    WHEN 'hormuz' THEN
      SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
      WHERE tenant_id = v_tenant_id AND source_id = 'rss_lloyds_maritime' LIMIT 1;
      IF v_src_id IS NULL THEN
        SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
        WHERE tenant_id = v_tenant_id AND source_id = 'openweather' LIMIT 1;
      END IF;
      IF v_src_id IS NOT NULL THEN
        v_ext_id     := 'demo-hormuz-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US');
        v_dedup_hash := encode(sha256((v_ext_id || v_tenant_id::text)::bytea), 'hex');
        INSERT INTO osint_signal (
          tenant_id, osint_source_id, source_id, source, kind, signal_kind_subtype,
          ext_id, category, severity, title_en, title, summary, severity_v2,
          url, geographies, dedup_hash,
          data_classification, is_active, created_at, updated_at
        ) VALUES (
          v_tenant_id, v_src_id, v_src_code, v_src_code,
          'geopolitical', 'scenario_trigger',
          v_ext_id, 'geopolitical', 'high',
          'Hormuz Strait disruption — shipping route blocked',
          'Hormuz Strait disruption — shipping route blocked',
          'Hormuz Strait disruption signal injected by demo scenario trigger.',
          'high',
          'https://demo/hormuz/signal',
          '["persian_gulf","strait_of_hormuz"]'::JSONB,
          v_dedup_hash,
          'demo', TRUE, clock_timestamp(), clock_timestamp()
        )
        ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
        RETURNING id INTO v_signal_id;
      END IF;

    -- ----------------------------------------------------------------
    -- ofac_sanctions: sanctions signal referencing known counterparty
    -- Correlations left to cron (no dedicated sanctions rule fn yet).
    -- ----------------------------------------------------------------
    WHEN 'ofac_sanctions' THEN
      SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
      WHERE tenant_id = v_tenant_id AND source_id = 'ofac_sdn' LIMIT 1;
      IF v_src_id IS NULL THEN
        SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
        WHERE tenant_id = v_tenant_id AND source_id = 'rss_reuters_sanctions' LIMIT 1;
      END IF;
      IF v_src_id IS NOT NULL THEN
        v_ext_id     := 'demo-ofac-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US');
        v_dedup_hash := encode(sha256((v_ext_id || v_tenant_id::text)::bytea), 'hex');
        INSERT INTO osint_signal (
          tenant_id, osint_source_id, source_id, source, kind, signal_kind_subtype,
          ext_id, category, severity, title_en, title, summary, severity_v2,
          url, affected_entities, dedup_hash,
          data_classification, is_active, created_at, updated_at
        ) VALUES (
          v_tenant_id, v_src_id, v_src_code, v_src_code,
          'sanctions', 'scenario_trigger',
          v_ext_id, 'geopolitical', 'critical',
          'OFAC SDN designation — IBM Middle East FZ-LLC',
          'OFAC SDN designation — IBM Middle East FZ-LLC',
          'OFAC sanctions designation injected by demo scenario for chain-exposure walk.',
          'critical',
          'https://demo/ofac_sanctions/signal',
          '[{"name":"IBM Middle East FZ-LLC","role":"counterparty"},{"name":"Galadari Brothers Group","role":"chain_entity"}]'::JSONB,
          v_dedup_hash,
          'demo', TRUE, clock_timestamp(), clock_timestamp()
        )
        ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
        RETURNING id INTO v_signal_id;
      END IF;

    -- ----------------------------------------------------------------
    -- brent_review: commodity signal with BRENT marker
    -- Correlations left to cron (no dedicated commodity rule fn yet).
    -- ----------------------------------------------------------------
    WHEN 'brent_review' THEN
      SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
      WHERE tenant_id = v_tenant_id AND source_id = 'commodity_crude' LIMIT 1;
      IF v_src_id IS NULL THEN
        SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
        WHERE tenant_id = v_tenant_id AND source_id = 'mock_social_x' LIMIT 1;
      END IF;
      IF v_src_id IS NOT NULL THEN
        v_ext_id     := 'demo-brent-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US');
        v_dedup_hash := encode(sha256((v_ext_id || v_tenant_id::text)::bytea), 'hex');
        INSERT INTO osint_signal (
          tenant_id, osint_source_id, source_id, source, kind, signal_kind_subtype,
          ext_id, category, severity, title_en, title, summary, severity_v2,
          url, raw_payload, dedup_hash,
          data_classification, is_active, created_at, updated_at
        ) VALUES (
          v_tenant_id, v_src_id, v_src_code, v_src_code,
          'commodity', 'scenario_trigger',
          v_ext_id, 'commodity_prices', 'medium',
          'Brent Crude price-review threshold breach — $98.5/bbl',
          'Brent Crude price-review threshold breach — $98.5/bbl',
          'Brent crosses price-review clause trigger threshold injected by demo scenario.',
          'medium',
          'https://demo/brent_review/signal',
          '{"marker":"BRENT","priceUsd":98.5,"currency":"USD","unit":"barrel","breachType":"sustained_threshold"}'::JSONB,
          v_dedup_hash,
          'demo', TRUE, clock_timestamp(), clock_timestamp()
        )
        ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
        RETURNING id INTO v_signal_id;
      END IF;

    -- ----------------------------------------------------------------
    -- epc_sla: internal milestone_slippage signal — signal only.
    -- GAP: fn_rule_evaluate_sla not yet implemented; correlations via cron.
    -- SKIP full correlation (needs specific seeded EPC contract_id).
    -- ----------------------------------------------------------------
    WHEN 'epc_sla' THEN
      SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
      WHERE tenant_id = v_tenant_id AND source_id = 'internal:harness' LIMIT 1;
      IF v_src_id IS NULL THEN
        SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
        WHERE tenant_id = v_tenant_id AND source_id = 'mock_social_x' LIMIT 1;
      END IF;
      IF v_src_id IS NOT NULL THEN
        v_ext_id     := 'demo-epc-sla-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US');
        v_dedup_hash := encode(sha256((v_ext_id || v_tenant_id::text)::bytea), 'hex');
        INSERT INTO osint_signal (
          tenant_id, osint_source_id, source_id, source, kind, signal_kind_subtype,
          ext_id, category, severity, title_en, title, summary, severity_v2,
          url, raw_payload, dedup_hash,
          data_classification, is_active, created_at, updated_at
        ) VALUES (
          v_tenant_id, v_src_id, v_src_code, v_src_code,
          'internal', 'milestone_slippage',
          v_ext_id, 'supply_chain', 'high',
          'EPC milestone slippage — 21 days late, cure notice triggered',
          'EPC milestone slippage — 21 days late, cure notice triggered',
          'Internal milestone slippage signal injected by demo scenario. fn_rule_evaluate_sla not yet implemented; correlations via cron.',
          'high',
          'https://demo/epc_sla/signal',
          '{"daysLate":21,"clauseType":"cure_period","demoNote":"fn_rule_evaluate_sla_not_yet_implemented"}'::JSONB,
          v_dedup_hash,
          'demo', TRUE, clock_timestamp(), clock_timestamp()
        )
        ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
        RETURNING id INTO v_signal_id;
      END IF;

    -- ----------------------------------------------------------------
    -- renewal: calendar-driven lookahead — signal only.
    -- GAP: no calendar-rule fn; pg_cron handles lookahead in production.
    -- ----------------------------------------------------------------
    WHEN 'renewal' THEN
      SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
      WHERE tenant_id = v_tenant_id AND source_id = 'mock_social_x' LIMIT 1;
      IF v_src_id IS NOT NULL THEN
        v_ext_id     := 'demo-renewal-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US');
        v_dedup_hash := encode(sha256((v_ext_id || v_tenant_id::text)::bytea), 'hex');
        INSERT INTO osint_signal (
          tenant_id, osint_source_id, source_id, source, kind, signal_kind_subtype,
          ext_id, category, severity, title_en, title, summary, severity_v2,
          url, raw_payload, dedup_hash,
          data_classification, is_active, created_at, updated_at
        ) VALUES (
          v_tenant_id, v_src_id, 'mock_social_x', 'mock_social_x',
          'internal', 'renewal_lookahead',
          v_ext_id, 'supply_chain', 'low',
          'Renewal lookahead triggered — 90 day window',
          'Renewal lookahead triggered — 90 day window',
          'Calendar renewal-lookahead signal injected by demo scenario. Production pg_cron handles real calendar scanning.',
          'low',
          'https://demo/renewal/signal',
          '{"horizonDays":90,"demoNote":"calendar_rule_not_yet_implemented_correlations_via_cron"}'::JSONB,
          v_dedup_hash,
          'demo', TRUE, clock_timestamp(), clock_timestamp()
        )
        ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
        RETURNING id INTO v_signal_id;
      END IF;

    -- ----------------------------------------------------------------
    -- cyclone: weather signal + fn_rule_evaluate_weather_fm_eligible + advisory draft.
    -- FULLY WIRED path.
    -- ----------------------------------------------------------------
    WHEN 'cyclone' THEN
      SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
      WHERE tenant_id = v_tenant_id AND source_id = 'ncm_uae' LIMIT 1;
      IF v_src_id IS NULL THEN
        SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
        WHERE tenant_id = v_tenant_id AND source_id = 'openweather' LIMIT 1;
      END IF;
      IF v_src_id IS NOT NULL THEN
        v_ext_id     := 'demo-cyclone-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US');
        v_dedup_hash := encode(sha256((v_ext_id || v_tenant_id::text)::bytea), 'hex');
        INSERT INTO osint_signal (
          tenant_id, osint_source_id, source_id, source, kind, signal_kind_subtype,
          ext_id, category, severity, title_en, title, summary, severity_v2,
          url, geographies, dedup_hash,
          data_classification, is_active, created_at, updated_at
        ) VALUES (
          v_tenant_id, v_src_id, v_src_code, v_src_code,
          'weather', 'scenario_trigger',
          v_ext_id, 'supply_chain', 'critical',
          'Cyclone warning — Persian Gulf, critical severity',
          'Cyclone warning — Persian Gulf, critical severity',
          'Cyclone weather event in Persian Gulf bbox. FM clause eligibility evaluation triggered.',
          'critical',
          'https://demo/cyclone/signal',
          '["persian_gulf","gulf_of_oman"]'::JSONB,
          v_dedup_hash,
          'demo', TRUE, clock_timestamp(), clock_timestamp()
        )
        ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
        RETURNING id INTO v_signal_id;

        -- Call weather FM rule if signal was inserted
        IF v_signal_id IS NOT NULL THEN
          v_weather_result := fn_rule_evaluate_weather_fm_eligible(v_signal_id);

          -- If correlations created, attempt advisory draft on first matched contract
          IF (v_weather_result->>'inserted')::INTEGER > 0 THEN
            SELECT c.id INTO v_first_contract_id
            FROM jsonb_array_elements(v_weather_result->'correlations') AS elem
            CROSS JOIN LATERAL (SELECT (elem->>'contractId')::BIGINT AS id) c
            LIMIT 1;

            SELECT id INTO v_correlation_id
            FROM correlation
            WHERE tenant_id = v_tenant_id
              AND signal_id = v_signal_id
              AND contract_id = v_first_contract_id
            LIMIT 1;

            SELECT id INTO v_template_id
            FROM advisory_template
            WHERE tenant_id = v_tenant_id AND template_id = 'weather_fm_notice_v1' AND is_active = TRUE
            LIMIT 1;

            IF v_correlation_id IS NOT NULL AND v_template_id IS NOT NULL THEN
              PERFORM fn_advisory_draft_generate(
                p_actor_id,
                v_correlation_id,
                v_template_id,
                NULL,                -- p_contract_id (use from correlation)
                NULL, NULL, NULL, NULL, NULL,
                jsonb_build_object(
                  'contract_id',                v_first_contract_id,
                  'weather_event_summary',      'Cyclone — Persian Gulf critical severity',
                  'weather_threshold_breached', 'wind_speed_kt_75_sustained',
                  'fm_clause_text',             'Force Majeure — weather event',
                  'notice_period_days',         7
                )
              );
            END IF;
          END IF;
        END IF;
      END IF;

    -- ----------------------------------------------------------------
    -- icv_shortfall: internal ICV signal + synthetic correlation + advisory draft.
    -- PARTIAL: no fn_rule_evaluate_icv yet; synthetic correlation bridges the gap.
    -- ----------------------------------------------------------------
    WHEN 'icv_shortfall' THEN
      SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
      WHERE tenant_id = v_tenant_id AND source_id = 'internal:icv_custom' LIMIT 1;
      IF v_src_id IS NULL THEN
        SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
        WHERE tenant_id = v_tenant_id AND source_id = 'mock_social_x' LIMIT 1;
      END IF;
      IF v_src_id IS NOT NULL THEN
        v_ext_id     := 'demo-icv-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US');
        v_dedup_hash := encode(sha256((v_ext_id || v_tenant_id::text)::bytea), 'hex');
        INSERT INTO osint_signal (
          tenant_id, osint_source_id, source_id, source, kind, signal_kind_subtype,
          ext_id, category, severity, title_en, title, summary, severity_v2,
          url, raw_payload, dedup_hash,
          data_classification, is_active, created_at, updated_at
        ) VALUES (
          v_tenant_id, v_src_id, v_src_code, v_src_code,
          'internal', 'icv_downgrade',
          v_ext_id, 'supply_chain', 'high',
          'ICV shortfall — supplier score 18%, threshold 35%',
          'ICV shortfall — supplier score 18%, threshold 35%',
          'ICV custom adapter signal: supplier ICV score below contractual minimum.',
          'high',
          'https://demo/icv_shortfall/signal',
          '{"currentIcvPct":18,"targetIcvPct":35,"rectificationPeriodDays":90,"demoNote":"fn_rule_evaluate_icv_not_yet_implemented"}'::JSONB,
          v_dedup_hash,
          'demo', TRUE, clock_timestamp(), clock_timestamp()
        )
        ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
        RETURNING id INTO v_signal_id;

        -- Synthetic correlation → advisory draft
        IF v_signal_id IS NOT NULL THEN
          SELECT c.id INTO v_first_contract_id
          FROM contract c
          JOIN contract_clause_extracted cce ON cce.contract_id = c.id
          WHERE cce.tenant_id = v_tenant_id
            AND cce.clause_type_v2 = 'icv_in_country_value'
            AND cce.is_active = TRUE
            AND c.is_active = TRUE
          LIMIT 1;

          IF v_first_contract_id IS NOT NULL THEN
            INSERT INTO correlation (
              tenant_id, signal_id, contract_id, rule_id,
              match_reason, confidence, status, is_active, created_at
            ) VALUES (
              v_tenant_id, v_signal_id, v_first_contract_id,
              'rule.icv.shortfall_trigger',
              'Demo scenario: ICV score 18% below 35% threshold',
              0.90, 'active', TRUE, clock_timestamp()
            )
            ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING
            RETURNING id INTO v_correlation_id;

            IF v_correlation_id IS NOT NULL THEN
              SELECT id INTO v_template_id FROM advisory_template
              WHERE tenant_id = v_tenant_id AND template_id = 'icv_rectification_notice_v1' AND is_active = TRUE
              LIMIT 1;
              IF v_template_id IS NOT NULL THEN
                PERFORM fn_advisory_draft_generate(
                  p_actor_id, v_correlation_id, v_template_id,
                  NULL, NULL, NULL, NULL, NULL, NULL,
                  jsonb_build_object(
                    'contract_id',               v_first_contract_id,
                    'current_icv_pct',           18,
                    'target_icv_pct',            35,
                    'rectification_period_days', 90
                  )
                );
              END IF;
            END IF;
          END IF;
        END IF;
      END IF;

    -- ----------------------------------------------------------------
    -- esg_subcontractor: pick existing ESG signal (seeded in 241) or insert one.
    -- PARTIAL: synthetic correlation + advisory draft.
    -- ----------------------------------------------------------------
    WHEN 'esg_subcontractor' THEN
      -- Use an existing ESG mock signal if available (avoids wasted insert)
      SELECT id INTO v_esg_signal_id
      FROM osint_signal
      WHERE tenant_id = v_tenant_id
        AND source_id = 'mock_social_x'
        AND kind = 'news'
        AND data_classification = 'demo'
        AND is_active = TRUE
      ORDER BY id DESC
      LIMIT 1;

      IF v_esg_signal_id IS NULL THEN
        SELECT id, source_id INTO v_src_id, v_src_code FROM osint_source
        WHERE tenant_id = v_tenant_id AND source_id = 'mock_social_x' LIMIT 1;
        IF v_src_id IS NOT NULL THEN
          v_ext_id     := 'demo-esg-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US');
          v_dedup_hash := encode(sha256((v_ext_id || v_tenant_id::text)::bytea), 'hex');
          INSERT INTO osint_signal (
            tenant_id, osint_source_id, source_id, source, kind, signal_kind_subtype,
            ext_id, category, severity, title_en, title, summary, severity_v2,
            url, affected_entities, dedup_hash,
            data_classification, is_active, created_at, updated_at
          ) VALUES (
            v_tenant_id, v_src_id, 'mock_social_x', 'mock_social_x',
            'news', 'esg_concern',
            v_ext_id, 'geopolitical', 'high',
            'Labour violation alleged at sub-contractor — demo scenario injection',
            'Labour violation alleged at sub-contractor — demo scenario injection',
            'ESG/labour violation at sub-contractor injected by esg_subcontractor scenario.',
            'high',
            'https://demo/esg_subcontractor/signal',
            '[{"name":"Galadari Brothers Group","role":"subcontractor"}]'::JSONB,
            v_dedup_hash,
            'demo', TRUE, clock_timestamp(), clock_timestamp()
          )
          ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
          RETURNING id INTO v_esg_signal_id;
          v_signal_id := v_esg_signal_id;
        END IF;
      END IF;

      -- Synthetic correlation + advisory draft
      IF v_esg_signal_id IS NOT NULL THEN
        SELECT c.id INTO v_first_contract_id
        FROM contract c
        WHERE c.is_active = TRUE
        LIMIT 1;

        IF v_first_contract_id IS NOT NULL THEN
          INSERT INTO correlation (
            tenant_id, signal_id, contract_id, rule_id,
            match_reason, confidence, status, is_active, created_at
          ) VALUES (
            v_tenant_id, v_esg_signal_id, v_first_contract_id,
            'rule.esg.sub_contractor_violation',
            'Demo scenario: ESG/labour violation keyword match via mock_social_x',
            0.75, 'active', TRUE, clock_timestamp()
          )
          ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING
          RETURNING id INTO v_esg_corr_id;

          IF v_esg_corr_id IS NOT NULL THEN
            SELECT id INTO v_template_id FROM advisory_template
            WHERE tenant_id = v_tenant_id AND template_id = 'esg_concern_memo_v1' AND is_active = TRUE
            LIMIT 1;
            IF v_template_id IS NOT NULL THEN
              PERFORM fn_advisory_draft_generate(
                p_actor_id, v_esg_corr_id, v_template_id,
                NULL, NULL, NULL, NULL, NULL, NULL,
                jsonb_build_object(
                  'contract_id',             v_first_contract_id,
                  'prime_counterparty_name', 'Prime Contractor',
                  'sub_contractor_name',     'Galadari Brothers Group',
                  'concern_summary',         'Labour rights violation flagged at sub-contractor site',
                  'source_url',              'https://demo/esg_subcontractor/signal',
                  'recommended_review',      'Compliance ESG review within 5 business days'
                )
              );
            END IF;
          END IF;
        END IF;
      END IF;

    ELSE
      -- Unknown scenario_id (future-proofing): no-op injection
      NULL;
  END CASE;

  -- ================================================================
  -- OUTCOME CAPTURE (window-snapshot from v_started_at for AC-S16)
  -- ================================================================
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

COMMENT ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) IS 'DEFINER: trigger demo scenario with per-scenario event-injection handlers (DEBT-CRIJ-3 v2). cyclone=FULLY WIRED (signal+fn_rule_evaluate_weather_fm_eligible+advisory_draft). icv_shortfall/esg_subcontractor=PARTIAL (signal+synthetic_correlation+advisory_draft). hormuz/ofac_sanctions/brent_review=SIGNAL-ONLY (no dedicated rule fn; cron correlates). epc_sla/renewal=SIGNAL-ONLY (GAP logged in raw_payload). All 6 signal INSERTs supply required NOT NULL columns (ext_id, category, source, severity, title_en, dedup_hash). Outcome JSONB reflects real counts. Requires demo.scenario.trigger permission.';
REVOKE EXECUTE ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_scenario_trigger(BIGINT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (246, '246_crij_scenario_trigger_fix_not_null', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 246;
-- Restore fn_demo_scenario_trigger from migration 245 if needed.
-- ============================================================
