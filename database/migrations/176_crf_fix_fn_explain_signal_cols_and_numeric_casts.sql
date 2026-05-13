-- =====================================================================
-- 176_crf_fix_fn_explain_signal_cols_and_numeric_casts.sql
-- =====================================================================
-- DEFECT-CR-F-1 (S2-22 column-existence + BIGINT/NUMERIC serialization)
--
-- Fixes 4 issues found by Smoke + Integration Verifier:
--
-- (A) fn_risk_score_explain — S2-22 column-existence:
--     sig.signal_kind → sig.kind
--     sig.occurred_at → sig.event_date_v2
--     Causes Postgres 42703 → HTTP 500 on every GET /contracts/:id/risk-score
--     for contracts with correlations.
--
-- (B) fn_risk_score_history — BIGINT-as-string convention:
--     riskScoreId, contractId, marValue cast to ::text
--     FE types declare these as `string` per project BIGINT serialization rule
--     (numbers > 2^53 lose precision in JSON).
--
-- (C) fn_avar_aggregate — NUMERIC-monetary-as-string + contractId/counterpartyId BIGINT:
--     totalAvar, breakdown[].avar, deltaVsPriorWindow.priorAvar, deltaVsPriorWindow.deltaAed
--     all cast to ::text.
--
-- (D) fn_score_recompute_for_weight_change — BIGINT array as string array:
--     failedContractIds array elements cast to ::text in JSONB output.
--
-- Body preservation per memory feedback_fn_rewrites_lose_safety_guards.md:
--   - Permission gates preserved
--   - 22023 / 42501 / P0002 / SQLSTATE raises preserved
--   - SECURITY DEFINER / STABLE preserved per original
--   - REVOKE FROM PUBLIC + GRANT TO neondb_owner re-issued at end of each
-- =====================================================================

