-- ============================================================================
-- Migration 700 — Contract Activity tab: drop AI-generated noise events
-- ============================================================================
-- Per request, the contract detail "Activity" tab should narrate real
-- workflow events (drafted, edited, submitted, approved, status changes,
-- versions, signatures) and NOT the internal AI housekeeping events:
--   * ai_summary_generated
--   * ai_risk_score_updated
--   * ai_diff_summary_generated
--
-- Approach: exclude these three activity_type values at the READ layer in
-- fn_contract_activity_list (both the COUNT and the page query). The rows are
-- left in contract_activity untouched (reversible — the emit path in
-- fn_contract_ai_summary_persist / fn_contract_version_diff_summary_persist is
-- unchanged); they simply never surface in the tab again.
--
-- Signature unchanged (6-arg) — CREATE OR REPLACE only. Body identical to
-- migration 007 except the added NOT IN (...) predicate on activity_type.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION fn_contract_activity_list(
  p_contract_id    BIGINT,
  p_page           INTEGER DEFAULT 1,
  p_limit          INTEGER DEFAULT 50,
  p_activity_type  TEXT    DEFAULT NULL,
  p_actor_id       BIGINT  DEFAULT NULL,
  p_actor_role     TEXT    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset INTEGER;
  v_total  BIGINT;
  v_data   JSONB;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_contract_activity_list: %', 'page:Page must be >= 1';
  END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'fn_contract_activity_list: %', 'limit:Limit must be between 1 and 100';
  END IF;

  PERFORM 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_activity_list: %', 'contractId:Contract not found';
  END IF;

  v_offset := (p_page - 1) * p_limit;

  SELECT COUNT(*) INTO v_total
    FROM contract_activity ca
    WHERE ca.contract_id = p_contract_id
      AND ca.is_active = TRUE
      AND ca.activity_type NOT IN ('ai_summary_generated', 'ai_risk_score_updated', 'ai_diff_summary_generated')
      AND (p_activity_type IS NULL OR ca.activity_type = p_activity_type);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', ca.id,
    'activityType', ca.activity_type,
    'actor', CASE WHEN u.id IS NOT NULL THEN
                jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
              ELSE NULL END,
    'descriptionEn', ca.description_en,
    'descriptionAr', ca.description_ar,
    'metadata', ca.metadata,
    'createdAt', ca.created_at
  ) ORDER BY ca.created_at DESC), '[]'::JSONB) INTO v_data
    FROM (
      SELECT * FROM contract_activity
        WHERE contract_id = p_contract_id
          AND is_active = TRUE
          AND activity_type NOT IN ('ai_summary_generated', 'ai_risk_score_updated', 'ai_diff_summary_generated')
          AND (p_activity_type IS NULL OR activity_type = p_activity_type)
        ORDER BY created_at DESC
        LIMIT p_limit OFFSET v_offset
    ) ca
    LEFT JOIN "user" u ON u.id = ca.actor_id;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', v_total,
      'page', p_page,
      'limit', p_limit,
      'totalPages', CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER)
    )
  );
END;
$$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (700, 'activity_exclude_ai_events', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- Restores migration 007's body (no AI-type exclusion).
-- BEGIN;
-- CREATE OR REPLACE FUNCTION fn_contract_activity_list(
--   p_contract_id BIGINT, p_page INTEGER DEFAULT 1, p_limit INTEGER DEFAULT 50,
--   p_activity_type TEXT DEFAULT NULL, p_actor_id BIGINT DEFAULT NULL, p_actor_role TEXT DEFAULT NULL
-- ) RETURNS JSONB LANGUAGE plpgsql SECURITY INVOKER STABLE SET search_path = public, pg_temp
-- AS $$ ... (007 body without the NOT IN predicate) ... $$;
-- DELETE FROM schema_migrations WHERE version = 700;
-- COMMIT;
-- ROLLBACK END
