-- ============================================================================
-- 050_m5_regulatory_functions.sql
-- ============================================================================
-- Module:    M5 (Regulatory Radar)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   046 (permissions), 047 (contract_activity whitelist), 048 (regulator),
--            049 (regulation, impact_category, regulatory_update, regulatory_impact),
--            M0 (fn_current_user_has_permission), M1a (contract.drafted_by),
--            M1a..M4 fn_contract_activity_create (extended in 047 to 25-value whitelist).
-- ----------------------------------------------------------------------------
-- All 15 M5 fn_'s. Mandatory NNN_fn_<entity>_functions.sql migration per Agent 4
-- v2.1 quality check #14.
--
-- Security envelope (S2-21):
--   - 14 INVOKER + 1 DEFINER carve-out (fn_regulatory_impact_create_bulk per DN-3)
--   - Every fn_: SET search_path = public, pg_temp
--   - Every fn_: REVOKE ALL FROM PUBLIC + GRANT EXECUTE TO neondb_owner only
--   - Zero PUBLIC EXECUTE grants — count stays at 5 (M3 token-bearer fn_'s)
--
-- S2-19 fn-to-fn calls verified:
--   fn_contract_activity_create (BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) RETURNS JSONB — 6-arg M5/047 form
--   fn_current_user_has_permission (TEXT) RETURNS BOOLEAN — 1-arg canonical
--
-- S2-17 concurrency primitives: SELECT FOR UPDATE on every write path before mutation.
-- S2-18 NULL-safe equality: IS NOT DISTINCT FROM on regulatory_update_id; COALESCE-sentinel ON CONFLICT.
-- S2-22 column-existence: every UPDATE/INSERT cross-checked against 049 DDL.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- WRITE FUNCTION 1 of 9: fn_regulation_create (S3 — INVOKER)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulation_create(
  p_reference_code   TEXT,
  p_title_en         TEXT,
  p_title_ar         TEXT,
  p_issuer_id        BIGINT,
  p_regulation_type  TEXT,
  p_jurisdiction     TEXT,
  p_effective_date   DATE,
  p_summary_en       TEXT,
  p_summary_ar       TEXT,
  p_source_url       TEXT,
  p_tags             TEXT[],
  p_status           TEXT,
  p_actor_id         BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('regulations.manage') THEN
    RAISE EXCEPTION 'fn_regulation_create: %', 'forbidden:regulations.manage required'
      USING ERRCODE = '42501';
  END IF;

  IF p_title_en IS NULL OR length(trim(p_title_en)) = 0 THEN
    RAISE EXCEPTION 'fn_regulation_create: %', 'titleEn:Title (English) is required'
      USING ERRCODE = '23502';
  END IF;

  IF p_reference_code IS NULL OR length(trim(p_reference_code)) = 0 THEN
    RAISE EXCEPTION 'fn_regulation_create: %', 'referenceCode:Reference code is required'
      USING ERRCODE = '23502';
  END IF;

  INSERT INTO regulation (
    reference_code, title_en, title_ar, issuer_id, regulation_type, jurisdiction,
    effective_date, summary_en, summary_ar, source_url, tags, status,
    created_by, updated_by
  ) VALUES (
    p_reference_code, p_title_en, p_title_ar, p_issuer_id, p_regulation_type, p_jurisdiction,
    p_effective_date, p_summary_en, p_summary_ar, p_source_url,
    COALESCE(p_tags, '{}'::text[]),
    COALESCE(p_status, 'active'),
    p_actor_id, p_actor_id
  ) RETURNING id INTO v_id;

  RETURN fn_regulation_get_by_id(v_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_regulation_create(TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, DATE, TEXT, TEXT, TEXT, TEXT[], TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulation_create(TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, DATE, TEXT, TEXT, TEXT, TEXT[], TEXT, BIGINT) TO neondb_owner;


-- ============================================================================
-- WRITE FUNCTION 2 of 9: fn_regulation_update (S4 — INVOKER, dynamic patch)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulation_update(
  p_id       BIGINT,
  p_patch    JSONB,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_exists BIGINT;
  v_new_superseded_by BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('regulations.manage') THEN
    RAISE EXCEPTION 'fn_regulation_update: %', 'forbidden:regulations.manage required'
      USING ERRCODE = '42501';
  END IF;

  IF p_patch ? 'referenceCode' THEN
    RAISE EXCEPTION 'fn_regulation_update: %', 'referenceCode:Reference code is immutable'
      USING ERRCODE = '23501';
  END IF;

  SELECT id INTO v_exists FROM regulation
    WHERE id = p_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_regulation_update: %', 'id:Regulation not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF p_patch ? 'supersededById' THEN
    v_new_superseded_by := NULLIF(p_patch->>'supersededById','')::BIGINT;
    IF v_new_superseded_by IS NOT NULL AND v_new_superseded_by = p_id THEN
      RAISE EXCEPTION 'fn_regulation_update: %', 'supersededById:A regulation cannot supersede itself'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  UPDATE regulation SET
    title_en         = COALESCE((p_patch->>'titleEn'),         title_en),
    title_ar         = COALESCE((p_patch->>'titleAr'),         title_ar),
    issuer_id        = COALESCE(NULLIF(p_patch->>'issuerId','')::BIGINT, issuer_id),
    regulation_type  = COALESCE((p_patch->>'regulationType'),  regulation_type),
    jurisdiction     = COALESCE((p_patch->>'jurisdiction'),    jurisdiction),
    effective_date   = COALESCE(NULLIF(p_patch->>'effectiveDate','')::DATE, effective_date),
    superseded_by_id = CASE
                         WHEN p_patch ? 'supersededById'
                         THEN NULLIF(p_patch->>'supersededById','')::BIGINT
                         ELSE superseded_by_id
                       END,
    summary_en       = COALESCE((p_patch->>'summaryEn'),       summary_en),
    summary_ar       = COALESCE((p_patch->>'summaryAr'),       summary_ar),
    source_url       = COALESCE((p_patch->>'sourceUrl'),       source_url),
    tags             = CASE
                         WHEN p_patch ? 'tags'
                         THEN ARRAY(SELECT jsonb_array_elements_text(p_patch->'tags'))::TEXT[]
                         ELSE tags
                       END,
    status           = CASE
                         WHEN p_patch ? 'supersededById'
                              AND NULLIF(p_patch->>'supersededById','') IS NOT NULL
                         THEN 'superseded'
                         ELSE COALESCE((p_patch->>'status'), status)
                       END,
    updated_at       = CURRENT_TIMESTAMP,
    updated_by       = p_actor_id
    WHERE id = p_id;

  RETURN fn_regulation_get_by_id(p_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_regulation_update(BIGINT, JSONB, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulation_update(BIGINT, JSONB, BIGINT) TO neondb_owner;


-- ============================================================================
-- WRITE FUNCTION 3 of 9: fn_regulation_delete (S5 — INVOKER, soft-delete with guard)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulation_delete(
  p_id       BIGINT,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_exists BIGINT;
  v_active_impact_count INTEGER;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM "user" u JOIN role r ON r.id = u.role_id
    WHERE u.id = p_actor_id AND r.name IN ('platform_admin','Super Admin')
  ) THEN
    RAISE EXCEPTION 'fn_regulation_delete: %', 'forbidden:platform_admin required'
      USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_exists FROM regulation
    WHERE id = p_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_regulation_delete: %', 'id:Regulation not found'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT COUNT(*) INTO v_active_impact_count
    FROM regulatory_impact
    WHERE regulation_id = p_id AND is_active = TRUE;
  IF v_active_impact_count > 0 THEN
    RAISE EXCEPTION 'fn_regulation_delete: %',
      format('regulationId:Cannot delete: %s active impact rows reference this regulation', v_active_impact_count)
      USING ERRCODE = '23503';
  END IF;

  UPDATE regulation
    SET is_active  = FALSE,
        status     = 'repealed',
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id
    WHERE id = p_id;

  RETURN jsonb_build_object('id', p_id, 'isActive', FALSE);
END;
$$;

REVOKE ALL ON FUNCTION fn_regulation_delete(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulation_delete(BIGINT, BIGINT) TO neondb_owner;


-- ============================================================================
-- WRITE FUNCTION 4 of 9: fn_regulatory_update_create (S8 — INVOKER)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulatory_update_create(
  p_regulator_id              BIGINT,
  p_title_en                  TEXT,
  p_title_ar                  TEXT,
  p_summary_en                TEXT,
  p_summary_ar                TEXT,
  p_reference_number          TEXT,
  p_published_date            DATE,
  p_effective_date            DATE,
  p_compliance_deadline       DATE,
  p_severity                  TEXT,
  p_source_url                TEXT,
  p_affected_clause_categories TEXT[],
  p_category_id               BIGINT,
  p_sub_source                TEXT,
  p_actor_id                  BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('regulations.manage') THEN
    RAISE EXCEPTION 'fn_regulatory_update_create: %', 'forbidden:regulations.manage required'
      USING ERRCODE = '42501';
  END IF;

  IF p_title_en IS NULL OR length(trim(p_title_en)) = 0 THEN
    RAISE EXCEPTION 'fn_regulatory_update_create: %', 'titleEn:Title (English) is required'
      USING ERRCODE = '23502';
  END IF;

  IF p_published_date IS NULL THEN
    RAISE EXCEPTION 'fn_regulatory_update_create: %', 'publishedDate:Published date is required'
      USING ERRCODE = '23502';
  END IF;

  IF p_effective_date IS NOT NULL AND p_effective_date < p_published_date THEN
    RAISE EXCEPTION 'fn_regulatory_update_create: %', 'effectiveDate:Effective date cannot be before published date'
      USING ERRCODE = '23514';
  END IF;
  IF p_compliance_deadline IS NOT NULL AND p_compliance_deadline < p_published_date THEN
    RAISE EXCEPTION 'fn_regulatory_update_create: %', 'complianceDeadline:Compliance deadline cannot be before published date'
      USING ERRCODE = '23514';
  END IF;

  INSERT INTO regulatory_update (
    regulator_id, title_en, title_ar, summary_en, summary_ar, reference_number,
    published_date, effective_date, compliance_deadline, severity, source_url,
    affected_clause_categories, category_id, sub_source,
    created_by, updated_by
  ) VALUES (
    p_regulator_id, p_title_en, p_title_ar, p_summary_en, p_summary_ar, p_reference_number,
    p_published_date, p_effective_date, p_compliance_deadline,
    COALESCE(p_severity, 'medium'),
    p_source_url,
    COALESCE(p_affected_clause_categories, '{}'::text[]),
    p_category_id, p_sub_source,
    p_actor_id, p_actor_id
  ) RETURNING id INTO v_id;

  RETURN fn_regulatory_update_get_by_id(v_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_regulatory_update_create(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE, DATE, TEXT, TEXT, TEXT[], BIGINT, TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulatory_update_create(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE, DATE, TEXT, TEXT, TEXT[], BIGINT, TEXT, BIGINT) TO neondb_owner;


-- ============================================================================
-- WRITE FUNCTION 5 of 9: fn_regulatory_update_update (S9 — INVOKER, dynamic patch)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulatory_update_update(
  p_id       BIGINT,
  p_patch    JSONB,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_exists BIGINT;
  v_new_published DATE;
  v_min_detected DATE;
BEGIN
  IF NOT fn_current_user_has_permission('regulations.manage') THEN
    RAISE EXCEPTION 'fn_regulatory_update_update: %', 'forbidden:regulations.manage required'
      USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_exists FROM regulatory_update
    WHERE id = p_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_regulatory_update_update: %', 'id:Regulatory update not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF p_patch ? 'publishedDate' THEN
    v_new_published := NULLIF(p_patch->>'publishedDate','')::DATE;
    IF v_new_published IS NOT NULL THEN
      SELECT MIN(detected_at)::DATE INTO v_min_detected
        FROM regulatory_impact
        WHERE regulatory_update_id = p_id AND is_active = TRUE;
      IF v_min_detected IS NOT NULL AND v_new_published > v_min_detected THEN
        RAISE EXCEPTION 'fn_regulatory_update_update: %',
          'publishedDate:Cannot change published date below earliest impact detection date'
          USING ERRCODE = '23514';
      END IF;
    END IF;
  END IF;

  UPDATE regulatory_update SET
    regulator_id                = COALESCE(NULLIF(p_patch->>'regulatorId','')::BIGINT, regulator_id),
    title_en                    = COALESCE((p_patch->>'titleEn'),     title_en),
    title_ar                    = COALESCE((p_patch->>'titleAr'),     title_ar),
    summary_en                  = COALESCE((p_patch->>'summaryEn'),   summary_en),
    summary_ar                  = COALESCE((p_patch->>'summaryAr'),   summary_ar),
    reference_number            = COALESCE((p_patch->>'referenceNumber'), reference_number),
    published_date              = COALESCE(NULLIF(p_patch->>'publishedDate','')::DATE, published_date),
    effective_date              = CASE WHEN p_patch ? 'effectiveDate'
                                       THEN NULLIF(p_patch->>'effectiveDate','')::DATE
                                       ELSE effective_date END,
    compliance_deadline         = CASE WHEN p_patch ? 'complianceDeadline'
                                       THEN NULLIF(p_patch->>'complianceDeadline','')::DATE
                                       ELSE compliance_deadline END,
    severity                    = COALESCE((p_patch->>'severity'),    severity),
    source_url                  = COALESCE((p_patch->>'sourceUrl'),   source_url),
    affected_clause_categories  = CASE
                                    WHEN p_patch ? 'affectedClauseCategories'
                                    THEN ARRAY(SELECT jsonb_array_elements_text(p_patch->'affectedClauseCategories'))::TEXT[]
                                    ELSE affected_clause_categories
                                  END,
    category_id                 = CASE WHEN p_patch ? 'categoryId'
                                       THEN NULLIF(p_patch->>'categoryId','')::BIGINT
                                       ELSE category_id END,
    sub_source                  = COALESCE((p_patch->>'subSource'),   sub_source),
    updated_at                  = CURRENT_TIMESTAMP,
    updated_by                  = p_actor_id
    WHERE id = p_id;

  RETURN fn_regulatory_update_get_by_id(p_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_regulatory_update_update(BIGINT, JSONB, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulatory_update_update(BIGINT, JSONB, BIGINT) TO neondb_owner;


-- ============================================================================
-- WRITE FUNCTION 6 of 9: fn_regulatory_update_delete (S10 — INVOKER, cascade-soft)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulatory_update_delete(
  p_id       BIGINT,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_exists BIGINT;
  v_cascaded_impacts INTEGER;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM "user" u JOIN role r ON r.id = u.role_id
    WHERE u.id = p_actor_id AND r.name IN ('platform_admin','Super Admin')
  ) THEN
    RAISE EXCEPTION 'fn_regulatory_update_delete: %', 'forbidden:platform_admin required'
      USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_exists FROM regulatory_update
    WHERE id = p_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_regulatory_update_delete: %', 'id:Regulatory update not found'
      USING ERRCODE = 'P0002';
  END IF;

  UPDATE regulatory_update
    SET is_active  = FALSE,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id
    WHERE id = p_id;

  -- AC-S10-02 cascade-soft-delete: only update-driven impacts (regulatory_update_id = p_id);
  -- structural impacts (regulatory_update_id IS NULL) are unaffected by equality semantics.
  UPDATE regulatory_impact
    SET is_active  = FALSE,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id
    WHERE regulatory_update_id = p_id
      AND is_active = TRUE;
  GET DIAGNOSTICS v_cascaded_impacts = ROW_COUNT;

  RETURN jsonb_build_object(
    'id', p_id,
    'isActive', FALSE,
    'cascadedImpacts', v_cascaded_impacts
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_regulatory_update_delete(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulatory_update_delete(BIGINT, BIGINT) TO neondb_owner;


-- ============================================================================
-- WRITE FUNCTION 7 of 9: fn_regulatory_impact_create_bulk (S11 — DEFINER carve-out)
-- ============================================================================
-- DN-3 DEFINER carve-out: legal_counsel must write impacts on contracts they
-- don't directly own. RLS regulatory_impact_insert_legal_or_admin gates on
-- regulations.manage but contract recursion would narrow visibility on
-- subsequent SELECTs. DEFINER bypasses RLS for the bulk write path. Defence-
-- in-depth: permission gate at fn body line 1 + S2-17 atomic gate+commit on
-- regulatory_update row preserve security invariants.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulatory_impact_create_bulk(
  p_regulatory_update_id BIGINT,
  p_regulation_id        BIGINT,
  p_contract_ids         BIGINT[],
  p_impact_payload       JSONB,
  p_actor_id             BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_regulatory_update_row BIGINT;
  v_contract_id           BIGINT;
  v_payload_for_contract  JSONB;
  v_score                 INTEGER;
  v_note_en               TEXT;
  v_note_ar               TEXT;
  v_summary_en            TEXT;
  v_summary_ar            TEXT;
  v_inserted_id           BIGINT;
  v_created               INTEGER := 0;
  v_skipped               INTEGER := 0;
  v_impact_ids            BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
  -- 1. Permission gate (defence-in-depth)
  IF NOT fn_current_user_has_permission('regulations.manage') THEN
    RAISE EXCEPTION 'fn_regulatory_impact_create_bulk: %', 'forbidden:regulations.manage required'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Input validation (AC-S11-03)
  IF p_contract_ids IS NULL OR array_length(p_contract_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'fn_regulatory_impact_create_bulk: %', 'contractIds:At least one contract required'
      USING ERRCODE = '23514';
  END IF;

  -- 3. S2-17 ATOMIC GATE+COMMIT (Codex M1c 020 / M2 026 / M2 031 TOCTOU lesson)
  --    SELECT FOR UPDATE on regulatory_update row before per-contract loop.
  SELECT id INTO v_regulatory_update_row
    FROM regulatory_update
    WHERE id = p_regulatory_update_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_regulatory_impact_create_bulk: %',
      'regulatoryUpdateId:Regulatory update not found'
      USING ERRCODE = '23503';
  END IF;

  -- 4. Validate regulation
  PERFORM 1 FROM regulation WHERE id = p_regulation_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_regulatory_impact_create_bulk: %',
      'regulationId:Regulation not found'
      USING ERRCODE = '23503';
  END IF;

  -- 5. Per-contract INSERT loop with ON CONFLICT idempotency
  FOREACH v_contract_id IN ARRAY p_contract_ids LOOP
    v_payload_for_contract := p_impact_payload -> v_contract_id::TEXT;

    -- S2-16 DTO-to-fn-body destructure (camelCase keys)
    v_score      := NULLIF(v_payload_for_contract->>'impactScore','')::INTEGER;
    v_note_en    := v_payload_for_contract->>'noteEn';
    v_note_ar    := v_payload_for_contract->>'noteAr';
    v_summary_en := v_payload_for_contract->>'summaryEn';
    v_summary_ar := v_payload_for_contract->>'summaryAr';

    -- S2-22 column-existence verified — 18 columns vs 049 DDL
    INSERT INTO regulatory_impact (
      contract_id, regulation_id, regulatory_update_id,
      impact_score, impact_note_en, impact_note_ar,
      impact_summary_en, impact_summary_ar,
      detected_at, resolved, resolution_action, resolution_note,
      is_seed, created_at, updated_at, created_by, updated_by, is_active
    ) VALUES (
      v_contract_id, p_regulation_id, p_regulatory_update_id,
      v_score, v_note_en, v_note_ar,
      v_summary_en, v_summary_ar,
      CURRENT_TIMESTAMP, FALSE, NULL, NULL,
      FALSE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, p_actor_id, p_actor_id, TRUE
    )
    ON CONFLICT (contract_id, regulation_id, COALESCE(regulatory_update_id, 0::BIGINT))
      WHERE is_active = TRUE
      DO NOTHING
    RETURNING id INTO v_inserted_id;

    IF v_inserted_id IS NOT NULL THEN
      v_created := v_created + 1;
      v_impact_ids := array_append(v_impact_ids, v_inserted_id);

      -- Q9 EMIT contract_activity (whitelist extended in 047)
      PERFORM fn_contract_activity_create(
        v_contract_id,
        'regulatory_impact_detected',
        p_actor_id,
        NULL, NULL,
        jsonb_build_object(
          'regulatoryImpactId', v_inserted_id,
          'regulatoryUpdateId', p_regulatory_update_id,
          'regulationId',       p_regulation_id,
          'impactScore',        v_score
        )
      );
    ELSE
      v_skipped := v_skipped + 1;
    END IF;

    v_inserted_id := NULL;  -- reset for next iteration
  END LOOP;

  RETURN jsonb_build_object(
    'createdCount',          v_created,
    'skippedDuplicateCount', v_skipped,
    'impactIds',             to_jsonb(v_impact_ids)
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_regulatory_impact_create_bulk(BIGINT, BIGINT, BIGINT[], JSONB, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulatory_impact_create_bulk(BIGINT, BIGINT, BIGINT[], JSONB, BIGINT) TO neondb_owner;


-- ============================================================================
-- WRITE FUNCTION 8 of 9: fn_regulatory_impact_resolve (S13 — INVOKER, polymorphic)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulatory_impact_resolve(
  p_id                BIGINT,
  p_resolution_action TEXT,
  p_resolution_note   TEXT,
  p_actor_id          BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contract_id BIGINT;
  v_drafted_by  BIGINT;
  v_allowed     BOOLEAN;
  v_resolved    BOOLEAN;
BEGIN
  -- AC-S13-03 validate resolution_action
  IF p_resolution_action IS NULL
     OR p_resolution_action NOT IN ('amended','waived','out_of_scope','pending') THEN
    RAISE EXCEPTION 'fn_regulatory_impact_resolve: %',
      'resolutionAction:Invalid resolution action — must be one of amended, waived, out_of_scope, pending'
      USING ERRCODE = '23514';
  END IF;

  -- SELECT FOR UPDATE OF ri (lock the impact row; join contract for ownership)
  SELECT ri.contract_id, c.drafted_by
    INTO v_contract_id, v_drafted_by
    FROM regulatory_impact ri
    JOIN contract c ON c.id = ri.contract_id
    WHERE ri.id = p_id AND ri.is_active = TRUE
    FOR UPDATE OF ri;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_regulatory_impact_resolve: %', 'id:Regulatory impact not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- AC-S13-05 polymorphic permission: regulations.manage OR contract drafter
  v_allowed := fn_current_user_has_permission('regulations.manage')
            OR (v_drafted_by = p_actor_id);
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'fn_regulatory_impact_resolve: %',
      'forbidden:regulations.manage required (or be the contract drafter)'
      USING ERRCODE = '42501';
  END IF;

  -- AC-S13-02 resolved-flag derivation
  v_resolved := (p_resolution_action <> 'pending');

  -- S2-22 column-existence verified — 5 columns vs 049 DDL
  UPDATE regulatory_impact SET
    resolved          = v_resolved,
    resolution_action = p_resolution_action,
    resolution_note   = p_resolution_note,
    updated_at        = CURRENT_TIMESTAMP,
    updated_by        = p_actor_id
    WHERE id = p_id;

  IF v_resolved THEN
    PERFORM fn_contract_activity_create(
      v_contract_id,
      'regulatory_impact_resolved',
      p_actor_id,
      NULL, NULL,
      jsonb_build_object(
        'regulatoryImpactId', p_id,
        'resolutionAction',   p_resolution_action,
        'hasNote',            p_resolution_note IS NOT NULL
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'id',               p_id,
    'resolved',         v_resolved,
    'resolutionAction', p_resolution_action,
    'updatedAt',        CURRENT_TIMESTAMP
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_regulatory_impact_resolve(BIGINT, TEXT, TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulatory_impact_resolve(BIGINT, TEXT, TEXT, BIGINT) TO neondb_owner;


-- ============================================================================
-- WRITE FUNCTION 9 of 9: fn_impact_category_upsert (S15 — INVOKER, upsert)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_impact_category_upsert(
  p_key                       TEXT,
  p_name_en                   TEXT,
  p_name_ar                   TEXT,
  p_description_en            TEXT,
  p_description_ar            TEXT,
  p_icon                      TEXT,
  p_colour                    TEXT,
  p_active                    BOOLEAN,
  p_display_order             INTEGER,
  p_sources                   JSONB,
  p_severity_scale            JSONB,
  p_ai_prompt_context         TEXT,
  p_default_clause_categories TEXT[],
  p_actor_id                  BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id           BIGINT;
  v_key          TEXT;
  v_disposition  TEXT;
  v_idx          INTEGER;
  v_array_len    INTEGER;
  v_elem         JSONB;
BEGIN
  -- AC-S15-05 platform_admin gate
  IF NOT fn_current_user_has_permission('config.manage') THEN
    RAISE EXCEPTION 'fn_impact_category_upsert: %', 'forbidden:config.manage required'
      USING ERRCODE = '42501';
  END IF;

  -- AC-S15-03 nameAr mandatory
  IF p_name_ar IS NULL OR length(trim(p_name_ar)) = 0 THEN
    RAISE EXCEPTION 'fn_impact_category_upsert: %', 'nameAr:Arabic name is required'
      USING ERRCODE = '23502';
  END IF;

  IF p_key IS NULL OR length(trim(p_key)) = 0 THEN
    RAISE EXCEPTION 'fn_impact_category_upsert: %', 'key:Key is required'
      USING ERRCODE = '23502';
  END IF;

  -- AC-S15-04 severity_scale shape validation
  IF p_severity_scale IS NOT NULL THEN
    IF jsonb_typeof(p_severity_scale) <> 'array' THEN
      RAISE EXCEPTION 'fn_impact_category_upsert: %',
        'severityScale:severityScale must be a JSON array of strings'
        USING ERRCODE = '23514';
    END IF;
    v_array_len := jsonb_array_length(p_severity_scale);
    FOR v_idx IN 0..(v_array_len - 1) LOOP
      v_elem := p_severity_scale -> v_idx;
      IF jsonb_typeof(v_elem) <> 'string' THEN
        RAISE EXCEPTION 'fn_impact_category_upsert: %',
          'severityScale:severityScale entries must be strings'
          USING ERRCODE = '23514';
      END IF;
    END LOOP;
  END IF;

  INSERT INTO impact_category (
    key, name_en, name_ar, description_en, description_ar, icon, colour,
    active, display_order, sources, severity_scale, ai_prompt_context,
    default_clause_categories, created_by, updated_by
  ) VALUES (
    p_key, p_name_en, p_name_ar, p_description_en, p_description_ar,
    COALESCE(p_icon, 'shield'),
    COALESCE(p_colour, 'slate'),
    COALESCE(p_active, TRUE),
    COALESCE(p_display_order, 0),
    COALESCE(p_sources, '[]'::jsonb),
    COALESCE(p_severity_scale, '["low","medium","high","critical"]'::jsonb),
    p_ai_prompt_context,
    COALESCE(p_default_clause_categories, '{}'::text[]),
    p_actor_id, p_actor_id
  )
  ON CONFLICT (key) DO UPDATE SET
    name_en                   = EXCLUDED.name_en,
    name_ar                   = EXCLUDED.name_ar,
    description_en            = EXCLUDED.description_en,
    description_ar            = EXCLUDED.description_ar,
    icon                      = EXCLUDED.icon,
    colour                    = EXCLUDED.colour,
    active                    = EXCLUDED.active,
    display_order             = EXCLUDED.display_order,
    sources                   = EXCLUDED.sources,
    severity_scale            = EXCLUDED.severity_scale,
    ai_prompt_context         = EXCLUDED.ai_prompt_context,
    default_clause_categories = EXCLUDED.default_clause_categories,
    updated_at                = CURRENT_TIMESTAMP,
    updated_by                = p_actor_id
  RETURNING id, key,
    (CASE WHEN xmax = 0 THEN 'created' ELSE 'updated' END)
  INTO v_id, v_key, v_disposition;

  RETURN jsonb_build_object(
    'id', v_id,
    'key', v_key,
    'createdOrUpdated', v_disposition
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_impact_category_upsert(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INTEGER, JSONB, JSONB, TEXT, TEXT[], BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_impact_category_upsert(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INTEGER, JSONB, JSONB, TEXT, TEXT[], BIGINT) TO neondb_owner;


-- ============================================================================
-- READ FUNCTION 1 of 6: fn_regulation_get_by_id (S2)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulation_get_by_id(
  p_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result JSONB;
BEGIN
  WITH RECURSIVE chain AS (
    SELECT id, reference_code, title_en, title_ar, status, superseded_by_id, 1 AS depth
      FROM regulation WHERE id = p_id
    UNION ALL
    SELECT r.id, r.reference_code, r.title_en, r.title_ar, r.status, r.superseded_by_id,
           c.depth + 1
      FROM regulation r JOIN chain c ON r.id = c.superseded_by_id
      WHERE c.depth < 5
  )
  SELECT jsonb_build_object(
      'id',             r.id,
      'referenceCode',  r.reference_code,
      'titleEn',        r.title_en,
      'titleAr',        r.title_ar,
      'issuer',         (
                          SELECT jsonb_build_object(
                            'id', g.id, 'code', g.code,
                            'nameEn', g.name_en, 'nameAr', g.name_ar
                          )
                          FROM regulator g WHERE g.id = r.issuer_id
                        ),
      'regulationType', r.regulation_type,
      'jurisdiction',   r.jurisdiction,
      'effectiveDate',  r.effective_date,
      'summaryEn',      r.summary_en,
      'summaryAr',      r.summary_ar,
      'sourceUrl',      r.source_url,
      'tags',           to_jsonb(r.tags),
      'status',         r.status,
      'isActive',       r.is_active,
      'supersededBy',   COALESCE((
                          SELECT jsonb_agg(jsonb_build_object(
                            'id',             c.id,
                            'referenceCode',  c.reference_code,
                            'titleEn',        c.title_en,
                            'titleAr',        c.title_ar,
                            'status',         c.status,
                            'depth',          c.depth
                          ) ORDER BY c.depth)
                          FROM chain c WHERE c.depth > 1
                        ), '[]'::jsonb)
    )
    INTO v_result
    FROM regulation r
    WHERE r.id = p_id AND r.is_active = TRUE;

  RETURN v_result;  -- NULL when not found / inactive
END;
$$;

REVOKE ALL ON FUNCTION fn_regulation_get_by_id(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulation_get_by_id(BIGINT) TO neondb_owner;


-- ============================================================================
-- READ FUNCTION 2 of 6: fn_regulation_list (S1)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulation_list(
  p_page            INTEGER DEFAULT 1,
  p_limit           INTEGER DEFAULT 20,
  p_jurisdiction    TEXT    DEFAULT NULL,
  p_regulation_type TEXT    DEFAULT NULL,
  p_issuer_id       BIGINT  DEFAULT NULL,
  p_status          TEXT    DEFAULT NULL,
  p_search          TEXT    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset INTEGER;
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_limit, 1);

  SELECT COUNT(*) INTO v_total
    FROM regulation r
    WHERE r.is_active = TRUE
      AND (p_jurisdiction    IS NULL OR r.jurisdiction    = p_jurisdiction)
      AND (p_regulation_type IS NULL OR r.regulation_type = p_regulation_type)
      AND (p_issuer_id       IS NULL OR r.issuer_id       = p_issuer_id)
      AND (p_status          IS NULL OR r.status          = p_status)
      AND (p_search          IS NULL OR (
              r.title_en       ILIKE '%' || p_search || '%'
           OR r.title_ar       ILIKE '%' || p_search || '%'
           OR r.reference_code ILIKE '%' || p_search || '%'
      ));

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',             r.id,
      'referenceCode',  r.reference_code,
      'titleEn',        r.title_en,
      'titleAr',        r.title_ar,
      'issuer',         (
                          SELECT jsonb_build_object(
                            'id', g.id, 'code', g.code, 'nameEn', g.name_en
                          )
                          FROM regulator g WHERE g.id = r.issuer_id
                        ),
      'regulationType', r.regulation_type,
      'jurisdiction',   r.jurisdiction,
      'effectiveDate',  r.effective_date,
      'supersededByCode', (
                            SELECT s.reference_code
                            FROM regulation s WHERE s.id = r.superseded_by_id
                          ),
      'status',         r.status,
      'isActive',       r.is_active
    ) ORDER BY r.effective_date DESC NULLS LAST, r.created_at DESC
  ), '[]'::jsonb)
    INTO v_data
    FROM (
      SELECT *
        FROM regulation
        WHERE is_active = TRUE
          AND (p_jurisdiction    IS NULL OR jurisdiction    = p_jurisdiction)
          AND (p_regulation_type IS NULL OR regulation_type = p_regulation_type)
          AND (p_issuer_id       IS NULL OR issuer_id       = p_issuer_id)
          AND (p_status          IS NULL OR status          = p_status)
          AND (p_search          IS NULL OR (
                  title_en       ILIKE '%' || p_search || '%'
               OR title_ar       ILIKE '%' || p_search || '%'
               OR reference_code ILIKE '%' || p_search || '%'
          ))
        ORDER BY effective_date DESC NULLS LAST, created_at DESC
        LIMIT GREATEST(p_limit, 1) OFFSET v_offset
    ) r;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       GREATEST(p_page, 1),
      'limit',      GREATEST(p_limit, 1),
      'totalPages', CASE WHEN v_total = 0 THEN 0
                         ELSE CEIL(v_total::FLOAT / GREATEST(p_limit, 1))::INTEGER
                    END
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_regulation_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulation_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TEXT, TEXT) TO neondb_owner;


-- ============================================================================
-- READ FUNCTION 3 of 6: fn_regulatory_update_get_by_id (S7)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulatory_update_get_by_id(
  p_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
      'id',                       u.id,
      'regulator',                (
                                    SELECT jsonb_build_object(
                                      'id', g.id, 'code', g.code,
                                      'nameEn', g.name_en, 'nameAr', g.name_ar
                                    )
                                    FROM regulator g WHERE g.id = u.regulator_id
                                  ),
      'category',                 (
                                    SELECT jsonb_build_object(
                                      'id', c.id, 'key', c.key,
                                      'nameEn', c.name_en, 'nameAr', c.name_ar,
                                      'icon', c.icon, 'colour', c.colour
                                    )
                                    FROM impact_category c WHERE c.id = u.category_id
                                  ),
      'titleEn',                  u.title_en,
      'titleAr',                  u.title_ar,
      'summaryEn',                u.summary_en,
      'summaryAr',                u.summary_ar,
      'referenceNumber',          u.reference_number,
      'publishedDate',            u.published_date,
      'effectiveDate',            u.effective_date,
      'complianceDeadline',       u.compliance_deadline,
      'severity',                 u.severity,
      'sourceUrl',                u.source_url,
      'affectedClauseCategories', to_jsonb(u.affected_clause_categories),
      'subSource',                u.sub_source,
      'isActive',                 u.is_active,
      'impactSummary',            (
                                    SELECT jsonb_build_object(
                                      'totalImpacts',   COUNT(*),
                                      'resolvedCount',  COUNT(*) FILTER (WHERE resolved = TRUE),
                                      'pendingCount',   COUNT(*) FILTER (WHERE resolved = FALSE),
                                      'avgImpactScore', ROUND(AVG(impact_score)::NUMERIC, 2)
                                    )
                                    FROM regulatory_impact
                                    WHERE regulatory_update_id = u.id AND is_active = TRUE
                                  )
    )
    INTO v_result
    FROM regulatory_update u
    WHERE u.id = p_id AND u.is_active = TRUE;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION fn_regulatory_update_get_by_id(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulatory_update_get_by_id(BIGINT) TO neondb_owner;


-- ============================================================================
-- READ FUNCTION 4 of 6: fn_regulatory_update_list (S6)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulatory_update_list(
  p_page                    INTEGER DEFAULT 1,
  p_limit                   INTEGER DEFAULT 20,
  p_regulator_id            BIGINT  DEFAULT NULL,
  p_severity                TEXT    DEFAULT NULL,
  p_category_id             BIGINT  DEFAULT NULL,
  p_effective_from          DATE    DEFAULT NULL,
  p_effective_to            DATE    DEFAULT NULL,
  p_compliance_deadline_max DATE    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset INTEGER;
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_limit, 1);

  SELECT COUNT(*) INTO v_total
    FROM regulatory_update u
    WHERE u.is_active = TRUE
      AND (p_regulator_id            IS NULL OR u.regulator_id        = p_regulator_id)
      AND (p_severity                IS NULL OR u.severity            = p_severity)
      AND (p_category_id             IS NULL OR u.category_id         = p_category_id)
      AND (p_effective_from          IS NULL OR u.effective_date     >= p_effective_from)
      AND (p_effective_to            IS NULL OR u.effective_date     <= p_effective_to)
      AND (p_compliance_deadline_max IS NULL OR u.compliance_deadline <= p_compliance_deadline_max);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',                       u.id,
      'regulator',                (
                                    SELECT jsonb_build_object(
                                      'id', g.id, 'code', g.code, 'nameEn', g.name_en
                                    )
                                    FROM regulator g WHERE g.id = u.regulator_id
                                  ),
      'titleEn',                  u.title_en,
      'titleAr',                  u.title_ar,
      'summaryEn',                u.summary_en,
      'summaryAr',                u.summary_ar,
      'referenceNumber',          u.reference_number,
      'publishedDate',            u.published_date,
      'effectiveDate',            u.effective_date,
      'complianceDeadline',       u.compliance_deadline,
      'severity',                 u.severity,
      'sourceUrl',                u.source_url,
      'affectedClauseCategories', to_jsonb(u.affected_clause_categories),
      'category',                 (
                                    SELECT jsonb_build_object(
                                      'id', c.id, 'key', c.key,
                                      'nameEn', c.name_en, 'nameAr', c.name_ar,
                                      'icon', c.icon, 'colour', c.colour
                                    )
                                    FROM impact_category c WHERE c.id = u.category_id
                                  ),
      'subSource',                u.sub_source
    ) ORDER BY u.published_date DESC, u.id DESC
  ), '[]'::jsonb)
    INTO v_data
    FROM (
      SELECT *
        FROM regulatory_update
        WHERE is_active = TRUE
          AND (p_regulator_id            IS NULL OR regulator_id        = p_regulator_id)
          AND (p_severity                IS NULL OR severity            = p_severity)
          AND (p_category_id             IS NULL OR category_id         = p_category_id)
          AND (p_effective_from          IS NULL OR effective_date     >= p_effective_from)
          AND (p_effective_to            IS NULL OR effective_date     <= p_effective_to)
          AND (p_compliance_deadline_max IS NULL OR compliance_deadline <= p_compliance_deadline_max)
        ORDER BY published_date DESC, id DESC
        LIMIT GREATEST(p_limit, 1) OFFSET v_offset
    ) u;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       GREATEST(p_page, 1),
      'limit',      GREATEST(p_limit, 1),
      'totalPages', CASE WHEN v_total = 0 THEN 0
                         ELSE CEIL(v_total::FLOAT / GREATEST(p_limit, 1))::INTEGER
                    END
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_regulatory_update_list(INTEGER, INTEGER, BIGINT, TEXT, BIGINT, DATE, DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulatory_update_list(INTEGER, INTEGER, BIGINT, TEXT, BIGINT, DATE, DATE, DATE) TO neondb_owner;


-- ============================================================================
-- READ FUNCTION 5 of 6: fn_regulatory_impact_list (S12)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_regulatory_impact_list(
  p_page                 INTEGER DEFAULT 1,
  p_limit                INTEGER DEFAULT 20,
  p_contract_id          BIGINT  DEFAULT NULL,
  p_regulation_id        BIGINT  DEFAULT NULL,
  p_regulatory_update_id BIGINT  DEFAULT NULL,
  p_resolved             BOOLEAN DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset INTEGER;
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  IF p_contract_id IS NULL AND p_regulation_id IS NULL AND p_regulatory_update_id IS NULL THEN
    RAISE EXCEPTION 'fn_regulatory_impact_list: %',
      'filters:At least one of contractId, regulationId, regulatoryUpdateId is required'
      USING ERRCODE = '23514';
  END IF;

  v_offset := (GREATEST(p_page, 1) - 1) * GREATEST(p_limit, 1);

  SELECT COUNT(*) INTO v_total
    FROM regulatory_impact ri
    WHERE ri.is_active = TRUE
      AND (p_contract_id          IS NULL OR ri.contract_id          = p_contract_id)
      AND (p_regulation_id        IS NULL OR ri.regulation_id        = p_regulation_id)
      AND (p_regulatory_update_id IS NULL OR ri.regulatory_update_id IS NOT DISTINCT FROM p_regulatory_update_id)
      AND (p_resolved             IS NULL OR ri.resolved             = p_resolved);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',                ri.id,
      'contract',          (
                             SELECT jsonb_build_object(
                               'id', c.id, 'contractNumber', c.contract_number,
                               'titleEn', c.title_en
                             )
                             FROM contract c WHERE c.id = ri.contract_id
                           ),
      'regulation',        (
                             SELECT jsonb_build_object(
                               'id', g.id, 'referenceCode', g.reference_code,
                               'titleEn', g.title_en
                             )
                             FROM regulation g WHERE g.id = ri.regulation_id
                           ),
      'regulatoryUpdate',  (
                             SELECT jsonb_build_object(
                               'id', u.id, 'titleEn', u.title_en, 'severity', u.severity
                             )
                             FROM regulatory_update u WHERE u.id = ri.regulatory_update_id
                           ),
      'impactScore',       ri.impact_score,
      'impactNoteEn',      ri.impact_note_en,
      'impactNoteAr',      ri.impact_note_ar,
      'impactSummaryEn',   ri.impact_summary_en,
      'impactSummaryAr',   ri.impact_summary_ar,
      'detectedAt',        ri.detected_at,
      'resolved',          ri.resolved,
      'resolutionAction',  ri.resolution_action,
      'resolutionNote',    ri.resolution_note
    ) ORDER BY ri.detected_at DESC
  ), '[]'::jsonb)
    INTO v_data
    FROM (
      SELECT *
        FROM regulatory_impact
        WHERE is_active = TRUE
          AND (p_contract_id          IS NULL OR contract_id          = p_contract_id)
          AND (p_regulation_id        IS NULL OR regulation_id        = p_regulation_id)
          AND (p_regulatory_update_id IS NULL OR regulatory_update_id IS NOT DISTINCT FROM p_regulatory_update_id)
          AND (p_resolved             IS NULL OR resolved             = p_resolved)
        ORDER BY detected_at DESC
        LIMIT GREATEST(p_limit, 1) OFFSET v_offset
    ) ri;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       GREATEST(p_page, 1),
      'limit',      GREATEST(p_limit, 1),
      'totalPages', CASE WHEN v_total = 0 THEN 0
                         ELSE CEIL(v_total::FLOAT / GREATEST(p_limit, 1))::INTEGER
                    END
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_regulatory_impact_list(INTEGER, INTEGER, BIGINT, BIGINT, BIGINT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_regulatory_impact_list(INTEGER, INTEGER, BIGINT, BIGINT, BIGINT, BOOLEAN) TO neondb_owner;


-- ============================================================================
-- READ FUNCTION 6 of 6: fn_impact_category_list (S14)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_impact_category_list(
  p_include_inactive BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_data JSONB;
BEGIN
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',                       c.id,
      'key',                      c.key,
      'nameEn',                   c.name_en,
      'nameAr',                   c.name_ar,
      'descriptionEn',            c.description_en,
      'descriptionAr',            c.description_ar,
      'icon',                     c.icon,
      'colour',                   c.colour,
      'active',                   c.active,
      'displayOrder',             c.display_order,
      'sources',                  c.sources,
      'severityScale',            c.severity_scale,
      'aiPromptContext',          c.ai_prompt_context,
      'defaultClauseCategories',  to_jsonb(c.default_clause_categories)
    ) ORDER BY c.display_order ASC, c.id ASC
  ), '[]'::jsonb)
    INTO v_data
    FROM impact_category c
    WHERE c.is_active = TRUE
      AND (COALESCE(p_include_inactive, FALSE) = TRUE OR c.active = TRUE);

  RETURN jsonb_build_object('data', v_data);
END;
$$;

REVOKE ALL ON FUNCTION fn_impact_category_list(BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_impact_category_list(BOOLEAN) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (50, 'm5_regulatory_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP FUNCTION IF EXISTS fn_impact_category_list(BOOLEAN);
DROP FUNCTION IF EXISTS fn_regulatory_impact_list(INTEGER, INTEGER, BIGINT, BIGINT, BIGINT, BOOLEAN);
DROP FUNCTION IF EXISTS fn_regulatory_update_list(INTEGER, INTEGER, BIGINT, TEXT, BIGINT, DATE, DATE, DATE);
DROP FUNCTION IF EXISTS fn_regulatory_update_get_by_id(BIGINT);
DROP FUNCTION IF EXISTS fn_regulation_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TEXT, TEXT);
DROP FUNCTION IF EXISTS fn_regulation_get_by_id(BIGINT);
DROP FUNCTION IF EXISTS fn_impact_category_upsert(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INTEGER, JSONB, JSONB, TEXT, TEXT[], BIGINT);
DROP FUNCTION IF EXISTS fn_regulatory_impact_resolve(BIGINT, TEXT, TEXT, BIGINT);
DROP FUNCTION IF EXISTS fn_regulatory_impact_create_bulk(BIGINT, BIGINT, BIGINT[], JSONB, BIGINT);
DROP FUNCTION IF EXISTS fn_regulatory_update_delete(BIGINT, BIGINT);
DROP FUNCTION IF EXISTS fn_regulatory_update_update(BIGINT, JSONB, BIGINT);
DROP FUNCTION IF EXISTS fn_regulatory_update_create(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE, DATE, TEXT, TEXT, TEXT[], BIGINT, TEXT, BIGINT);
DROP FUNCTION IF EXISTS fn_regulation_delete(BIGINT, BIGINT);
DROP FUNCTION IF EXISTS fn_regulation_update(BIGINT, JSONB, BIGINT);
DROP FUNCTION IF EXISTS fn_regulation_create(TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, DATE, TEXT, TEXT, TEXT, TEXT[], TEXT, BIGINT);
DELETE FROM schema_migrations WHERE version = 50;
COMMIT;
-- ROLLBACK END
