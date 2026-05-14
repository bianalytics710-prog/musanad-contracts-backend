-- Migration: 238_seed_correlation_rule_weather_fm.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: 1 new correlation_rule (rule.weather.fm_eligible) + 2 fixtures + fn_rule_evaluate_weather_fm_eligible.
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Seed helper function
CREATE OR REPLACE FUNCTION fn_correlation_rule_seed_weather_fm_eligible()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_inserted_rules    INTEGER := 0;
  v_inserted_fixtures INTEGER := 0;
  v_tid UUID;
  v_rule_db_id BIGINT;
BEGIN
  FOR v_tid IN SELECT id FROM tenant WHERE is_active = TRUE LOOP
    -- Insert rule
    INSERT INTO correlation_rule (tenant_id, rule_id, name, name_ar, scenario, match_yaml, produce_yaml, version_hash, is_active, created_at, updated_at)
    VALUES (
      v_tid,
      'rule.weather.fm_eligible',
      'Weather FM Eligible',
      'استحقاق القوة القاهرة بسبب الطقس',
      'weather_fm',
      $YAML$signal:
  severity: { gte: high }
  kind: weather
  location: { in_bbox: persian_gulf_or_oman_bbox }
contract:
  contract_type: { in: [o_m, drilling, charter_party] }
  has_clause:
    clause_type: { in: [weather, force_majeure, excusable_delay] }$YAML$,
      $YAML$correlation:
  rule_id: rule.weather.fm_eligible
  alert_roles: [legal_counsel, operations]
  sla_hours: 8$YAML$,
      encode(sha256('rule.weather.fm_eligible.v1'::bytea), 'hex'),
      TRUE, now(), now()
    )
    ON CONFLICT (tenant_id, rule_id) DO NOTHING;
    DECLARE rc INTEGER; BEGIN GET DIAGNOSTICS rc = ROW_COUNT; v_inserted_rules := v_inserted_rules + rc; END;

    -- Get the rule DB id
    SELECT id INTO v_rule_db_id FROM correlation_rule
    WHERE tenant_id = v_tid AND rule_id = 'rule.weather.fm_eligible';

    -- Positive fixture: critical-severity weather signal in Gulf bbox + O&M contract with weather clause → 1 correlation expected
    INSERT INTO correlation_rule_fixture (
      tenant_id, correlation_rule_id, fixture_id, description,
      given_signal, given_contract_seed_set, expected_match, expected_correlation,
      data_classification, created_at, updated_at
    ) VALUES (
      v_tid, v_rule_db_id, 'fixture.weather.fm_eligible.positive',
      'Critical-severity weather signal in Persian Gulf bbox + O&M contract with weather clause → 1 correlation expected',
      '{"kind":"weather","severity_v2":"critical","geographies":["persian_gulf"]}'::jsonb,
      '{"contract_type":"o_m","has_clause":{"clause_type":"weather"}}'::jsonb,
      TRUE,
      '{"correlationCount":1}'::jsonb,
      'demo', now(), now()
    ) ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;
    DECLARE rc INTEGER; BEGIN GET DIAGNOSTICS rc = ROW_COUNT; v_inserted_fixtures := v_inserted_fixtures + rc; END;

    -- Negative fixture: low-severity weather signal → 0 correlations expected
    INSERT INTO correlation_rule_fixture (
      tenant_id, correlation_rule_id, fixture_id, description,
      given_signal, given_contract_seed_set, expected_match, expected_correlation,
      data_classification, created_at, updated_at
    ) VALUES (
      v_tid, v_rule_db_id, 'fixture.weather.fm_eligible.negative',
      'Low-severity weather signal → severity filter blocks → 0 correlations expected',
      '{"kind":"weather","severity_v2":"low","geographies":["persian_gulf"]}'::jsonb,
      '{"contract_type":"o_m","has_clause":{"clause_type":"weather"}}'::jsonb,
      FALSE,
      '{"correlationCount":0}'::jsonb,
      'demo', now(), now()
    ) ON CONFLICT (correlation_rule_id, fixture_id) DO NOTHING;
    DECLARE rc INTEGER; BEGIN GET DIAGNOSTICS rc = ROW_COUNT; v_inserted_fixtures := v_inserted_fixtures + rc; END;
  END LOOP;

  RETURN jsonb_build_object('rulesInserted', v_inserted_rules, 'fixturesInserted', v_inserted_fixtures);
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_correlation_rule_seed_weather_fm_eligible: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_correlation_rule_seed_weather_fm_eligible() IS 'Migration-internal: idempotent seed for rule.weather.fm_eligible + 2 fixtures (positive + negative) per tenant.';
REVOKE EXECUTE ON FUNCTION fn_correlation_rule_seed_weather_fm_eligible() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_correlation_rule_seed_weather_fm_eligible() TO neondb_owner;

