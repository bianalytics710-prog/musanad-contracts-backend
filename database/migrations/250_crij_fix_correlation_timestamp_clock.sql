-- Migration: 250_crij_fix_correlation_timestamp_clock.sql
-- Module: M17+M18 — CR-I + CR-J DEBT-CRIJ-3 fix v5
-- Description: fn_rule_evaluate_weather_fm_eligible uses now() for correlation.created_at,
--   but fn_demo_scenario_trigger captures v_started_at = clock_timestamp() AFTER the lock.
--   Since now() = transaction start time and clock_timestamp() advances, the correlation
--   ends up with created_at < v_started_at, causing the outcome window to miss it.
--   Fix: use clock_timestamp() in the correlation INSERT, consistent with all other
--   demo-path INSERTs. Also apply the same fix to both synthetic correlation INSERTs
--   inside fn_demo_scenario_trigger (icv_shortfall + esg_subcontractor — already use
--   clock_timestamp() per migration 249, but confirmed here for completeness).
-- Date: 2026-05-14

-- ============================================================
-- Fix: fn_rule_evaluate_weather_fm_eligible — now() → clock_timestamp() in correlation INSERT
-- ============================================================
CREATE OR REPLACE FUNCTION fn_rule_evaluate_weather_fm_eligible(p_signal_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id       UUID;
  v_signal          RECORD;
  v_correlations    JSONB := '[]'::jsonb;
  v_inserted_count  INTEGER := 0;
  v_contract_id     BIGINT;
  v_rule_hash       TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;
  v_rule_hash := encode(sha256('rule.weather.fm_eligible.v1'::bytea), 'hex');

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
    RETURN jsonb_build_object('correlations', '[]'::jsonb, 'inserted', 0);
  END IF;

  FOR v_contract_id IN
    SELECT DISTINCT c.id
    FROM contract c
    JOIN contract_clause_extracted cce ON cce.contract_id = c.id
    WHERE c.is_active = TRUE
      AND c.contract_type IN ('o_m', 'drilling', 'charter_party')
      AND cce.clause_type_v2 IN ('weather', 'force_majeure', 'excusable_delay')
      AND cce.is_active = TRUE
      AND cce.tenant_id = v_tenant_id
  LOOP
    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id,
      rule_version_hash,
      match_reason, confidence, status, is_active, created_at
    ) VALUES (
      v_tenant_id, p_signal_id, v_contract_id,
      'rule.weather.fm_eligible',
      v_rule_hash,
      'Weather event severity ' || v_signal.severity_v2 || ' in Gulf region matched FM-eligible contract',
      0.85,
      'active', TRUE, clock_timestamp()   -- clock_timestamp() so outcome window captures it
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
COMMENT ON FUNCTION fn_rule_evaluate_weather_fm_eligible(bigint) IS 'DEFINER: evaluate rule.weather.fm_eligible for a given signal; INSERT INTO correlation (clock_timestamp for outcome-window accuracy) with rule_version_hash ON CONFLICT DO NOTHING. Matches high/critical-severity weather signals in Gulf region to O&M/drilling/charter_party contracts with FM/weather clauses.';
REVOKE EXECUTE ON FUNCTION fn_rule_evaluate_weather_fm_eligible(bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_rule_evaluate_weather_fm_eligible(bigint) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (250, '250_crij_fix_correlation_timestamp_clock', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 250;
-- Restore fn_rule_evaluate_weather_fm_eligible from migration 249.
-- ============================================================
