-- Migration: 167_fix_fn_correlation_list_group_by.sql
-- Module: M13 / CR-E — third instance of the GROUP BY + window-fn defect
-- (after 161 fn_rule_list and 162 fn_clause_review_queue_list).
--
-- DEFECT: SELECT mixing jsonb_agg(...) + COUNT(*) OVER () + ORDER BY non-
--   aggregated cols causes PG17 to demand the cols in GROUP BY.
-- FIX: split into separate COUNT and paginated CTE wrapped by jsonb_agg.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_correlation_list(
  p_page         INTEGER,
  p_limit        INTEGER,
  p_contract_id  BIGINT,
  p_rule_id      TEXT,
  p_signal_id    BIGINT,
  p_status       TEXT,
  p_scenario     TEXT,
  p_since        TIMESTAMPTZ,
  p_actor_id     BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_page   INTEGER := GREATEST(1, COALESCE(p_page, 1));
  v_limit  INTEGER := LEAST(100, GREATEST(1, COALESCE(p_limit, 20)));
  v_offset INTEGER;
  v_data   JSONB;
  v_total  BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('correlation.read') THEN
    RAISE EXCEPTION 'Permission denied: correlation.read required' USING ERRCODE = '42501';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  SELECT COUNT(*)
  INTO v_total
  FROM correlation corr
  JOIN contract c ON c.id = corr.contract_id
  LEFT JOIN correlation_rule cr ON cr.tenant_id = corr.tenant_id
    AND cr.rule_id = corr.rule_id
    AND cr.is_active = TRUE
  WHERE corr.is_active = TRUE
    AND (p_contract_id IS NULL OR corr.contract_id = p_contract_id)
    AND (p_rule_id    IS NULL OR corr.rule_id    = p_rule_id)
    AND (p_signal_id  IS NULL OR corr.signal_id  = p_signal_id)
    AND (p_status     IS NULL OR corr.status     = p_status)
    AND (p_scenario   IS NULL OR cr.scenario     = p_scenario)
    AND (p_since      IS NULL OR corr.created_at >= p_since);

  WITH paged AS (
    SELECT
      corr.id, corr.signal_id, corr.contract_id,
      c.title_en, c.title_ar,
      corr.rule_id, cr.name AS rule_name, cr.name_ar AS rule_name_ar, cr.scenario,
      corr.rule_version_hash, corr.confidence, corr.match_reason,
      corr.status, corr.expires_at, corr.dismissed_at, corr.dismissed_reason,
      corr.created_at
    FROM correlation corr
    JOIN contract c ON c.id = corr.contract_id
    LEFT JOIN correlation_rule cr ON cr.tenant_id = corr.tenant_id
      AND cr.rule_id = corr.rule_id
      AND cr.is_active = TRUE
    WHERE corr.is_active = TRUE
      AND (p_contract_id IS NULL OR corr.contract_id = p_contract_id)
      AND (p_rule_id    IS NULL OR corr.rule_id    = p_rule_id)
      AND (p_signal_id  IS NULL OR corr.signal_id  = p_signal_id)
      AND (p_status     IS NULL OR corr.status     = p_status)
      AND (p_scenario   IS NULL OR cr.scenario     = p_scenario)
      AND (p_since      IS NULL OR corr.created_at >= p_since)
    ORDER BY corr.created_at DESC
    LIMIT  v_limit
    OFFSET v_offset
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',                id,
      'signalId',          signal_id,
      'contractId',        contract_id,
      'contractTitleEn',   title_en,
      'contractTitleAr',   title_ar,
      'ruleId',            rule_id,
      'ruleName',          rule_name,
      'ruleNameAr',        rule_name_ar,
      'scenario',          scenario,
      'ruleVersionHash',   rule_version_hash,
      'confidence',        confidence,
      'matchReason',       match_reason,
      'status',            status,
      'expiresAt',         expires_at,
      'dismissedAt',       dismissed_at,
      'dismissedReason',   dismissed_reason,
      'createdAt',         created_at
    )
  )
  INTO v_data
  FROM paged;

  RETURN jsonb_build_object(
    'data',       COALESCE(v_data, '[]'::jsonb),
    'pagination', jsonb_build_object(
      'total',      COALESCE(v_total, 0),
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', GREATEST(1, CEIL(COALESCE(v_total, 0)::numeric / v_limit))
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_correlation_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_correlation_list(INTEGER, INTEGER, BIGINT, TEXT, BIGINT, TEXT, TEXT, TIMESTAMPTZ, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_correlation_list(INTEGER, INTEGER, BIGINT, TEXT, BIGINT, TEXT, TEXT, TIMESTAMPTZ, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations(version, description) VALUES (167, '167_fix_fn_correlation_list_group_by') ON CONFLICT DO NOTHING;
