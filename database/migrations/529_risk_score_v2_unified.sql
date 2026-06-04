-- MIGRATION: 529_risk_score_v2_unified.sql
-- Date: 2026-06-03
-- Description:
--   Replace the legacy fn_risk_score_compute (5-dim probability×impact, then
--   100 − Σ inversion) with an additive, explainable formula whose every
--   addend is configurable by platform_admin via system_setting.
--
--   Three problems this fixes:
--     1. Gauge said "97 · HIGH RISK" while grounded summary said "41 · Medium"
--        on the same contract — two separate pipelines wrote two columns.
--     2. The compute fn inverted the score (100 − Σ), but every consumer
--        (FE gauge, dashboard ORDER BY, grounded summary, narrative) reads
--        the column as risk magnitude (high = bad). Red 97 actually meant
--        "almost no risk" by the function's intent.
--     3. Score had no per-addend traceability — users couldn't see WHY
--        their contract scored 97.
--
--   New formula (additive, max 100, no inversion):
--     score = A + B + C + D + E, clamped to [0, 100]
--       A. External signals       (max 50) — per active correlation:
--          confidence × source_reliability × severity_weight (configurable)
--          where severity comes from osint_signal.severity.
--       B. Value tier             (max 15) — bucketed contract.value_aed
--       C. Duration               (max 10) — bucketed contract length
--       D. Sector complexity      (max 15) — per contract_type lookup
--       E. Clause-derived risk    (max 15) — sum of clause flags, capped
--
--   Every addend is persisted to risk_score.explanation.addends[] so the
--   FE hover-card can render it line-by-line with actual point values.
--
--   ai_risk_score (denormalised cache on contract) is now mirrored by a
--   trigger from risk_score.health_score — there is exactly one source of
--   truth.

BEGIN;

-- ============================================================
-- 0. Widen risk_score.triggered_by CHECK to admit 'config_change'.
--    Added so bulk recomputes triggered by formula tweaks have a
--    distinguishable audit trail vs. signal-driven recalculations.
-- ============================================================
ALTER TABLE risk_score DROP CONSTRAINT IF EXISTS risk_score_triggered_by_check;
ALTER TABLE risk_score ADD CONSTRAINT risk_score_triggered_by_check
  CHECK (triggered_by = ANY (ARRAY[
    'signal','clause_change','weight_change','scheduled','manual','bootstrap','config_change'
  ]));

-- ============================================================
-- 1. New permission: score.config.manage.
-- ============================================================
INSERT INTO permission (code, module, action, description, is_active, created_at)
VALUES ('score.config.manage', 'score', 'config.manage', 'Edit the risk scoring formula configuration (tiers, weights, sector points)', TRUE, CURRENT_TIMESTAMP)
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permission (role_id, permission_id, is_active, created_at)
SELECT r.id, p.id, TRUE, CURRENT_TIMESTAMP
  FROM role r, permission p
 WHERE r.name IN ('Super Admin', 'platform_admin')
   AND p.code = 'score.config.manage'
ON CONFLICT DO NOTHING;

