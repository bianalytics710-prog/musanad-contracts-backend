-- Migration: 171_crf_risk_score_functions.sql
-- Module: M14 — CR-F (5-Dim Risk Scoring + MaR + AVaR)
-- Description: 8 net-new fn_'s:
--   fn_risk_score_compute, fn_risk_score_explain, fn_risk_score_history,
--   fn_score_recompute_for_signal, fn_score_recompute_for_weight_change,
--   fn_avar_aggregate, fn_scoring_weights_get, fn_scoring_weights_set.
--   Each fn: COMMENT + REVOKE FROM PUBLIC + GRANT TO neondb_owner trio (S2-21 / B14).
-- Standards applied: S2-17,S2-18,S2-19,S2-20,S2-21,S2-22,S2-22b,S2-23,S2-24,S2-25,S2-26,S2-27,B14.
-- QA S2 W3 patch: fn_risk_score_compute — currency AED guard inserted between Step 1 and Step 3.
-- QA S2 W4 patch: fn_risk_score_compute — v_contributing_correlations + v_clause_id_array
--   DECLARED at top, explicitly accumulated in Step 11/12 loop, referenced in Step 13 INSERT.
-- DEFECT-1 fix: fn_scoring_weights_set Step 6 — audit_log INSERT uses live schema
--   (changed_by not changed_by_id; no record_id_text column — see db-impl-defect-report.md).
-- DEFECT-3 fix: fn_risk_score_compute Step 1 — contract table has no tenant_id column (M0 design);
--   v_tenant_id sourced from app.current_tenant_id GUC instead of v_contract_row.tenant_id.
--   db-design.md §2.1 SELECT assumed tenant_id on contract — live schema confirms column absent.
-- Design note #12: fn_party_chain_walk absent from live DB — counterparty_chain treated as counterparty_id.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ============================================================
-- 1. fn_risk_score_compute — primary write
-- ============================================================
CREATE OR REPLACE FUNCTION fn_risk_score_compute(
  p_contract_id  BIGINT,
  p_triggered_by TEXT,
  p_actor_id     BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
  v_contract_row         RECORD;
  v_tenant_id            UUID;
  v_actor_id             BIGINT;
  v_existing_id          BIGINT;
  v_risk_score_id        BIGINT;

  -- Correlation inputs
  v_correlations         JSONB[];   -- raw correlation rows (array of JSONB objects)

  -- Scoring config
  v_weights              JSONB;
  v_weights_version      TEXT;
  v_weights_sum          NUMERIC;
  v_exposure_defaults    JSONB;
  v_impact_multipliers   JSONB;
  v_contract_type_key    TEXT;
  v_exposure_fraction    NUMERIC;

  -- Clause signals
  v_clause_signals       RECORD;

  -- Per-dimension probability (scaled 0..100)
  v_prob_legal           NUMERIC := 0;
  v_prob_financial       NUMERIC := 0;
  v_prob_operational     NUMERIC := 0;
  v_prob_reputational    NUMERIC := 0;
  v_prob_compliance      NUMERIC := 0;

  -- Per-dimension impact
  v_impact_legal         NUMERIC := 0;
  v_impact_financial     NUMERIC := 0;
  v_impact_operational   NUMERIC := 0;
  v_impact_reputational  NUMERIC := 0;
  v_impact_compliance    NUMERIC := 0;

  -- Per-dimension scores (0..100)
  v_dim_legal            INTEGER;
  v_dim_financial        INTEGER;
  v_dim_operational      INTEGER;
  v_dim_reputational     INTEGER;
  v_dim_compliance       INTEGER;
  v_health_score         INTEGER;

  -- Per-dimension reason code arrays
  v_reasons_legal        JSONB := '[]'::jsonb;
  v_reasons_financial    JSONB := '[]'::jsonb;
  v_reasons_operational  JSONB := '[]'::jsonb;
  v_reasons_reputational JSONB := '[]'::jsonb;
  v_reasons_compliance   JSONB := '[]'::jsonb;

  -- MaR computation (QA W4: explicit accumulator declarations)
  v_mar_total                 NUMERIC := NULL;
  v_mar_currency              CHAR(3) := 'AED';
  v_contributing_correlations JSONB   := '[]'::jsonb;   -- QA W4 accumulator
  v_clause_id_array           JSONB   := '[]'::jsonb;   -- QA W4 accumulator

  -- Loop vars
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
  -- Step 0 — Validate triggered_by against enum (S2-25 explicit ERRCODE)
  IF p_triggered_by NOT IN ('signal','clause_change','weight_change','scheduled','manual','bootstrap') THEN
    RAISE EXCEPTION 'invalid triggered_by: %', p_triggered_by USING ERRCODE = '22023';
  END IF;

  -- Step 1 — S2-23 FK pre-validation (contract exists + active)
  -- DEFECT-3 fix: contract table has no tenant_id column (M0 design — tenant resolved from GUC).
  -- v_tenant_id sourced from app.current_tenant_id GUC; see db-impl-defect-report.md DEFECT-3.
  SELECT id, value_aed, currency, contract_type, emirate
  INTO   v_contract_row
  FROM   contract
  WHERE  id = p_contract_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract with id % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  -- QA S2 W3 patch: currency AED guard (inserted between Step 1 and Step 2/3)
  -- ERROR CONDITION from db-design.md §2.1 line 578: contract currency must be AED in v1
  IF v_contract_row.currency IS NOT NULL AND v_contract_row.currency != 'AED' THEN
    RAISE EXCEPTION 'contract currency must be AED in v1 (got %)', v_contract_row.currency
      USING ERRCODE = '22023';
  END IF;

  -- Step 2 — Resolve actor sentinel (S2-20: 0 → NULL)
  v_actor_id := p_actor_id;
  IF v_actor_id = 0 THEN v_actor_id := NULL; END IF;

  -- Step 3 — Concurrency: 60s dedup window check (S2-17 FOR UPDATE)
  SELECT id INTO v_existing_id
  FROM   risk_score
  WHERE  contract_id  = p_contract_id
    AND  triggered_by = p_triggered_by
    AND  calculated_at >= NOW() - INTERVAL '60 seconds'
  ORDER BY calculated_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_existing_id IS NOT NULL THEN
    -- Return existing snapshot with "deduplicated":true note
    RETURN jsonb_build_object(
      'riskScoreId',  v_existing_id,
      'contractId',   p_contract_id,
      'deduplicated', TRUE,
      'note',         'snapshot exists within 60s dedup window'
    );
  END IF;

  -- Step 4 — Load active correlations for this contract (direct read — NOT via fn_correlation_list per S2-19)
  -- DEFINER context bypasses RLS; explicit tenant_id filter belt-and-suspenders.
  SELECT array_agg(jsonb_build_object(
    'correlationId',     c.id,
    'ruleId',            c.rule_id,
    'signalId',          c.signal_id,
    'confidence',        c.confidence,
    'matchReason',       c.match_reason,
    'matchEntities',     c.match_entities,
    'sourceReliability', COALESCE(s.source_reliability, 1.0)
  )) INTO v_correlations
  FROM   correlation c
  JOIN   osint_signal sig ON sig.id = c.signal_id
  JOIN   osint_source s   ON s.id   = sig.osint_source_id
  WHERE  c.tenant_id   = v_tenant_id
    AND  c.contract_id = p_contract_id
    AND  c.status      = 'active'
    AND  c.is_active   = TRUE;
  -- v_correlations may be NULL (no firings) — handled gracefully (AC-S16-03)

  -- Step 5 — Load scoring config (3 system_setting rows)
  SELECT value INTO v_weights
    FROM system_setting WHERE key = 'scoring.weights' AND is_active = TRUE;
  IF v_weights IS NULL THEN
    RAISE EXCEPTION 'scoring.weights config missing' USING ERRCODE = '22023';
  END IF;
  v_weights_version := v_weights->>'version';

  -- Validate weights sum to 1.0 ± 0.001
  v_weights_sum := (v_weights->>'legal')::numeric
                 + (v_weights->>'financial')::numeric
                 + (v_weights->>'operational')::numeric
                 + (v_weights->>'reputational')::numeric
                 + (v_weights->>'compliance')::numeric;
  IF ABS(v_weights_sum - 1.0) > 0.001 THEN
    RAISE EXCEPTION 'scoring.weights sum != 1.0 (actual: %)', v_weights_sum
      USING ERRCODE = '22023';
  END IF;

  SELECT value INTO v_exposure_defaults
    FROM system_setting WHERE key = 'scoring.exposure_fraction_defaults' AND is_active = TRUE;
  SELECT value INTO v_impact_multipliers
    FROM system_setting WHERE key = 'scoring.impact_multipliers' AND is_active = TRUE;
  -- Defensive fallback if missing
  v_exposure_defaults  := COALESCE(v_exposure_defaults,  '{}'::jsonb);
  v_impact_multipliers := COALESCE(v_impact_multipliers, '{}'::jsonb);

  -- Resolve exposure fraction for this contract_type (case-insensitive normalize)
  v_contract_type_key := lower(COALESCE(v_contract_row.contract_type, ''));
  v_exposure_fraction := COALESCE(
    NULLIF(v_exposure_defaults->>v_contract_type_key, '')::numeric,
    (v_exposure_defaults->>'default')::numeric,
    0.10  -- final fallback
  );

  -- Step 6 — Load impact factor inputs from contract_clause_extracted (partial-coverage tolerant)
  SELECT
    bool_or((parameters->>'indemnity_scope')::text = 'broad')               AS has_broad_indemnity,
    COALESCE(SUM((parameters->>'liability_cap_value')::numeric), 0)          AS total_liability_cap,
    bool_or(COALESCE((parameters->>'public_visibility')::boolean, FALSE))    AS is_public,
    COUNT(*) FILTER (WHERE COALESCE((parameters->>'regulatory_linkage')::boolean, FALSE))  AS regulatory_clauses,
    COUNT(*) FILTER (WHERE COALESCE((parameters->>'critical_path_impact')::boolean, FALSE)) AS critical_path_clauses,
    bool_or(COALESCE((parameters->>'single_source_dependency')::boolean, FALSE)) AS has_single_source
  INTO v_clause_signals
  FROM contract_clause_extracted
  WHERE contract_id = p_contract_id AND is_active = TRUE;
  -- All fields default to 0/FALSE if no clauses extracted (graceful degradation per A5)

  -- Step 7 — Compute per-dimension probability (A4 — × 100 scaling from [0,1] sourceReliability)
  -- Iterate correlations and accumulate per-dimension probability contributions
  IF v_correlations IS NOT NULL THEN
    FOREACH v_corr IN ARRAY v_correlations LOOP
      v_rule_id    := v_corr->>'ruleId';
      v_confidence := (v_corr->>'confidence')::numeric;
      v_source_rel := (v_corr->>'sourceReliability')::numeric;
      v_prob_contrib := v_confidence * v_source_rel;  -- in [0,1]; × 100 for dim score range

      -- Dimension routing by rule_id prefix (v1 hardcoded mapping)
      -- 'rule.sanctions.*' → legal + compliance
      IF v_rule_id LIKE 'rule.sanctions.%' OR v_rule_id LIKE 'rule.regulatory.%' THEN
        v_prob_legal       := v_prob_legal       + 100 * v_prob_contrib;
        v_prob_compliance  := v_prob_compliance  + 100 * v_prob_contrib;
        v_reasons_legal    := v_reasons_legal    || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
        v_reasons_compliance := v_reasons_compliance || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      -- 'rule.market.*' → financial
      ELSIF v_rule_id LIKE 'rule.market.%' THEN
        v_prob_financial   := v_prob_financial   + 100 * v_prob_contrib;
        v_reasons_financial := v_reasons_financial || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      -- 'rule.geopolitical.*' → operational + reputational
      ELSIF v_rule_id LIKE 'rule.geopolitical.%' THEN
        v_prob_operational    := v_prob_operational    + 100 * v_prob_contrib;
        v_prob_reputational   := v_prob_reputational   + 100 * v_prob_contrib;
        v_reasons_operational    := v_reasons_operational    || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
        v_reasons_reputational   := v_reasons_reputational   || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      -- 'rule.cyber.*' → operational + reputational + compliance
      ELSIF v_rule_id LIKE 'rule.cyber.%' THEN
        v_prob_operational   := v_prob_operational   + 100 * v_prob_contrib;
        v_prob_reputational  := v_prob_reputational  + 100 * v_prob_contrib;
        v_prob_compliance    := v_prob_compliance    + 100 * v_prob_contrib;
        v_reasons_operational   := v_reasons_operational   || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
        v_reasons_reputational  := v_reasons_reputational  || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
        v_reasons_compliance    := v_reasons_compliance    || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      -- 'rule.disruption.*' → operational + financial
      ELSIF v_rule_id LIKE 'rule.disruption.%' THEN
        v_prob_operational  := v_prob_operational  + 100 * v_prob_contrib;
        v_prob_financial    := v_prob_financial    + 100 * v_prob_contrib;
        v_reasons_operational  := v_reasons_operational  || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
        v_reasons_financial    := v_reasons_financial    || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      -- 'rule.counterparty.*' → financial + legal + reputational
      ELSIF v_rule_id LIKE 'rule.counterparty.%' THEN
        v_prob_financial    := v_prob_financial    + 100 * v_prob_contrib;
        v_prob_legal        := v_prob_legal        + 100 * v_prob_contrib;
        v_prob_reputational := v_prob_reputational + 100 * v_prob_contrib;
        v_reasons_financial    := v_reasons_financial    || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
        v_reasons_legal        := v_reasons_legal        || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
        v_reasons_reputational := v_reasons_reputational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSE
        -- Unknown rule prefix: spread across all dims equally
        v_prob_legal        := v_prob_legal        + 100 * v_prob_contrib / 5;
        v_prob_financial    := v_prob_financial    + 100 * v_prob_contrib / 5;
        v_prob_operational  := v_prob_operational  + 100 * v_prob_contrib / 5;
        v_prob_reputational := v_prob_reputational + 100 * v_prob_contrib / 5;
        v_prob_compliance   := v_prob_compliance   + 100 * v_prob_contrib / 5;
      END IF;
    END LOOP;
  END IF;

  -- Clamp probabilities to 0..100
  v_prob_legal        := LEAST(100, GREATEST(0, ROUND(v_prob_legal)));
  v_prob_financial    := LEAST(100, GREATEST(0, ROUND(v_prob_financial)));
  v_prob_operational  := LEAST(100, GREATEST(0, ROUND(v_prob_operational)));
  v_prob_reputational := LEAST(100, GREATEST(0, ROUND(v_prob_reputational)));
  v_prob_compliance   := LEAST(100, GREATEST(0, ROUND(v_prob_compliance)));

  -- Step 8 — Compute per-dimension impact (heuristics from clause signals + contract attrs)
  -- Legal: broad indemnity → 80; liability_cap > 10M → +40, > 1M → +20
  v_impact_legal :=
      CASE WHEN v_clause_signals.has_broad_indemnity THEN 80 ELSE 0 END
    + CASE WHEN v_clause_signals.total_liability_cap > 10000000 THEN 40
           WHEN v_clause_signals.total_liability_cap > 1000000  THEN 20
           ELSE 0 END;
  v_impact_legal := LEAST(100, GREATEST(0, v_impact_legal));
  IF v_clause_signals.has_broad_indemnity THEN
    v_reasons_legal := v_reasons_legal || jsonb_build_array('clause type broad_indemnity → elevated legal impact');
  END IF;

  -- Financial: base = round(100 * exposure_fraction); +20 if value_aed > 100M
  v_impact_financial :=
      ROUND(100 * v_exposure_fraction)
    + CASE WHEN v_contract_row.value_aed > 100000000 THEN 20 ELSE 0 END;
  v_impact_financial := LEAST(100, GREATEST(0, v_impact_financial));
  v_reasons_financial := v_reasons_financial || jsonb_build_array('exposure_fraction ' || v_exposure_fraction);

  -- Operational: critical_path_clauses × 25 + 10 if has_single_source
  v_impact_operational :=
      v_clause_signals.critical_path_clauses * 25
    + CASE WHEN v_clause_signals.has_single_source THEN 10 ELSE 0 END;
  v_impact_operational := LEAST(100, GREATEST(0, v_impact_operational));
  IF v_clause_signals.has_single_source THEN
    v_reasons_operational := v_reasons_operational || jsonb_build_array('clause type single_source_dependency → elevated operational impact');
  END IF;

  -- Reputational: public contract → 80, else 30
  v_impact_reputational := CASE WHEN v_clause_signals.is_public THEN 80 ELSE 30 END;
  v_reasons_reputational := v_reasons_reputational || jsonb_build_array('public_visibility: ' || v_clause_signals.is_public);

  -- Compliance: regulatory_clauses × 30
  v_impact_compliance := LEAST(100, GREATEST(0, v_clause_signals.regulatory_clauses * 30));
  IF v_clause_signals.regulatory_clauses > 0 THEN
    v_reasons_compliance := v_reasons_compliance || jsonb_build_array('regulatory_clauses: ' || v_clause_signals.regulatory_clauses);
  END IF;

  -- Step 9 — Compose dim_X scores (prob × impact / 100, clamped 0..100)
  v_dim_legal        := LEAST(100, GREATEST(0, ROUND(v_prob_legal        * v_impact_legal        / 100.0)));
  v_dim_financial    := LEAST(100, GREATEST(0, ROUND(v_prob_financial    * v_impact_financial    / 100.0)));
  v_dim_operational  := LEAST(100, GREATEST(0, ROUND(v_prob_operational  * v_impact_operational  / 100.0)));
  v_dim_reputational := LEAST(100, GREATEST(0, ROUND(v_prob_reputational * v_impact_reputational / 100.0)));
  v_dim_compliance   := LEAST(100, GREATEST(0, ROUND(v_prob_compliance   * v_impact_compliance   / 100.0)));

  -- Step 10 — Compose Health Score (AC-S1-02: equals round(SUM(dim_X × weight_X)) within ±1)
  v_health_score := LEAST(100, GREATEST(0, ROUND(
      v_dim_legal        * (v_weights->>'legal')::numeric
    + v_dim_financial    * (v_weights->>'financial')::numeric
    + v_dim_operational  * (v_weights->>'operational')::numeric
    + v_dim_reputational * (v_weights->>'reputational')::numeric
    + v_dim_compliance   * (v_weights->>'compliance')::numeric
  )));

  -- Step 11 — Compute MaR per correlation + total (QA W4: explicit accumulator loop)
  -- v_contributing_correlations declared at top; accumulated here
  IF v_contract_row.value_aed IS NOT NULL AND v_correlations IS NOT NULL THEN
    v_mar_total := 0;
    FOREACH v_corr IN ARRAY v_correlations LOOP
      v_confidence := (v_corr->>'confidence')::numeric;
      v_source_rel := (v_corr->>'sourceReliability')::numeric;
      v_rule_id    := v_corr->>'ruleId';

      -- Compute impact multiplier (multiplicative composition)
      v_impact_mult := 1.0;
      IF v_rule_id LIKE 'rule.counterparty.%' THEN
        v_impact_mult := v_impact_mult * COALESCE((v_impact_multipliers->>'single_source_dependency')::numeric, 1.0);
      END IF;
      IF v_clause_signals.regulatory_clauses > 0 THEN
        v_impact_mult := v_impact_mult * COALESCE((v_impact_multipliers->>'regulatory_linkage')::numeric, 1.0);
      END IF;
      IF v_clause_signals.critical_path_clauses > 0 THEN
        v_impact_mult := v_impact_mult * COALESCE((v_impact_multipliers->>'critical_path_impact')::numeric, 1.0);
      END IF;
      -- Cap multiplier at 3.0 to prevent runaway (defensive)
      v_impact_mult := LEAST(3.0, v_impact_mult);

      v_corr_mar := v_contract_row.value_aed
                  * v_exposure_fraction
                  * (v_confidence * v_source_rel)
                  * v_impact_mult;

      v_mar_total := v_mar_total + v_corr_mar;

      -- Accumulate contributing_correlations array (QA W4)
      v_contributing_correlations := v_contributing_correlations || jsonb_build_array(jsonb_build_object(
        'correlationId',       (v_corr->>'correlationId')::bigint,
        'ruleId',              v_rule_id,
        'signalId',            (v_corr->>'signalId')::bigint,
        'confidence',          v_confidence,
        'sourceReliability',   v_source_rel,
        'probability',         ROUND(v_confidence * v_source_rel * 100, 2),
        'impactMultiplier',    v_impact_mult,
        'marContribution',     ROUND(v_corr_mar, 2),
        'dimensionsAffected',  CASE
          WHEN v_rule_id LIKE 'rule.sanctions.%'    THEN '["legal","compliance"]'::jsonb
          WHEN v_rule_id LIKE 'rule.regulatory.%'   THEN '["legal","compliance"]'::jsonb
          WHEN v_rule_id LIKE 'rule.market.%'        THEN '["financial"]'::jsonb
          WHEN v_rule_id LIKE 'rule.geopolitical.%'  THEN '["operational","reputational"]'::jsonb
          WHEN v_rule_id LIKE 'rule.cyber.%'         THEN '["operational","reputational","compliance"]'::jsonb
          WHEN v_rule_id LIKE 'rule.disruption.%'    THEN '["operational","financial"]'::jsonb
          WHEN v_rule_id LIKE 'rule.counterparty.%'  THEN '["financial","legal","reputational"]'::jsonb
          ELSE '["legal","financial","operational","reputational","compliance"]'::jsonb
        END
      ));
    END LOOP;
  ELSE
    -- No value_aed or no correlations: mar_total stays NULL (or 0 if value_aed present but no correlations)
    IF v_contract_row.value_aed IS NOT NULL THEN
      v_mar_total := 0;
    END IF;
  END IF;

  -- Step 12 — Build clause_id_array (QA W4: explicit accumulator — for contributingClauses in explanation)
  -- Collect extracted clause IDs for this contract that have match_evidence linkage
  SELECT COALESCE(jsonb_agg(cce.id ORDER BY cce.id), '[]'::jsonb)
  INTO   v_clause_id_array
  FROM   contract_clause_extracted cce
  WHERE  cce.contract_id = p_contract_id
    AND  cce.is_active   = TRUE;

  -- Build explanation JSONB (reason codes per dimension)
  v_explanation := jsonb_build_object(
    'dimensions', jsonb_build_object(
      'legal',        jsonb_build_object('score', v_dim_legal,        'probability', v_prob_legal,        'impact', v_impact_legal,        'reasons', v_reasons_legal),
      'financial',    jsonb_build_object('score', v_dim_financial,    'probability', v_prob_financial,    'impact', v_impact_financial,    'reasons', v_reasons_financial),
      'operational',  jsonb_build_object('score', v_dim_operational,  'probability', v_prob_operational,  'impact', v_impact_operational,  'reasons', v_reasons_operational),
      'reputational', jsonb_build_object('score', v_dim_reputational, 'probability', v_prob_reputational, 'impact', v_impact_reputational, 'reasons', v_reasons_reputational),
      'compliance',   jsonb_build_object('score', v_dim_compliance,   'probability', v_prob_compliance,   'impact', v_impact_compliance,   'reasons', v_reasons_compliance)
    ),
    'marFormula', jsonb_build_object(
      'contractValue',    v_contract_row.value_aed,
      'exposureFraction', v_exposure_fraction,
      'probability',      NULL,
      'impactMultiplier', NULL,
      'marValue',         v_mar_total
    ),
    'weightsAtCalculation', jsonb_build_object(
      'legal',        (v_weights->>'legal')::numeric,
      'financial',    (v_weights->>'financial')::numeric,
      'operational',  (v_weights->>'operational')::numeric,
      'reputational', (v_weights->>'reputational')::numeric,
      'compliance',   (v_weights->>'compliance')::numeric
    ),
    'contributingClauses', v_clause_id_array   -- QA W4: explicitly accumulated above
  );

  -- Step 13 — INSERT risk_score row (S2-22: all 18 columns verified against migration 169 DDL)
  -- No updated_at / updated_by / is_active — append-only
  INSERT INTO risk_score (
    tenant_id, contract_id,
    health_score, dim_legal, dim_financial, dim_operational, dim_reputational, dim_compliance,
    mar_value, mar_currency,
    contributing_correlations, explanation,
    weights_version, calculated_at, triggered_by, data_classification,
    created_at, created_by
  ) VALUES (
    v_tenant_id, p_contract_id,
    v_health_score, v_dim_legal, v_dim_financial, v_dim_operational, v_dim_reputational, v_dim_compliance,
    v_mar_total, 'AED',
    v_contributing_correlations, v_explanation,
    v_weights_version, NOW(), p_triggered_by, 'demo',
    NOW(), v_actor_id
  )
  RETURNING id INTO v_risk_score_id;

  -- Step 14 — Refresh latest_risk_score MV (full refresh — v1 demo scale, < 1s NFR-3)
  REFRESH MATERIALIZED VIEW latest_risk_score;

  -- Step 15 — Emit contract_activity 'ai_risk_score_updated' (A6 — reuse existing activity_type)
  -- S2-19: fn_contract_activity_create signature verified: (BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB)
  PERFORM fn_contract_activity_create(
    p_contract_id,
    'ai_risk_score_updated',
    v_actor_id,
    'Risk score recomputed (Health Score: ' || v_health_score || ')',
    'تم إعادة احتساب درجة المخاطر (' || v_health_score || ')',
    jsonb_build_object(
      'riskScoreId',    v_risk_score_id,
      'healthScore',    v_health_score,
      'triggeredBy',    p_triggered_by,
      'weightsVersion', v_weights_version
    )
  );

  -- Step 16 — RETURN summary JSONB
  RETURN jsonb_build_object(
    'riskScoreId',                  v_risk_score_id,
    'contractId',                   p_contract_id,
    'healthScore',                  v_health_score,
    'dimensions', jsonb_build_object(
      'legal',        v_dim_legal,
      'financial',    v_dim_financial,
      'operational',  v_dim_operational,
      'reputational', v_dim_reputational,
      'compliance',   v_dim_compliance
    ),
    'marValue',                     v_mar_total,
    'marCurrency',                  'AED',
    'weightsVersion',               v_weights_version,
    'calculatedAt',                 NOW(),
    'contributingCorrelationCount', COALESCE(array_length(v_correlations, 1), 0),
    'deduplicated',                 FALSE
  );

EXCEPTION
  WHEN OTHERS THEN
    -- S2-26: preserve original SQLSTATE through the catch-all
    RAISE EXCEPTION 'fn_risk_score_compute: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_risk_score_compute(BIGINT, TEXT, BIGINT) IS
  'Computes and persists one risk_score snapshot for one contract. Idempotent within 60s on (contract_id, triggered_by). Reads correlations + clauses + scoring config; emits contract_activity ai_risk_score_updated; refreshes latest_risk_score MV. SECURITY DEFINER (worker / signal / scheduled / bootstrap context). Returns riskScoreId + dimensions + marValue. NFR < 30s. QA W3 patch: AED-only guard. QA W4 patch: explicit contributing_correlations + clause_id_array accumulators.';
REVOKE EXECUTE ON FUNCTION fn_risk_score_compute(BIGINT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_score_compute(BIGINT, TEXT, BIGINT) TO neondb_owner;


-- ============================================================
-- 2. fn_risk_score_explain — primary detail read
-- ============================================================
CREATE OR REPLACE FUNCTION fn_risk_score_explain(
  p_contract_id BIGINT,
  p_actor_id    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id           UUID;
  v_latest              RECORD;
  v_contributing_hydrated JSONB;
BEGIN
  -- Permission gate (S2-25: 42501)
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;

  -- Step 1 — Resolve tenant
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  -- Step 2 — Read latest snapshot from MV (A3: explicit tenant_id filter — non-negotiable)
  -- DEFECT-3 fix: MV column is 'id' (not 'risk_score_id' — design assumed alias that was not in CREATE MV).
  SELECT
    id, tenant_id, contract_id, health_score,
    dim_legal, dim_financial, dim_operational, dim_reputational, dim_compliance,
    mar_value, mar_currency, contributing_correlations, explanation,
    weights_version, calculated_at, triggered_by
  INTO v_latest
  FROM   latest_risk_score
  WHERE  contract_id = p_contract_id
    AND  tenant_id   = v_tenant_id;   -- A3 non-negotiable tenant filter

  IF NOT FOUND THEN
    -- AC-S9-02: contract has no score history yet
    RAISE EXCEPTION 'risk_score for contract % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;

  -- Step 3 — Hydrate contributing_correlations[] with correlation + signal + clause details
  SELECT jsonb_agg(jsonb_build_object(
    'correlationId',     c.id,
    'ruleId',            c.rule_id,
    'ruleVersionHash',   c.rule_version_hash,
    'confidence',        c.confidence,
    'matchReason',       c.match_reason,
    'status',            c.status,
    'sourceReliability', COALESCE(s.source_reliability, 1.0),
    'probability',       ROUND(100 * c.confidence * COALESCE(s.source_reliability, 1.0)),
    'signal', jsonb_build_object(
      'id',         sig.id,
      'titleEn',    sig.title_en,
      'titleAr',    sig.title_ar,
      'signalKind', sig.signal_kind,
      'occurredAt', sig.occurred_at
    ),
    'marContribution',    (cc.elem->>'marContribution')::numeric,
    'impactMultiplier',   (cc.elem->>'impactMultiplier')::numeric,
    'dimensionsAffected', cc.elem->'dimensionsAffected',
    'matchedClause',      (
      SELECT jsonb_build_object('id', cce.id, 'clauseTypeV2', cce.clause_type_v2, 'snippet', LEFT(cce.text_excerpts::text, 240))
      FROM   contract_clause_extracted cce
      WHERE  cce.contract_id = c.contract_id
        AND  cce.is_active   = TRUE
        AND  c.match_evidence ? 'clauseId'
        AND  cce.id = (c.match_evidence->>'clauseId')::bigint
      LIMIT 1
    )
  ))
  INTO v_contributing_hydrated
  FROM   jsonb_array_elements(v_latest.contributing_correlations) WITH ORDINALITY AS cc(elem, ord)
  JOIN   correlation c    ON c.id  = (cc.elem->>'correlationId')::bigint
  JOIN   osint_signal sig ON sig.id = c.signal_id
  JOIN   osint_source s   ON s.id   = sig.osint_source_id
  WHERE  c.tenant_id = v_tenant_id;

  -- Step 4 — Compose return JSONB
  RETURN jsonb_build_object(
    'riskScoreId',              v_latest.id,
    'contractId',               v_latest.contract_id,
    'healthScore',              v_latest.health_score,
    'dimensions',               v_latest.explanation->'dimensions',
    'marFormula',               v_latest.explanation->'marFormula',
    'marValue',                 v_latest.mar_value,
    'marCurrency',              v_latest.mar_currency,
    'weightsVersion',           v_latest.weights_version,
    'weightsAtCalculation',     v_latest.explanation->'weightsAtCalculation',
    'contributingCorrelations', COALESCE(v_contributing_hydrated, '[]'::jsonb),
    'calculatedAt',             v_latest.calculated_at,
    'triggeredBy',              v_latest.triggered_by
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_score_explain: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_risk_score_explain(BIGINT, BIGINT) IS
  'Latest risk_score detail for one contract with hydrated contributing_correlations (rule + signal + matched clause). Reads via latest_risk_score MV with mandatory tenant_id filter (A3). Permission: score.read.';
REVOKE EXECUTE ON FUNCTION fn_risk_score_explain(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_score_explain(BIGINT, BIGINT) TO neondb_owner;


-- ============================================================
-- 3. fn_risk_score_history — history list
-- ============================================================
CREATE OR REPLACE FUNCTION fn_risk_score_history(
  p_contract_id BIGINT,
  p_window_days INTEGER,
  p_actor_id    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_snapshots JSONB;
BEGIN
  -- Permission gate (S2-25: 42501)
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;

  -- Step 1 — Validate window (S2-25: 22023)
  IF p_window_days NOT IN (30, 90, 180) THEN
    RAISE EXCEPTION 'windowDays must be 30, 90, or 180 (got %)', p_window_days
      USING ERRCODE = '22023';
  END IF;

  -- Step 2 — Resolve tenant + verify contract exists (S2-23)
  -- DEFECT-3 fix: contract table has no tenant_id column — omit from FK check predicate.
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF NOT EXISTS (
    SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'contract with id % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;

  -- Step 3 — Read history (uses idx_risk_score_tenant_contract_calc)
  SELECT jsonb_agg(jsonb_build_object(
    'riskScoreId',     id,
    'calculatedAt',    calculated_at,
    'healthScore',     health_score,
    'dimLegal',        dim_legal,
    'dimFinancial',    dim_financial,
    'dimOperational',  dim_operational,
    'dimReputational', dim_reputational,
    'dimCompliance',   dim_compliance,
    'marValue',        mar_value,
    'marCurrency',     mar_currency,
    'triggeredBy',     triggered_by,
    'weightsVersion',  weights_version
  ) ORDER BY calculated_at ASC)  -- ascending for chart rendering (AC-S11-04)
  INTO   v_snapshots
  FROM   risk_score
  WHERE  contract_id   = p_contract_id
    AND  tenant_id     = v_tenant_id
    AND  calculated_at >= NOW() - (p_window_days || ' days')::interval;

  -- Step 4 — RETURN
  RETURN jsonb_build_object(
    'contractId', p_contract_id,
    'windowDays', p_window_days,
    'snapshots',  COALESCE(v_snapshots, '[]'::jsonb),
    'count',      jsonb_array_length(COALESCE(v_snapshots, '[]'::jsonb))
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_score_history: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_risk_score_history(BIGINT, INTEGER, BIGINT) IS
  'Risk score history for one contract over 30/90/180-day window. Ascending order for chart rendering (AC-S11-04). Permission: score.read.';
REVOKE EXECUTE ON FUNCTION fn_risk_score_history(BIGINT, INTEGER, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_score_history(BIGINT, INTEGER, BIGINT) TO neondb_owner;


-- ============================================================
-- 4. fn_score_recompute_for_signal — worker dispatch
-- ============================================================
CREATE OR REPLACE FUNCTION fn_score_recompute_for_signal(
  p_signal_id BIGINT,
  p_actor_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
  v_affected_contract_ids BIGINT[];
  v_contract_id           BIGINT;
  v_result                JSONB;
  v_recomputed_ids        BIGINT[] := ARRAY[]::bigint[];
  v_dedup_count           INTEGER  := 0;
BEGIN
  -- Step 1 — S2-23 FK pre-validation (signal exists)
  IF NOT EXISTS (SELECT 1 FROM osint_signal WHERE id = p_signal_id) THEN
    RAISE EXCEPTION 'osint_signal with id % not found', p_signal_id USING ERRCODE = 'P0002';
  END IF;

  -- Step 2 — Identify distinct affected contracts (S2-22b: correlation.signal_id indexed)
  SELECT array_agg(DISTINCT contract_id ORDER BY contract_id)
  INTO   v_affected_contract_ids
  FROM   correlation
  WHERE  signal_id = p_signal_id
    AND  status    = 'active'
    AND  is_active = TRUE;

  IF v_affected_contract_ids IS NULL OR array_length(v_affected_contract_ids, 1) IS NULL THEN
    RETURN jsonb_build_object(
      'signalId',                  p_signal_id,
      'affectedContractCount',     0,
      'recomputedRiskScoreIds',    '[]'::jsonb,
      'deduplicatedContractCount', 0
    );
  END IF;

  -- Step 3 — Dispatch per-contract recompute (60s dedup inside fn_risk_score_compute absorbs thundering herd)
  -- S2-19: fn_risk_score_compute signature (BIGINT, TEXT, BIGINT) — self-reference, matches this CR-F
  FOREACH v_contract_id IN ARRAY v_affected_contract_ids LOOP
    v_result := fn_risk_score_compute(v_contract_id, 'signal', p_actor_id);
    IF (v_result->>'deduplicated')::boolean THEN
      v_dedup_count := v_dedup_count + 1;
    ELSE
      v_recomputed_ids := v_recomputed_ids || (v_result->>'riskScoreId')::bigint;
    END IF;
  END LOOP;

  -- Step 4 — RETURN summary
  RETURN jsonb_build_object(
    'signalId',                  p_signal_id,
    'affectedContractCount',     array_length(v_affected_contract_ids, 1),
    'recomputedRiskScoreIds',    to_jsonb(v_recomputed_ids),
    'deduplicatedContractCount', v_dedup_count
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_score_recompute_for_signal: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_score_recompute_for_signal(BIGINT, BIGINT) IS
  'Worker fn — dispatches per-contract risk_score recomputes for all contracts correlated against a given signal. Called from score-recompute.worker.ts on PG NOTIFY ''correlation_inserted''. SECURITY DEFINER (worker context). Returns affected/recomputed/deduplicated counts.';
REVOKE EXECUTE ON FUNCTION fn_score_recompute_for_signal(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_score_recompute_for_signal(BIGINT, BIGINT) TO neondb_owner;


-- ============================================================
-- 5. fn_score_recompute_for_weight_change — bulk recompute
-- ============================================================
CREATE OR REPLACE FUNCTION fn_score_recompute_for_weight_change(
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
  v_weights_version TEXT;
  v_tenant_id       UUID;
  v_contract_id     BIGINT;
  v_started_at      TIMESTAMPTZ;
  v_total           INTEGER := 0;
  v_recomputed      INTEGER := 0;
  v_failed_ids      BIGINT[] := ARRAY[]::bigint[];
BEGIN
  -- Permission gate (reject system-actor in bulk recompute context)
  IF p_actor_id IS NULL OR p_actor_id = 0 THEN
    RAISE EXCEPTION 'p_actor_id must be a non-system actor for bulk recompute'
      USING ERRCODE = '42501';
  END IF;
  -- S2-19: fn_current_user_has_permission signature (TEXT) RETURNS BOOLEAN
  IF NOT fn_current_user_has_permission('score.weights.manage') THEN
    RAISE EXCEPTION 'Permission denied: score.weights.manage required' USING ERRCODE = '42501';
  END IF;

  -- Step 1 — Capture starting weightsVersion (audit anchor)
  SELECT value->>'version' INTO v_weights_version
    FROM system_setting WHERE key = 'scoring.weights' AND is_active = TRUE;

  -- Step 2 — Tenant scope from GUC
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  -- Step 3 — Iterate all active contracts
  -- DEFECT-3 fix: contract table has no tenant_id column — tenant scoping happens inside fn_risk_score_compute via GUC.
  -- Per-contract SAVEPOINT via nested BEGIN/EXCEPTION (R11 mitigation — partial failure isolates)
  v_started_at := clock_timestamp();

  FOR v_contract_id IN
    SELECT id FROM contract
    WHERE  is_active = TRUE
    ORDER BY id
  LOOP
    v_total := v_total + 1;
    BEGIN
      -- S2-19: fn_risk_score_compute signature (BIGINT, TEXT, BIGINT)
      PERFORM fn_risk_score_compute(v_contract_id, 'weight_change', p_actor_id);
      v_recomputed := v_recomputed + 1;
    EXCEPTION
      WHEN OTHERS THEN
        -- S2-26: log + continue — don't roll back the whole bulk job
        v_failed_ids := v_failed_ids || v_contract_id;
        RAISE NOTICE 'fn_score_recompute_for_weight_change: contract % failed: %', v_contract_id, SQLERRM;
    END;
  END LOOP;

  -- Step 4 — RETURN summary
  RETURN jsonb_build_object(
    'weightsVersion',         v_weights_version,
    'totalContractsTargeted', v_total,
    'recomputedCount',        v_recomputed,
    'failedContractIds',      to_jsonb(v_failed_ids),
    'elapsedMs',              EXTRACT(MILLISECONDS FROM (clock_timestamp() - v_started_at))::integer
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_score_recompute_for_weight_change: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_score_recompute_for_weight_change(BIGINT) IS
  'Bulk-recompute all active contracts in the calling tenant after weight change. Per-contract SAVEPOINT — partial failure isolates (R11). Permission: score.weights.manage. SECURITY DEFINER.';
REVOKE EXECUTE ON FUNCTION fn_score_recompute_for_weight_change(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_score_recompute_for_weight_change(BIGINT) TO neondb_owner;


-- ============================================================
-- 6. fn_avar_aggregate — AVaR roll-up (S2-24 critical)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_avar_aggregate(
  p_filters     JSONB,
  p_window_days INTEGER,
  p_actor_id    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_group_by    TEXT;
  v_tenant_id   UUID;
  v_filter_bu   TEXT;
  v_filter_geo  TEXT;
  v_filter_cp   BIGINT;
  v_filter_kind TEXT;
  v_window_from TIMESTAMPTZ;
  v_result      JSONB;
BEGIN
  -- Permission gate (S2-25: 42501)
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;

  -- Step 1 — Validate windowDays (S2-25: 22023)
  IF p_window_days < 1 OR p_window_days > 365 THEN
    RAISE EXCEPTION 'windowDays out of [1, 365] (got %)', p_window_days USING ERRCODE = '22023';
  END IF;

  -- Step 2 — Resolve filters
  v_group_by := COALESCE(p_filters->>'groupBy', 'business_unit');
  IF v_group_by NOT IN ('business_unit','counterparty_id','counterparty_chain','geography','risk_kind') THEN
    RAISE EXCEPTION 'groupBy out of allowed set (got %)', v_group_by USING ERRCODE = '22023';
  END IF;

  v_tenant_id   := current_setting('app.current_tenant_id', true)::uuid;
  v_filter_bu   := lower(p_filters->>'businessUnit');
  v_filter_geo  := lower(p_filters->>'geography');
  v_filter_cp   := (p_filters->>'counterpartyId')::bigint;
  v_filter_kind := lower(p_filters->>'riskKind');
  v_window_from := NOW() - (p_window_days || ' days')::interval;

  -- Step 3-4 — S2-24 SPLIT-AGGREGATE PATTERN (non-negotiable)
  -- WRONG: jsonb_agg(jsonb_build_object('avar', SUM(mar_value))) — nested aggregate → error
  -- CORRECT: WITH per_bucket AS (SUM + GROUP BY) → outer SELECT jsonb_agg
  --
  -- A3: explicit WHERE tenant_id = v_tenant_id on latest_risk_score (non-negotiable)
  -- Design note #12: counterparty_chain treated as counterparty_id (fn_party_chain_walk absent from live DB)
  WITH filtered AS (
    SELECT
      lrs.contract_id,
      lrs.mar_value,
      lrs.health_score,
      lrs.contributing_correlations,
      lrs.calculated_at,
      c.contract_type,
      c.emirate,
      c.counterparty_id
    FROM   latest_risk_score lrs
    JOIN   contract c ON c.id = lrs.contract_id AND c.is_active = TRUE
    WHERE  lrs.tenant_id     = v_tenant_id             -- A3 explicit MV tenant filter
      AND  lrs.calculated_at >= v_window_from
      AND  (v_filter_bu   IS NULL OR lower(c.contract_type) = v_filter_bu)
      AND  (v_filter_geo  IS NULL OR lower(c.emirate)       = v_filter_geo)
      AND  (v_filter_cp   IS NULL OR c.counterparty_id      = v_filter_cp)
      AND  (v_filter_kind IS NULL OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(lrs.contributing_correlations) AS cc(elem)
        WHERE cc.elem->>'ruleId' LIKE 'rule.' || v_filter_kind || '.%'
      ))
  ),
  per_bucket AS (
    SELECT
      CASE v_group_by
        WHEN 'business_unit'      THEN COALESCE(contract_type,        '(none)')
        WHEN 'geography'          THEN COALESCE(emirate,               '(none)')
        WHEN 'counterparty_id'    THEN COALESCE(counterparty_id::text, '(unknown)')
        -- counterparty_chain treated as counterparty_id (fn_party_chain_walk absent — design note #12)
        WHEN 'counterparty_chain' THEN COALESCE(counterparty_id::text, '(unknown)')
        WHEN 'risk_kind'          THEN '(all)'
        ELSE COALESCE(contract_type, '(none)')
      END                                                               AS bucket_label,
      SUM(mar_value)                                                    AS bucket_avar,
      COUNT(*)                                                          AS bucket_count,
      COUNT(*) FILTER (WHERE mar_value IS NULL)                         AS bucket_no_value_count
    FROM filtered
    GROUP BY bucket_label
  ),
  totals AS (
    SELECT
      SUM(bucket_avar)            AS total_avar,
      SUM(bucket_count)           AS total_contract_count,
      SUM(bucket_no_value_count)  AS no_value_count
    FROM per_bucket
  )
  SELECT jsonb_build_object(
    'totalAvar',      COALESCE((SELECT total_avar FROM totals), 0),
    'currency',       'AED',
    'contractCount',  COALESCE((SELECT total_contract_count FROM totals), 0),
    'windowDays',     p_window_days,
    'groupBy',        v_group_by,
    'noValueCount',   COALESCE((SELECT no_value_count FROM totals), 0),
    'breakdown',      COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'key',           bucket_label,
        'label',         bucket_label,
        'avar',          bucket_avar,
        'contractCount', bucket_count,
        'pctOfTotal',    ROUND(100.0 * bucket_avar / NULLIF((SELECT total_avar FROM totals), 0), 2)
      ) ORDER BY bucket_avar DESC NULLS LAST)
      FROM per_bucket
    ), '[]'::jsonb),
    'deltaVsPriorWindow', (
      -- Prior-window calculation against risk_score directly (MV only has latest)
      -- AC-S5-03: priorAvar/deltaAed/deltaPct
      SELECT jsonb_build_object(
        'priorAvar', COALESCE(SUM(rs.mar_value), 0),
        'deltaAed',  COALESCE((SELECT total_avar FROM totals), 0) - COALESCE(SUM(rs.mar_value), 0),
        'deltaPct',  ROUND(
          100.0 *
          (COALESCE((SELECT total_avar FROM totals), 0) - COALESCE(SUM(rs.mar_value), 0))
          / NULLIF(SUM(rs.mar_value), 0)
        , 2)
      )
      FROM (
        SELECT DISTINCT ON (contract_id) mar_value
        FROM risk_score
        WHERE tenant_id    = v_tenant_id
          AND calculated_at >= NOW() - (2 * p_window_days || ' days')::interval
          AND calculated_at <  NOW() - (p_window_days     || ' days')::interval
        ORDER BY contract_id, calculated_at DESC
      ) rs
    )
  )
  INTO v_result;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_avar_aggregate: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_avar_aggregate(JSONB, INTEGER, BIGINT) IS
  'AVaR roll-up over latest_risk_score for the calling tenant with optional filter + groupBy breakdown. S2-24 SPLIT-AGGREGATE: WITH per_bucket CTE (SUM + GROUP BY) + outer jsonb_agg. A3: explicit tenant_id filter on MV. Design note #12: counterparty_chain treated as counterparty_id (fn_party_chain_walk absent). NFR < 500ms at 100 contracts. Permission: score.read.';
REVOKE EXECUTE ON FUNCTION fn_avar_aggregate(JSONB, INTEGER, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_avar_aggregate(JSONB, INTEGER, BIGINT) TO neondb_owner;


-- ============================================================
-- 7. fn_scoring_weights_get — admin read
-- ============================================================
CREATE OR REPLACE FUNCTION fn_scoring_weights_get(
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_weights            JSONB;
  v_exposure_defaults  JSONB;
  v_impact_multipliers JSONB;
  v_current_meta       JSONB;
  v_history            JSONB;
BEGIN
  -- Permission gate (S2-25: 42501)
  IF NOT fn_current_user_has_permission('score.weights.manage') THEN
    RAISE EXCEPTION 'Permission denied: score.weights.manage required' USING ERRCODE = '42501';
  END IF;

  -- Step 1 — Read 3 scoring config rows
  SELECT value INTO v_weights             FROM system_setting WHERE key = 'scoring.weights'                    AND is_active = TRUE;
  SELECT value INTO v_exposure_defaults   FROM system_setting WHERE key = 'scoring.exposure_fraction_defaults' AND is_active = TRUE;
  SELECT value INTO v_impact_multipliers  FROM system_setting WHERE key = 'scoring.impact_multipliers'         AND is_active = TRUE;

  -- Step 2 — Read updatedAt + updatedBy meta from system_setting row
  SELECT row_to_json(ss.*)::jsonb INTO v_current_meta
  FROM   system_setting ss
  WHERE  ss.key = 'scoring.weights';

  -- Last 10 history rows from audit_log (using live schema: changed_by, no record_id_text)
  SELECT jsonb_agg(jsonb_build_object(
    'version',     new_values->>'version',
    'changedAt',   changed_at,
    'changedById', changed_by
  ) ORDER BY changed_at DESC)
  INTO   v_history
  FROM   audit_log
  WHERE  table_name = 'system_setting'
    AND  action     = 'UPDATE'
    AND  new_values->>'key' = 'scoring.weights'
  LIMIT  10;

  -- Step 3 — RETURN
  RETURN jsonb_build_object(
    'current', jsonb_build_object(
      'legal',         (v_weights->>'legal')::numeric,
      'financial',     (v_weights->>'financial')::numeric,
      'operational',   (v_weights->>'operational')::numeric,
      'reputational',  (v_weights->>'reputational')::numeric,
      'compliance',    (v_weights->>'compliance')::numeric,
      'version',       v_weights->>'version',
      'updatedAt',     v_current_meta->'updated_at',
      'updatedBy',     v_current_meta->'updated_by'
    ),
    'history',                  COALESCE(v_history, '[]'::jsonb),
    'exposureFractionDefaults', v_exposure_defaults,
    'impactMultipliers',        v_impact_multipliers
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_scoring_weights_get: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_scoring_weights_get(BIGINT) IS
  'Read scoring weights config + history + exposure-fraction defaults + impact multipliers. Permission: score.weights.manage.';
REVOKE EXECUTE ON FUNCTION fn_scoring_weights_get(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_scoring_weights_get(BIGINT) TO neondb_owner;


-- ============================================================
-- 8. fn_scoring_weights_set — admin write
-- DEFECT-1 fix in Step 6: audit_log uses changed_by (not changed_by_id); no record_id_text column.
-- Key encoded in old_values/new_values JSONB instead. See db-impl-defect-report.md DEFECT-1.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_scoring_weights_set(
  p_weights  JSONB,
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
AS $$
DECLARE
  v_dim             TEXT;
  v_w               NUMERIC;
  v_sum             NUMERIC := 0;
  v_current_version TEXT;
  v_new_version     TEXT;
  v_new_value       JSONB;
BEGIN
  -- Permission gate (S2-25: 42501)
  IF NOT fn_current_user_has_permission('score.weights.manage') THEN
    RAISE EXCEPTION 'Permission denied: score.weights.manage required' USING ERRCODE = '42501';
  END IF;

  -- Step 1 — Validate all 5 dim keys present + in [0,1]
  FOREACH v_dim IN ARRAY ARRAY['legal','financial','operational','reputational','compliance'] LOOP
    IF NOT (p_weights ? v_dim) THEN
      RAISE EXCEPTION 'weights.% missing', v_dim USING ERRCODE = '22023';
    END IF;
    v_w := (p_weights->>v_dim)::numeric;
    IF v_w IS NULL OR v_w < 0 OR v_w > 1 THEN
      RAISE EXCEPTION 'weights.% out of [0,1] (got %)', v_dim, v_w USING ERRCODE = '22023';
    END IF;
    v_sum := v_sum + v_w;
  END LOOP;

  -- Step 2 — Validate sum to 1.0 ± 0.001
  IF ABS(v_sum - 1.0) > 0.001 THEN
    RAISE EXCEPTION 'weights.sum: weights sum to % (must be 1.0 ± 0.001)', v_sum
      USING ERRCODE = '22023';
  END IF;

  -- Step 3 — Compute new version (monotonic increment; S2-17 FOR UPDATE prevents concurrent race)
  SELECT value->>'version' INTO v_current_version
    FROM system_setting WHERE key = 'scoring.weights' AND is_active = TRUE
    FOR UPDATE;
  IF v_current_version IS NULL THEN v_current_version := '0'; END IF;
  v_new_version := (v_current_version::integer + 1)::text;

  -- Step 4 — Compose new value JSONB (preserve full shape)
  v_new_value := p_weights || jsonb_build_object('version', v_new_version);

  -- Step 5 — UPDATE system_setting (S2-22: columns value + updated_at + updated_by exist on system_setting)
  UPDATE system_setting
     SET value      = v_new_value,
         updated_at = NOW(),
         updated_by = p_actor_id
   WHERE key        = 'scoring.weights';

  -- Step 6 — Explicit audit_log INSERT (Strategy A — system_setting has no audit trigger per R-PA7 pattern)
  -- DEFECT-1 fix: live audit_log schema uses changed_by (not changed_by_id) and has no record_id_text.
  -- Key 'scoring.weights' encoded in old_values/new_values JSONB under 'key' field.
  -- S2-22: columns verified — table_name, record_id, action, old_values, new_values, changed_by, changed_at
  INSERT INTO audit_log (
    table_name, record_id, action,
    old_values, new_values, changed_by, changed_at
  )
  VALUES (
    'system_setting',
    NULL,
    'UPDATE',
    jsonb_build_object('key', 'scoring.weights', 'version', v_current_version),
    jsonb_build_object('key', 'scoring.weights', 'version', v_new_version),
    p_actor_id,
    NOW()
  );

  -- Step 7 — RETURN
  RETURN jsonb_build_object(
    'newVersion',     v_new_version,
    'weightsApplied', v_new_value,
    'totalSum',       v_sum
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_scoring_weights_set: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_scoring_weights_set(JSONB, BIGINT) IS
  'Validate + persist new scoring weights to system_setting. Sum=1.0 ±0.001; each w in [0,1]; bumps version monotonically (FOR UPDATE S2-17). Emits explicit audit_log row (system_setting has no trigger — Strategy A). DEFECT-1: uses changed_by (not changed_by_id); key encoded in JSONB. Permission: score.weights.manage.';
REVOKE EXECUTE ON FUNCTION fn_scoring_weights_set(JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_scoring_weights_set(JSONB, BIGINT) TO neondb_owner;


-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (171, '171_crf_risk_score_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 171;
-- DROP FUNCTION IF EXISTS fn_scoring_weights_set(JSONB, BIGINT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_scoring_weights_get(BIGINT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_avar_aggregate(JSONB, INTEGER, BIGINT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_score_recompute_for_weight_change(BIGINT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_score_recompute_for_signal(BIGINT, BIGINT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_risk_score_history(BIGINT, INTEGER, BIGINT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_risk_score_explain(BIGINT, BIGINT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_risk_score_compute(BIGINT, TEXT, BIGINT) CASCADE;
-- ============================================================
