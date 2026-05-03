-- ============================================================================
-- 005_m1a_contract_functions.sql — M1a contract fn_ functions and activity triggers
-- ============================================================================
-- Module:   M1a (Contracts: Core CRUD & Lifecycle)
-- Owner:    Agent 4 — DB Architect
-- Depends:  001_foundation.sql, 002_security_hardening.sql, 003_m1a_contracts.sql, 004_m1a_extend_sensitive_fields.sql
-- ----------------------------------------------------------------------------
-- 12 fn_contract_* functions (10 public api + 1 SECURITY DEFINER helper +
-- fn_contract_delete which is SECURITY DEFINER), 2 trigger function bodies,
-- 2 CREATE TRIGGER bindings on contract / contract_version.
-- ----------------------------------------------------------------------------
-- Order:
--   1. fn_contract_activity_create (SECURITY DEFINER helper, called by triggers + status_update + set_tags)
--   2. fn_contract_get_by_id (read; called by fn_contract_create + fn_contract_update)
--   3. fn_contract_list, fn_contract_get_tree, fn_contract_version_list, fn_contract_activity_list (other reads)
--   4. fn_contract_create, fn_contract_update, fn_contract_delete, fn_contract_status_update,
--      fn_contract_set_tags, fn_contract_version_create (writes)
--   5. fn_trg_contract_activity_emit, fn_trg_contract_version_activity_emit (trigger bodies)
--   6. CREATE TRIGGER bindings
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- 1. fn_contract_activity_create — INTERNAL helper (SECURITY DEFINER)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_activity_create(
  p_contract_id    BIGINT,
  p_activity_type  TEXT,
  p_actor_id       BIGINT       DEFAULT NULL,
  p_description_en TEXT         DEFAULT NULL,
  p_description_ar TEXT         DEFAULT NULL,
  p_metadata       JSONB        DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id      BIGINT;
  v_actor   BIGINT;
BEGIN
  IF p_activity_type NOT IN ('created','updated','status_changed','version_created','tagged','soft_deleted','restored') THEN
    RAISE EXCEPTION 'fn_contract_activity_create: %', 'activityType:Invalid activity type';
  END IF;

  IF p_actor_id IS NOT NULL THEN
    v_actor := p_actor_id;
  ELSE
    BEGIN
      v_actor := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    EXCEPTION WHEN OTHERS THEN v_actor := NULL;
    END;
  END IF;

  INSERT INTO contract_activity (
    contract_id, activity_type, actor_id, description_en, description_ar, metadata
  ) VALUES (
    p_contract_id, p_activity_type, v_actor, p_description_en, p_description_ar, p_metadata
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) TO neondb_owner;

COMMENT ON FUNCTION fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) IS
  'INTERNAL helper. SECURITY DEFINER. Invoked ONLY by contract activity-write triggers (and fn_contract_status_update / fn_contract_set_tags directly when richer metadata than the trigger has access to is needed). Not exposed via HTTP API. EXECUTE granted only to neondb_owner — bypasses contract_activity RLS deny-direct-INSERT.';

-- ============================================================
-- 2. fn_contract_get_by_id — read (also called by create/update)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_get_by_id(
  p_id          BIGINT,
  p_actor_id    BIGINT,
  p_actor_role  TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row              contract%ROWTYPE;
  v_drafter          JSONB;
  v_reviewer         JSONB;
  v_approver         JSONB;
  v_tags             JSONB;
  v_attachment_count INTEGER := 0;
  v_comment_count    INTEGER := 0;
BEGIN
  SELECT * INTO v_row FROM contract WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_drafter
    FROM "user" u WHERE u.id = v_row.drafted_by;
  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_reviewer
    FROM "user" u WHERE u.id = v_row.reviewed_by;
  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_approver
    FROM "user" u WHERE u.id = v_row.approved_by;

  SELECT COALESCE(jsonb_agg(tag ORDER BY tag), '[]'::JSONB) INTO v_tags
    FROM contract_tag
    WHERE contract_id = p_id AND is_active = TRUE;

  IF to_regclass('public.contract_attachment') IS NOT NULL THEN
    EXECUTE 'SELECT COUNT(*)::INT FROM public.contract_attachment WHERE contract_id = $1 AND is_active = TRUE'
      INTO v_attachment_count
      USING p_id;
  END IF;
  IF to_regclass('public.contract_comment') IS NOT NULL THEN
    EXECUTE 'SELECT COUNT(*)::INT FROM public.contract_comment WHERE contract_id = $1 AND is_active = TRUE'
      INTO v_comment_count
      USING p_id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'contractNumber', v_row.contract_number,
    'titleEn', v_row.title_en,
    'titleAr', v_row.title_ar,
    'contractType', v_row.contract_type,
    'templateId', v_row.template_id,
    'status', v_row.status,
    'language', v_row.language,
    'ourPartyId', v_row.our_party_id,
    'counterpartyId', v_row.counterparty_id,
    'valueAed', v_row.value_aed,
    'currency', v_row.currency,
    'startDate', v_row.start_date,
    'endDate', v_row.end_date,
    'signedAt', v_row.signed_at,
    'expiryNoticeDays', v_row.expiry_notice_days,
    'emirate', v_row.emirate,
    'governingLaw', v_row.governing_law,
    'jurisdictionCourt', v_row.jurisdiction_court,
    'parentContractId', v_row.parent_contract_id,
    'relationshipType', v_row.relationship_type,
    'bodyEn', v_row.body_en,
    'bodyAr', v_row.body_ar,
    'currentVersion', v_row.current_version,
    'draftedBy', v_drafter,
    'reviewedBy', v_reviewer,
    'approvedBy', v_approver,
    'tags', v_tags,
    'attachmentCount', v_attachment_count,
    'commentCount', v_comment_count,
    'createdAt', v_row.created_at,
    'updatedAt', v_row.updated_at
  );
