-- ============================================================================
-- 007_m1a_fix_total_pages_zero.sql
--   Pagination fix: totalPages must be 0 when total = 0 (was clamped to 1).
-- ============================================================================
-- Module:    M1a (Contracts: Core CRUD & Lifecycle) — patch
-- Owner:     DB Implementation Agent (smoke-test follow-up patch)
-- Depends:   005_m1a_contract_functions.sql
-- ----------------------------------------------------------------------------
-- Why:
--   fn_contract_list, fn_contract_version_list, fn_contract_activity_list
--   computed totalPages as GREATEST(1, CEIL(total/limit)) which forces
--   totalPages=1 even when total=0. Standard pagination math is
--   CEIL(0/N)=0 — empty list should report totalPages=0 so the FE
--   pager doesn't render a phantom "page 1 of 1".
--
-- Fix:
--   Remove the GREATEST(1, ...) clamp. CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER)
--   on its own naturally yields 0 when v_total=0.
--
-- Method:
--   CREATE OR REPLACE FUNCTION on each of the three affected fn_'s. Bodies
--   identical to migration 005 except the one totalPages expression.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- 1. fn_contract_list — fix totalPages math
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_list(
  p_page              INTEGER       DEFAULT 1,
  p_limit             INTEGER       DEFAULT 20,
  p_status            TEXT          DEFAULT NULL,
  p_contract_type     TEXT          DEFAULT NULL,
  p_counterparty_id   BIGINT        DEFAULT NULL,
  p_drafted_by        BIGINT        DEFAULT NULL,
  p_approved_by       BIGINT        DEFAULT NULL,
  p_start_date_from   DATE          DEFAULT NULL,
  p_start_date_to     DATE          DEFAULT NULL,
  p_end_date_from     DATE          DEFAULT NULL,
  p_end_date_to       DATE          DEFAULT NULL,
  p_tags              TEXT[]        DEFAULT NULL,
  p_search            TEXT          DEFAULT NULL,
  p_actor_id          BIGINT        DEFAULT NULL,
  p_actor_role        TEXT          DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset    INTEGER;
  v_total     BIGINT;
  v_data      JSONB;
  v_role_can_see_all BOOLEAN;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'page:Page must be >= 1';
  END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'limit:Limit must be between 1 and 100';
  END IF;

  v_offset := (p_page - 1) * p_limit;

  v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive');

  SELECT COUNT(*) INTO v_total
    FROM contract c
    WHERE c.is_active = TRUE
      AND (p_status IS NULL          OR c.status = p_status)
      AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
      AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
      AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
      AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
      AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
      AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
      AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
      AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
      AND (p_search IS NULL OR (
            lower(c.contract_number)    LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_en,'')) LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_ar,'')) LIKE '%' || lower(p_search) || '%'))
      AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
            (SELECT COUNT(*) FROM unnest(p_tags) tg
              WHERE EXISTS (
                SELECT 1 FROM contract_tag ct
                  WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
              )) = array_length(p_tags, 1)))
      AND (v_role_can_see_all OR (
            c.drafted_by  = p_actor_id
         OR c.reviewed_by = p_actor_id
         OR c.approved_by = p_actor_id
         OR c.created_by  = p_actor_id));

  SELECT COALESCE(jsonb_agg(row_to_payload), '[]'::JSONB) INTO v_data
    FROM (
      SELECT jsonb_build_object(
        'id', c.id,
        'contractNumber', c.contract_number,
        'titleEn', c.title_en,
        'titleAr', c.title_ar,
        'contractType', c.contract_type,
        'status', c.status,
        'valueAed', c.value_aed,
        'currency', c.currency,
        'startDate', c.start_date,
        'endDate', c.end_date,
        'counterpartyId', c.counterparty_id,
        'ourPartyId', c.our_party_id,
        'tags', COALESCE((SELECT jsonb_agg(ct.tag ORDER BY ct.tag)
                           FROM contract_tag ct
                           WHERE ct.contract_id = c.id AND ct.is_active = TRUE), '[]'::JSONB),
        'currentVersion', c.current_version,
        'createdAt', c.created_at,
        'updatedAt', c.updated_at
      ) AS row_to_payload
        FROM contract c
        WHERE c.is_active = TRUE
          AND (p_status IS NULL          OR c.status = p_status)
          AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
          AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
          AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
          AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
          AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
          AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
          AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
          AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
          AND (p_search IS NULL OR (
                lower(c.contract_number)    LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_en,'')) LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_ar,'')) LIKE '%' || lower(p_search) || '%'))
          AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
                (SELECT COUNT(*) FROM unnest(p_tags) tg
                  WHERE EXISTS (
                    SELECT 1 FROM contract_tag ct
                      WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
                  )) = array_length(p_tags, 1)))
          AND (v_role_can_see_all OR (
                c.drafted_by  = p_actor_id
             OR c.reviewed_by = p_actor_id
             OR c.approved_by = p_actor_id
             OR c.created_by  = p_actor_id))
        ORDER BY c.created_at DESC, c.end_date ASC NULLS LAST
        LIMIT p_limit OFFSET v_offset
    ) sub;

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