-- ============================================================
-- 2. Seed configurable formula settings under scoring.v2.*
-- ============================================================
INSERT INTO system_setting (key, value, description, category, is_secret, is_active, created_at, updated_at)
VALUES
  ('scoring.v2.signal_severity_weights',
   '{"critical": 30, "high": 20, "medium": 12, "low": 6, "informational": 2}'::jsonb,
   'Points per active correlation by osint_signal.severity. Used in bucket A (external signals).',
   'scoring', FALSE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  ('scoring.v2.signal_bucket_cap',
   '{"cap": 50}'::jsonb,
   'Maximum total points from bucket A (external signals). Stops one noisy contract from being driven to 100 by signals alone.',
   'scoring', FALSE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  ('scoring.v2.value_tiers',
   '{"tiers": [
     {"minAed": 50000000, "points": 15, "label": "AED 50M and above"},
     {"minAed": 5000000,  "points": 10, "label": "AED 5M to 50M"},
     {"minAed": 500000,   "points": 5,  "label": "AED 500K to 5M"}
   ]}'::jsonb,
   'Bucket B (value tier) — first matching tier wins. Tiers are evaluated top-down.',
   'scoring', FALSE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  ('scoring.v2.duration_tiers',
   '{"tiers": [
     {"minMonths": 36, "points": 10, "label": "3 years or longer"},
     {"minMonths": 12, "points": 5,  "label": "1 to 3 years"}
   ]}'::jsonb,
   'Bucket C (duration) — first matching tier wins.',
   'scoring', FALSE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  ('scoring.v2.sector_complexity',
   '{"byType": {
     "gas_spa": 15, "concession": 15,
     "epc": 10, "master_services": 10,
     "vessel_charter": 8, "term_sale": 8,
     "msa": 3, "vendor": 3, "consulting": 3, "services": 3, "partnership": 3, "other": 3,
     "nda": 0, "sow": 0, "employment": 0, "license": 0
   }, "default": 3}'::jsonb,
   'Bucket D (sector complexity) — per contract_type lookup, default applies when type is unknown.',
   'scoring', FALSE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  ('scoring.v2.clause_signals',
   '{"broadIndemnity": 10, "liabilityCapHigh": 5, "singleSource": 5, "regulatorsThreePlus": 5, "cap": 15}'::jsonb,
   'Bucket E (clause-derived) — each flag adds points, sum capped at cap.',
   'scoring', FALSE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  ('scoring.v2.bands',
   '{"lowMax": 29, "mediumMax": 59}'::jsonb,
   'Color-band thresholds. Score 0..lowMax = Low (sage), lowMax+1..mediumMax = Medium (gold), above = High (terracotta).',
   'scoring', FALSE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  description = EXCLUDED.description,
  updated_at = CURRENT_TIMESTAMP;

-- ============================================================
-- 3. fn_risk_scoring_config_get — bundle all 6 settings for admin UI.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_risk_scoring_config_get(p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $fn$
BEGIN
  IF NOT (fn_current_user_has_permission('score.config.manage')
       OR fn_current_user_has_permission('score.weights.manage')
       OR fn_current_user_has_permission('score.read')) THEN
    RAISE EXCEPTION 'Permission denied: score.config.manage required' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'signalSeverityWeights', (SELECT value FROM system_setting WHERE key = 'scoring.v2.signal_severity_weights' AND is_active),
    'signalBucketCap',       (SELECT value FROM system_setting WHERE key = 'scoring.v2.signal_bucket_cap' AND is_active),
    'valueTiers',            (SELECT value FROM system_setting WHERE key = 'scoring.v2.value_tiers' AND is_active),
    'durationTiers',         (SELECT value FROM system_setting WHERE key = 'scoring.v2.duration_tiers' AND is_active),
    'sectorComplexity',      (SELECT value FROM system_setting WHERE key = 'scoring.v2.sector_complexity' AND is_active),
    'clauseSignals',         (SELECT value FROM system_setting WHERE key = 'scoring.v2.clause_signals' AND is_active),
    'bands',                 (SELECT value FROM system_setting WHERE key = 'scoring.v2.bands' AND is_active)
  );
END;
$fn$;

REVOKE EXECUTE ON FUNCTION fn_risk_scoring_config_get(bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_scoring_config_get(bigint) TO neondb_owner;

-- ============================================================
-- 4. fn_risk_scoring_config_set — admin write. Updates one or many keys.
--    Input shape: same as fn_risk_scoring_config_get's output. Any key
--    omitted is left unchanged.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_risk_scoring_config_set(p_input jsonb, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $fn$
DECLARE
  v_updated_keys TEXT[] := ARRAY[]::TEXT[];
BEGIN
  IF NOT fn_current_user_has_permission('score.config.manage') THEN
    RAISE EXCEPTION 'Permission denied: score.config.manage required' USING ERRCODE = '42501';
  END IF;

  IF p_input ? 'signalSeverityWeights' THEN
    UPDATE system_setting SET value = p_input->'signalSeverityWeights', updated_at = CURRENT_TIMESTAMP, updated_by = p_actor_id
     WHERE key = 'scoring.v2.signal_severity_weights';
    v_updated_keys := v_updated_keys || 'signalSeverityWeights';
  END IF;
  IF p_input ? 'signalBucketCap' THEN
    UPDATE system_setting SET value = p_input->'signalBucketCap', updated_at = CURRENT_TIMESTAMP, updated_by = p_actor_id
     WHERE key = 'scoring.v2.signal_bucket_cap';
    v_updated_keys := v_updated_keys || 'signalBucketCap';
  END IF;
  IF p_input ? 'valueTiers' THEN
    UPDATE system_setting SET value = p_input->'valueTiers', updated_at = CURRENT_TIMESTAMP, updated_by = p_actor_id
     WHERE key = 'scoring.v2.value_tiers';
    v_updated_keys := v_updated_keys || 'valueTiers';
  END IF;
  IF p_input ? 'durationTiers' THEN
    UPDATE system_setting SET value = p_input->'durationTiers', updated_at = CURRENT_TIMESTAMP, updated_by = p_actor_id
     WHERE key = 'scoring.v2.duration_tiers';
    v_updated_keys := v_updated_keys || 'durationTiers';
  END IF;
  IF p_input ? 'sectorComplexity' THEN
    UPDATE system_setting SET value = p_input->'sectorComplexity', updated_at = CURRENT_TIMESTAMP, updated_by = p_actor_id
     WHERE key = 'scoring.v2.sector_complexity';
    v_updated_keys := v_updated_keys || 'sectorComplexity';
  END IF;
  IF p_input ? 'clauseSignals' THEN
    UPDATE system_setting SET value = p_input->'clauseSignals', updated_at = CURRENT_TIMESTAMP, updated_by = p_actor_id
     WHERE key = 'scoring.v2.clause_signals';
    v_updated_keys := v_updated_keys || 'clauseSignals';
  END IF;
  IF p_input ? 'bands' THEN
    UPDATE system_setting SET value = p_input->'bands', updated_at = CURRENT_TIMESTAMP, updated_by = p_actor_id
     WHERE key = 'scoring.v2.bands';
    v_updated_keys := v_updated_keys || 'bands';
  END IF;

  RETURN jsonb_build_object(
    'updatedKeys', to_jsonb(v_updated_keys),
    'config',      fn_risk_scoring_config_get(p_actor_id)
  );
END;
$fn$;

REVOKE EXECUTE ON FUNCTION fn_risk_scoring_config_set(jsonb, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_scoring_config_set(jsonb, bigint) TO neondb_owner;

-- ============================================================
-- 5. Rewrite fn_risk_score_compute — additive formula with addends.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_risk_score_compute(p_contract_id bigint, p_triggered_by text, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $fn$
DECLARE
  v_tenant_id            UUID;
  v_actor_id             BIGINT;
  v_contract             RECORD;
  v_duration_months      INTEGER;
  v_severity_weights     JSONB;
  v_signal_cap           INTEGER;
  v_value_tiers          JSONB;
  v_duration_tiers       JSONB;
  v_sector_points        JSONB;
  v_clause_points        JSONB;
  v_bands                JSONB;
  v_existing_id          BIGINT;
  v_risk_score_id        BIGINT;
  v_correlations         RECORD;
  v_addends              JSONB := '[]'::jsonb;
  v_score_a              INTEGER := 0;
  v_score_b              INTEGER := 0;
  v_score_c              INTEGER := 0;
  v_score_d              INTEGER := 0;
  v_score_e              INTEGER := 0;
  v_score_total          INTEGER := 0;
  v_signal_addends       JSONB := '[]'::jsonb;
  v_signal_label         TEXT;
  v_signal_pts           NUMERIC;
  v_clause_signals       RECORD;
  v_clause_addends       JSONB := '[]'::jsonb;
  v_contributing         JSONB := '[]'::jsonb;
  v_mar_total            NUMERIC := NULL;
  v_exposure_fraction    NUMERIC;
  v_exposure_defaults    JSONB;
  v_corr_mar             NUMERIC;
  v_explanation          JSONB;
  v_value_tier           JSONB;
  v_dur_tier             JSONB;
  v_sector_pts           INTEGER;
  v_e_total              INTEGER;
  v_e_cap                INTEGER;
BEGIN
  IF p_triggered_by NOT IN ('signal','clause_change','weight_change','scheduled','manual','bootstrap','config_change') THEN
    RAISE EXCEPTION 'invalid triggered_by: %', p_triggered_by USING ERRCODE = '22023';
  END IF;

  SELECT id, value_aed, currency, contract_type, counterparty_id, start_date, end_date
    INTO v_contract
    FROM contract
   WHERE id = p_contract_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract with id % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;

  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  v_actor_id := p_actor_id;
  IF v_actor_id = 0 THEN v_actor_id := NULL; END IF;

  v_duration_months := COALESCE(
    EXTRACT(YEAR  FROM AGE(v_contract.end_date, v_contract.start_date)) * 12 +
    EXTRACT(MONTH FROM AGE(v_contract.end_date, v_contract.start_date)),
    0
  )::integer;

  -- Load configurable formula bits.
  SELECT value INTO v_severity_weights FROM system_setting WHERE key = 'scoring.v2.signal_severity_weights' AND is_active;
  SELECT (value->>'cap')::integer INTO v_signal_cap FROM system_setting WHERE key = 'scoring.v2.signal_bucket_cap' AND is_active;
  SELECT value INTO v_value_tiers    FROM system_setting WHERE key = 'scoring.v2.value_tiers'    AND is_active;
  SELECT value INTO v_duration_tiers FROM system_setting WHERE key = 'scoring.v2.duration_tiers' AND is_active;
  SELECT value INTO v_sector_points  FROM system_setting WHERE key = 'scoring.v2.sector_complexity' AND is_active;
  SELECT value INTO v_clause_points  FROM system_setting WHERE key = 'scoring.v2.clause_signals'    AND is_active;
  SELECT value INTO v_bands          FROM system_setting WHERE key = 'scoring.v2.bands'             AND is_active;

  IF v_severity_weights IS NULL OR v_value_tiers IS NULL OR v_sector_points IS NULL THEN
    RAISE EXCEPTION 'scoring.v2.* settings missing — apply mig 529' USING ERRCODE = '22023';
  END IF;

  -- 60-second dedup window (preserves the M14 invariant).
  SELECT id INTO v_existing_id
    FROM risk_score
   WHERE contract_id  = p_contract_id
     AND triggered_by = p_triggered_by
     AND calculated_at >= fn_demo_now() - INTERVAL '60 seconds'
   ORDER BY calculated_at DESC LIMIT 1
   FOR UPDATE;
  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object('riskScoreId', v_existing_id, 'contractId', p_contract_id, 'deduplicated', TRUE);
  END IF;

  -- ============================================================
  -- Bucket A: external signals
  -- ============================================================
  FOR v_correlations IN
    SELECT c.id, c.rule_id, c.confidence, c.match_reason, c.signal_id,
           COALESCE(s.source_reliability, 1.0) AS reliability,
           sig.severity,
           cr.name AS rule_name, cr.scenario
      FROM correlation c
      LEFT JOIN osint_signal sig    ON sig.id = c.signal_id
      LEFT JOIN osint_source  s     ON s.id   = sig.osint_source_id
      LEFT JOIN correlation_rule cr ON cr.rule_id = c.rule_id AND cr.tenant_id = v_tenant_id
     WHERE c.tenant_id   = v_tenant_id
       AND c.contract_id = p_contract_id
       AND c.status      = 'active'
       AND c.is_active   = TRUE
  LOOP
    v_signal_pts := ROUND(
      COALESCE(v_correlations.confidence, 0.8) *
      v_correlations.reliability *
      COALESCE((v_severity_weights->>COALESCE(v_correlations.severity, 'medium'))::numeric,
               (v_severity_weights->>'medium')::numeric)
    );
    v_signal_label := COALESCE(v_correlations.rule_name, v_correlations.rule_id);
    v_score_a := v_score_a + v_signal_pts;
    v_signal_addends := v_signal_addends || jsonb_build_array(jsonb_build_object(
      'bucket',  'A',
      'label',   v_signal_label,
      'points',  v_signal_pts,
      'detail',  'confidence ' || ROUND(COALESCE(v_correlations.confidence, 0.8), 2)
                 || ' x reliability ' || ROUND(v_correlations.reliability, 2)
                 || ' x severity weight ' || COALESCE((v_severity_weights->>COALESCE(v_correlations.severity, 'medium'))::text, '?')
                 || ' (' || COALESCE(v_correlations.severity, 'medium') || ')',
      'correlationId', v_correlations.id::text,
      'ruleId',  v_correlations.rule_id
    ));
    -- MaR contribution while we have the row.
    SELECT value INTO v_exposure_defaults FROM system_setting WHERE key = 'scoring.exposure_fraction_defaults' AND is_active = TRUE;
    v_exposure_defaults := COALESCE(v_exposure_defaults, '{}'::jsonb);
    v_exposure_fraction := COALESCE(NULLIF(v_exposure_defaults->>lower(COALESCE(v_contract.contract_type, '')), '')::numeric,
                                     (v_exposure_defaults->>'default')::numeric, 0.10);
    IF v_contract.value_aed IS NOT NULL THEN
      v_corr_mar := v_contract.value_aed * v_exposure_fraction * v_correlations.confidence * v_correlations.reliability;
      v_mar_total := COALESCE(v_mar_total, 0) + v_corr_mar;
    END IF;
    v_contributing := v_contributing || jsonb_build_array(jsonb_build_object(
      'correlationId',     v_correlations.id::text,
      'ruleId',            v_correlations.rule_id,
      'ruleName',          v_signal_label,
      'scenario',          v_correlations.scenario,
      'confidence',        v_correlations.confidence,
      'sourceReliability', v_correlations.reliability,
      'severity',          v_correlations.severity,
      'probability',       ROUND(100 * COALESCE(v_correlations.confidence, 0) * v_correlations.reliability),
      'impactMultiplier',  1.0,
      'marContribution',   v_corr_mar,
      'dimensionsAffected', CASE v_correlations.scenario
        WHEN 'sanctions'  THEN '["compliance","reputational"]'::jsonb
        WHEN 'esg'        THEN '["compliance","reputational"]'::jsonb
        WHEN 'brent'      THEN '["financial"]'::jsonb
        WHEN 'hormuz'     THEN '["operational","financial"]'::jsonb
        WHEN 'epc_sla'    THEN '["operational","financial"]'::jsonb
        WHEN 'weather_fm' THEN '["operational"]'::jsonb
        WHEN 'payment'    THEN '["financial"]'::jsonb
        WHEN 'renewal'    THEN '["financial","operational"]'::jsonb
        WHEN 'operations' THEN '["operational","financial"]'::jsonb
        ELSE '["legal"]'::jsonb
      END
    ));
  END LOOP;

  -- Cap bucket A and append a "(capped)" addend if we hit the ceiling.
  IF v_score_a > COALESCE(v_signal_cap, 50) THEN
    v_addends := v_addends || jsonb_build_array(jsonb_build_object(
      'bucket', 'A', 'label', 'External signals (capped)',
      'points', COALESCE(v_signal_cap, 50),
      'detail', 'sum of correlation points = ' || v_score_a || ', capped at ' || COALESCE(v_signal_cap, 50)
    ));
    v_score_a := COALESCE(v_signal_cap, 50);
  ELSE
    v_addends := v_addends || v_signal_addends;
  END IF;

  -- ============================================================
  -- Bucket B: value tier (first matching tier wins).
  -- ============================================================
  IF v_contract.value_aed IS NOT NULL THEN
    SELECT t INTO v_value_tier
      FROM jsonb_array_elements(v_value_tiers->'tiers') t
     WHERE (t->>'minAed')::numeric <= v_contract.value_aed
     ORDER BY (t->>'minAed')::numeric DESC
     LIMIT 1;
    IF v_value_tier IS NOT NULL THEN
      v_score_b := (v_value_tier->>'points')::integer;
      v_addends := v_addends || jsonb_build_array(jsonb_build_object(
        'bucket', 'B', 'label', 'Value tier — ' || (v_value_tier->>'label'),
        'points', v_score_b,
        'detail', 'contract value AED ' || ROUND(v_contract.value_aed, 0)
      ));
    END IF;
  END IF;

  -- ============================================================
  -- Bucket C: duration tier.
  -- ============================================================
  IF v_duration_months > 0 THEN
    SELECT t INTO v_dur_tier
      FROM jsonb_array_elements(v_duration_tiers->'tiers') t
     WHERE (t->>'minMonths')::integer <= v_duration_months
     ORDER BY (t->>'minMonths')::integer DESC
     LIMIT 1;
    IF v_dur_tier IS NOT NULL THEN
      v_score_c := (v_dur_tier->>'points')::integer;
      v_addends := v_addends || jsonb_build_array(jsonb_build_object(
        'bucket', 'C', 'label', 'Duration — ' || (v_dur_tier->>'label'),
        'points', v_score_c,
        'detail', v_duration_months || ' months between start and end date'
      ));
    END IF;
  END IF;

  -- ============================================================
  -- Bucket D: sector complexity (per contract_type lookup).
  -- ============================================================
  v_sector_pts := COALESCE(
    (v_sector_points->'byType'->>lower(COALESCE(v_contract.contract_type, '')))::integer,
    (v_sector_points->>'default')::integer,
    0
  );
  IF v_sector_pts > 0 THEN
    v_score_d := v_sector_pts;
    v_addends := v_addends || jsonb_build_array(jsonb_build_object(
      'bucket', 'D', 'label', 'Sector complexity — ' || COALESCE(v_contract.contract_type, 'unknown'),
      'points', v_score_d,
      'detail', 'configurable per contract_type'
    ));
  END IF;

  -- ============================================================
  -- Bucket E: clause-derived flags.
  -- ============================================================
  SELECT
    bool_or((parameters->>'indemnity_scope')::text = 'broad')              AS broad_indemnity,
    COALESCE(SUM((parameters->>'liability_cap_value')::numeric), 0)         AS total_liability_cap,
    bool_or(COALESCE((parameters->>'single_source_dependency')::boolean, FALSE)) AS single_source,
    COUNT(*) FILTER (WHERE COALESCE((parameters->>'regulatory_linkage')::boolean, FALSE))    AS regulatory_clauses
  INTO v_clause_signals
  FROM contract_clause_extracted
  WHERE contract_id = p_contract_id AND is_active = TRUE;

  v_e_total := 0;
  v_clause_addends := '[]'::jsonb;
  IF v_clause_signals.broad_indemnity THEN
    v_e_total := v_e_total + COALESCE((v_clause_points->>'broadIndemnity')::integer, 0);
    v_clause_addends := v_clause_addends || jsonb_build_array(jsonb_build_object(
      'bucket', 'E', 'label', 'Broad indemnity clause',
      'points', COALESCE((v_clause_points->>'broadIndemnity')::integer, 0),
      'detail', 'extracted indemnity scope = broad'));
  END IF;
  IF v_clause_signals.total_liability_cap > 10000000 THEN
    v_e_total := v_e_total + COALESCE((v_clause_points->>'liabilityCapHigh')::integer, 0);
    v_clause_addends := v_clause_addends || jsonb_build_array(jsonb_build_object(
      'bucket', 'E', 'label', 'High liability cap (>10M)',
      'points', COALESCE((v_clause_points->>'liabilityCapHigh')::integer, 0),
      'detail', 'cumulative cap AED ' || ROUND(v_clause_signals.total_liability_cap, 0)));
  END IF;
  IF v_clause_signals.single_source THEN
    v_e_total := v_e_total + COALESCE((v_clause_points->>'singleSource')::integer, 0);
    v_clause_addends := v_clause_addends || jsonb_build_array(jsonb_build_object(
      'bucket', 'E', 'label', 'Single-source supplier',
      'points', COALESCE((v_clause_points->>'singleSource')::integer, 0),
      'detail', 'extracted clause flag set'));
  END IF;
  IF v_clause_signals.regulatory_clauses >= 3 THEN
    v_e_total := v_e_total + COALESCE((v_clause_points->>'regulatorsThreePlus')::integer, 0);
    v_clause_addends := v_clause_addends || jsonb_build_array(jsonb_build_object(
      'bucket', 'E', 'label', 'Three or more regulatory clauses',
      'points', COALESCE((v_clause_points->>'regulatorsThreePlus')::integer, 0),
      'detail', v_clause_signals.regulatory_clauses || ' clauses tagged regulatory_linkage'));
  END IF;

  v_e_cap := COALESCE((v_clause_points->>'cap')::integer, 15);
  v_score_e := LEAST(v_e_total, v_e_cap);
  IF v_e_total > v_e_cap THEN
    v_addends := v_addends || jsonb_build_array(jsonb_build_object(
      'bucket', 'E', 'label', 'Clause-derived risk (capped)',
      'points', v_e_cap,
      'detail', 'raw sum ' || v_e_total || ' capped at ' || v_e_cap));
  ELSE
    v_addends := v_addends || v_clause_addends;
  END IF;

  -- ============================================================
  -- Total + clamp.
  -- ============================================================
  v_score_total := LEAST(100, GREATEST(0, v_score_a + v_score_b + v_score_c + v_score_d + v_score_e));

  -- ============================================================
  -- Persist.
  -- ============================================================
  v_explanation := jsonb_build_object(
    'formulaVersion', 'v2',
    'addends',        v_addends,
    'bucketSubtotals', jsonb_build_object(
      'A', v_score_a, 'B', v_score_b, 'C', v_score_c, 'D', v_score_d, 'E', v_score_e
    ),
    'bands',          v_bands,
    'config',         jsonb_build_object(
      'signalSeverityWeights', v_severity_weights,
      'signalBucketCap',       v_signal_cap,
      'valueTiers',            v_value_tiers,
      'durationTiers',         v_duration_tiers,
      'sectorComplexity',      v_sector_points,
      'clauseSignals',         v_clause_points
    )
  );

  INSERT INTO risk_score (
    tenant_id, contract_id, health_score,
    dim_legal, dim_financial, dim_operational, dim_reputational, dim_compliance,
    mar_value, mar_currency, contributing_correlations, explanation,
    weights_version, calculated_at, triggered_by, data_classification,
    created_at, created_by
  ) VALUES (
    v_tenant_id, p_contract_id, v_score_total,
    -- Legacy dim columns: kept for backwards compat; populate with bucket
    -- subtotals (rough mapping) so the dim bars still light up meaningfully.
    LEAST(100, v_score_d),                        -- legal ≈ sector complexity
    LEAST(100, v_score_b),                        -- financial ≈ value tier
    LEAST(100, v_score_c + v_score_e),            -- operational ≈ duration + clause flags
    LEAST(100, GREATEST(0, v_score_a / 2)),       -- reputational ≈ half of signals
    LEAST(100, v_score_a),                        -- compliance ≈ signals (sanctions/esg)
    v_mar_total, 'AED', v_contributing, v_explanation,
    'v2', fn_demo_now(), p_triggered_by, 'demo',
    NOW(), v_actor_id
  ) RETURNING id INTO v_risk_score_id;

  REFRESH MATERIALIZED VIEW latest_risk_score;

  PERFORM fn_contract_activity_create(
    p_contract_id, 'ai_risk_score_updated', v_actor_id,
    'Risk score recomputed: ' || v_score_total || '/100',
    'تم إعادة احتساب درجة المخاطر: ' || v_score_total || '/100',
    jsonb_build_object('riskScoreId', v_risk_score_id, 'healthScore', v_score_total, 'triggeredBy', p_triggered_by, 'formulaVersion', 'v2')
  );

  RETURN jsonb_build_object(
    'riskScoreId',                v_risk_score_id,
    'contractId',                 p_contract_id,
    'healthScore',                v_score_total,
    'bucketSubtotals',            v_explanation->'bucketSubtotals',
    'addendCount',                jsonb_array_length(v_addends),
    'marValue',                   v_mar_total,
    'marCurrency',                'AED',
    'formulaVersion',             'v2',
    'calculatedAt',               fn_demo_now(),
    'deduplicated',               FALSE
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_score_compute: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION fn_risk_score_compute(bigint, text, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_score_compute(bigint, text, bigint) TO neondb_owner;

-- ============================================================
-- 6. Bump fn_risk_score_explain to surface addends + formulaVersion.
--    (mig 528 stays the structural baseline — we just enrich the return.)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_risk_score_explain(p_contract_id bigint, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $fn$
DECLARE
  v_tenant_id   UUID;
  v_latest      RECORD;
  v_explanation JSONB;
  v_addends     JSONB;
  v_bands       JSONB;
  v_band_label  TEXT;
  v_narrative   TEXT;
  v_contributing JSONB;
  v_dominant    JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  SELECT id, tenant_id, contract_id, health_score,
         dim_legal, dim_financial, dim_operational, dim_reputational, dim_compliance,
         mar_value, mar_currency, contributing_correlations, explanation,
         weights_version, calculated_at, triggered_by
    INTO v_latest
    FROM latest_risk_score
   WHERE contract_id = p_contract_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'risk_score for contract % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;

  v_explanation := COALESCE(v_latest.explanation, '{}'::jsonb);
  v_addends     := COALESCE(v_explanation->'addends', '[]'::jsonb);
  v_bands       := COALESCE(v_explanation->'bands',
                            (SELECT value FROM system_setting WHERE key='scoring.v2.bands' AND is_active LIMIT 1),
                            '{"lowMax":29,"mediumMax":59}'::jsonb);

  v_band_label := CASE
    WHEN v_latest.health_score <= (v_bands->>'lowMax')::integer    THEN 'Low'
    WHEN v_latest.health_score <= (v_bands->>'mediumMax')::integer THEN 'Medium'
    ELSE 'High'
  END;

  -- Hydrated contributing — mig 528 logic, kept here so downstream can rely on it.
  v_contributing := COALESCE(v_latest.contributing_correlations, '[]'::jsonb);

  -- Pick the highest-impact addend as the narrative driver.
  SELECT a INTO v_dominant
    FROM jsonb_array_elements(v_addends) a
   ORDER BY (a->>'points')::numeric DESC NULLS LAST
   LIMIT 1;

  IF v_dominant IS NOT NULL AND (v_dominant->>'points')::integer > 0 THEN
    v_narrative := 'Score ' || v_latest.health_score || '/100 (' || v_band_label || ') — top driver: '
                || (v_dominant->>'label') || ' (+' || (v_dominant->>'points') || ' pts). '
                || jsonb_array_length(v_addends) || ' factor(s) considered.';
  ELSE
    v_narrative := 'Score ' || v_latest.health_score || '/100 (' || v_band_label
                || ') — no notable risk factors detected.';
  END IF;

  RETURN jsonb_build_object(
    'riskScoreId',              v_latest.id::text,
    'contractId',               v_latest.contract_id::text,
    'healthScore',              v_latest.health_score,
    'band',                     v_band_label,
    'bands',                    v_bands,
    'narrative',                v_narrative,
    'formulaVersion',           COALESCE(v_explanation->>'formulaVersion', 'v1'),
    'addends',                  v_addends,
    'bucketSubtotals',          COALESCE(v_explanation->'bucketSubtotals', '{}'::jsonb),
    'dimensions',               jsonb_build_object(
      'legal',        jsonb_build_object('score', COALESCE(v_latest.dim_legal, 0),        'reasons', '[]'::jsonb),
      'financial',    jsonb_build_object('score', COALESCE(v_latest.dim_financial, 0),    'reasons', '[]'::jsonb),
      'operational',  jsonb_build_object('score', COALESCE(v_latest.dim_operational, 0),  'reasons', '[]'::jsonb),
      'reputational', jsonb_build_object('score', COALESCE(v_latest.dim_reputational, 0), 'reasons', '[]'::jsonb),
      'compliance',   jsonb_build_object('score', COALESCE(v_latest.dim_compliance, 0),   'reasons', '[]'::jsonb)
    ),
    'marFormula',               COALESCE(v_explanation->'marFormula', '{}'::jsonb),
    'marValue',                 v_latest.mar_value::text,
    'marCurrency',              v_latest.mar_currency,
    'weightsVersion',           v_latest.weights_version,
    'weightsAtCalculation',     '{}'::jsonb,
    'contributingCorrelations', v_contributing,
    'calculatedAt',             v_latest.calculated_at,
    'triggeredBy',              v_latest.triggered_by
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_score_explain: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION fn_risk_score_explain(bigint, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_score_explain(bigint, bigint) TO neondb_owner;

-- ============================================================
-- 7. Trigger to mirror risk_score.health_score → contract.ai_risk_score.
--    One source of truth, no more divergence between Grounded summary
--    and the gauge.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_mirror_risk_to_contract()
 RETURNS trigger
 LANGUAGE plpgsql
AS $fn$
BEGIN
  -- Only mirror for the latest row by contract_id; we approximate by always
  -- writing on INSERT because risk_score is append-only in this codebase.
  UPDATE contract
     SET ai_risk_score = NEW.health_score,
         updated_at    = CURRENT_TIMESTAMP
   WHERE id = NEW.contract_id
     AND (ai_risk_score IS DISTINCT FROM NEW.health_score);
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS mirror_risk_to_contract ON risk_score;
CREATE TRIGGER mirror_risk_to_contract
  AFTER INSERT ON risk_score
  FOR EACH ROW
  EXECUTE FUNCTION fn_mirror_risk_to_contract();

-- ============================================================
-- 8. Bulk-recompute every contract that has stored snapshots.
-- ============================================================
DO $bulk$
DECLARE
  v_cid BIGINT;
  v_ok  INTEGER := 0;
  v_err INTEGER := 0;
BEGIN
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', false);
  FOR v_cid IN
    SELECT DISTINCT contract_id FROM risk_score
    UNION
    SELECT DISTINCT contract_id FROM correlation WHERE status='active' AND is_active=TRUE
  LOOP
    BEGIN
      PERFORM fn_risk_score_compute(v_cid, 'config_change', 1);
      v_ok := v_ok + 1;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err + 1;
    END;
  END LOOP;
  RAISE NOTICE 'Recompute complete: % ok, % errored', v_ok, v_err;
END;
$bulk$;

-- ============================================================
-- 9. Backfill ai_risk_score from latest snapshot for any contracts
--    that didn't get recomputed (no correlations and no prior snapshot).
-- ============================================================
UPDATE contract c
   SET ai_risk_score = lrs.health_score,
       updated_at    = CURRENT_TIMESTAMP
  FROM latest_risk_score lrs
 WHERE lrs.contract_id = c.id
   AND (c.ai_risk_score IS DISTINCT FROM lrs.health_score);

-- ============================================================
-- 10. Schema migration registry.
-- ============================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (529, 'risk_score_v2_unified', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