END;
$$;

COMMENT ON FUNCTION fn_contract_get_by_id IS
  'M1a single get. SECURITY INVOKER. Returns NULL when row missing or is_active=false (controller maps to 404). Actor enrichment via inline JOIN to "user". attachmentCount/commentCount tolerate the contract_attachment/contract_comment tables not yet existing (to_regclass guard).';

-- ============================================================
-- 3. fn_contract_list — read
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
      'totalPages', GREATEST(1, CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER))
    )
  );
END;
$$;

COMMENT ON FUNCTION fn_contract_list IS
  'M1a list. SECURITY INVOKER. Role-aware filter. body_en/body_ar EXCLUDED from output (AC-S1-08). Pagination 1..100 enforced.';

-- ============================================================
-- 4. fn_contract_get_tree — read
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_get_tree(
  p_id         BIGINT,
  p_actor_id   BIGINT,
  p_actor_role TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_root_id  BIGINT;
  v_tree     JSONB;
  v_truncated BOOLEAN := FALSE;
  v_role_can_see_all BOOLEAN;
BEGIN
  PERFORM 1 FROM contract WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_get_tree: %', 'id:Contract not found';
  END IF;

  v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive');

  WITH RECURSIVE up_tree AS (
    SELECT id, parent_contract_id, 1 AS depth
      FROM contract
      WHERE id = p_id
    UNION ALL
    SELECT c.id, c.parent_contract_id, ut.depth + 1
      FROM contract c
      INNER JOIN up_tree ut ON c.id = ut.parent_contract_id
      WHERE c.is_active = TRUE AND ut.depth < 20
  )
  SELECT id INTO v_root_id FROM up_tree WHERE parent_contract_id IS NULL ORDER BY depth DESC LIMIT 1;
  IF v_root_id IS NULL THEN
    WITH RECURSIVE up_tree2 AS (
      SELECT id, parent_contract_id, 1 AS depth
        FROM contract
        WHERE id = p_id
      UNION ALL
      SELECT c.id, c.parent_contract_id, ut.depth + 1
        FROM contract c
        INNER JOIN up_tree2 ut ON c.id = ut.parent_contract_id
        WHERE c.is_active = TRUE AND ut.depth < 20
    )
    SELECT id INTO v_root_id FROM up_tree2 ORDER BY depth DESC LIMIT 1;
    v_truncated := TRUE;
  END IF;

  WITH RECURSIVE down_tree AS (
    SELECT id, contract_number, title_en, status, parent_contract_id, relationship_type, created_at, 0 AS depth
      FROM contract
      WHERE id = v_root_id AND is_active = TRUE
    UNION ALL
    SELECT c.id, c.contract_number, c.title_en, c.status, c.parent_contract_id, c.relationship_type, c.created_at, dt.depth + 1
      FROM contract c
      INNER JOIN down_tree dt ON c.parent_contract_id = dt.id
      WHERE c.is_active = TRUE AND dt.depth < 20
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', dt.id,
    'contractNumber', dt.contract_number,
    'titleEn', dt.title_en,
    'status', dt.status,
    'parentContractId', dt.parent_contract_id,
    'relationshipType', dt.relationship_type,
    'createdAt', dt.created_at,
    'depth', dt.depth
  ) ORDER BY dt.depth, dt.created_at), '[]'::JSONB) INTO v_tree
    FROM down_tree dt
    WHERE
      v_role_can_see_all
      OR EXISTS (
        SELECT 1 FROM contract c2
          WHERE c2.id = dt.id
            AND (c2.drafted_by = p_actor_id OR c2.reviewed_by = p_actor_id OR c2.approved_by = p_actor_id OR c2.created_by = p_actor_id));

  IF EXISTS (
    WITH RECURSIVE dt2 AS (
      SELECT id, parent_contract_id, 0 AS depth FROM contract WHERE id = v_root_id AND is_active = TRUE
      UNION ALL
      SELECT c.id, c.parent_contract_id, dt2.depth + 1
        FROM contract c
        INNER JOIN dt2 ON c.parent_contract_id = dt2.id
        WHERE c.is_active = TRUE AND dt2.depth < 21)
    SELECT 1 FROM dt2 WHERE depth = 21
  ) THEN
    v_truncated := TRUE;
  END IF;

  RETURN jsonb_build_object(
    'rootId', v_root_id,
    'tree', v_tree,
    'currentNode', p_id,
    'truncated', v_truncated
  );
