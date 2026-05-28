-- ============================================================
-- Migration 279: CR-FIX1 Issue 4 — fn_risk_score_compute
--   Invert health_score to TRUE health semantics:
--     100 = fully healthy / no risk  (was 0)
--       0 = critical risk             (was 100)
--   Formula change ONLY at Step 10:
--     v_health_score := LEAST(100, GREATEST(0, ROUND(
--       100 - ( v_dim_legal*weight_legal + v_dim_financial*weight_financial
--             + v_dim_operational*weight_operational
--             + v_dim_reputational*weight_reputational
--             + v_dim_compliance*weight_compliance ) )));
--   Everything else (dim computations, MaR, INSERT, RETURN) is
--   preserved byte-for-byte from the live definition captured before
--   this migration was written.
--   After the function replace, a DO block recomputes all active
--   contracts and refreshes the materialized view.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_risk_score_compute(p_contract_id bigint, p_triggered_by text, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_contract_row         RECORD;
  v_tenant_id            UUID;
  v_actor_id             BIGINT;
  v_existing_id          BIGINT;
  v_risk_score_id        BIGINT;
  v_correlations         JSONB[];
  v_weights              JSONB;
  v_weights_version      TEXT;
  v_weights_sum          NUMERIC;
  v_exposure_defaults    JSONB;
  v_impact_multipliers   JSONB;
  v_contract_type_key    TEXT;
  v_exposure_fraction    NUMERIC;
  v_clause_signals       RECORD;
  v_prob_legal           NUMERIC := 0;
  v_prob_financial       NUMERIC := 0;
  v_prob_operational     NUMERIC := 0;
  v_prob_reputational    NUMERIC := 0;
  v_prob_compliance      NUMERIC := 0;
  v_impact_legal         NUMERIC := 0;
  v_impact_financial     NUMERIC := 0;
  v_impact_operational   NUMERIC := 0;
  v_impact_reputational  NUMERIC := 0;
  v_impact_compliance    NUMERIC := 0;
  v_dim_legal            INTEGER;
  v_dim_financial        INTEGER;
  v_dim_operational      INTEGER;
  v_dim_reputational     INTEGER;
  v_dim_compliance       INTEGER;
  v_health_score         INTEGER;
  v_reasons_legal        JSONB := '[]'::jsonb;
  v_reasons_financial    JSONB := '[]'::jsonb;
  v_reasons_operational  JSONB := '[]'::jsonb;
  v_reasons_reputational JSONB := '[]'::jsonb;
  v_reasons_compliance   JSONB := '[]'::jsonb;
  v_mar_total                 NUMERIC := NULL;
  v_mar_currency              CHAR(3) := 'AED';
  v_contributing_correlations JSONB   := '[]'::jsonb;
  v_clause_id_array           JSONB   := '[]'::jsonb;
  v_corr                 JSONB;
  v_impact_mult          NUMERIC;
  v_corr_mar             NUMERIC;
  v_rule_id              TEXT;
  v_confidence           NUMERIC;
  v_source_rel           NUMERIC;
  v_prob_contrib         NUMERIC;
  v_explanation          JSONB;
  v_result               JSONB;
BEGIN
  IF p_triggered_by NOT IN ('signal','clause_change','weight_change','scheduled','manual','bootstrap') THEN
    RAISE EXCEPTION 'invalid triggered_by: %', p_triggered_by USING ERRCODE = '22023';
  END IF;
  SELECT id, value_aed, currency, contract_type, emirate
  INTO   v_contract_row
  FROM   contract
  WHERE  id = p_contract_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract with id % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_contract_row.currency IS NOT NULL AND v_contract_row.currency != 'AED' THEN
    RAISE EXCEPTION 'contract currency must be AED in v1 (got %)', v_contract_row.currency USING ERRCODE = '22023';
  END IF;
  v_actor_id := p_actor_id;
  IF v_actor_id = 0 THEN v_actor_id := NULL; END IF;
  SELECT id INTO v_existing_id
  FROM   risk_score
  WHERE  contract_id  = p_contract_id
    AND  triggered_by = p_triggered_by
    AND  calculated_at >= fn_demo_now() - INTERVAL '60 seconds'
  ORDER BY calculated_at DESC
  LIMIT 1
  FOR UPDATE;
  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object('riskScoreId', v_existing_id, 'contractId', p_contract_id, 'deduplicated', TRUE, 'note', 'snapshot exists within 60s dedup window');
  END IF;
  SELECT array_agg(jsonb_build_object('correlationId', c.id, 'ruleId', c.rule_id, 'signalId', c.signal_id, 'confidence', c.confidence, 'matchReason', c.match_reason, 'matchEntities', c.match_entities, 'sourceReliability', COALESCE(s.source_reliability, 1.0))) INTO v_correlations
  FROM   correlation c
  JOIN   osint_signal sig ON sig.id = c.signal_id
  JOIN   osint_source s   ON s.id   = sig.osint_source_id
  WHERE  c.tenant_id   = v_tenant_id
    AND  c.contract_id = p_contract_id
    AND  c.status      = 'active'
    AND  c.is_active   = TRUE;
  SELECT value INTO v_weights FROM system_setting WHERE key = 'scoring.weights' AND is_active = TRUE;
  IF v_weights IS NULL THEN RAISE EXCEPTION 'scoring.weights config missing' USING ERRCODE = '22023'; END IF;
  v_weights_version := v_weights->>'version';
  v_weights_sum := (v_weights->>'legal')::numeric + (v_weights->>'financial')::numeric + (v_weights->>'operational')::numeric + (v_weights->>'reputational')::numeric + (v_weights->>'compliance')::numeric;
  IF ABS(v_weights_sum - 1.0) > 0.001 THEN RAISE EXCEPTION 'scoring.weights sum != 1.0 (actual: %)', v_weights_sum USING ERRCODE = '22023'; END IF;
  SELECT value INTO v_exposure_defaults FROM system_setting WHERE key = 'scoring.exposure_fraction_defaults' AND is_active = TRUE;
  SELECT value INTO v_impact_multipliers FROM system_setting WHERE key = 'scoring.impact_multipliers' AND is_active = TRUE;
  v_exposure_defaults  := COALESCE(v_exposure_defaults,  '{}'::jsonb);
  v_impact_multipliers := COALESCE(v_impact_multipliers, '{}'::jsonb);
  v_contract_type_key := lower(COALESCE(v_contract_row.contract_type, ''));
  v_exposure_fraction := COALESCE(NULLIF(v_exposure_defaults->>v_contract_type_key, '')::numeric, (v_exposure_defaults->>'default')::numeric, 0.10);
  SELECT bool_or((parameters->>'indemnity_scope')::text = 'broad') AS has_broad_indemnity, COALESCE(SUM((parameters->>'liability_cap_value')::numeric), 0) AS total_liability_cap, bool_or(COALESCE((parameters->>'public_visibility')::boolean, FALSE)) AS is_public, COUNT(*) FILTER (WHERE COALESCE((parameters->>'regulatory_linkage')::boolean, FALSE)) AS regulatory_clauses, COUNT(*) FILTER (WHERE COALESCE((parameters->>'critical_path_impact')::boolean, FALSE)) AS critical_path_clauses, bool_or(COALESCE((parameters->>'single_source_dependency')::boolean, FALSE)) AS has_single_source
  INTO v_clause_signals FROM contract_clause_extracted WHERE contract_id = p_contract_id AND is_active = TRUE;
  IF v_correlations IS NOT NULL THEN
    FOREACH v_corr IN ARRAY v_correlations LOOP
      v_rule_id := v_corr->>'ruleId'; v_confidence := (v_corr->>'confidence')::numeric; v_source_rel := (v_corr->>'sourceReliability')::numeric; v_prob_contrib := v_confidence * v_source_rel;
      IF v_rule_id LIKE 'rule.sanctions.%' OR v_rule_id LIKE 'rule.regulatory.%' THEN
        v_prob_legal := v_prob_legal + 100 * v_prob_contrib; v_prob_compliance := v_prob_compliance + 100 * v_prob_contrib;
        v_reasons_legal := v_reasons_legal || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_compliance := v_reasons_compliance || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSIF v_rule_id LIKE 'rule.market.%' THEN
        v_prob_financial := v_prob_financial + 100 * v_prob_contrib; v_reasons_financial := v_reasons_financial || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSIF v_rule_id LIKE 'rule.geopolitical.%' THEN
        v_prob_operational := v_prob_operational + 100 * v_prob_contrib; v_prob_reputational := v_prob_reputational + 100 * v_prob_contrib;
        v_reasons_operational := v_reasons_operational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_reputational := v_reasons_reputational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSIF v_rule_id LIKE 'rule.cyber.%' THEN
        v_prob_operational := v_prob_operational + 100 * v_prob_contrib; v_prob_reputational := v_prob_reputational + 100 * v_prob_contrib; v_prob_compliance := v_prob_compliance + 100 * v_prob_contrib;
        v_reasons_operational := v_reasons_operational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_reputational := v_reasons_reputational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_compliance := v_reasons_compliance || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSIF v_rule_id LIKE 'rule.disruption.%' THEN
        v_prob_operational := v_prob_operational + 100 * v_prob_contrib; v_prob_financial := v_prob_financial + 100 * v_prob_contrib;
        v_reasons_operational := v_reasons_operational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_financial := v_reasons_financial || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSIF v_rule_id LIKE 'rule.counterparty.%' THEN
        v_prob_financial := v_prob_financial + 100 * v_prob_contrib; v_prob_legal := v_prob_legal + 100 * v_prob_contrib; v_prob_reputational := v_prob_reputational + 100 * v_prob_contrib;
        v_reasons_financial := v_reasons_financial || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_legal := v_reasons_legal || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_reputational := v_reasons_reputational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSE
        v_prob_legal := v_prob_legal + 100 * v_prob_contrib / 5; v_prob_financial := v_prob_financial + 100 * v_prob_contrib / 5; v_prob_operational := v_prob_operational + 100 * v_prob_contrib / 5; v_prob_reputational := v_prob_reputational + 100 * v_prob_contrib / 5; v_prob_compliance := v_prob_compliance + 100 * v_prob_contrib / 5;
      END IF;
    END LOOP;
  END IF;
  v_prob_legal := LEAST(100, GREATEST(0, ROUND(v_prob_legal))); v_prob_financial := LEAST(100, GREATEST(0, ROUND(v_prob_financial))); v_prob_operational := LEAST(100, GREATEST(0, ROUND(v_prob_operational))); v_prob_reputational := LEAST(100, GREATEST(0, ROUND(v_prob_reputational))); v_prob_compliance := LEAST(100, GREATEST(0, ROUND(v_prob_compliance)));
  v_impact_legal := LEAST(100, GREATEST(0, CASE WHEN v_clause_signals.has_broad_indemnity THEN 80 ELSE 0 END + CASE WHEN v_clause_signals.total_liability_cap > 10000000 THEN 40 WHEN v_clause_signals.total_liability_cap > 1000000 THEN 20 ELSE 0 END));
  v_impact_financial := LEAST(100, GREATEST(0, ROUND(100 * v_exposure_fraction) + CASE WHEN v_contract_row.value_aed > 100000000 THEN 20 ELSE 0 END));
  v_reasons_financial := v_reasons_financial || jsonb_build_array('exposure_fraction ' || v_exposure_fraction);
  v_impact_operational := LEAST(100, GREATEST(0, v_clause_signals.critical_path_clauses * 25 + CASE WHEN v_clause_signals.has_single_source THEN 10 ELSE 0 END));
  v_impact_reputational := CASE WHEN v_clause_signals.is_public THEN 80 ELSE 30 END;
  v_reasons_reputational := v_reasons_reputational || jsonb_build_array('public_visibility: ' || v_clause_signals.is_public);
  v_impact_compliance := LEAST(100, GREATEST(0, v_clause_signals.regulatory_clauses * 30));
  v_dim_legal        := LEAST(100, GREATEST(0, ROUND(v_prob_legal        * v_impact_legal        / 100.0)));
  v_dim_financial    := LEAST(100, GREATEST(0, ROUND(v_prob_financial    * v_impact_financial    / 100.0)));
  v_dim_operational  := LEAST(100, GREATEST(0, ROUND(v_prob_operational  * v_impact_operational  / 100.0)));
  v_dim_reputational := LEAST(100, GREATEST(0, ROUND(v_prob_reputational * v_impact_reputational / 100.0)));
  v_dim_compliance   := LEAST(100, GREATEST(0, ROUND(v_prob_compliance   * v_impact_compliance   / 100.0)));
  -- Step 10 (CR-FIX1 Issue 4): INVERTED health semantics.
  -- Previously: health_score = Σ dim_X * weight_X  (risk magnitude; 0=no risk, 100=maximum risk)
  -- Now: health_score = 100 - Σ dim_X * weight_X   (100=healthy/no-risk, 0=critical)
  v_health_score := LEAST(100, GREATEST(0, ROUND(100 - (
      v_dim_legal        * (v_weights->>'legal')::numeric
    + v_dim_financial    * (v_weights->>'financial')::numeric
    + v_dim_operational  * (v_weights->>'operational')::numeric
    + v_dim_reputational * (v_weights->>'reputational')::numeric
    + v_dim_compliance   * (v_weights->>'compliance')::numeric
  ))));
  IF v_contract_row.value_aed IS NOT NULL AND v_correlations IS NOT NULL THEN
    v_mar_total := 0;
    FOREACH v_corr IN ARRAY v_correlations LOOP
      v_confidence := (v_corr->>'confidence')::numeric; v_source_rel := (v_corr->>'sourceReliability')::numeric; v_rule_id := v_corr->>'ruleId'; v_impact_mult := 1.0;
      IF v_rule_id LIKE 'rule.counterparty.%' THEN v_impact_mult := v_impact_mult * COALESCE((v_impact_multipliers->>'single_source_dependency')::numeric, 1.0); END IF;
      IF v_clause_signals.regulatory_clauses > 0 THEN v_impact_mult := v_impact_mult * COALESCE((v_impact_multipliers->>'regulatory_linkage')::numeric, 1.0); END IF;
      IF v_clause_signals.critical_path_clauses > 0 THEN v_impact_mult := v_impact_mult * COALESCE((v_impact_multipliers->>'critical_path_impact')::numeric, 1.0); END IF;
      v_impact_mult := LEAST(3.0, v_impact_mult);
      v_corr_mar := v_contract_row.value_aed * v_exposure_fraction * (v_confidence * v_source_rel) * v_impact_mult;
      v_mar_total := v_mar_total + v_corr_mar;
      v_contributing_correlations := v_contributing_correlations || jsonb_build_array(jsonb_build_object('correlationId', (v_corr->>'correlationId')::bigint, 'ruleId', v_rule_id, 'signalId', (v_corr->>'signalId')::bigint, 'confidence', v_confidence, 'sourceReliability', v_source_rel, 'probability', ROUND(v_confidence * v_source_rel * 100, 2), 'impactMultiplier', v_impact_mult, 'marContribution', ROUND(v_corr_mar, 2), 'dimensionsAffected', CASE WHEN v_rule_id LIKE 'rule.sanctions.%' THEN '["legal","compliance"]'::jsonb WHEN v_rule_id LIKE 'rule.regulatory.%' THEN '["legal","compliance"]'::jsonb WHEN v_rule_id LIKE 'rule.market.%' THEN '["financial"]'::jsonb WHEN v_rule_id LIKE 'rule.geopolitical.%' THEN '["operational","reputational"]'::jsonb WHEN v_rule_id LIKE 'rule.cyber.%' THEN '["operational","reputational","compliance"]'::jsonb WHEN v_rule_id LIKE 'rule.disruption.%' THEN '["operational","financial"]'::jsonb WHEN v_rule_id LIKE 'rule.counterparty.%' THEN '["financial","legal","reputational"]'::jsonb ELSE '["legal","financial","operational","reputational","compliance"]'::jsonb END));
    END LOOP;
  ELSE
    IF v_contract_row.value_aed IS NOT NULL THEN v_mar_total := 0; END IF;
  END IF;
  SELECT COALESCE(jsonb_agg(cce.id ORDER BY cce.id), '[]'::jsonb) INTO v_clause_id_array FROM contract_clause_extracted cce WHERE cce.contract_id = p_contract_id AND cce.is_active = TRUE;
  v_explanation := jsonb_build_object('dimensions', jsonb_build_object('legal', jsonb_build_object('score', v_dim_legal, 'probability', v_prob_legal, 'impact', v_impact_legal, 'reasons', v_reasons_legal), 'financial', jsonb_build_object('score', v_dim_financial, 'probability', v_prob_financial, 'impact', v_impact_financial, 'reasons', v_reasons_financial), 'operational', jsonb_build_object('score', v_dim_operational, 'probability', v_prob_operational, 'impact', v_impact_operational, 'reasons', v_reasons_operational), 'reputational', jsonb_build_object('score', v_dim_reputational, 'probability', v_prob_reputational, 'impact', v_impact_reputational, 'reasons', v_reasons_reputational), 'compliance', jsonb_build_object('score', v_dim_compliance, 'probability', v_prob_compliance, 'impact', v_impact_compliance, 'reasons', v_reasons_compliance)), 'marFormula', jsonb_build_object('contractValue', v_contract_row.value_aed, 'exposureFraction', v_exposure_fraction, 'probability', NULL, 'impactMultiplier', NULL, 'marValue', v_mar_total), 'weightsAtCalculation', jsonb_build_object('legal', (v_weights->>'legal')::numeric, 'financial', (v_weights->>'financial')::numeric, 'operational', (v_weights->>'operational')::numeric, 'reputational', (v_weights->>'reputational')::numeric, 'compliance', (v_weights->>'compliance')::numeric), 'contributingClauses', v_clause_id_array);
  INSERT INTO risk_score (tenant_id, contract_id, health_score, dim_legal, dim_financial, dim_operational, dim_reputational, dim_compliance, mar_value, mar_currency, contributing_correlations, explanation, weights_version, calculated_at, triggered_by, data_classification, created_at, created_by)
  VALUES (v_tenant_id, p_contract_id, v_health_score, v_dim_legal, v_dim_financial, v_dim_operational, v_dim_reputational, v_dim_compliance, v_mar_total, 'AED', v_contributing_correlations, v_explanation, v_weights_version, fn_demo_now(), p_triggered_by, 'demo', NOW(), v_actor_id)
  RETURNING id INTO v_risk_score_id;
  REFRESH MATERIALIZED VIEW latest_risk_score;
  PERFORM fn_contract_activity_create(p_contract_id, 'ai_risk_score_updated', v_actor_id, 'Risk score recomputed (Health Score: ' || v_health_score || ')', 'تم إعادة احتساب درجة المخاطر (' || v_health_score || ')', jsonb_build_object('riskScoreId', v_risk_score_id, 'healthScore', v_health_score, 'triggeredBy', p_triggered_by, 'weightsVersion', v_weights_version));
  RETURN jsonb_build_object('riskScoreId', v_risk_score_id, 'contractId', p_contract_id, 'healthScore', v_health_score, 'dimensions', jsonb_build_object('legal', v_dim_legal, 'financial', v_dim_financial, 'operational', v_dim_operational, 'reputational', v_dim_reputational, 'compliance', v_dim_compliance), 'marValue', v_mar_total, 'marCurrency', 'AED', 'weightsVersion', v_weights_version, 'calculatedAt', fn_demo_now(), 'contributingCorrelationCount', COALESCE(array_length(v_correlations, 1), 0), 'deduplicated', FALSE);
EXCEPTION
  WHEN OTHERS THEN RAISE EXCEPTION 'fn_risk_score_compute: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

-- S2-21 trio
COMMENT ON FUNCTION public.fn_risk_score_compute(bigint, text, bigint) IS
  'CR-FIX1 (279): health_score semantics INVERTED — 100=healthy/no-risk, 0=critical. Step 10 now computes 100-(Σ dim_X*weight_X). DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';
REVOKE EXECUTE ON FUNCTION public.fn_risk_score_compute(bigint, text, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_risk_score_compute(bigint, text, bigint) TO neondb_owner;

-- ============================================================
-- Recompute all active contracts with the corrected formula.
-- Sets GUCs to the system tenant + actor_id=1 (system).
-- The 60s dedup window applies per contract; one snapshot per
-- contract is inserted for triggered_by='manual'.
-- latest_risk_score MV is refreshed CONCURRENTLY at the end
-- (unique index latest_risk_score_pk exists).
-- ============================================================
DO $$
DECLARE
  r RECORD;
BEGIN
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', true);
  PERFORM set_config('app.current_user_id',   '1', true);

  FOR r IN
    SELECT id FROM contract WHERE is_active = TRUE
  LOOP
    BEGIN
      PERFORM fn_risk_score_compute(r.id, 'manual', 1);
    EXCEPTION WHEN OTHERS THEN
      -- Log but do not abort the recompute loop on individual contract errors
      RAISE WARNING 'fn_risk_score_compute failed for contract %: %', r.id, SQLERRM;
    END;
  END LOOP;

  REFRESH MATERIALIZED VIEW CONCURRENTLY latest_risk_score;
END;
$$;

-- schema_migrations
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (279, 'crfix1_risk_score_health_semantics', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if needed):
-- Restore original Step 10 (remove 100 - wrapper), recompute,
-- refresh MV, then:
-- DELETE FROM schema_migrations WHERE version = 279;
-- ============================================================
