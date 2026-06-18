-- ============================================================================
-- Migration 705 — Consolidated activity feed (admin)
-- ============================================================================
-- The admin "Audit log" page is being reframed as a consolidated, cross-contract
-- version of the per-contract Activity tab: the same human-readable lifecycle
-- events (created, submitted, approved, sent for signature, signed, status
-- changed, …) for ALL contracts in one feed — not the raw table/record-id
-- audit_log grid.
--
-- fn_activity_feed_list reads contract_activity across every contract, excluding
-- the AI housekeeping events (hidden everywhere since mig 700) and inactive
-- rows. SECURITY DEFINER + audit.read gate: this is an admin oversight view, so
-- it intentionally spans all contracts regardless of per-row RLS.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION fn_activity_feed_list(
  p_page          INTEGER DEFAULT 1,
  p_limit         INTEGER DEFAULT 50,
  p_contract_id   BIGINT DEFAULT NULL,
  p_actor_id      BIGINT DEFAULT NULL,
  p_activity_type TEXT DEFAULT NULL,
  p_date_from     TIMESTAMPTZ DEFAULT NULL,
  p_date_to       TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user_id BIGINT;
  v_page    INTEGER := COALESCE(p_page, 1);
  v_limit   INTEGER := COALESCE(p_limit, 50);
  v_offset  INTEGER;
  v_total   BIGINT;
  v_data    JSONB;
BEGIN
  IF v_page < 1 THEN
    RAISE EXCEPTION 'fn_activity_feed_list: page must be >= 1' USING ERRCODE = '22023';
  END IF;
  IF v_limit < 1 OR v_limit > 200 THEN
    RAISE EXCEPTION 'fn_activity_feed_list: limit must be 1..200' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_activity_feed_list: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('audit.read') THEN
    RAISE EXCEPTION 'fn_activity_feed_list: forbidden — audit.read required' USING ERRCODE = '42501';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  SELECT COUNT(*) INTO v_total
  FROM contract_activity ca
  JOIN contract ct ON ct.id = ca.contract_id AND ct.is_active = TRUE
  WHERE ca.is_active = TRUE
    AND ca.activity_type NOT IN ('ai_summary_generated', 'ai_risk_score_updated', 'ai_diff_summary_generated')
    AND (p_contract_id   IS NULL OR ca.contract_id = p_contract_id)
    AND (p_actor_id      IS NULL OR ca.actor_id = p_actor_id)
    AND (p_activity_type IS NULL OR ca.activity_type = p_activity_type)
    AND (p_date_from     IS NULL OR ca.created_at >= p_date_from)
    AND (p_date_to       IS NULL OR ca.created_at <  p_date_to);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',             ca.id,
      'activityType',   ca.activity_type,
      'contractId',     ca.contract_id,
      'contractNumber', ct.contract_number,
      'contractTitle',  ct.title_en,
      'actor', CASE WHEN u.id IS NOT NULL THEN
                 jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
               ELSE NULL END,
      'actorEmail',     u.email,
      'descriptionEn',  ca.description_en,
      'descriptionAr',  ca.description_ar,
      'metadata',       ca.metadata,
      'createdAt',      ca.created_at
    ) ORDER BY ca.created_at DESC, ca.id DESC
  ), '[]'::jsonb)
    INTO v_data
  FROM (
    SELECT ca.*
    FROM contract_activity ca
    JOIN contract ct ON ct.id = ca.contract_id AND ct.is_active = TRUE
    WHERE ca.is_active = TRUE
      AND ca.activity_type NOT IN ('ai_summary_generated', 'ai_risk_score_updated', 'ai_diff_summary_generated')
      AND (p_contract_id   IS NULL OR ca.contract_id = p_contract_id)
      AND (p_actor_id      IS NULL OR ca.actor_id = p_actor_id)
      AND (p_activity_type IS NULL OR ca.activity_type = p_activity_type)
      AND (p_date_from     IS NULL OR ca.created_at >= p_date_from)
      AND (p_date_to       IS NULL OR ca.created_at <  p_date_to)
    ORDER BY ca.created_at DESC, ca.id DESC
    LIMIT v_limit OFFSET v_offset
  ) ca
  JOIN contract ct ON ct.id = ca.contract_id
  LEFT JOIN "user" u ON u.id = ca.actor_id;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'page',       v_page,
      'limit',      v_limit,
      'total',      v_total,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_limit)::INTEGER END
    )
  );
END;
$fn$;

REVOKE ALL ON FUNCTION fn_activity_feed_list(INTEGER, INTEGER, BIGINT, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_activity_feed_list(INTEGER, INTEGER, BIGINT, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO neondb_owner;
COMMENT ON FUNCTION fn_activity_feed_list(INTEGER, INTEGER, BIGINT, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) IS
  '705: consolidated cross-contract activity feed (admin oversight view). Same human events as the per-contract Activity tab, excluding AI housekeeping types. DEFINER + audit.read gate. Filters: contract, actor, type, date.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (705, 'activity_feed_list', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- DROP FUNCTION IF EXISTS fn_activity_feed_list(INTEGER, INTEGER, BIGINT, BIGINT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ);
-- DELETE FROM schema_migrations WHERE version = 705;
-- ROLLBACK END
