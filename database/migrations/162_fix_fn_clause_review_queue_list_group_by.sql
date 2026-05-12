-- Migration: 162_fix_fn_clause_review_queue_list_group_by.sql
-- Module: M12 / CR-D — Defect fix surfaced during E2E browser walkthrough
--
-- DEFECT: fn_clause_review_queue_list mixes jsonb_agg() with COUNT(*) OVER ()
--   and ORDER BY non-aggregated columns in the same SELECT-INTO. PG17 rejects
--   with: column "cce.confidence" must appear in the GROUP BY clause.
--   Same family as the fn_rule_list defect fixed in migration 161.
-- FIX: split into separate paginated-data CTE and total-count query.
--
-- Verified by: GET /api/v1/clauses/review-queue → returns 200 with paginated
--   queue items (or empty array when no clauses awaiting review).
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_clause_review_queue_list(
  p_page             INTEGER,
  p_limit            INTEGER,
  p_contract_id      BIGINT,
  p_family           TEXT,
  p_confidence_band  TEXT,
  p_search           TEXT,
  p_actor_id         BIGINT
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
  -- Permission gate
  IF NOT fn_current_user_has_permission('clause.review') THEN
    RAISE EXCEPTION 'Permission denied: clause.review required' USING ERRCODE = '42501';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  -- Total count (separate query to avoid jsonb_agg + window function conflict)
  SELECT COUNT(*)
  INTO v_total
  FROM contract_clause_extracted cce
  JOIN contract c ON c.id = cce.contract_id
  JOIN clause_taxonomy ct ON ct.tenant_id = cce.tenant_id
    AND ct.clause_type_id = cce.clause_type_v2
  WHERE cce.review_status = 'pending_review'
    AND cce.is_active = TRUE
    AND (p_contract_id IS NULL OR cce.contract_id = p_contract_id)
    AND (p_family IS NULL OR ct.family = p_family)
    AND (
      p_confidence_band IS NULL
      OR (p_confidence_band = 'low'    AND (cce.confidence IS NULL OR cce.confidence < 0.50))
      OR (p_confidence_band = 'medium' AND cce.confidence BETWEEN 0.50 AND 0.70)
    )
    AND (
      p_search IS NULL
      OR c.title_en ILIKE '%' || p_search || '%'
      OR c.title_ar ILIKE '%' || p_search || '%'
    );

  -- Paginated data — order in an inner subquery, then aggregate.
  WITH paged AS (
    SELECT
      cce.id,
      cce.contract_id,
      c.title_en AS contract_title_en,
      c.title_ar AS contract_title_ar,
      cce.clause_type_v2,
      ct.family,
      ct.display_name_en,
      ct.display_name_ar,
      cce.parameters,
      cce.confidence,
      cce.page_no,
      cce.review_status,
      cce.created_at
    FROM contract_clause_extracted cce
    JOIN contract c ON c.id = cce.contract_id
    JOIN clause_taxonomy ct ON ct.tenant_id = cce.tenant_id
      AND ct.clause_type_id = cce.clause_type_v2
    WHERE cce.review_status = 'pending_review'
      AND cce.is_active = TRUE
      AND (p_contract_id IS NULL OR cce.contract_id = p_contract_id)
      AND (p_family IS NULL OR ct.family = p_family)
      AND (
        p_confidence_band IS NULL
        OR (p_confidence_band = 'low'    AND (cce.confidence IS NULL OR cce.confidence < 0.50))
        OR (p_confidence_band = 'medium' AND cce.confidence BETWEEN 0.50 AND 0.70)
      )
      AND (
        p_search IS NULL
        OR c.title_en ILIKE '%' || p_search || '%'
        OR c.title_ar ILIKE '%' || p_search || '%'
      )
    ORDER BY cce.confidence ASC NULLS FIRST, cce.created_at DESC
    LIMIT  v_limit
    OFFSET v_offset
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'id',                id,
      'contractId',        contract_id,
      'contractTitleEn',   contract_title_en,
      'contractTitleAr',   contract_title_ar,
      'clauseTypeV2',      clause_type_v2,
      'family',            family,
      'displayNameEn',     display_name_en,
      'displayNameAr',     display_name_ar,
      'parametersPreview', parameters,
      'confidence',        confidence,
      'pageNo',            page_no,
      'reviewStatus',      review_status,
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
    RAISE EXCEPTION 'fn_clause_review_queue_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_clause_review_queue_list(INTEGER, INTEGER, BIGINT, TEXT, TEXT, TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_clause_review_queue_list(INTEGER, INTEGER, BIGINT, TEXT, TEXT, TEXT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations(version, description) VALUES (162, '162_fix_fn_clause_review_queue_list_group_by') ON CONFLICT DO NOTHING;

-- ============================================================
-- ROLLBACK (manual; do not auto-run on rollback)
-- ============================================================
-- See migration 146 for the original body. Roll back by re-applying 146's
-- version of fn_clause_review_queue_list (acknowledging the GROUP BY defect
-- will return).