-- ============================================================
-- 2. fn_contract_version_list — fix totalPages math
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_version_list(
  p_contract_id BIGINT,
  p_page        INTEGER DEFAULT 1,
  p_limit       INTEGER DEFAULT 20,
  p_actor_id    BIGINT  DEFAULT NULL,
  p_actor_role  TEXT    DEFAULT NULL
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
    RAISE EXCEPTION 'fn_contract_version_list: %', 'page:Page must be >= 1';
  END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'fn_contract_version_list: %', 'limit:Limit must be between 1 and 100';
  END IF;

  PERFORM 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_version_list: %', 'contractId:Contract not found';
  END IF;

  v_offset := (p_page - 1) * p_limit;

  SELECT COUNT(*) INTO v_total FROM contract_version WHERE contract_id = p_contract_id AND is_active = TRUE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', cv.id,
    'versionNumber', cv.version_number,
    'bodyEn', cv.body_en,
    'bodyAr', cv.body_ar,
    'diffSummary', cv.diff_summary,
    'changeNote', cv.change_note,
    'changedBy', CASE WHEN u.id IS NOT NULL THEN
                   jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
                 ELSE NULL END,
    'createdAt', cv.created_at
  ) ORDER BY cv.version_number DESC), '[]'::JSONB) INTO v_data
    FROM (
      SELECT * FROM contract_version
        WHERE contract_id = p_contract_id AND is_active = TRUE
        ORDER BY version_number DESC
        LIMIT p_limit OFFSET v_offset
    ) cv
    LEFT JOIN "user" u ON u.id = cv.changed_by;

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

-- ============================================================
-- 3. fn_contract_activity_list — fix totalPages math
-- ============================================================

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
VALUES (7, 'm1a_fix_total_pages_zero', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 007_m1a_fix_total_pages_zero.sql
-- ============================================================================
-- Restores the GREATEST(1, ...) clamp on all three list functions.
-- ROLLBACK BEGIN
BEGIN;

CREATE OR REPLACE FUNCTION fn_contract_list(
  p_page              INTEGER       DEFAULT 1,
  p_limit             INTEGER       DEFAULT 20,
  p_status            TEXT          DEFAULT NULL,
  p_contract_type     TEXT          DEFAULT NULL,
  p_counterparty_id   BIGINT        DEFAULT NULL,
  p_drafted_by        BIGINT        DEFAULT NULL,
  p_approved_by       BIGINT        DEFAULT NULL,
  p_start_date_from   DATE          DEFAULT NULL,
  p_start_date_to     DATE          DEFAULT NULL,
  p_end_date_from     DATE          DEFAULT NULL,
  p_end_date_to       DATE          DEFAULT NULL,
  p_tags              TEXT[]        DEFAULT NULL,
  p_search            TEXT          DEFAULT NULL,
  p_actor_id          BIGINT        DEFAULT NULL,
  p_actor_role        TEXT          DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset    INTEGER;
  v_total     BIGINT;
  v_data      JSONB;
  v_role_can_see_all BOOLEAN;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'page:Page must be >= 1';
  END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'limit:Limit must be between 1 and 100';
  END IF;
  v_offset := (p_page - 1) * p_limit;
  v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive');
  SELECT COUNT(*) INTO v_total FROM contract c WHERE c.is_active = TRUE
      AND (p_status IS NULL          OR c.status = p_status)
      AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
      AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
      AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
      AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
      AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
      AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
      AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
      AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
      AND (p_search IS NULL OR (
            lower(c.contract_number)    LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_en,'')) LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_ar,'')) LIKE '%' || lower(p_search) || '%'))
      AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
            (SELECT COUNT(*) FROM unnest(p_tags) tg
              WHERE EXISTS (SELECT 1 FROM contract_tag ct
                  WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE)) = array_length(p_tags, 1)))
      AND (v_role_can_see_all OR (
            c.drafted_by  = p_actor_id OR c.reviewed_by = p_actor_id
         OR c.approved_by = p_actor_id OR c.created_by  = p_actor_id));
  SELECT COALESCE(jsonb_agg(row_to_payload), '[]'::JSONB) INTO v_data FROM (
      SELECT jsonb_build_object(
        'id', c.id, 'contractNumber', c.contract_number,
        'titleEn', c.title_en, 'titleAr', c.title_ar,
        'contractType', c.contract_type, 'status', c.status,
        'valueAed', c.value_aed, 'currency', c.currency,
        'startDate', c.start_date, 'endDate', c.end_date,
        'counterpartyId', c.counterparty_id, 'ourPartyId', c.our_party_id,
        'tags', COALESCE((SELECT jsonb_agg(ct.tag ORDER BY ct.tag) FROM contract_tag ct
                           WHERE ct.contract_id = c.id AND ct.is_active = TRUE), '[]'::JSONB),
        'currentVersion', c.current_version,
        'createdAt', c.created_at, 'updatedAt', c.updated_at
      ) AS row_to_payload
        FROM contract c WHERE c.is_active = TRUE
          AND (p_status IS NULL          OR c.status = p_status)
          AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
          AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
          AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
          AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
          AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
          AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
          AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
          AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
          AND (p_search IS NULL OR (
                lower(c.contract_number)    LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_en,'')) LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_ar,'')) LIKE '%' || lower(p_search) || '%'))
          AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
                (SELECT COUNT(*) FROM unnest(p_tags) tg
                  WHERE EXISTS (SELECT 1 FROM contract_tag ct
                      WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE)) = array_length(p_tags, 1)))
          AND (v_role_can_see_all OR (
                c.drafted_by  = p_actor_id OR c.reviewed_by = p_actor_id
             OR c.approved_by = p_actor_id OR c.created_by  = p_actor_id))
        ORDER BY c.created_at DESC, c.end_date ASC NULLS LAST
        LIMIT p_limit OFFSET v_offset
    ) sub;
  RETURN jsonb_build_object('data', v_data, 'pagination', jsonb_build_object(
      'total', v_total, 'page', p_page, 'limit', p_limit,
      'totalPages', GREATEST(1, CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER))));