-- Rule evaluator for weather FM eligibility
CREATE OR REPLACE FUNCTION fn_rule_evaluate_weather_fm_eligible(
  p_signal_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id       UUID;
  v_signal          RECORD;
  v_correlations    JSONB := '[]'::jsonb;
  v_inserted_count  INTEGER := 0;
  v_contract_id     BIGINT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  -- Fetch signal with severity and location check
  SELECT os.id, os.severity_v2, os.kind, os.geographies
  INTO v_signal
  FROM osint_signal os
  WHERE os.id = p_signal_id
    AND os.tenant_id = v_tenant_id
    AND os.kind = 'weather'
    AND os.severity_v2 IN ('high', 'critical')
    AND (
      os.geographies::text ILIKE '%persian_gulf%'
      OR os.geographies::text ILIKE '%gulf_of_oman%'
      OR os.geographies::text ILIKE '%gulf%'
    );

  IF NOT FOUND THEN
    -- Signal does not match rule criteria — return empty
    RETURN jsonb_build_object('correlations', '[]'::jsonb);
  END IF;

  -- Find contracts matching contract_type + has relevant FM/weather clause
  FOR v_contract_id IN
    SELECT DISTINCT c.id
    FROM contract c
    JOIN contract_clause_extracted cce ON cce.contract_id = c.id
    WHERE c.tenant_id = v_tenant_id
      AND c.is_active = TRUE
      AND c.contract_type IN ('o_m', 'drilling', 'charter_party')
      AND cce.clause_type_v2 IN ('weather', 'force_majeure', 'excusable_delay')
      AND cce.is_active = TRUE
  LOOP
    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id,
      match_reason, confidence, status, is_active, created_at
    ) VALUES (
      v_tenant_id, p_signal_id, v_contract_id,
      'rule.weather.fm_eligible',
      'Weather event severity ' || v_signal.severity_v2 || ' in Gulf region matched FM-eligible contract',
      0.85,
      'active', TRUE, now()
    )
    ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;

    IF FOUND THEN
      v_inserted_count := v_inserted_count + 1;
      v_correlations := v_correlations || jsonb_build_array(
        jsonb_build_object('contractId', v_contract_id, 'ruleId', 'rule.weather.fm_eligible')
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object('correlations', v_correlations, 'inserted', v_inserted_count);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_rule_evaluate_weather_fm_eligible: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_rule_evaluate_weather_fm_eligible(BIGINT) IS 'DEFINER: evaluate rule.weather.fm_eligible for a given signal; INSERT INTO correlation ON CONFLICT DO NOTHING. Matches high/critical-severity weather signals in Gulf region to O&M/drilling/charter_party contracts with FM/weather clauses.';
REVOKE EXECUTE ON FUNCTION fn_rule_evaluate_weather_fm_eligible(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_rule_evaluate_weather_fm_eligible(BIGINT) TO neondb_owner;

-- Execute the seed
SELECT fn_correlation_rule_seed_weather_fm_eligible();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (238, '238_seed_correlation_rule_weather_fm', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 238;
-- DROP FUNCTION IF EXISTS fn_rule_evaluate_weather_fm_eligible(BIGINT);
-- DROP FUNCTION IF EXISTS fn_correlation_rule_seed_weather_fm_eligible();
-- ============================================================
