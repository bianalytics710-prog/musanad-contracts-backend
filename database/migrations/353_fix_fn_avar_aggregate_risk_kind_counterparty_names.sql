-- Migration: 353_fix_fn_avar_aggregate_risk_kind_counterparty_names.sql
-- Unit: QA Phase 3.2 — surfaced by user screenshot of Eman dashboard 2026-05-31
-- Description: Three fixes to fn_avar_aggregate body (BUG-015, BUG-016, BUG-017):
--
--   BUG-015 — Risk kind subtab showed '(all)' hardcoded label. Now groups by
--             rule-category prefix extracted from contributing_correlations[].ruleId
--             (e.g. 'rule.weather.fm_eligible' → 'weather', 'rule.sanctions.ofac' →
--             'sanctions'). Unbucketable rows collapse to '(uncategorised)'.
--
--   BUG-016 — Counterparty subtab Y-axis showed raw IDs (92, 91...). Now LEFT
--             JOINs party.name_en (with party.name_ar fallback) so the chart
--             reads as human-friendly names. Falls back to "Party #<id>" when
--             party row missing.
--
--   BUG-017 — Empty buckets (AVaR = 0 or NULL) rendered as ghost rows. Now
--             filtered out at per_bucket CTE level so the breakdown only shows
--             categories with non-zero AVaR data.
--
-- All other behaviour preserved byte-for-byte (perm gate, window validation,
-- groupBy validation, totals, deltaVsPriorWindow). S2-24 split-aggregate
-- pattern preserved.
--
-- Rollback: see ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
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

  -- BUG-015 fix: extract rule-category from contributing_correlations[].ruleId.
  -- The ruleId pattern is 'rule.<category>.<rest>' (e.g. 'rule.weather.fm_eligible',
  -- 'rule.sanctions.ofac_hit', 'rule.esg.high_water_stress'). We split on dot
  -- and take element [2]. For risk_kind groupBy each contract may contribute
  -- to multiple buckets (one per distinct category in its contributing
  -- correlations) — so we EXPLODE the rows at the CTE level rather than
  -- collapsing in CASE.
  --
  -- BUG-016 fix: LEFT JOIN party p ON p.id = c.counterparty_id and use
  -- coalesce(p.name_en, p.name_ar, 'Party #'||c.counterparty_id::text) for
  -- counterparty groupings.
  WITH filtered AS (
    SELECT
      lrs.contract_id,
      lrs.mar_value,
      lrs.health_score,
      lrs.contributing_correlations,
      lrs.calculated_at,
      c.contract_type,
      c.emirate,
      c.counterparty_id,
      COALESCE(p.name_en, p.name_ar, 'Party #' || c.counterparty_id::text) AS counterparty_name
    FROM   latest_risk_score lrs
    JOIN   contract c ON c.id = lrs.contract_id AND c.is_active = TRUE
    LEFT JOIN party p ON p.id = c.counterparty_id AND p.is_active = TRUE
    WHERE  lrs.tenant_id     = v_tenant_id
      AND  lrs.calculated_at >= v_window_from
      AND  (v_filter_bu   IS NULL OR lower(c.contract_type) = v_filter_bu)
      AND  (v_filter_geo  IS NULL OR lower(c.emirate)       = v_filter_geo)
      AND  (v_filter_cp   IS NULL OR c.counterparty_id      = v_filter_cp)
      AND  (v_filter_kind IS NULL OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(lrs.contributing_correlations) AS cc(elem)
        WHERE cc.elem->>'ruleId' LIKE 'rule.' || v_filter_kind || '.%'
      ))
  ),
  -- BUG-015: for risk_kind groupBy, each contract contributes one row per
  -- distinct rule-category in its contributing_correlations. Use a separate
  -- CTE that explodes the JSONB array; for non-risk_kind groupings, just
  -- emit one row per contract.
  exploded AS (
    SELECT
      f.contract_id,
      f.mar_value,
      f.contract_type,
      f.emirate,
      f.counterparty_id,
      f.counterparty_name,
      CASE
        WHEN v_group_by = 'risk_kind' THEN
          COALESCE(
            (regexp_match(cc.elem->>'ruleId', '^rule\.([^.]+)\.'))[1],
            '(uncategorised)'
          )
        ELSE NULL
      END AS risk_kind_label
    FROM filtered f
    LEFT JOIN LATERAL (
      SELECT elem
      FROM jsonb_array_elements(COALESCE(f.contributing_correlations, '[]'::jsonb)) AS arr(elem)
      WHERE v_group_by = 'risk_kind'
    ) cc ON TRUE
    WHERE v_group_by != 'risk_kind' OR cc.elem IS NOT NULL
  ),
  per_bucket AS (
    SELECT
      CASE v_group_by
        WHEN 'business_unit'      THEN COALESCE(contract_type, '(none)')
        WHEN 'geography'          THEN COALESCE(emirate,        '(none)')
        WHEN 'counterparty_id'    THEN counterparty_name
        WHEN 'counterparty_chain' THEN counterparty_name
        WHEN 'risk_kind'          THEN risk_kind_label
        ELSE COALESCE(contract_type, '(none)')
      END                                                               AS bucket_label,
      SUM(mar_value)                                                    AS bucket_avar,
      COUNT(DISTINCT contract_id)                                       AS bucket_count,
      COUNT(DISTINCT contract_id) FILTER (WHERE mar_value IS NULL)      AS bucket_no_value_count
    FROM exploded
    GROUP BY bucket_label
    -- BUG-017: drop zero/NULL buckets so the chart only shows categories with data
    HAVING COALESCE(SUM(mar_value), 0) > 0
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
  'AVaR roll-up over latest_risk_score for the calling tenant. S2-24 SPLIT-AGGREGATE preserved. QA Phase 3.2 (mig 353) fixes: (1) BUG-015 risk_kind now groups by rule-category extracted from contributing_correlations[].ruleId pattern; (2) BUG-016 counterparty bucketLabel uses party.name_en (LEFT JOIN) not raw ID; (3) BUG-017 zero/NULL AVaR buckets filtered out via HAVING clause so chart only shows non-zero categories. Permission: score.read.';
REVOKE EXECUTE ON FUNCTION fn_avar_aggregate(JSONB, INTEGER, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_avar_aggregate(JSONB, INTEGER, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (353, 'BUG-015/016/017 fix fn_avar_aggregate: risk_kind grouping + counterparty names + drop zero buckets', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Re-apply migration 171 body to restore pre-353 fn_avar_aggregate.
-- DELETE FROM schema_migrations WHERE version = 353;
