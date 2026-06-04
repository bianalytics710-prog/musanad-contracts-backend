-- MIGRATION: 528_risk_score_explain_human.sql
-- Date: 2026-06-03
-- Description:
--   Rewrite fn_risk_score_explain so the Risk tab is actually informative.
--
--   Bugs fixed:
--     1. Hydration JOIN dropped every correlation because osint_source was
--        INNER-joined but osint_signal.osint_source_id is frequently NULL.
--        → switched to LEFT JOIN; source_reliability still falls back to 1.0.
--
--     2. dimensions[*].reasons was always [] because the function copied
--        explanation->'dimensions'->X->'reasons' which is empty in every
--        snapshot. → now derived at read time from (a) hydrated correlations
--        bucketed by scenario→dimension mapping, and (b) one intrinsic
--        per-dimension factor computed from contract properties.
--
--     3. WhatIf / drill-down showed raw ruleId (e.g.
--        rule.hormuz.charter_party_disruption). → now also emits ruleName
--        from correlation_rule.name and ruleNameAr from name_ar.
--
--   New keys added to the response envelope:
--     - narrative           — one-sentence plain-English explanation of the
--                             score, anchored on the dominant correlation
--                             plus the strongest intrinsic factor.
--     - dimensions[*].reasons[] — distinct, human-readable bullets per dim.
--
--   Backwards compatible: existing keys preserved; FE consumes the new
--   keys additively.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_risk_score_explain(p_contract_id bigint, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_tenant_id              UUID;
  v_latest                 RECORD;
  v_contract               RECORD;
  v_counterparty_name      TEXT;
  v_duration_months        INTEGER;
  v_hydrated               JSONB;
  v_dimensions             JSONB;
  v_narrative              TEXT;
  v_band                   TEXT;
  v_dominant               JSONB;
  v_value_factor           TEXT;
  v_duration_factor        TEXT;
  v_regulatory_factor      TEXT;
  v_legal_factor           TEXT;
  v_reputational_factor    TEXT;
BEGIN
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  SELECT id, tenant_id, contract_id, health_score, dim_legal, dim_financial,
         dim_operational, dim_reputational, dim_compliance,
         mar_value, mar_currency, contributing_correlations, explanation,
         weights_version, calculated_at, triggered_by
    INTO v_latest
    FROM latest_risk_score
   WHERE contract_id = p_contract_id
     AND tenant_id   = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'risk_score for contract % not found', p_contract_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Pull contract properties for intrinsic per-dim factors.
  SELECT c.id, c.contract_type, c.value_aed, c.start_date, c.end_date,
         c.title_en, c.counterparty_id
    INTO v_contract
    FROM contract c
   WHERE c.id = p_contract_id;

  SELECT p.name_en INTO v_counterparty_name
    FROM party p WHERE p.id = v_contract.counterparty_id;

  v_duration_months := COALESCE(
    EXTRACT(YEAR FROM AGE(v_contract.end_date, v_contract.start_date)) * 12 +
    EXTRACT(MONTH FROM AGE(v_contract.end_date, v_contract.start_date)),
    0
  )::integer;

  -- ============================================================
  -- 1. Hydrate stored correlation refs.
  --    Fix: LEFT JOIN osint_source (was INNER → dropped every row when
  --    osint_signal.osint_source_id is NULL, which is the common case for
  --    seeded ESG/sanctions/Hormuz signals).
  --    Adds ruleName from correlation_rule.name + scenario for downstream
  --    dimension bucketing.
  -- ============================================================
  SELECT jsonb_agg(jsonb_build_object(
    'correlationId',     c.id::text,
    'ruleId',            c.rule_id,
    'ruleName',          COALESCE(cr.name, c.rule_id),
    'ruleNameAr',        cr.name_ar,
    'scenario',          cr.scenario,
    'ruleVersionHash',   c.rule_version_hash,
    'confidence',        c.confidence,
    'matchReason',       c.match_reason,
    'status',            c.status,
    'sourceReliability', COALESCE(s.source_reliability, 1.0),
    'probability',       ROUND(100 * c.confidence * COALESCE(s.source_reliability, 1.0)),
    'signal', jsonb_build_object(
      'id',         sig.id::text,
      'titleEn',    sig.title_en,
      'titleAr',    sig.title_ar,
      'signalKind', sig.kind,
      'occurredAt', sig.event_date_v2
    ),
    'marContribution',   (cc.elem->>'marContribution')::numeric,
    'impactMultiplier',  COALESCE((cc.elem->>'impactMultiplier')::numeric, 1.0),
    -- Derive dimensionsAffected from scenario when the stored elem doesn't carry it.
    'dimensionsAffected', COALESCE(
      cc.elem->'dimensionsAffected',
      CASE cr.scenario
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
    ),
    'matchedClause', (
      SELECT jsonb_build_object(
        'id',           cce.id::text,
        'clauseTypeV2', cce.clause_type_v2,
        'snippet',      LEFT(cce.text_excerpts::text, 240)
      )
      FROM contract_clause_extracted cce
      WHERE cce.contract_id = c.contract_id
        AND cce.is_active = TRUE
        AND c.match_evidence ? 'clauseId'
        AND cce.id = (c.match_evidence->>'clauseId')::bigint
      LIMIT 1
    )
  ))
  INTO v_hydrated
  FROM jsonb_array_elements(COALESCE(v_latest.contributing_correlations, '[]'::jsonb))
       WITH ORDINALITY AS cc(elem, ord)
  JOIN correlation c       ON c.id  = (cc.elem->>'correlationId')::bigint
  LEFT JOIN osint_signal sig    ON sig.id = c.signal_id
  LEFT JOIN osint_source s      ON s.id   = sig.osint_source_id
  LEFT JOIN correlation_rule cr ON cr.rule_id = c.rule_id AND cr.tenant_id = v_tenant_id
  WHERE c.tenant_id = v_tenant_id
    AND c.is_active = TRUE;

  v_hydrated := COALESCE(v_hydrated, '[]'::jsonb);

  -- ============================================================
  -- 2. Per-dimension intrinsic factor strings.
  -- ============================================================
  v_value_factor := CASE
    WHEN v_contract.value_aed IS NULL                THEN 'Contract value not recorded'
    WHEN v_contract.value_aed >= 50000000            THEN 'Very large exposure (AED ' || ROUND(v_contract.value_aed/1000000.0, 1) || 'M)'
    WHEN v_contract.value_aed >= 5000000             THEN 'Material financial commitment (AED ' || ROUND(v_contract.value_aed/1000000.0, 1) || 'M)'
    WHEN v_contract.value_aed >= 500000              THEN 'Moderate value (AED ' || ROUND(v_contract.value_aed/1000.0, 0) || 'K)'
    ELSE                                                  'Limited value at stake (AED ' || ROUND(v_contract.value_aed, 0) || ')'
  END;

  v_duration_factor := CASE
    WHEN v_duration_months >= 36 THEN 'Long-term commitment (' || (v_duration_months / 12) || '+ years)'
    WHEN v_duration_months >= 12 THEN 'Multi-year delivery window (' || v_duration_months || ' months)'
    WHEN v_duration_months >= 6  THEN 'Standard delivery window (' || v_duration_months || ' months)'
    WHEN v_duration_months > 0   THEN 'Short engagement (' || v_duration_months || ' months)'
    ELSE                              'Open-ended or unspecified duration'
  END;

  v_regulatory_factor := CASE v_contract.contract_type
    WHEN 'gas_spa'         THEN 'Hydrocarbon supply — MoIE, OPEC compliance, FTA price oversight'
    WHEN 'concession'      THEN 'Concession agreement — MoIE, ADNOC HQ, sovereign risk oversight'
    WHEN 'epc'             THEN 'EPC contract — MoIAT (ICV), Civil Defense, HSE regulators'
    WHEN 'master_services' THEN 'MSA framework — MoHRE, FTA, sector-specific overlays'
    WHEN 'msa'             THEN 'MSA — multi-regulator surface; check ICV and FTA touch points'
    WHEN 'vessel_charter'  THEN 'Charter party — IMO, Hormuz transit advisories, P&I cover'
    WHEN 'term_sale'       THEN 'Term sale — FTA tariff, OFAC sanctions screening'
    WHEN 'vendor'          THEN 'Vendor procurement — ICV, sanctions screening, supplier ESG'
    WHEN 'services'        THEN 'Services contract — standard regulatory footprint'
    WHEN 'nda'             THEN 'NDA — UAE Federal Law No. 5 (Cybercrimes), PDPL'
    WHEN 'consulting'      THEN 'Consulting — MoHRE labour rules, PDPL'
    WHEN 'sow'             THEN 'SoW under master agreement — inherits parent overlay'
    WHEN 'employment'      THEN 'Employment — MoHRE labour law, PDPL'
    WHEN 'license'         THEN 'IP licence — UAE Federal Law No. 7 (Trademarks), 38 (Copyright)'
    ELSE                        'Sector-regulated contract — multi-regulator exposure'
  END;

  v_legal_factor := CASE
    WHEN v_contract.value_aed IS NULL              THEN 'Standard boilerplate (no value signal)'
    WHEN v_contract.value_aed >= 10000000          THEN 'High clause density expected — indemnity, IP, liability caps, termination'
    WHEN v_contract.value_aed >= 1000000           THEN 'Moderate clause density — standard MSA/SOW structure'
    ELSE                                                'Templated clause set — balanced rights'
  END;

  v_reputational_factor := CASE
    WHEN v_counterparty_name IS NULL THEN 'Counterparty profile not recorded'
    ELSE 'Counterparty: ' || v_counterparty_name
  END;

  -- ============================================================
  -- 3. Build per-dimension reasons arrays.
  --    Each dimension: (a) correlation lines whose dimensionsAffected
  --    contains this dim, capped at 3 to avoid wall-of-text, then
  --    (b) one intrinsic factor line.
  -- ============================================================
  v_dimensions := jsonb_build_object(
    'legal', jsonb_build_object(
      'score',   COALESCE(v_latest.dim_legal, 0),
      'reasons', COALESCE((
        SELECT jsonb_agg(line) FROM (
          SELECT e->>'ruleName' || ' — ' || COALESCE(e->>'matchReason', 'signal active') AS line
          FROM jsonb_array_elements(v_hydrated) e
          WHERE e->'dimensionsAffected' @> '"legal"'::jsonb
          LIMIT 3
        ) t
      ), '[]'::jsonb) || jsonb_build_array(v_legal_factor)
    ),
    'financial', jsonb_build_object(
      'score',   COALESCE(v_latest.dim_financial, 0),
      'reasons', COALESCE((
        SELECT jsonb_agg(line) FROM (
          SELECT e->>'ruleName' || ' — ' || COALESCE(e->>'matchReason', 'signal active') AS line
          FROM jsonb_array_elements(v_hydrated) e
          WHERE e->'dimensionsAffected' @> '"financial"'::jsonb
          LIMIT 3
        ) t
      ), '[]'::jsonb) || jsonb_build_array(v_value_factor)
    ),
    'operational', jsonb_build_object(
      'score',   COALESCE(v_latest.dim_operational, 0),
      'reasons', COALESCE((
        SELECT jsonb_agg(line) FROM (
          SELECT e->>'ruleName' || ' — ' || COALESCE(e->>'matchReason', 'signal active') AS line
          FROM jsonb_array_elements(v_hydrated) e
          WHERE e->'dimensionsAffected' @> '"operational"'::jsonb
          LIMIT 3
        ) t
      ), '[]'::jsonb) || jsonb_build_array(v_duration_factor)
    ),
    'reputational', jsonb_build_object(
      'score',   COALESCE(v_latest.dim_reputational, 0),
      'reasons', COALESCE((
        SELECT jsonb_agg(line) FROM (
          SELECT e->>'ruleName' || ' — ' || COALESCE(e->>'matchReason', 'signal active') AS line
          FROM jsonb_array_elements(v_hydrated) e
          WHERE e->'dimensionsAffected' @> '"reputational"'::jsonb
          LIMIT 3
        ) t
      ), '[]'::jsonb) || jsonb_build_array(v_reputational_factor)
    ),
    'compliance', jsonb_build_object(
      'score',   COALESCE(v_latest.dim_compliance, 0),
      'reasons', COALESCE((
        SELECT jsonb_agg(line) FROM (
          SELECT e->>'ruleName' || ' — ' || COALESCE(e->>'matchReason', 'signal active') AS line
          FROM jsonb_array_elements(v_hydrated) e
          WHERE e->'dimensionsAffected' @> '"compliance"'::jsonb
          LIMIT 3
        ) t
      ), '[]'::jsonb) || jsonb_build_array(v_regulatory_factor)
    )
  );

  -- ============================================================
  -- 4. Narrative — one sentence anchoring score band + dominant
  --    correlation (highest probability) + strongest intrinsic factor.
  -- ============================================================
  v_band := CASE
    WHEN v_latest.health_score >= 60 THEN 'High'
    WHEN v_latest.health_score >= 30 THEN 'Medium'
    WHEN v_latest.health_score > 0   THEN 'Low'
    ELSE                                  'Insufficient data'
  END;

  -- Pick the highest-probability correlation as the headline driver.
  SELECT e INTO v_dominant
    FROM jsonb_array_elements(v_hydrated) e
    ORDER BY (e->>'probability')::numeric DESC NULLS LAST
    LIMIT 1;

  IF v_dominant IS NOT NULL THEN
    v_narrative := 'Score ' || v_latest.health_score || ' (' || v_band || ') — driven by ' ||
                   COALESCE(v_dominant->>'ruleName', v_dominant->>'ruleId') ||
                   '. ' || v_value_factor ||
                   '; ' || v_duration_factor || '.';
  ELSE
    v_narrative := 'Score ' || v_latest.health_score || ' (' || v_band ||
                   ') — no live external signals are firing. Score reflects ' ||
                   v_value_factor || ' and ' || v_duration_factor || '.';
  END IF;

  -- ============================================================
  -- 5. Return envelope.
  -- ============================================================
  RETURN jsonb_build_object(
    'riskScoreId',              v_latest.id::text,
    'contractId',               v_latest.contract_id::text,
    'healthScore',              v_latest.health_score,
    'narrative',                v_narrative,
    'dimensions',               v_dimensions,
    'marFormula',               COALESCE(v_latest.explanation->'marFormula', '{}'::jsonb),
    'marValue',                 v_latest.mar_value::text,
    'marCurrency',              v_latest.mar_currency,
    'weightsVersion',           v_latest.weights_version,
    'weightsAtCalculation',     COALESCE(v_latest.explanation->'weightsAtCalculation', '{}'::jsonb),
    'contributingCorrelations', v_hydrated,
    'calculatedAt',             v_latest.calculated_at,
    'triggeredBy',              v_latest.triggered_by
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_risk_score_explain: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_risk_score_explain(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_score_explain(BIGINT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (528, 'risk_score_explain_human', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