END;
$$;

COMMENT ON FUNCTION fn_contract_get_tree IS
  'M1a parent/child tree. SECURITY INVOKER. Walks up to root then down via two recursive CTEs each capped at depth 20. Truncation flag set if cap reached. Role-aware filter omits invisible nodes (not redacted placeholders, per AC-S7-04).';

-- ============================================================
-- 5. fn_contract_version_list — read
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
      'totalPages', GREATEST(1, CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER))
    )
  );
END;
$$;

COMMENT ON FUNCTION fn_contract_version_list IS 'M1a version list. SECURITY INVOKER. Newest-first; bodyEn/bodyAr returned but pino-redacted in BE logs. RLS contract_version_select_parent_aware enforces parent visibility.';

-- ============================================================
-- 6. fn_contract_activity_list — read
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
      'totalPages', GREATEST(1, CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER))
    )
  );
END;
$$;

COMMENT ON FUNCTION fn_contract_activity_list IS 'M1a activity list. SECURITY INVOKER. Newest-first. Optional activityType filter. Parent visibility enforced by RLS contract_activity_select_parent_aware.';

-- ============================================================
-- 7. fn_contract_create — write
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_create(
  p_data     JSONB,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id              BIGINT;
  v_contract_number VARCHAR(50);
  v_year            INTEGER := EXTRACT(YEAR FROM CURRENT_TIMESTAMP)::INTEGER;
  v_seq             INTEGER;
  v_attempt         INTEGER := 0;
  v_inserted        BOOLEAN := FALSE;
  v_tag             TEXT;
  v_parent_id       BIGINT;
  v_value           NUMERIC;
  v_start           DATE;
  v_end             DATE;
  v_lang            TEXT;
  v_law             TEXT;
  v_rel             TEXT;
BEGIN
  IF NULLIF(TRIM(p_data->>'titleEn'), '') IS NULL THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'titleEn:Title (English) is required';
  END IF;
  IF NULLIF(TRIM(p_data->>'contractType'), '') IS NULL THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'contractType:Contract type is required';
  END IF;

  v_value := NULLIF(p_data->>'valueAed','')::NUMERIC;
  IF v_value IS NOT NULL AND v_value < 0 THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'valueAed:Value must be greater than or equal to zero';
  END IF;

  v_start := NULLIF(p_data->>'startDate','')::DATE;
  v_end   := NULLIF(p_data->>'endDate','')::DATE;
  IF v_start IS NOT NULL AND v_end IS NOT NULL AND v_end < v_start THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'endDate:End date must be on or after start date';
  END IF;

  v_lang := COALESCE(NULLIF(p_data->>'language',''), 'en');
  IF v_lang NOT IN ('en','ar','bilingual') THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'language:Invalid language';
  END IF;

  v_law := NULLIF(p_data->>'governingLaw','');
  IF v_law IS NOT NULL AND v_law NOT IN ('uae_federal','dubai','abu_dhabi','sharjah','difc','adgm','english','other') THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'governingLaw:Invalid governing law';
  END IF;

  v_rel := NULLIF(p_data->>'relationshipType','');
  IF v_rel IS NOT NULL AND v_rel NOT IN ('amendment','renewal','extension','superseded','sow_under_msa') THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'relationshipType:Invalid relationship type';
  END IF;

  v_parent_id := NULLIF(p_data->>'parentContractId','')::BIGINT;
  IF v_parent_id IS NOT NULL THEN
    PERFORM 1 FROM contract WHERE id = v_parent_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'fn_contract_create: %', 'parentContractId:Parent contract not found';
    END IF;
  END IF;

  LOOP
    v_attempt := v_attempt + 1;
    SELECT COALESCE(MAX(CAST(SUBSTRING(contract_number FROM 'CT-' || v_year || '-(\d+)$') AS INTEGER)), 0) + 1
      INTO v_seq
      FROM contract
      WHERE contract_number LIKE 'CT-' || v_year || '-%';
    v_contract_number := 'CT-' || v_year || '-' || LPAD(v_seq::TEXT, 6, '0');

    BEGIN
      INSERT INTO contract (
        contract_number, title_en, title_ar, contract_type, template_id, status,
        language, our_party_id, counterparty_id, value_aed, currency,
        start_date, end_date, signed_at, expiry_notice_days,
        emirate, governing_law, jurisdiction_court,
        parent_contract_id, relationship_type, body_en, body_ar,
        current_version, drafted_by, reviewed_by, approved_by,
        created_by, updated_by
      ) VALUES (
        v_contract_number,
        p_data->>'titleEn',
        NULLIF(p_data->>'titleAr',''),
        p_data->>'contractType',
        NULLIF(p_data->>'templateId','')::BIGINT,
        'draft',
        v_lang,
        NULLIF(p_data->>'ourPartyId','')::BIGINT,
        NULLIF(p_data->>'counterpartyId','')::BIGINT,
        v_value,
        COALESCE(NULLIF(p_data->>'currency',''), 'AED'),
        v_start,
        v_end,
        NULLIF(p_data->>'signedAt','')::TIMESTAMPTZ,
        COALESCE(NULLIF(p_data->>'expiryNoticeDays','')::INTEGER, 30),
        NULLIF(p_data->>'emirate',''),
        v_law,
        NULLIF(p_data->>'jurisdictionCourt',''),
        v_parent_id,
        v_rel,
        NULLIF(p_data->>'bodyEn',''),
        NULLIF(p_data->>'bodyAr',''),
        1,
        COALESCE(NULLIF(p_data->>'draftedBy','')::BIGINT, p_actor_id),
        NULLIF(p_data->>'reviewedBy','')::BIGINT,
        NULLIF(p_data->>'approvedBy','')::BIGINT,
        p_actor_id,
        p_actor_id
      ) RETURNING id INTO v_id;
      v_inserted := TRUE;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF v_attempt >= 3 THEN
        RAISE EXCEPTION 'fn_contract_create: %', 'contractNumber:Contract number already exists';
      END IF;
    END;
  END LOOP;

  IF p_data ? 'tags' AND jsonb_typeof(p_data->'tags') = 'array' THEN
    FOR v_tag IN SELECT TRIM(value::TEXT, '"') FROM jsonb_array_elements_text(p_data->'tags')
    LOOP
      IF char_length(v_tag) BETWEEN 1 AND 64 THEN
        INSERT INTO contract_tag (contract_id, tag, created_by)
        VALUES (v_id, v_tag, p_actor_id)
        ON CONFLICT DO NOTHING;
      ELSE
        RAISE EXCEPTION 'fn_contract_create: %', 'tags:Each tag must be 1 to 64 characters';
      END IF;
    END LOOP;
  END IF;

  RETURN fn_contract_get_by_id(v_id, p_actor_id, NULL);
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_create: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_create: %', SQLERRM;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_contract_create(JSONB, BIGINT) IS
  'M1a write. SECURITY INVOKER. Validates inputs, auto-generates CT-YYYY-NNNNNN contract_number with up to 3 retries on UNIQUE collision, INSERTs contract row, INSERTs contract_tag rows, returns the full row via fn_contract_get_by_id. Activity ''created'' is emitted by the AFTER INSERT trigger trg_contract_activity_emit_iu.';

-- ============================================================
-- 8. fn_contract_update — write
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_update(
  p_id       BIGINT,
  p_data     JSONB,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing      contract%ROWTYPE;
  v_new_start     DATE;
  v_new_end       DATE;
  v_new_parent_id BIGINT;
  v_body_en_changed BOOLEAN := FALSE;
  v_body_ar_changed BOOLEAN := FALSE;
  v_body_en_new   TEXT;
  v_body_ar_new   TEXT;
  v_change_note   TEXT;
  v_new_version   INTEGER;
  v_lang          TEXT;
  v_law           TEXT;
  v_rel           TEXT;
  v_value         NUMERIC;
  v_cycle_count   INTEGER;
BEGIN
  SELECT * INTO v_existing FROM contract WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_update: %', 'id:Contract not found';
  END IF;

  IF p_data ? 'status' THEN
    RAISE EXCEPTION 'fn_contract_update: %', 'status:Use fn_contract_status_update to change status';
  END IF;

  IF p_data ? 'language' THEN
    v_lang := p_data->>'language';
    IF v_lang NOT IN ('en','ar','bilingual') THEN
      RAISE EXCEPTION 'fn_contract_update: %', 'language:Invalid language';
    END IF;
  END IF;
  IF p_data ? 'governingLaw' THEN
    v_law := NULLIF(p_data->>'governingLaw','');
    IF v_law IS NOT NULL AND v_law NOT IN ('uae_federal','dubai','abu_dhabi','sharjah','difc','adgm','english','other') THEN
      RAISE EXCEPTION 'fn_contract_update: %', 'governingLaw:Invalid governing law';
    END IF;
  END IF;
  IF p_data ? 'relationshipType' THEN
    v_rel := NULLIF(p_data->>'relationshipType','');
    IF v_rel IS NOT NULL AND v_rel NOT IN ('amendment','renewal','extension','superseded','sow_under_msa') THEN
      RAISE EXCEPTION 'fn_contract_update: %', 'relationshipType:Invalid relationship type';
    END IF;
  END IF;

  IF p_data ? 'valueAed' THEN
    v_value := NULLIF(p_data->>'valueAed','')::NUMERIC;
    IF v_value IS NOT NULL AND v_value < 0 THEN
      RAISE EXCEPTION 'fn_contract_update: %', 'valueAed:Value must be greater than or equal to zero';
    END IF;
  END IF;

  v_new_start := COALESCE(NULLIF(p_data->>'startDate','')::DATE, v_existing.start_date);
  v_new_end   := COALESCE(NULLIF(p_data->>'endDate','')::DATE,   v_existing.end_date);
  IF v_new_start IS NOT NULL AND v_new_end IS NOT NULL AND v_new_end < v_new_start THEN
    RAISE EXCEPTION 'fn_contract_update: %', 'endDate:End date must be on or after start date';
  END IF;

  IF p_data ? 'parentContractId' THEN
    v_new_parent_id := NULLIF(p_data->>'parentContractId','')::BIGINT;
    IF v_new_parent_id = p_id THEN
      RAISE EXCEPTION 'fn_contract_update: %', 'parentContractId:Contract cannot be its own parent';
    END IF;
    IF v_new_parent_id IS NOT NULL THEN
      PERFORM 1 FROM contract WHERE id = v_new_parent_id AND is_active = TRUE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_contract_update: %', 'parentContractId:Parent contract not found';
      END IF;
      WITH RECURSIVE ancestors(id, parent_contract_id, depth) AS (
        SELECT id, parent_contract_id, 1
          FROM contract
          WHERE id = v_new_parent_id
        UNION ALL
        SELECT c.id, c.parent_contract_id, a.depth + 1
          FROM contract c
          INNER JOIN ancestors a ON c.id = a.parent_contract_id
          WHERE a.depth < 20
      )
      SELECT COUNT(*) INTO v_cycle_count FROM ancestors WHERE id = p_id;
      IF v_cycle_count > 0 THEN
        RAISE EXCEPTION 'fn_contract_update: %', 'parentContractId:Cycle detected in contract tree';
      END IF;
    END IF;
  END IF;

  IF p_data ? 'bodyEn' THEN
    v_body_en_new := NULLIF(p_data->>'bodyEn','');
    v_body_en_changed := (v_body_en_new IS DISTINCT FROM v_existing.body_en);
  END IF;
  IF p_data ? 'bodyAr' THEN
    v_body_ar_new := NULLIF(p_data->>'bodyAr','');
    v_body_ar_changed := (v_body_ar_new IS DISTINCT FROM v_existing.body_ar);
  END IF;

  UPDATE contract SET
    title_en           = COALESCE(NULLIF(p_data->>'titleEn',''),               title_en),
    title_ar           = CASE WHEN p_data ? 'titleAr' THEN NULLIF(p_data->>'titleAr','') ELSE title_ar END,
    contract_type      = COALESCE(NULLIF(p_data->>'contractType',''),          contract_type),
    template_id        = CASE WHEN p_data ? 'templateId' THEN NULLIF(p_data->>'templateId','')::BIGINT ELSE template_id END,
    language           = COALESCE(v_lang,                                       language),
    our_party_id       = CASE WHEN p_data ? 'ourPartyId' THEN NULLIF(p_data->>'ourPartyId','')::BIGINT ELSE our_party_id END,
    counterparty_id    = CASE WHEN p_data ? 'counterpartyId' THEN NULLIF(p_data->>'counterpartyId','')::BIGINT ELSE counterparty_id END,
    value_aed          = CASE WHEN p_data ? 'valueAed' THEN v_value ELSE value_aed END,
    currency           = COALESCE(NULLIF(p_data->>'currency',''),               currency),
    start_date         = CASE WHEN p_data ? 'startDate' THEN v_new_start ELSE start_date END,
    end_date           = CASE WHEN p_data ? 'endDate'   THEN v_new_end   ELSE end_date END,
    signed_at          = CASE WHEN p_data ? 'signedAt'  THEN NULLIF(p_data->>'signedAt','')::TIMESTAMPTZ ELSE signed_at END,
    expiry_notice_days = COALESCE(NULLIF(p_data->>'expiryNoticeDays','')::INTEGER, expiry_notice_days),
    emirate            = CASE WHEN p_data ? 'emirate'           THEN NULLIF(p_data->>'emirate','') ELSE emirate END,
    governing_law      = CASE WHEN p_data ? 'governingLaw'      THEN v_law ELSE governing_law END,
    jurisdiction_court = CASE WHEN p_data ? 'jurisdictionCourt' THEN NULLIF(p_data->>'jurisdictionCourt','') ELSE jurisdiction_court END,
    parent_contract_id = CASE WHEN p_data ? 'parentContractId'  THEN v_new_parent_id ELSE parent_contract_id END,
    relationship_type  = CASE WHEN p_data ? 'relationshipType'  THEN v_rel ELSE relationship_type END,
    body_en            = CASE WHEN v_body_en_changed THEN v_body_en_new ELSE body_en END,
    body_ar            = CASE WHEN v_body_ar_changed THEN v_body_ar_new ELSE body_ar END,
    drafted_by         = CASE WHEN p_data ? 'draftedBy'  THEN NULLIF(p_data->>'draftedBy','')::BIGINT  ELSE drafted_by  END,
    reviewed_by        = CASE WHEN p_data ? 'reviewedBy' THEN NULLIF(p_data->>'reviewedBy','')::BIGINT ELSE reviewed_by END,
    approved_by        = CASE WHEN p_data ? 'approvedBy' THEN NULLIF(p_data->>'approvedBy','')::BIGINT ELSE approved_by END,
    updated_at         = CURRENT_TIMESTAMP,
    updated_by         = p_actor_id
  WHERE id = p_id;

  IF v_body_en_changed OR v_body_ar_changed THEN
    v_change_note := COALESCE(NULLIF(p_data->>'changeNote',''), 'Body update via fn_contract_update');
    PERFORM 1 FROM contract WHERE id = p_id FOR UPDATE;

    SELECT COALESCE(MAX(version_number), 0) + 1 INTO v_new_version
      FROM contract_version
      WHERE contract_id = p_id;

    INSERT INTO contract_version (
      contract_id, version_number, body_en, body_ar, diff_summary, change_note, changed_by, created_by
    ) VALUES (
      p_id,
      v_new_version,
      COALESCE(v_body_en_new, v_existing.body_en),
      COALESCE(v_body_ar_new, v_existing.body_ar),
      NULL,
      v_change_note,
      p_actor_id,
      p_actor_id
    );

    UPDATE contract SET current_version = v_new_version WHERE id = p_id;
  END IF;

  RETURN fn_contract_get_by_id(p_id, p_actor_id, NULL);
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_update: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_update: %', SQLERRM;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_contract_update(BIGINT, JSONB, BIGINT) IS
  'M1a partial-update. SECURITY INVOKER. Refuses status changes (use fn_contract_status_update). Detects body changes and creates a contract_version row with FOR UPDATE lock for atomic version_number increment. Cycle detection via recursive CTE capped at depth 20.';

-- ============================================================
-- 9. fn_contract_delete — write (SECURITY DEFINER, TOCTOU defense)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_delete(
  p_id       BIGINT,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_locked_id   BIGINT;
  v_active      BOOLEAN;
  v_child_count INTEGER;
BEGIN
  SELECT id, is_active INTO v_locked_id, v_active
    FROM contract
    WHERE id = p_id
    FOR UPDATE;

  IF NOT FOUND OR NOT v_active THEN
    RAISE EXCEPTION 'fn_contract_delete: %', 'id:Contract not found';
  END IF;

  SELECT COUNT(*) INTO v_child_count
    FROM contract
    WHERE parent_contract_id = p_id
      AND is_active = TRUE;

  IF v_child_count > 0 THEN
    RAISE EXCEPTION 'fn_contract_delete: %', 'children:Cannot delete contract with active child contracts';
  END IF;

  PERFORM set_config('app.fn_contract_delete', 'true', true);

  UPDATE contract
    SET is_active = FALSE,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id
    WHERE id = p_id;

  UPDATE contract_tag
    SET is_active = FALSE
    WHERE contract_id = p_id AND is_active = TRUE;

  PERFORM set_config('app.fn_contract_delete', '', true);

  RETURN jsonb_build_object('success', true, 'id', p_id, 'message', 'Contract deactivated');
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('app.fn_contract_delete', '', true);
    IF SQLERRM LIKE 'fn_contract_delete: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_delete: %', SQLERRM;
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_delete(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_delete(BIGINT, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_contract_delete(BIGINT, BIGINT) IS
  'M1a soft-delete. SECURITY DEFINER. Codex G2 TOCTOU defense: SELECT ... FOR UPDATE locks the row, child-active check is inside the lock, then flag flip. Sets transaction-local GUC app.fn_contract_delete=true so the companion RLS policy contract_deny_direct_is_active_update permits THIS update only.';

-- ============================================================
-- 10. fn_contract_status_update — write
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_status_update(
  p_id         BIGINT,
  p_new_status TEXT,
  p_actor_id   BIGINT,
  p_reason     TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing_status TEXT;
BEGIN
  SELECT status INTO v_existing_status
    FROM contract
    WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_status_update: %', 'id:Contract not found';
  END IF;

  IF p_new_status NOT IN ('draft','in_review','approved','awaiting_signature_employer','awaiting_signature_counterparty','fully_signed','active','expiring_soon','expired','amended','renewed','terminated','rejected','resubmission_requested') THEN
    RAISE EXCEPTION 'fn_contract_status_update: %', 'newStatus:Invalid status';
  END IF;

  IF v_existing_status = p_new_status THEN
    RAISE EXCEPTION 'fn_contract_status_update: %', 'newStatus:Status is already ' || p_new_status;
  END IF;

  UPDATE contract
    SET status = p_new_status,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id
    WHERE id = p_id;

  PERFORM fn_contract_activity_create(
    p_id,
    'status_changed',
    p_actor_id,
    NULL,
    NULL,
    jsonb_build_object('fromStatus', v_existing_status, 'toStatus', p_new_status, 'reason', p_reason)
  );

  RETURN jsonb_build_object(
    'id', p_id,
    'fromStatus', v_existing_status,
    'toStatus', p_new_status,
    'changedAt', CURRENT_TIMESTAMP
  );
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_status_update: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_status_update: %', SQLERRM;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_contract_status_update(BIGINT, TEXT, BIGINT, TEXT) IS
  'M1a PLACEHOLDER. SECURITY INVOKER. Validates enum membership only — M2 will replace with state-machine-aware variant. Calls fn_contract_activity_create directly to capture p_reason in metadata; the AFTER UPDATE trigger detects the duplicate and skips re-emitting.';

-- ============================================================
-- 11. fn_contract_set_tags — write
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_set_tags(
  p_id       BIGINT,
  p_tags     TEXT[],
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tag_normalised TEXT;
  v_added          TEXT[] := ARRAY[]::TEXT[];
  v_removed        TEXT[] := ARRAY[]::TEXT[];
  v_current_tags   TEXT[];
  v_final_tags     TEXT[];
BEGIN
  PERFORM 1 FROM contract WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_set_tags: %', 'id:Contract not found';
  END IF;

  IF p_tags IS NOT NULL THEN
    FOR v_tag_normalised IN SELECT TRIM(unnest) FROM unnest(p_tags) LOOP
      IF char_length(v_tag_normalised) NOT BETWEEN 1 AND 64 THEN
        RAISE EXCEPTION 'fn_contract_set_tags: %', 'tags:Each tag must be 1 to 64 characters';
      END IF;
      IF v_tag_normalised ~ '[\x00-\x1F\x7F]' THEN
        RAISE EXCEPTION 'fn_contract_set_tags: %', 'tags:Tag must not contain control characters';
      END IF;
    END LOOP;
  END IF;

  SELECT COALESCE(array_agg(tag), ARRAY[]::TEXT[])
    INTO v_current_tags
    FROM contract_tag
    WHERE contract_id = p_id AND is_active = TRUE;

  SELECT COALESCE(array_agg(DISTINCT TRIM(t)), ARRAY[]::TEXT[])
    INTO v_final_tags
    FROM unnest(COALESCE(p_tags, ARRAY[]::TEXT[])) t
    WHERE TRIM(t) <> '';

  v_added   := (SELECT COALESCE(array_agg(t), ARRAY[]::TEXT[]) FROM unnest(v_final_tags) t WHERE NOT (t = ANY(v_current_tags)));
  v_removed := (SELECT COALESCE(array_agg(t), ARRAY[]::TEXT[]) FROM unnest(v_current_tags) t WHERE NOT (t = ANY(v_final_tags)));

  IF array_length(v_removed, 1) > 0 THEN
    UPDATE contract_tag
      SET is_active = FALSE
      WHERE contract_id = p_id
        AND is_active = TRUE
        AND tag = ANY(v_removed);
  END IF;

  IF array_length(v_added, 1) > 0 THEN
    UPDATE contract_tag
      SET is_active = TRUE,
          created_at = CURRENT_TIMESTAMP,
          created_by = p_actor_id
      WHERE contract_id = p_id
        AND is_active = FALSE
        AND tag = ANY(v_added);
    INSERT INTO contract_tag (contract_id, tag, created_by)
      SELECT p_id, t, p_actor_id
        FROM unnest(v_added) t
        WHERE NOT EXISTS (
          SELECT 1 FROM contract_tag ct
            WHERE ct.contract_id = p_id AND ct.tag = t AND ct.is_active = TRUE
        );
  END IF;

  IF (array_length(v_added,1) > 0) OR (array_length(v_removed,1) > 0) THEN
    PERFORM fn_contract_activity_create(
      p_id,
      'tagged',
      p_actor_id,
      NULL,
      NULL,
      jsonb_build_object('added', to_jsonb(v_added), 'removed', to_jsonb(v_removed))
    );
  END IF;

  RETURN jsonb_build_object('id', p_id, 'tags', to_jsonb(v_final_tags));
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_set_tags: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_set_tags: %', SQLERRM;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_contract_set_tags(BIGINT, TEXT[], BIGINT) IS
  'M1a tag-set replacement. SECURITY INVOKER. Computes added/removed diff against current active set, soft-deletes removed and re-inserts (or reactivates) added, emits a single statement-level "tagged" activity with metadata={added, removed}.';

-- ============================================================
-- 12. fn_contract_version_create — write
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_version_create(
  p_contract_id BIGINT,
  p_data        JSONB,
  p_actor_id    BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_existing      contract%ROWTYPE;
  v_new_version   INTEGER;
  v_body_en_new   TEXT;
  v_body_ar_new   TEXT;
  v_change_note   TEXT;
  v_new_id        BIGINT;
  v_now           TIMESTAMPTZ := CURRENT_TIMESTAMP;
BEGIN
  SELECT * INTO v_existing
    FROM contract
    WHERE id = p_contract_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_version_create: %', 'contractId:Contract not found';
  END IF;

  v_body_en_new := NULLIF(p_data->>'bodyEn','');
  v_body_ar_new := NULLIF(p_data->>'bodyAr','');
  IF v_body_en_new IS NULL AND v_body_ar_new IS NULL THEN
    RAISE EXCEPTION 'fn_contract_version_create: %', 'body:At least one of bodyEn or bodyAr must be provided';
  END IF;

  v_change_note := NULLIF(TRIM(p_data->>'changeNote'),'');
  IF v_change_note IS NULL THEN
    RAISE EXCEPTION 'fn_contract_version_create: %', 'changeNote:Change note is required';
  END IF;

  SELECT COALESCE(MAX(version_number), 0) + 1
    INTO v_new_version
    FROM contract_version
    WHERE contract_id = p_contract_id;

  BEGIN
    INSERT INTO contract_version (
      contract_id, version_number, body_en, body_ar, diff_summary, change_note, changed_by, created_by
    ) VALUES (
      p_contract_id,
      v_new_version,
      COALESCE(v_body_en_new, v_existing.body_en),
      COALESCE(v_body_ar_new, v_existing.body_ar),
      NULLIF(p_data->>'diffSummary',''),
      v_change_note,
      p_actor_id,
      p_actor_id
    ) RETURNING id INTO v_new_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'fn_contract_version_create: %', 'versionNumber:Version conflict — please retry';
  END;

  UPDATE contract
    SET body_en         = COALESCE(v_body_en_new, body_en),
        body_ar         = COALESCE(v_body_ar_new, body_ar),
        current_version = v_new_version,
        updated_at      = v_now,
        updated_by      = p_actor_id
    WHERE id = p_contract_id;

  RETURN jsonb_build_object(
    'id', v_new_id,
    'versionNumber', v_new_version,
    'contractId', p_contract_id,
    'createdAt', v_now
  );
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_version_create: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_version_create: %', SQLERRM;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_contract_version_create(BIGINT, JSONB, BIGINT) IS
  'M1a version snapshot. SECURITY INVOKER. SELECT FOR UPDATE on parent contract row guarantees atomic version_number increment. Updates contract head pointer (body + current_version) inside the same txn.';

-- ============================================================
-- 13. Trigger function bodies + bindings
-- ============================================================

CREATE OR REPLACE FUNCTION fn_trg_contract_activity_emit() RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM fn_contract_activity_create(NEW.id, 'created', NULL, NULL, NULL, NULL);
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
      IF NOT EXISTS (
        SELECT 1 FROM contract_activity
          WHERE contract_id = NEW.id
            AND activity_type = 'status_changed'
            AND created_at > CURRENT_TIMESTAMP - INTERVAL '1 second'
            AND metadata->>'fromStatus' = OLD.status
            AND metadata->>'toStatus' = NEW.status
      ) THEN
        PERFORM fn_contract_activity_create(
          NEW.id, 'status_changed', NULL, NULL, NULL,
          jsonb_build_object('fromStatus', OLD.status, 'toStatus', NEW.status));
      END IF;
    END IF;

    IF OLD.is_active = TRUE AND NEW.is_active = FALSE THEN
      PERFORM fn_contract_activity_create(NEW.id, 'soft_deleted', NULL, NULL, NULL, NULL);
    ELSIF OLD.is_active = FALSE AND NEW.is_active = TRUE THEN
      PERFORM fn_contract_activity_create(NEW.id, 'restored', NULL, NULL, NULL, NULL);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_contract_activity_emit_iu ON contract;
CREATE TRIGGER trg_contract_activity_emit_iu
  AFTER INSERT OR UPDATE OF status, is_active ON contract
  FOR EACH ROW EXECUTE FUNCTION fn_trg_contract_activity_emit();

CREATE OR REPLACE FUNCTION fn_trg_contract_version_activity_emit() RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM fn_contract_activity_create(
    NEW.contract_id,
    'version_created',
    NEW.changed_by,
    NULL, NULL,
    jsonb_build_object('versionNumber', NEW.version_number));
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_contract_version_activity_emit ON contract_version;
CREATE TRIGGER trg_contract_version_activity_emit
  AFTER INSERT ON contract_version
  FOR EACH ROW EXECUTE FUNCTION fn_trg_contract_version_activity_emit();

-- ============================================================
-- 14. Record migration
-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (5, 'm1a_contract_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 005_m1a_contract_functions.sql
-- ============================================================================
-- ROLLBACK BEGIN
BEGIN;
  DROP TRIGGER IF EXISTS trg_contract_version_activity_emit ON contract_version;
  DROP TRIGGER IF EXISTS trg_contract_activity_emit_iu      ON contract;
  DROP FUNCTION IF EXISTS fn_trg_contract_version_activity_emit();
  DROP FUNCTION IF EXISTS fn_trg_contract_activity_emit();
  DROP FUNCTION IF EXISTS fn_contract_activity_list(BIGINT, INTEGER, INTEGER, TEXT, BIGINT, TEXT);
  DROP FUNCTION IF EXISTS fn_contract_activity_create(BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB);
  DROP FUNCTION IF EXISTS fn_contract_version_create(BIGINT, JSONB, BIGINT);
  DROP FUNCTION IF EXISTS fn_contract_version_list(BIGINT, INTEGER, INTEGER, BIGINT, TEXT);
  DROP FUNCTION IF EXISTS fn_contract_set_tags(BIGINT, TEXT[], BIGINT);
  DROP FUNCTION IF EXISTS fn_contract_get_tree(BIGINT, BIGINT, TEXT);
  DROP FUNCTION IF EXISTS fn_contract_status_update(BIGINT, TEXT, BIGINT, TEXT);
  DROP FUNCTION IF EXISTS fn_contract_delete(BIGINT, BIGINT);
  DROP FUNCTION IF EXISTS fn_contract_update(BIGINT, JSONB, BIGINT);
  DROP FUNCTION IF EXISTS fn_contract_create(JSONB, BIGINT);
  DROP FUNCTION IF EXISTS fn_contract_get_by_id(BIGINT, BIGINT, TEXT);
  DROP FUNCTION IF EXISTS fn_contract_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, BIGINT, BIGINT, DATE, DATE, DATE, DATE, TEXT[], TEXT, BIGINT, TEXT);
  DELETE FROM schema_migrations WHERE version = 5;
COMMIT;
-- ROLLBACK END
