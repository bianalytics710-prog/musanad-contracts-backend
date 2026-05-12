-- Migration: 146_crd_clause_functions.sql
-- Module: M12 / CR-D — Clause Taxonomy + Two-Stage Extractor + Auto-Obligation Derivation
-- Description: 7 net-new fn_'s:
--   fn_clause_taxonomy_list, fn_clause_extraction_request, fn_clause_upsert,
--   fn_clause_review_queue_list, fn_clause_review_resolve,
--   fn_clause_semantic_search, fn_obligations_derive_from_clause.
--   Each fn: COMMENT + REVOKE FROM PUBLIC + GRANT TO neondb_owner trio (S2-21 / B14).
-- Standards: S2-21 MANDATORY, S2-22, S2-22b, S2-23, S2-25, S2-26, S2-27.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ============================================================
-- 1. fn_clause_taxonomy_list
-- ============================================================
CREATE OR REPLACE FUNCTION fn_clause_taxonomy_list(p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_data      JSONB;
BEGIN
  -- Permission gate (clause.taxonomy.read)
  IF NOT fn_current_user_has_permission('clause.taxonomy.read') THEN
    RAISE EXCEPTION 'Permission denied: clause.taxonomy.read required' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  SELECT jsonb_build_object(
    'data', COALESCE(jsonb_agg(row_obj ORDER BY row_obj->>'family', row_obj->>'displayNameEn'), '[]'::jsonb),
    'groupedByFamily', COALESCE(
      (SELECT jsonb_object_agg(family_key, family_rows)
       FROM (
         SELECT ct.family AS family_key,
                jsonb_agg(
                  jsonb_build_object(
                    'id', ct.id,
                    'clauseTypeId', ct.clause_type_id,
                    'family', ct.family,
                    'displayNameEn', ct.display_name_en,
                    'displayNameAr', ct.display_name_ar,
                    'definitionEn', ct.definition_en,
                    'definitionAr', ct.definition_ar,
                    'identificationCuesEn', ct.identification_cues_en,
                    'identificationCuesAr', ct.identification_cues_ar,
                    'parameterSchema', ct.parameter_schema,
                    'version', ct.version,
                    'isDeprecated', ct.is_deprecated
                  ) ORDER BY ct.display_name_en
                ) AS family_rows
         FROM clause_taxonomy ct
         WHERE ct.is_active = TRUE AND ct.is_deprecated = FALSE
           AND ct.tenant_id = v_tenant_id
         GROUP BY ct.family
       ) grouped
      ),
      '{}'::jsonb
    )
  )
  INTO v_data
  FROM (
    SELECT jsonb_build_object(
      'id', ct.id,
      'clauseTypeId', ct.clause_type_id,
      'family', ct.family,
      'displayNameEn', ct.display_name_en,
      'displayNameAr', ct.display_name_ar,
      'definitionEn', ct.definition_en,
      'definitionAr', ct.definition_ar,
      'identificationCuesEn', ct.identification_cues_en,
      'identificationCuesAr', ct.identification_cues_ar,
      'parameterSchema', ct.parameter_schema,
      'version', ct.version,
      'isDeprecated', ct.is_deprecated
    ) AS row_obj
    FROM clause_taxonomy ct
    WHERE ct.is_active = TRUE AND ct.is_deprecated = FALSE
      AND ct.tenant_id = v_tenant_id
  ) sub;

  RETURN COALESCE(v_data, '{"data":[],"groupedByFamily":{}}'::jsonb);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_clause_taxonomy_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_clause_taxonomy_list(BIGINT) IS 'Returns all active non-deprecated clause_taxonomy rows for the current tenant. Grouped by family. Used by admin viewer + Stage 2 prompt builder. Permission: clause.taxonomy.read.';
REVOKE EXECUTE ON FUNCTION fn_clause_taxonomy_list(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_clause_taxonomy_list(BIGINT) TO neondb_owner;

-- ============================================================
-- 2. fn_clause_extraction_request
-- ============================================================
CREATE OR REPLACE FUNCTION fn_clause_extraction_request(
  p_contract_version_id BIGINT,
  p_actor_id            BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id    UUID;
  v_contract_id  BIGINT;
  v_new_id       BIGINT;
  v_existing_id  BIGINT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  -- S2-23 FK pre-validation: contract_version must exist
  SELECT cv.contract_id
  INTO   v_contract_id
  FROM   contract_version cv
  WHERE  cv.id = p_contract_version_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_version with id % not found', p_contract_version_id USING ERRCODE = 'P0002';
  END IF;

  -- Idempotency check: if a pending_extraction marker already exists, do not re-queue
  SELECT id INTO v_existing_id
  FROM   contract_clause_extracted
  WHERE  contract_version_id = p_contract_version_id
    AND  review_status = 'pending_extraction'
    AND  is_active = TRUE
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object('queued', false, 'reason', 'already_queued', 'existingMarkerId', v_existing_id);
  END IF;

  -- Insert sentinel marker row (source_offset_start = -1 so real rows don't conflict on idempotency UNIQUE)
  INSERT INTO contract_clause_extracted (
    tenant_id, contract_id, contract_version_id,
    clause_type_v2, parameters, text_excerpts,
    source_offset_start, review_status,
    created_by, updated_by
  ) VALUES (
    v_tenant_id, v_contract_id, p_contract_version_id,
    '__pending_marker__', '{}'::jsonb, '{}'::jsonb,
    -1, 'pending_extraction',
    p_actor_id, p_actor_id
  )
  RETURNING id INTO v_new_id;

  RETURN jsonb_build_object('queued', true, 'extractionRunId', v_new_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_clause_extraction_request: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_clause_extraction_request(BIGINT, BIGINT) IS 'Queues clause extraction by inserting a pending_extraction sentinel marker row in contract_clause_extracted. Idempotent — re-call while pending returns {queued: false}. Called from BE worker on contract.ingested PG NOTIFY. SECURITY DEFINER (worker context without user session).';
REVOKE EXECUTE ON FUNCTION fn_clause_extraction_request(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_clause_extraction_request(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- 3. fn_clause_upsert
-- ============================================================
CREATE OR REPLACE FUNCTION fn_clause_upsert(
  p_contract_version_id       BIGINT,
  p_clause_type_v2            TEXT,
  p_parameters                JSONB,
  p_text_excerpts             JSONB,
  p_page_no                   INTEGER,
  p_source_offset_start       INTEGER,
  p_source_offset_end         INTEGER,
  p_confidence                NUMERIC,
  p_extraction_model_version  TEXT,
  p_extraction_prompt_hash    TEXT,
  p_embedding                 VECTOR(1536),
  p_summary_en                TEXT,
  p_summary_ar                TEXT,
  p_actor_id                  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id         UUID;
  v_contract_id       BIGINT;
  v_clause_id         BIGINT;
  v_review_status     TEXT;
  v_confidence_thresh NUMERIC;
  v_param_key         TEXT;
  v_obligations       JSONB;
  v_obligation_error  TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  -- S2-23 FK pre-validation: contract_version must exist
  SELECT cv.contract_id
  INTO   v_contract_id
  FROM   contract_version cv
  WHERE  cv.id = p_contract_version_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_version with id % not found', p_contract_version_id USING ERRCODE = 'P0002';
  END IF;

  -- S2-23 FK pre-validation: clause_type_v2 must exist in clause_taxonomy for this tenant
  IF NOT EXISTS (
    SELECT 1 FROM clause_taxonomy
    WHERE tenant_id = v_tenant_id AND clause_type_id = p_clause_type_v2 AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'clause_type_v2 % not found in clause_taxonomy for this tenant', p_clause_type_v2 USING ERRCODE = '22023';
  END IF;

  -- Annex A.1.2 refuse-to-fabricate: every parameter key must have a matching text_excerpt
  FOR v_param_key IN SELECT jsonb_object_keys(p_parameters) LOOP
    IF NOT (p_text_excerpts ? v_param_key) THEN
      RAISE EXCEPTION 'Parameter % has no matching text_excerpt — extraction rejected', v_param_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Confidence-driven review routing
  SELECT COALESCE(
    (SELECT value::numeric FROM system_setting WHERE key = 'clause.review_confidence_threshold'),
    0.70
  ) INTO v_confidence_thresh;

  IF p_confidence IS NULL OR p_confidence < v_confidence_thresh THEN
    v_review_status := 'pending_review';
  ELSE
    v_review_status := 'auto';
  END IF;

  -- UPSERT — idempotent on (tenant_id, contract_version_id, clause_type_v2, source_offset_start)
  INSERT INTO contract_clause_extracted (
    tenant_id, contract_id, contract_version_id,
    clause_type_v2, parameters, text_excerpts,
    page_no, source_offset_start, source_offset_end,
    confidence, summary_en, summary_ar,
    review_status, extraction_model_version, extraction_prompt_hash,
    embedding, created_by, updated_by
  ) VALUES (
    v_tenant_id, v_contract_id, p_contract_version_id,
    p_clause_type_v2, p_parameters, p_text_excerpts,
    p_page_no, p_source_offset_start, p_source_offset_end,
    p_confidence, p_summary_en, p_summary_ar,
    v_review_status, p_extraction_model_version, p_extraction_prompt_hash,
    p_embedding, p_actor_id, p_actor_id
  )
  ON CONFLICT (tenant_id, contract_version_id, clause_type_v2, source_offset_start)
  DO UPDATE SET
    parameters                = EXCLUDED.parameters,
    text_excerpts             = EXCLUDED.text_excerpts,
    confidence                = EXCLUDED.confidence,
    embedding                 = EXCLUDED.embedding,
    summary_en                = EXCLUDED.summary_en,
    summary_ar                = EXCLUDED.summary_ar,
    review_status             = v_review_status,
    extraction_model_version  = EXCLUDED.extraction_model_version,
    extraction_prompt_hash    = EXCLUDED.extraction_prompt_hash,
    updated_at                = NOW(),
    updated_by                = p_actor_id
  RETURNING id INTO v_clause_id;

  -- OD-5: Auto-obligation derivation — derivation failure does NOT roll back the clause
  -- Uses nested BEGIN/EXCEPTION block (equivalent to SAVEPOINT isolation in plpgsql)
  IF v_review_status = 'auto' AND p_clause_type_v2 IN (
    'force_majeure', 'term_and_renewal', 'cure_period', 'icv_in_country_value', 'insurance'
  ) THEN
    BEGIN
      v_obligations := fn_obligations_derive_from_clause(v_clause_id, p_actor_id);
    EXCEPTION WHEN OTHERS THEN
      v_obligation_error := SQLERRM;
      -- Clause persists; obligation derivation failure is recoverable
    END;
  END IF;

  RETURN jsonb_build_object(
    'clauseId', v_clause_id,
    'reviewStatus', v_review_status,
    'obligationsCreated', COALESCE(v_obligations -> 'obligationIds', '[]'::jsonb),
    'obligationsSkippedAsDup', COALESCE((v_obligations -> 'obligationsSkippedAsDup')::int, 0),
    'obligationDerivationError', v_obligation_error
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_clause_upsert: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_clause_upsert(BIGINT, TEXT, JSONB, JSONB, INTEGER, INTEGER, INTEGER, NUMERIC, TEXT, TEXT, VECTOR, TEXT, TEXT, BIGINT) IS 'Persists one LLM-extracted clause idempotently on (tenant_id, contract_version_id, clause_type_v2, source_offset_start). Enforces Annex A.1.2 refuse-to-fabricate (22023 on missing text_excerpt). Confidence-routes to pending_review. Triggers obligation derivation via nested BEGIN/EXCEPTION block (OD-5 — derivation failure does not roll back the clause). SECURITY DEFINER (worker context).';
REVOKE EXECUTE ON FUNCTION fn_clause_upsert(BIGINT, TEXT, JSONB, JSONB, INTEGER, INTEGER, INTEGER, NUMERIC, TEXT, TEXT, VECTOR, TEXT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_clause_upsert(BIGINT, TEXT, JSONB, JSONB, INTEGER, INTEGER, INTEGER, NUMERIC, TEXT, TEXT, VECTOR, TEXT, TEXT, BIGINT) TO neondb_owner;

-- ============================================================
-- 4. fn_clause_review_queue_list
-- ============================================================
CREATE OR REPLACE FUNCTION fn_clause_review_queue_list(
  p_page            INTEGER,
  p_limit           INTEGER,
  p_contract_id     BIGINT,
  p_family          TEXT,
  p_confidence_band TEXT,
  p_search          TEXT,
  p_actor_id        BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_page       INTEGER := GREATEST(1, COALESCE(p_page, 1));
  v_limit      INTEGER := LEAST(100, GREATEST(1, COALESCE(p_limit, 20)));
  v_offset     INTEGER;
  v_data       JSONB;
  v_total      BIGINT;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('clause.review') THEN
    RAISE EXCEPTION 'Permission denied: clause.review required' USING ERRCODE = '42501';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  SELECT
    jsonb_agg(
      jsonb_build_object(
        'id',              cce.id,
        'contractId',      cce.contract_id,
        'contractTitleEn', c.title_en,
        'contractTitleAr', c.title_ar,
        'clauseTypeV2',    cce.clause_type_v2,
        'family',          ct.family,
        'displayNameEn',   ct.display_name_en,
        'displayNameAr',   ct.display_name_ar,
        'parametersPreview', cce.parameters,
        'confidence',      cce.confidence,
        'pageNo',          cce.page_no,
        'reviewStatus',    cce.review_status,
        'createdAt',       cce.created_at
      )
    ),
    COUNT(*) OVER ()
  INTO v_data, v_total
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
  OFFSET v_offset;

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

COMMENT ON FUNCTION fn_clause_review_queue_list(INTEGER, INTEGER, BIGINT, TEXT, TEXT, TEXT, BIGINT) IS 'Paginated review queue for clauses with review_status=pending_review. Filters by contractId, family, confidence_band (low/medium), search. Permission: clause.review.';
REVOKE EXECUTE ON FUNCTION fn_clause_review_queue_list(INTEGER, INTEGER, BIGINT, TEXT, TEXT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_clause_review_queue_list(INTEGER, INTEGER, BIGINT, TEXT, TEXT, TEXT, BIGINT) TO neondb_owner;

-- ============================================================
-- 5. fn_clause_review_resolve
-- ============================================================
CREATE OR REPLACE FUNCTION fn_clause_review_resolve(
  p_clause_id                  BIGINT,
  p_action                     TEXT,
  p_parameters_correction      JSONB,
  p_text_excerpts_correction   JSONB,
  p_actor_id                   BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
AS $$
DECLARE
  v_current_status       TEXT;
  v_new_status           TEXT;
  v_clause_type_v2       TEXT;
  v_param_key            TEXT;
  v_obligations_recomputed BOOLEAN := FALSE;
  v_obligations          JSONB;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('clause.review') THEN
    RAISE EXCEPTION 'Permission denied: clause.review required' USING ERRCODE = '42501';
  END IF;

  -- Validate action
  IF p_action NOT IN ('confirm', 'correct', 'reject') THEN
    RAISE EXCEPTION 'Invalid action %. Must be confirm, correct, or reject', p_action USING ERRCODE = '22023';
  END IF;

  -- Fetch and lock current row
  SELECT review_status, clause_type_v2
  INTO   v_current_status, v_clause_type_v2
  FROM   contract_clause_extracted
  WHERE  id = p_clause_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_clause_extracted with id % not found', p_clause_id USING ERRCODE = 'P0002';
  END IF;

  -- Double-resolve guard (AC-S6-05)
  IF v_current_status IN ('reviewed', 'rejected') THEN
    RAISE EXCEPTION 'already_resolved: clause % has status %', p_clause_id, v_current_status USING ERRCODE = 'P0001';
  END IF;

  IF p_action = 'correct' THEN
    -- Refuse-to-fabricate on correction: every parameter key must have matching text_excerpt
    FOR v_param_key IN SELECT jsonb_object_keys(p_parameters_correction) LOOP
      IF NOT (p_text_excerpts_correction ? v_param_key) THEN
        RAISE EXCEPTION 'Parameter % has no matching text_excerpt in correction', v_param_key USING ERRCODE = '22023';
      END IF;
    END LOOP;
    v_new_status := 'reviewed';
    UPDATE contract_clause_extracted SET
      parameters    = p_parameters_correction,
      text_excerpts = p_text_excerpts_correction,
      review_status = v_new_status,
      reviewed_by   = p_actor_id,
      reviewed_at   = NOW(),
      updated_at    = NOW(),
      updated_by    = p_actor_id
    WHERE id = p_clause_id;

  ELSIF p_action = 'confirm' THEN
    v_new_status := 'reviewed';
    UPDATE contract_clause_extracted SET
      review_status = v_new_status,
      reviewed_by   = p_actor_id,
      reviewed_at   = NOW(),
      updated_at    = NOW(),
      updated_by    = p_actor_id
    WHERE id = p_clause_id;

  ELSE -- reject
    v_new_status := 'rejected';
    UPDATE contract_clause_extracted SET
      review_status = v_new_status,
      reviewed_by   = p_actor_id,
      reviewed_at   = NOW(),
      updated_at    = NOW(),
      updated_by    = p_actor_id
    WHERE id = p_clause_id;
  END IF;

  -- Re-run obligation derivation on confirm/correct for obligation-deriving clause types (idempotent via UNIQUE INDEX)
  IF p_action IN ('confirm', 'correct') AND v_clause_type_v2 IN (
    'force_majeure', 'term_and_renewal', 'cure_period', 'icv_in_country_value', 'insurance'
  ) THEN
    v_obligations := fn_obligations_derive_from_clause(p_clause_id, p_actor_id);
    v_obligations_recomputed := TRUE;
  END IF;

  RETURN jsonb_build_object(
    'clauseId',             p_clause_id,
    'newReviewStatus',      v_new_status,
    'obligationsRecomputed', v_obligations_recomputed
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_clause_review_resolve: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_clause_review_resolve(BIGINT, TEXT, JSONB, JSONB, BIGINT) IS 'Legal counsel resolves a pending_review clause via confirm / correct / reject. Double-resolve guard returns P0001 already_resolved. Enforces refuse-to-fabricate on correct action. Re-runs obligation derivation on confirm/correct. Permission: clause.review.';
REVOKE EXECUTE ON FUNCTION fn_clause_review_resolve(BIGINT, TEXT, JSONB, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_clause_review_resolve(BIGINT, TEXT, JSONB, JSONB, BIGINT) TO neondb_owner;

-- ============================================================
-- 6. fn_clause_semantic_search
-- ============================================================
CREATE OR REPLACE FUNCTION fn_clause_semantic_search(
  p_query_embedding  VECTOR(1536),
  p_contract_id      BIGINT,
  p_limit            INTEGER,
  p_similarity_min   NUMERIC,
  p_actor_id         BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_limit   INTEGER := LEAST(100, GREATEST(1, COALESCE(p_limit, 20)));
  v_sim_min NUMERIC := COALESCE(p_similarity_min, 0.0);
  v_data    JSONB;
  v_count   BIGINT;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('clause.search') THEN
    RAISE EXCEPTION 'Permission denied: clause.search required' USING ERRCODE = '42501';
  END IF;

  SELECT
    jsonb_agg(
      jsonb_build_object(
        'clauseId',      cce.id,
        'contractId',    cce.contract_id,
        'clauseTypeV2',  cce.clause_type_v2,
        'family',        ct.family,
        'displayNameEn', ct.display_name_en,
        'displayNameAr', ct.display_name_ar,
        'similarity',    ROUND((1 - (cce.embedding <=> p_query_embedding))::numeric, 4),
        'summaryEn',     cce.summary_en,
        'summaryAr',     cce.summary_ar,
        'pageNo',        cce.page_no
      )
    ),
    COUNT(*)
  INTO v_data, v_count
  FROM (
    SELECT cce.*, (1 - (cce.embedding <=> p_query_embedding)) AS similarity_score
    FROM   contract_clause_extracted cce
    WHERE  cce.is_active = TRUE
      AND  cce.embedding IS NOT NULL
      AND  (p_contract_id IS NULL OR cce.contract_id = p_contract_id)
      AND  (1 - (cce.embedding <=> p_query_embedding)) >= v_sim_min
    ORDER BY cce.embedding <=> p_query_embedding
    LIMIT  v_limit
  ) cce
  JOIN clause_taxonomy ct ON ct.tenant_id = cce.tenant_id
    AND ct.clause_type_id = cce.clause_type_v2;

  RETURN jsonb_build_object(
    'data',  COALESCE(v_data, '[]'::jsonb),
    'count', COALESCE(v_count, 0)
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_clause_semantic_search: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_clause_semantic_search(VECTOR, BIGINT, INTEGER, NUMERIC, BIGINT) IS 'pgvector cosine-similarity semantic search via ivfflat index (lists=100 default, CF-8 tunable). BE service computes query embedding before calling this fn. RLS narrows by tenant. Permission: clause.search. p95 < 300ms NFR per AC-S7-03.';
REVOKE EXECUTE ON FUNCTION fn_clause_semantic_search(VECTOR, BIGINT, INTEGER, NUMERIC, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_clause_semantic_search(VECTOR, BIGINT, INTEGER, NUMERIC, BIGINT) TO neondb_owner;

-- ============================================================
-- 7. fn_obligations_derive_from_clause
-- ============================================================
CREATE OR REPLACE FUNCTION fn_obligations_derive_from_clause(
  p_clause_id  BIGINT,
  p_actor_id   BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
  v_clause            RECORD;
  v_contract          RECORD;
  v_clause_type       TEXT;
  v_params            JSONB;
  v_obligation_ids    JSONB := '[]'::jsonb;
  v_skip_count        INTEGER := 0;
  v_new_id            BIGINT;
  v_inserted          BOOLEAN;
  v_due_date          DATE;
BEGIN
  -- Fetch clause + parent contract (S2-23 / CF-4: contract_obligation.updated_at exists)
  SELECT cce.clause_type_v2, cce.parameters, cce.contract_id
  INTO   v_clause
  FROM   contract_clause_extracted cce
  WHERE  cce.id = p_clause_id AND cce.is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_clause_extracted with id % not found', p_clause_id USING ERRCODE = 'P0002';
  END IF;

  v_clause_type := v_clause.clause_type_v2;
  v_params      := v_clause.parameters;

  SELECT c.id, c.effective_date
  INTO   v_contract
  FROM   contract c
  WHERE  c.id = v_clause.contract_id;

  -- CASE on clause_type_v2 — 5 obligation-deriving types
  IF v_clause_type = 'force_majeure' THEN
    IF v_params ? 'notice_period_days' THEN
      INSERT INTO contract_obligation (
        contract_id, obligation_type, description_en, description_ar,
        responsible_party, recurrence, status,
        derived_from_clause_id,
        created_at, updated_at, created_by, updated_by, is_active
      ) VALUES (
        v_clause.contract_id, 'notice',
        'FM event notification (notice period: ' || (v_params->>'notice_period_days') || ' days)',
        '[AR] FM event notification (notice period: ' || (v_params->>'notice_period_days') || ' days)',
        'affected_party', 'none', 'active',
        p_clause_id,
        NOW(), NOW(), p_actor_id, p_actor_id, TRUE
      )
      ON CONFLICT (derived_from_clause_id, obligation_type)
        WHERE derived_from_clause_id IS NOT NULL AND is_active = TRUE
      DO NOTHING
      RETURNING id INTO v_new_id;

      IF v_new_id IS NOT NULL THEN
        v_obligation_ids := v_obligation_ids || jsonb_build_array(v_new_id);
      ELSE
        v_skip_count := v_skip_count + 1;
      END IF;
    END IF;

  ELSIF v_clause_type = 'term_and_renewal' THEN
    IF (v_params ? 'expiry_date') AND (v_params ? 'renewal_notice_period_days') THEN
      BEGIN
        v_due_date := (v_params->>'expiry_date')::date
                      - ((v_params->>'renewal_notice_period_days')::int * INTERVAL '1 day');
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid date/duration in term_and_renewal parameters' USING ERRCODE = '22023';
      END;
      INSERT INTO contract_obligation (
        contract_id, obligation_type, description_en, description_ar,
        due_date, responsible_party, recurrence, status,
        derived_from_clause_id,
        created_at, updated_at, created_by, updated_by, is_active
      ) VALUES (
        v_clause.contract_id, 'renewal',
        'Renewal notice due ' || v_due_date::text || ' (expiry: ' || (v_params->>'expiry_date') || ')',
        '[AR] Renewal notice due ' || v_due_date::text,
        v_due_date, 'principal', 'none', 'active',
        p_clause_id,
        NOW(), NOW(), p_actor_id, p_actor_id, TRUE
      )
      ON CONFLICT (derived_from_clause_id, obligation_type)
        WHERE derived_from_clause_id IS NOT NULL AND is_active = TRUE
      DO NOTHING
      RETURNING id INTO v_new_id;

      IF v_new_id IS NOT NULL THEN
        v_obligation_ids := v_obligation_ids || jsonb_build_array(v_new_id);
      ELSE
        v_skip_count := v_skip_count + 1;
      END IF;
    END IF;

  ELSIF v_clause_type = 'cure_period' THEN
    IF v_params ? 'cure_period_days' THEN
      INSERT INTO contract_obligation (
        contract_id, obligation_type, description_en, description_ar,
        responsible_party, recurrence, status,
        derived_from_clause_id,
        created_at, updated_at, created_by, updated_by, is_active
      ) VALUES (
        v_clause.contract_id, 'cure',
        'Cure period obligation (' || (v_params->>'cure_period_days') || ' days to remedy breach)',
        '[AR] Cure period obligation (' || (v_params->>'cure_period_days') || ' days to remedy breach)',
        'contractor', 'none', 'active',
        p_clause_id,
        NOW(), NOW(), p_actor_id, p_actor_id, TRUE
      )
      ON CONFLICT (derived_from_clause_id, obligation_type)
        WHERE derived_from_clause_id IS NOT NULL AND is_active = TRUE
      DO NOTHING
      RETURNING id INTO v_new_id;

      IF v_new_id IS NOT NULL THEN
        v_obligation_ids := v_obligation_ids || jsonb_build_array(v_new_id);
      ELSE
        v_skip_count := v_skip_count + 1;
      END IF;
    END IF;

  ELSIF v_clause_type = 'icv_in_country_value' THEN
    IF (v_params ? 'icv_reporting_period_months') AND (v_contract.effective_date IS NOT NULL) THEN
      BEGIN
        v_due_date := (v_contract.effective_date
          + ((v_params->>'icv_reporting_period_months')::int * INTERVAL '1 month'))::date;
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid icv_reporting_period_months value' USING ERRCODE = '22023';
      END;
      INSERT INTO contract_obligation (
        contract_id, obligation_type, description_en, description_ar,
        due_date, responsible_party, recurrence, status,
        derived_from_clause_id,
        created_at, updated_at, created_by, updated_by, is_active
      ) VALUES (
        v_clause.contract_id, 'certification',
        'ICV certification due ' || v_due_date::text || ' (reporting period: ' || (v_params->>'icv_reporting_period_months') || ' months)',
        '[AR] ICV certification due ' || v_due_date::text,
        v_due_date, 'contractor', 'annual', 'active',
        p_clause_id,
        NOW(), NOW(), p_actor_id, p_actor_id, TRUE
      )
      ON CONFLICT (derived_from_clause_id, obligation_type)
        WHERE derived_from_clause_id IS NOT NULL AND is_active = TRUE
      DO NOTHING
      RETURNING id INTO v_new_id;

      IF v_new_id IS NOT NULL THEN
        v_obligation_ids := v_obligation_ids || jsonb_build_array(v_new_id);
      ELSE
        v_skip_count := v_skip_count + 1;
      END IF;
    END IF;

  ELSIF v_clause_type = 'insurance' THEN
    IF v_params ? 'expiry_date_per_policy' THEN
      INSERT INTO contract_obligation (
        contract_id, obligation_type, description_en, description_ar,
        responsible_party, recurrence, status,
        derived_from_clause_id,
        created_at, updated_at, created_by, updated_by, is_active
      ) VALUES (
        v_clause.contract_id, 'notice',
        'Insurance policy expiry notice (expiry: ' || (v_params->>'expiry_date_per_policy') || ')',
        '[AR] Insurance policy expiry notice',
        'contractor', 'annual', 'active',
        p_clause_id,
        NOW(), NOW(), p_actor_id, p_actor_id, TRUE
      )
      ON CONFLICT (derived_from_clause_id, obligation_type)
        WHERE derived_from_clause_id IS NOT NULL AND is_active = TRUE
      DO NOTHING
      RETURNING id INTO v_new_id;

      IF v_new_id IS NOT NULL THEN
        v_obligation_ids := v_obligation_ids || jsonb_build_array(v_new_id);
      ELSE
        v_skip_count := v_skip_count + 1;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'clauseId',               p_clause_id,
    'obligationIds',          v_obligation_ids,
    'obligationsSkippedAsDup', v_skip_count
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_obligations_derive_from_clause: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_obligations_derive_from_clause(BIGINT, BIGINT) IS 'Reads contract_clause_extracted.parameters and creates contract_obligation rows for 5 obligation-deriving clause types (force_majeure, term_and_renewal, cure_period, icv_in_country_value, insurance). Idempotent via partial UNIQUE INDEX on (derived_from_clause_id, obligation_type). Called from fn_clause_upsert via nested BEGIN/EXCEPTION block (OD-5) + from fn_clause_review_resolve on confirm/correct. SECURITY DEFINER.';
REVOKE EXECUTE ON FUNCTION fn_obligations_derive_from_clause(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_obligations_derive_from_clause(BIGINT, BIGINT) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (146, '146_crd_clause_functions', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 146;
-- DROP FUNCTION IF EXISTS fn_obligations_derive_from_clause(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_clause_semantic_search(VECTOR, BIGINT, INTEGER, NUMERIC, BIGINT);
-- DROP FUNCTION IF EXISTS fn_clause_review_resolve(BIGINT, TEXT, JSONB, JSONB, BIGINT);
-- DROP FUNCTION IF EXISTS fn_clause_review_queue_list(INTEGER, INTEGER, BIGINT, TEXT, TEXT, TEXT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_clause_upsert(BIGINT, TEXT, JSONB, JSONB, INTEGER, INTEGER, INTEGER, NUMERIC, TEXT, TEXT, VECTOR, TEXT, TEXT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_clause_extraction_request(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_clause_taxonomy_list(BIGINT);
-- ============================================================