-- ----------------------------------------------------------------------
-- (A) fn_risk_score_explain — column name fix
-- ----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_risk_score_explain(p_contract_id bigint, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_tenant_id           UUID;
  v_latest              RECORD;
  v_contributing_hydrated JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT id, tenant_id, contract_id, health_score, dim_legal, dim_financial, dim_operational, dim_reputational, dim_compliance, mar_value, mar_currency, contributing_correlations, explanation, weights_version, calculated_at, triggered_by
  INTO v_latest
  FROM   latest_risk_score
  WHERE  contract_id = p_contract_id
    AND  tenant_id   = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'risk_score for contract % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;
  SELECT jsonb_agg(jsonb_build_object('correlationId', c.id::text, 'ruleId', c.rule_id, 'ruleVersionHash', c.rule_version_hash, 'confidence', c.confidence, 'matchReason', c.match_reason, 'status', c.status, 'sourceReliability', COALESCE(s.source_reliability, 1.0), 'probability', ROUND(100 * c.confidence * COALESCE(s.source_reliability, 1.0)), 'signal', jsonb_build_object('id', sig.id::text, 'titleEn', sig.title_en, 'titleAr', sig.title_ar, 'signalKind', sig.kind, 'occurredAt', sig.event_date_v2), 'marContribution', (cc.elem->>'marContribution')::numeric, 'impactMultiplier', (cc.elem->>'impactMultiplier')::numeric, 'dimensionsAffected', cc.elem->'dimensionsAffected', 'matchedClause', (SELECT jsonb_build_object('id', cce.id::text, 'clauseTypeV2', cce.clause_type_v2, 'snippet', LEFT(cce.text_excerpts::text, 240)) FROM contract_clause_extracted cce WHERE cce.contract_id = c.contract_id AND cce.is_active = TRUE AND c.match_evidence ? 'clauseId' AND cce.id = (c.match_evidence->>'clauseId')::bigint LIMIT 1)))
  INTO v_contributing_hydrated
  FROM   jsonb_array_elements(v_latest.contributing_correlations) WITH ORDINALITY AS cc(elem, ord)
  JOIN   correlation c    ON c.id  = (cc.elem->>'correlationId')::bigint
  JOIN   osint_signal sig ON sig.id = c.signal_id
  JOIN   osint_source s   ON s.id   = sig.osint_source_id
  WHERE  c.tenant_id = v_tenant_id;
  RETURN jsonb_build_object('riskScoreId', v_latest.id::text, 'contractId', v_latest.contract_id::text, 'healthScore', v_latest.health_score, 'dimensions', v_latest.explanation->'dimensions', 'marFormula', v_latest.explanation->'marFormula', 'marValue', v_latest.mar_value::text, 'marCurrency', v_latest.mar_currency, 'weightsVersion', v_latest.weights_version, 'weightsAtCalculation', v_latest.explanation->'weightsAtCalculation', 'contributingCorrelations', COALESCE(v_contributing_hydrated, '[]'::jsonb), 'calculatedAt', v_latest.calculated_at, 'triggeredBy', v_latest.triggered_by);
EXCEPTION
  WHEN OTHERS THEN RAISE EXCEPTION 'fn_risk_score_explain: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_risk_score_explain(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_score_explain(BIGINT, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_risk_score_explain(BIGINT, BIGINT) IS
  'M14/CR-F. Returns expanded risk score for a contract with hydrated correlation details. Patched in migration 176 (DEFECT-CR-F-1): fixed osint_signal column references (kind, event_date_v2) + BIGINT-as-string casts (riskScoreId, contractId, correlationId, signal.id, matchedClause.id, marValue).';

-- ----------------------------------------------------------------------
-- (B) fn_risk_score_history — BIGINT/NUMERIC ::text casts
-- ----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_risk_score_history(p_contract_id bigint, p_window_days integer, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_tenant_id UUID;
  v_snapshots JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;
  IF p_window_days NOT IN (30, 90, 180) THEN
    RAISE EXCEPTION 'windowDays must be 30, 90, or 180 (got %)', p_window_days USING ERRCODE = '22023';
  END IF;
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'contract with id % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;
  SELECT jsonb_agg(jsonb_build_object('riskScoreId', id::text, 'calculatedAt', calculated_at, 'healthScore', health_score, 'dimLegal', dim_legal, 'dimFinancial', dim_financial, 'dimOperational', dim_operational, 'dimReputational', dim_reputational, 'dimCompliance', dim_compliance, 'marValue', mar_value::text, 'marCurrency', mar_currency, 'triggeredBy', triggered_by, 'weightsVersion', weights_version) ORDER BY calculated_at ASC)
  INTO   v_snapshots
  FROM   risk_score
  WHERE  contract_id   = p_contract_id
    AND  tenant_id     = v_tenant_id
    AND  calculated_at >= NOW() - (p_window_days || ' days')::interval;
  RETURN jsonb_build_object('contractId', p_contract_id::text, 'windowDays', p_window_days, 'snapshots', COALESCE(v_snapshots, '[]'::jsonb), 'count', jsonb_array_length(COALESCE(v_snapshots, '[]'::jsonb)));
EXCEPTION
  WHEN OTHERS THEN RAISE EXCEPTION 'fn_risk_score_history: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_risk_score_history(BIGINT, INTEGER, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_score_history(BIGINT, INTEGER, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_risk_score_history(BIGINT, INTEGER, BIGINT) IS
  'M14/CR-F. Returns risk_score snapshot history for a contract within window. Patched in migration 176 (DEFECT-CR-F-1): BIGINT/NUMERIC ::text casts on riskScoreId, contractId, marValue per project BIGINT-as-string convention.';

-- ----------------------------------------------------------------------
-- (C) fn_avar_aggregate — monetary NUMERIC ::text casts
-- ----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_avar_aggregate(p_filters jsonb, p_window_days integer, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
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
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;
  IF p_window_days < 1 OR p_window_days > 365 THEN
    RAISE EXCEPTION 'windowDays out of [1, 365] (got %)', p_window_days USING ERRCODE = '22023';
  END IF;
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
  WITH filtered AS (
    SELECT lrs.contract_id, lrs.mar_value, lrs.health_score, lrs.contributing_correlations, lrs.calculated_at, c.contract_type, c.emirate, c.counterparty_id
    FROM   latest_risk_score lrs
    JOIN   contract c ON c.id = lrs.contract_id AND c.is_active = TRUE
    WHERE  lrs.tenant_id     = v_tenant_id
      AND  lrs.calculated_at >= v_window_from
      AND  (v_filter_bu   IS NULL OR lower(c.contract_type) = v_filter_bu)
      AND  (v_filter_geo  IS NULL OR lower(c.emirate)       = v_filter_geo)
      AND  (v_filter_cp   IS NULL OR c.counterparty_id      = v_filter_cp)
      AND  (v_filter_kind IS NULL OR EXISTS (SELECT 1 FROM jsonb_array_elements(lrs.contributing_correlations) AS cc(elem) WHERE cc.elem->>'ruleId' LIKE 'rule.' || v_filter_kind || '.%'))
  ),
  per_bucket AS (
    SELECT
      CASE v_group_by
        WHEN 'business_unit'      THEN COALESCE(contract_type,        '(none)')
        WHEN 'geography'          THEN COALESCE(emirate,               '(none)')
        WHEN 'counterparty_id'    THEN COALESCE(counterparty_id::text, '(unknown)')
        WHEN 'counterparty_chain' THEN COALESCE(counterparty_id::text, '(unknown)')
        WHEN 'risk_kind'          THEN '(all)'
        ELSE COALESCE(contract_type, '(none)')
      END AS bucket_label,
      SUM(mar_value) AS bucket_avar,
      COUNT(*) AS bucket_count,
      COUNT(*) FILTER (WHERE mar_value IS NULL) AS bucket_no_value_count
    FROM filtered
    GROUP BY bucket_label
  ),
  totals AS (
    SELECT SUM(bucket_avar) AS total_avar, SUM(bucket_count) AS total_contract_count, SUM(bucket_no_value_count) AS no_value_count
    FROM per_bucket
  )
  SELECT jsonb_build_object(
    'totalAvar', COALESCE((SELECT total_avar FROM totals), 0)::text,
    'currency', 'AED',
    'contractCount', COALESCE((SELECT total_contract_count FROM totals), 0),
    'windowDays', p_window_days,
    'groupBy', v_group_by,
    'noValueCount', COALESCE((SELECT no_value_count FROM totals), 0),
    'breakdown', COALESCE((SELECT jsonb_agg(jsonb_build_object('key', bucket_label, 'label', bucket_label, 'avar', bucket_avar::text, 'contractCount', bucket_count, 'pctOfTotal', ROUND(100.0 * bucket_avar / NULLIF((SELECT total_avar FROM totals), 0), 2)) ORDER BY bucket_avar DESC NULLS LAST) FROM per_bucket), '[]'::jsonb),
    'deltaVsPriorWindow', (SELECT jsonb_build_object('priorAvar', COALESCE(SUM(rs.mar_value), 0)::text, 'deltaAed', (COALESCE((SELECT total_avar FROM totals), 0) - COALESCE(SUM(rs.mar_value), 0))::text, 'deltaPct', ROUND(100.0 * (COALESCE((SELECT total_avar FROM totals), 0) - COALESCE(SUM(rs.mar_value), 0)) / NULLIF(SUM(rs.mar_value), 0), 2)) FROM (SELECT DISTINCT ON (contract_id) mar_value FROM risk_score WHERE tenant_id = v_tenant_id AND calculated_at >= NOW() - (2 * p_window_days || ' days')::interval AND calculated_at < NOW() - (p_window_days || ' days')::interval ORDER BY contract_id, calculated_at DESC) rs)
  ) INTO v_result;
  RETURN v_result;
EXCEPTION
  WHEN OTHERS THEN RAISE EXCEPTION 'fn_avar_aggregate: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_avar_aggregate(JSONB, INTEGER, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_avar_aggregate(JSONB, INTEGER, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_avar_aggregate(JSONB, INTEGER, BIGINT) IS
  'M14/CR-F. Aggregates Asset Value at Risk (AVaR) across the latest risk_score per contract with filters + groupBy + delta-vs-prior-window. Patched in migration 176 (DEFECT-CR-F-1): NUMERIC monetary ::text casts on totalAvar / breakdown[].avar / deltaVsPriorWindow.priorAvar / deltaVsPriorWindow.deltaAed per project BIGINT-as-string convention.';

-- ----------------------------------------------------------------------
-- (D) fn_score_recompute_for_weight_change — BIGINT array ::text cast
-- ----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_score_recompute_for_weight_change(p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_weights_version TEXT;
  v_tenant_id       UUID;
  v_contract_id     BIGINT;
  v_started_at      TIMESTAMPTZ;
  v_total           INTEGER := 0;
  v_recomputed      INTEGER := 0;
  v_failed_ids      BIGINT[] := ARRAY[]::bigint[];
BEGIN
  IF p_actor_id IS NULL OR p_actor_id = 0 THEN
    RAISE EXCEPTION 'p_actor_id must be a non-system actor for bulk recompute' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('score.weights.manage') THEN
    RAISE EXCEPTION 'Permission denied: score.weights.manage required' USING ERRCODE = '42501';
  END IF;
  SELECT value->>'version' INTO v_weights_version FROM system_setting WHERE key = 'scoring.weights' AND is_active = TRUE;
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  v_started_at := clock_timestamp();
  FOR v_contract_id IN
    SELECT id FROM contract WHERE is_active = TRUE ORDER BY id
  LOOP
    v_total := v_total + 1;
    BEGIN
      PERFORM fn_risk_score_compute(v_contract_id, 'weight_change', p_actor_id);
      v_recomputed := v_recomputed + 1;
    EXCEPTION
      WHEN OTHERS THEN
        v_failed_ids := v_failed_ids || v_contract_id;
        RAISE NOTICE 'fn_score_recompute_for_weight_change: contract % failed: %', v_contract_id, SQLERRM;
    END;
  END LOOP;
  RETURN jsonb_build_object('weightsVersion', v_weights_version, 'totalContractsTargeted', v_total, 'recomputedCount', v_recomputed, 'failedContractIds', COALESCE((SELECT jsonb_agg(elem::text) FROM unnest(v_failed_ids) AS elem), '[]'::jsonb), 'elapsedMs', EXTRACT(MILLISECONDS FROM (clock_timestamp() - v_started_at))::integer);
EXCEPTION
  WHEN OTHERS THEN RAISE EXCEPTION 'fn_score_recompute_for_weight_change: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_score_recompute_for_weight_change(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_score_recompute_for_weight_change(BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_score_recompute_for_weight_change(BIGINT) IS
  'M14/CR-F. Bulk recomputes risk scores for every active contract after a weight change. Patched in migration 176 (DEFECT-CR-F-1): failedContractIds elements cast to ::text per project BIGINT-as-string convention.';

-- ----------------------------------------------------------------------
-- Migration record
-- ----------------------------------------------------------------------

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (176, '176_crf_fix_fn_explain_signal_cols_and_numeric_casts', NOW())
ON CONFLICT (version) DO NOTHING;

-- =====================================================================
-- ROLLBACK
-- =====================================================================
-- Re-apply migration 173 bodies for all 4 fn_'s (un-patched). Not advised.
-- =====================================================================