END;
$$;

CREATE OR REPLACE FUNCTION fn_contract_version_list(
  p_contract_id BIGINT, p_page INTEGER DEFAULT 1, p_limit INTEGER DEFAULT 20,
  p_actor_id BIGINT DEFAULT NULL, p_actor_role TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY INVOKER STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_offset INTEGER; v_total BIGINT; v_data JSONB;
BEGIN
  IF p_page < 1 THEN RAISE EXCEPTION 'fn_contract_version_list: %', 'page:Page must be >= 1'; END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'fn_contract_version_list: %', 'limit:Limit must be between 1 and 100'; END IF;
  PERFORM 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fn_contract_version_list: %', 'contractId:Contract not found'; END IF;
  v_offset := (p_page - 1) * p_limit;
  SELECT COUNT(*) INTO v_total FROM contract_version WHERE contract_id = p_contract_id AND is_active = TRUE;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', cv.id, 'versionNumber', cv.version_number,
    'bodyEn', cv.body_en, 'bodyAr', cv.body_ar,
    'diffSummary', cv.diff_summary, 'changeNote', cv.change_note,
    'changedBy', CASE WHEN u.id IS NOT NULL THEN
                   jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
                 ELSE NULL END,
    'createdAt', cv.created_at) ORDER BY cv.version_number DESC), '[]'::JSONB) INTO v_data
    FROM (SELECT * FROM contract_version WHERE contract_id = p_contract_id AND is_active = TRUE
            ORDER BY version_number DESC LIMIT p_limit OFFSET v_offset) cv
    LEFT JOIN "user" u ON u.id = cv.changed_by;
  RETURN jsonb_build_object('data', v_data, 'pagination', jsonb_build_object(
      'total', v_total, 'page', p_page, 'limit', p_limit,
      'totalPages', GREATEST(1, CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER))));
END;
$$;

CREATE OR REPLACE FUNCTION fn_contract_activity_list(
  p_contract_id BIGINT, p_page INTEGER DEFAULT 1, p_limit INTEGER DEFAULT 50,
  p_activity_type TEXT DEFAULT NULL, p_actor_id BIGINT DEFAULT NULL, p_actor_role TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY INVOKER STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_offset INTEGER; v_total BIGINT; v_data JSONB;
BEGIN
  IF p_page < 1 THEN RAISE EXCEPTION 'fn_contract_activity_list: %', 'page:Page must be >= 1'; END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'fn_contract_activity_list: %', 'limit:Limit must be between 1 and 100'; END IF;
  PERFORM 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fn_contract_activity_list: %', 'contractId:Contract not found'; END IF;
  v_offset := (p_page - 1) * p_limit;
  SELECT COUNT(*) INTO v_total FROM contract_activity ca
    WHERE ca.contract_id = p_contract_id AND ca.is_active = TRUE
      AND (p_activity_type IS NULL OR ca.activity_type = p_activity_type);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', ca.id, 'activityType', ca.activity_type,
    'actor', CASE WHEN u.id IS NOT NULL THEN
                jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
              ELSE NULL END,
    'descriptionEn', ca.description_en, 'descriptionAr', ca.description_ar,
    'metadata', ca.metadata, 'createdAt', ca.created_at) ORDER BY ca.created_at DESC), '[]'::JSONB) INTO v_data
    FROM (SELECT * FROM contract_activity WHERE contract_id = p_contract_id AND is_active = TRUE
            AND (p_activity_type IS NULL OR activity_type = p_activity_type)
            ORDER BY created_at DESC LIMIT p_limit OFFSET v_offset) ca
    LEFT JOIN "user" u ON u.id = ca.actor_id;
  RETURN jsonb_build_object('data', v_data, 'pagination', jsonb_build_object(
      'total', v_total, 'page', p_page, 'limit', p_limit,
      'totalPages', GREATEST(1, CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER))));
END;
$$;

DELETE FROM schema_migrations WHERE version = 7;
COMMIT;
-- ROLLBACK END
