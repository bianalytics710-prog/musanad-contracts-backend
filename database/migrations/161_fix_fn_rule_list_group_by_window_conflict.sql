-- Migration: 161_fix_fn_rule_list_group_by_window_conflict.sql
-- Module: M13 / CR-E fix — fn_rule_list PostgreSQL 17 GROUP BY + window fn conflict
-- Description: fn_rule_list original body used COUNT(*) OVER () as a window function
--   alongside jsonb_agg(...ORDER BY...) in the same SELECT...INTO statement.
--   PostgreSQL 17 enforces stricter rules and raises:
--     "column cr.last_reviewed_at must appear in the GROUP BY clause or be used in an aggregate function"
--   Fix: split into two queries — a COUNT query and a data-fetch query with subquery-level ORDER BY / LIMIT / OFFSET.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_rule_list(
  p_page     INTEGER DEFAULT 1,
  p_limit    INTEGER DEFAULT 20,
  p_scenario TEXT    DEFAULT NULL,
  p_enabled  BOOLEAN DEFAULT NULL,
  p_search   TEXT    DEFAULT NULL,
  p_actor_id BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_page   INTEGER := GREATEST(1, COALESCE(p_page, 1));
  v_limit  INTEGER := LEAST(100, GREATEST(1, COALESCE(p_limit, 20)));
  v_offset INTEGER;
  v_data   JSONB;
  v_total  BIGINT;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('rule.read') THEN
    RAISE EXCEPTION 'Permission denied: rule.read required' USING ERRCODE = '42501';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  -- Count total matching rows separately (avoids window fn + ORDER BY inside aggregate conflict on PG17)
  SELECT COUNT(*)
  INTO v_total
  FROM correlation_rule cr
  WHERE cr.is_active = TRUE
    AND (p_scenario IS NULL OR cr.scenario = p_scenario)
    AND (p_enabled  IS NULL OR cr.enabled  = p_enabled)
    AND (
      p_search IS NULL
      OR cr.name    ILIKE '%' || p_search || '%'
      OR cr.name_ar ILIKE '%' || p_search || '%'
    );

  -- Fetch page rows — ORDER BY + LIMIT + OFFSET in subquery, then jsonb_agg outer
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',               cr.id,
      'ruleId',           cr.rule_id,
      'name',             cr.name,
      'nameAr',           cr.name_ar,
      'scenario',         cr.scenario,
      'enabled',          cr.enabled,
      'versionHashShort', substr(cr.version_hash, 1, 8),
      'lastReviewedAt',   cr.last_reviewed_at,
      'createdAt',        cr.created_at,
      'updatedAt',        cr.updated_at,
      'fixtureCount',     COALESCE(
        (SELECT COUNT(*) FROM correlation_rule_fixture f
         WHERE f.correlation_rule_id = cr.id AND f.is_active = TRUE), 0)
    )
  )
  INTO v_data
  FROM (
    SELECT cr.*
    FROM correlation_rule cr
    WHERE cr.is_active = TRUE
      AND (p_scenario IS NULL OR cr.scenario = p_scenario)
      AND (p_enabled  IS NULL OR cr.enabled  = p_enabled)
      AND (
        p_search IS NULL
        OR cr.name    ILIKE '%' || p_search || '%'
        OR cr.name_ar ILIKE '%' || p_search || '%'
      )
    ORDER BY cr.last_reviewed_at ASC NULLS FIRST, cr.created_at ASC
    LIMIT  v_limit
    OFFSET v_offset
  ) cr;

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
    RAISE EXCEPTION 'fn_rule_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_rule_list(INTEGER, INTEGER, TEXT, BOOLEAN, TEXT, BIGINT)
  IS 'CR-E: List correlation rules with pagination, filters (scenario/enabled/search), and fixture count. PG17 fix: split COUNT and data queries.';

-- REVOKE / GRANT trio (S2-21)
REVOKE ALL ON FUNCTION fn_rule_list(INTEGER, INTEGER, TEXT, BOOLEAN, TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_rule_list(INTEGER, INTEGER, TEXT, BOOLEAN, TEXT, BIGINT) TO neondb_owner;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- To revert: restore the original fn_rule_list body from migration 153_cre_rule_functions.sql.
-- The original body used COUNT(*) OVER () in the same SELECT...INTO as jsonb_agg.
