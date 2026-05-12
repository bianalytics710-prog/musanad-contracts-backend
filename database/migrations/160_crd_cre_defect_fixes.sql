-- Migration: 160_crd_cre_defect_fixes.sql
-- Module: M12 / CR-D + M13 / CR-E — Testing-phase defect fixes
-- Defects found during Testing Agent test run (2026-05-12):
--
-- DEFECT-CRD-1: fn_clause_upsert — system_setting.value is jsonb; casting directly
--   to numeric fails when value is stored as a jsonb string "0.70".
--   Fix: use (value #>> '{}')::numeric to extract as text first.
--
-- DEFECT-CRD-2: fn_obligations_derive_from_clause — references c.effective_date
--   which does not exist on the contract table (correct column is c.start_date).
--   Fix: replace effective_date with start_date in the SELECT and ELSIF branch.
--
-- DEFECT-CRD-3: fn_clause_review_queue_list — uses jsonb_agg() and COUNT(*) OVER ()
--   in the same SELECT-INTO; this mixing of aggregate + window function without
--   a subquery causes "column must appear in GROUP BY" error at runtime.
--   Fix: rewrite as CTE (WITH paged AS (...) SELECT ...) so window function runs
--   in the inner query and jsonb_agg wraps the outer.
--
-- Standards: CREATE OR REPLACE preserves GRANT/REVOKE from migration 146/147.
-- Rollback: see ROLLBACK section.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- DEFECT-CRD-1 + DEFECT-CRD-2: Fix fn_clause_upsert
-- (only the confidence threshold read line changes; rest identical to 146)
CREATE OR REPLACE FUNCTION fn_clause_upsert(
  p_contract_version_id    BIGINT,
  p_clause_type_v2         TEXT,
  p_parameters             JSONB,
  p_text_excerpts          JSONB,
  p_page_no                INTEGER,
  p_source_offset_start    INTEGER,
  p_source_offset_end      INTEGER,
  p_confidence             NUMERIC,
  p_extraction_model_version TEXT,
  p_extraction_prompt_hash TEXT,
  p_embedding              vector,
  p_summary_en             TEXT,
  p_summary_ar             TEXT,
  p_actor_id               BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id          UUID;
  v_contract_id        BIGINT;
  v_clause_id          BIGINT;
  v_review_status      TEXT;
  v_confidence_thresh  NUMERIC;
  v_param_key          TEXT;
  v_obligations        JSONB;
  v_obligation_error   TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  -- Resolve contract from version
  SELECT cv.contract_id INTO v_contract_id
  FROM contract_version cv WHERE cv.id = p_contract_version_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_version with id % not found', p_contract_version_id USING ERRCODE = 'P0002';
  END IF;

  -- Validate clause type exists in tenant taxonomy
  IF NOT EXISTS (
    SELECT 1 FROM clause_taxonomy
    WHERE tenant_id = v_tenant_id AND clause_type_id = p_clause_type_v2 AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'clause_type_v2 % not found in clause_taxonomy for this tenant', p_clause_type_v2 USING ERRCODE = '22023';
  END IF;

  -- Validate every parameter has a matching text excerpt
  FOR v_param_key IN SELECT jsonb_object_keys(p_parameters) LOOP
    IF NOT (p_text_excerpts ? v_param_key) THEN
      RAISE EXCEPTION 'Parameter % has no matching text_excerpt — extraction rejected', v_param_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- DEFECT-CRD-1 FIX: use #>> '{}' to extract jsonb string as text before casting to numeric
  SELECT COALESCE(
    (SELECT (value #>> '{}')::numeric FROM system_setting WHERE key = 'clause.review_confidence_threshold'),
    0.70
  ) INTO v_confidence_thresh;

  IF p_confidence IS NULL OR p_confidence < v_confidence_thresh THEN
    v_review_status := 'pending_review';
  ELSE
    v_review_status := 'auto';
  END IF;

  INSERT INTO contract_clause_extracted (
    tenant_id, contract_id, contract_version_id, clause_type_v2,
    parameters, text_excerpts, page_no, source_offset_start, source_offset_end,
    confidence, summary_en, summary_ar, review_status,
    extraction_model_version, extraction_prompt_hash, embedding,
    created_by, updated_by
  )
  VALUES (
    v_tenant_id, v_contract_id, p_contract_version_id, p_clause_type_v2,
    p_parameters, p_text_excerpts, p_page_no, p_source_offset_start, p_source_offset_end,
    p_confidence, p_summary_en, p_summary_ar, v_review_status,
    p_extraction_model_version, p_extraction_prompt_hash, p_embedding,
    p_actor_id, p_actor_id
  )
  ON CONFLICT (tenant_id, contract_version_id, clause_type_v2, source_offset_start)
  DO UPDATE SET
    parameters              = EXCLUDED.parameters,
    text_excerpts           = EXCLUDED.text_excerpts,
    confidence              = EXCLUDED.confidence,
    embedding               = EXCLUDED.embedding,
    summary_en              = EXCLUDED.summary_en,
    summary_ar              = EXCLUDED.summary_ar,
    review_status           = v_review_status,
    extraction_model_version = EXCLUDED.extraction_model_version,
    extraction_prompt_hash  = EXCLUDED.extraction_prompt_hash,
    updated_at              = NOW(),
    updated_by              = p_actor_id
  RETURNING id INTO v_clause_id;

  -- Auto-derive obligations if high-confidence
  v_obligations := '{"derivedObligationIds":[],"obligationsSkippedAsDup":0}'::jsonb;
  IF v_review_status = 'auto' AND p_clause_type_v2 IN (
    'force_majeure','term_and_renewal','cure_period','icv_in_country_value','insurance'
  ) THEN
    BEGIN
      v_obligations := fn_obligations_derive_from_clause(v_clause_id, p_actor_id);
    EXCEPTION WHEN OTHERS THEN
      v_obligation_error := SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'clauseId',               v_clause_id,
    'reviewStatus',           v_review_status,
    'obligationsCreated',     COALESCE(v_obligations->'obligationIds', '[]'::jsonb),
    'obligationsSkippedAsDup', COALESCE((v_obligations->'obligationsSkippedAsDup')::int, 0),
    'obligationDerivationError', v_obligation_error
  );

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_clause_upsert: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

-- DEFECT-CRD-2 FIX: fn_obligations_derive_from_clause — replace c.effective_date with c.start_date
CREATE OR REPLACE FUNCTION fn_obligations_derive_from_clause(
  p_clause_id  BIGINT,
  p_actor_id   BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_clause          RECORD;
  v_contract        RECORD;
  v_clause_type     TEXT;
  v_params          JSONB;
  v_obligation_ids  JSONB := '[]'::jsonb;
  v_skip_count      INTEGER := 0;
  v_new_id          BIGINT;
  v_due_date        DATE;
BEGIN
  SELECT cce.clause_type_v2, cce.parameters, cce.contract_id
  INTO   v_clause
  FROM   contract_clause_extracted cce
  WHERE  cce.id = p_clause_id AND cce.is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_clause_extracted with id % not found', p_clause_id USING ERRCODE = 'P0002';
  END IF;

  v_clause_type := v_clause.clause_type_v2;
  v_params      := v_clause.parameters;

  -- DEFECT-CRD-2 FIX: contract table uses start_date, not effective_date
  SELECT c.id, c.start_date INTO v_contract FROM contract c WHERE c.id = v_clause.contract_id;

  -- DEFECT-CRD-4 FIX: contract_obligation requires title_en (NOT NULL) and
  -- data_classification (NOT NULL) — original migration 146 fn body omits them.
  IF v_clause_type = 'force_majeure' THEN
    IF v_params ? 'notice_period_days' THEN
      INSERT INTO contract_obligation (
        contract_id, title_en, obligation_type, description_en, description_ar,
        responsible_party, recurrence, status, derived_from_clause_id,
        data_classification, created_at, updated_at, created_by, updated_by, is_active
      )
      VALUES (
        v_clause.contract_id,
        'Force Majeure Notice (' || (v_params->>'notice_period_days') || ' days)',
        'notice',
        'FM event notification (notice period: ' || (v_params->>'notice_period_days') || ' days)',
        '[AR] FM event notification (notice period: ' || (v_params->>'notice_period_days') || ' days)',
        'our_party', 'once', 'open', p_clause_id,
        'demo', NOW(), NOW(), p_actor_id, p_actor_id, TRUE
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
        contract_id, title_en, obligation_type, description_en, description_ar,
        due_date, responsible_party, recurrence, status, derived_from_clause_id,
        data_classification, created_at, updated_at, created_by, updated_by, is_active
      )
      VALUES (
        v_clause.contract_id,
        'Renewal Notice Due ' || v_due_date::text,
        'renewal',
        'Renewal notice due ' || v_due_date::text,
        '[AR] Renewal notice due ' || v_due_date::text,
        v_due_date, 'our_party', 'once', 'open', p_clause_id,
        'demo', NOW(), NOW(), p_actor_id, p_actor_id, TRUE
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
        contract_id, title_en, obligation_type, description_en, description_ar,
        responsible_party, recurrence, status, derived_from_clause_id,
        data_classification, created_at, updated_at, created_by, updated_by, is_active
      )
      VALUES (
        v_clause.contract_id,
        'Cure Period (' || (v_params->>'cure_period_days') || ' days)',
        'cure',
        'Cure period obligation (' || (v_params->>'cure_period_days') || ' days to remedy breach)',
        '[AR] Cure period obligation (' || (v_params->>'cure_period_days') || ' days to remedy breach)',
        'counterparty', 'once', 'open', p_clause_id,
        'demo', NOW(), NOW(), p_actor_id, p_actor_id, TRUE
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
    -- DEFECT-CRD-2 FIX: use v_contract.start_date (was v_contract.effective_date)
    IF (v_params ? 'icv_reporting_period_months') AND (v_contract.start_date IS NOT NULL) THEN
      BEGIN
        v_due_date := (v_contract.start_date
                      + ((v_params->>'icv_reporting_period_months')::int * INTERVAL '1 month'))::date;
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid icv_reporting_period_months value' USING ERRCODE = '22023';
      END;
      INSERT INTO contract_obligation (
        contract_id, title_en, obligation_type, description_en, description_ar,
        due_date, responsible_party, recurrence, status, derived_from_clause_id,
        data_classification, created_at, updated_at, created_by, updated_by, is_active
      )
      VALUES (
        v_clause.contract_id,
        'ICV Certification Due ' || v_due_date::text,
        'certification',
        'ICV certification due ' || v_due_date::text,
        '[AR] ICV certification due ' || v_due_date::text,
        v_due_date, 'counterparty', 'annually', 'open', p_clause_id,
        'demo', NOW(), NOW(), p_actor_id, p_actor_id, TRUE
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
        contract_id, title_en, obligation_type, description_en, description_ar,
        responsible_party, recurrence, status, derived_from_clause_id,
        data_classification, created_at, updated_at, created_by, updated_by, is_active
      )
      VALUES (
        v_clause.contract_id,
        'Insurance Policy Expiry Notice',
        'notice',
        'Insurance policy expiry notice',
        '[AR] Insurance policy expiry notice',
        'counterparty', 'annually', 'open', p_clause_id,
        'demo', NOW(), NOW(), p_actor_id, p_actor_id, TRUE
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

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_obligations_derive_from_clause: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

-- DEFECT-CRD-3 FIX: fn_clause_review_queue_list — rewrite with CTE to avoid
-- aggregate + window function conflict in single SELECT-INTO
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
AS $$
DECLARE
  v_page   INTEGER := GREATEST(1, COALESCE(p_page, 1));
  v_limit  INTEGER := LEAST(100, GREATEST(1, COALESCE(p_limit, 20)));
  v_offset INTEGER;
  v_data   JSONB;
  v_total  BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('clause.review') THEN
    RAISE EXCEPTION 'Permission denied: clause.review required' USING ERRCODE = '42501';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  -- DEFECT-CRD-3 FIX: use CTE to separate window function from aggregate
  WITH filtered AS (
    SELECT
      cce.id, cce.contract_id, c.title_en, c.title_ar,
      cce.clause_type_v2, ct.family, ct.display_name_en, ct.display_name_ar,
      cce.parameters, cce.confidence, cce.page_no, cce.review_status, cce.created_at,
      COUNT(*) OVER () AS total_count
    FROM contract_clause_extracted cce
    JOIN contract c        ON c.id = cce.contract_id
    JOIN clause_taxonomy ct
      ON ct.tenant_id = cce.tenant_id AND ct.clause_type_id = cce.clause_type_v2
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
    LIMIT v_limit OFFSET v_offset
  )
  SELECT
    jsonb_agg(jsonb_build_object(
      'id',               id,
      'contractId',       contract_id,
      'contractTitleEn',  title_en,
      'contractTitleAr',  title_ar,
      'clauseTypeV2',     clause_type_v2,
      'family',           family,
      'displayNameEn',    display_name_en,
      'displayNameAr',    display_name_ar,
      'parametersPreview', parameters,
      'confidence',       confidence,
      'pageNo',           page_no,
      'reviewStatus',     review_status,
      'createdAt',        created_at
    )),
    COALESCE(MAX(total_count), 0)
  INTO v_data, v_total
  FROM filtered;

  RETURN jsonb_build_object(
    'data', COALESCE(v_data, '[]'::jsonb),
    'pagination', jsonb_build_object(
      'total',      COALESCE(v_total, 0),
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', GREATEST(1, CEIL(COALESCE(v_total, 0)::numeric / v_limit))
    )
  );

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_clause_review_queue_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

-- DEFECT-CRE-1 FIX: fn_rule_list — same jsonb_agg + COUNT(*) OVER() mixing pattern as DEFECT-CRD-3
CREATE OR REPLACE FUNCTION fn_rule_list(
  p_page    INTEGER,
  p_limit   INTEGER,
  p_scenario TEXT,
  p_enabled  BOOLEAN,
  p_search   TEXT,
  p_actor_id BIGINT
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
  IF NOT fn_current_user_has_permission('rule.read') THEN
    RAISE EXCEPTION 'Permission denied: rule.read required' USING ERRCODE = '42501';
  END IF;
  v_offset := (v_page - 1) * v_limit;

  WITH filtered AS (
    SELECT
      cr.id, cr.rule_id, cr.name, cr.name_ar, cr.scenario, cr.enabled,
      cr.version_hash, cr.last_reviewed_at, cr.created_at, cr.updated_at,
      COUNT(*) OVER () AS total_count
    FROM correlation_rule cr
    WHERE cr.is_active = TRUE
      AND (p_scenario IS NULL OR cr.scenario = p_scenario)
      AND (p_enabled IS NULL OR cr.enabled = p_enabled)
      AND (
        p_search IS NULL
        OR cr.name ILIKE '%' || p_search || '%'
        OR cr.name_ar ILIKE '%' || p_search || '%'
      )
    ORDER BY cr.last_reviewed_at ASC NULLS FIRST, cr.created_at ASC
    LIMIT v_limit OFFSET v_offset
  )
  SELECT
    jsonb_agg(jsonb_build_object(
      'id',               id,
      'ruleId',           rule_id,
      'name',             name,
      'nameAr',           name_ar,
      'scenario',         scenario,
      'enabled',          enabled,
      'versionHashShort', substr(version_hash, 1, 8),
      'versionHash',      version_hash,
      'lastReviewedAt',   last_reviewed_at,
      'createdAt',        created_at,
      'updatedAt',        updated_at,
      'fixtureCount',     COALESCE(
        (SELECT COUNT(*) FROM correlation_rule_fixture f
         WHERE f.correlation_rule_id = id AND f.is_active = TRUE), 0)
    ) ORDER BY last_reviewed_at ASC NULLS FIRST, created_at ASC),
    COALESCE(MAX(total_count), 0)
  INTO v_data, v_total
  FROM filtered;

  RETURN jsonb_build_object(
    'data',       COALESCE(v_data, '[]'::jsonb),
    'pagination', jsonb_build_object(
      'total',      COALESCE(v_total, 0),
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', GREATEST(1, CEIL(COALESCE(v_total, 0)::numeric / v_limit))
    )
  );
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_rule_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

-- DEFECT-CRE-2 FIX: fn_correlation_list — same jsonb_agg + COUNT(*) OVER() mixing pattern
CREATE OR REPLACE FUNCTION fn_correlation_list(
  p_page        INTEGER,
  p_limit       INTEGER,
  p_contract_id BIGINT,
  p_rule_id     TEXT,
  p_signal_id   BIGINT,
  p_status      TEXT,
  p_scenario    TEXT,
  p_since       TIMESTAMP WITH TIME ZONE,
  p_actor_id    BIGINT
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

  WITH filtered AS (
    SELECT
      corr.id, corr.signal_id, corr.contract_id,
      c.title_en, c.title_ar,
      corr.rule_id, cr.name AS rule_name, cr.name_ar AS rule_name_ar, cr.scenario,
      corr.rule_version_hash, corr.confidence, corr.match_reason,
      corr.status, corr.expires_at, corr.dismissed_at, corr.dismissed_reason,
      corr.created_at,
      COUNT(*) OVER () AS total_count
    FROM correlation corr
    JOIN contract c ON c.id = corr.contract_id
    LEFT JOIN correlation_rule cr ON cr.tenant_id = corr.tenant_id
      AND cr.rule_id = corr.rule_id AND cr.is_active = TRUE
    WHERE corr.is_active = TRUE
      AND (p_contract_id IS NULL OR corr.contract_id = p_contract_id)
      AND (p_rule_id IS NULL OR corr.rule_id = p_rule_id)
      AND (p_signal_id IS NULL OR corr.signal_id = p_signal_id)
      AND (p_status IS NULL OR corr.status = p_status)
      AND (p_scenario IS NULL OR cr.scenario = p_scenario)
      AND (p_since IS NULL OR corr.created_at >= p_since)
    ORDER BY corr.created_at DESC
    LIMIT v_limit OFFSET v_offset
  )
  SELECT
    jsonb_agg(jsonb_build_object(
      'id',               id,
      'signalId',         signal_id,
      'contractId',       contract_id,
      'contractTitleEn',  title_en,
      'contractTitleAr',  title_ar,
      'ruleId',           rule_id,
      'ruleName',         rule_name,
      'ruleNameAr',       rule_name_ar,
      'scenario',         scenario,
      'ruleVersionHash',  rule_version_hash,
      'confidence',       confidence,
      'matchReason',      match_reason,
      'status',           status,
      'expiresAt',        expires_at,
      'dismissedAt',      dismissed_at,
      'dismissedReason',  dismissed_reason,
      'createdAt',        created_at
    ) ORDER BY created_at DESC),
    COALESCE(MAX(total_count), 0)
  INTO v_data, v_total
  FROM filtered;

  RETURN jsonb_build_object(
    'data',       COALESCE(v_data, '[]'::jsonb),
    'pagination', jsonb_build_object(
      'total',      COALESCE(v_total, 0),
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', GREATEST(1, CEIL(COALESCE(v_total, 0)::numeric / v_limit))
    )
  );
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_correlation_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

-- Re-apply permissions (same as migration 147 / 154)
REVOKE ALL ON FUNCTION fn_clause_upsert(BIGINT,TEXT,JSONB,JSONB,INTEGER,INTEGER,INTEGER,NUMERIC,TEXT,TEXT,vector,TEXT,TEXT,BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_clause_upsert(BIGINT,TEXT,JSONB,JSONB,INTEGER,INTEGER,INTEGER,NUMERIC,TEXT,TEXT,vector,TEXT,TEXT,BIGINT) TO neondb_owner;

REVOKE ALL ON FUNCTION fn_obligations_derive_from_clause(BIGINT,BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_obligations_derive_from_clause(BIGINT,BIGINT) TO neondb_owner;

REVOKE ALL ON FUNCTION fn_clause_review_queue_list(INTEGER,INTEGER,BIGINT,TEXT,TEXT,TEXT,BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_clause_review_queue_list(INTEGER,INTEGER,BIGINT,TEXT,TEXT,TEXT,BIGINT) TO neondb_owner;

REVOKE ALL ON FUNCTION fn_rule_list(INTEGER,INTEGER,TEXT,BOOLEAN,TEXT,BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_rule_list(INTEGER,INTEGER,TEXT,BOOLEAN,TEXT,BIGINT) TO neondb_owner;

REVOKE ALL ON FUNCTION fn_correlation_list(INTEGER,INTEGER,BIGINT,TEXT,BIGINT,TEXT,TEXT,TIMESTAMP WITH TIME ZONE,BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_correlation_list(INTEGER,INTEGER,BIGINT,TEXT,BIGINT,TEXT,TEXT,TIMESTAMP WITH TIME ZONE,BIGINT) TO neondb_owner;

-- Record migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (160, 'DEFECT-CRD-1/2/3: fix fn_clause_upsert confidence threshold cast, fn_obligations_derive_from_clause effective_date→start_date, fn_clause_review_queue_list GROUP BY', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- To rollback: restore the three functions from migration 146.
-- DELETE FROM schema_migrations WHERE version = 160;
