-- MIGRATION: 517_tpa_functions.sql
-- Feature: Third-Party Agreement Assessment (TPA) — fn_'s
-- Date: 2026-06-03
-- Description:
--   DB-side functions called by the BE TPA controller. All are DEFINER
--   except the read-side fn_'s which are STABLE INVOKER (RLS enforced via
--   tenant GUC). Per-fn explicit REVOKE PUBLIC + GRANT neondb_owner so the
--   S2-21 'no PUBLIC EXECUTE' guard stays clean (16+ consecutive modules).

BEGIN;

-- ============================================================
-- fn_tpa_playbook_list — list active playbooks
-- ============================================================
CREATE OR REPLACE FUNCTION fn_tpa_playbook_list(p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_result JSONB;
BEGIN
  IF NOT fn_has_permission(p_actor_id, 'tpa.review.read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             p.id,
    'playbookKey',    p.playbook_key,
    'agreementType',  p.agreement_type,
    'nameEn',         p.name_en,
    'nameAr',         p.name_ar,
    'descriptionEn',  p.description_en,
    'version',        p.version,
    'status',         p.status,
    'clauseCount',    (SELECT COUNT(*) FROM tpa_playbook_clause c
                       WHERE c.playbook_id = p.id AND c.is_active = TRUE)
  ) ORDER BY p.agreement_type, p.name_en), '[]'::jsonb) INTO v_result
  FROM tpa_playbook p
  WHERE p.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    AND p.is_active = TRUE
    AND p.status = 'active';

  RETURN v_result;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION fn_tpa_playbook_list(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tpa_playbook_list(BIGINT) TO neondb_owner;


-- ============================================================
-- fn_tpa_playbook_get — playbook header + clauses
-- ============================================================
CREATE OR REPLACE FUNCTION fn_tpa_playbook_get(p_actor_id BIGINT, p_playbook_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_result JSONB;
BEGIN
  IF NOT fn_has_permission(p_actor_id, 'tpa.review.read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',             p.id,
    'playbookKey',    p.playbook_key,
    'agreementType',  p.agreement_type,
    'nameEn',         p.name_en,
    'nameAr',         p.name_ar,
    'descriptionEn',  p.description_en,
    'version',        p.version,
    'status',         p.status,
    'clauses',        COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id',               c.id,
        'clauseKey',        c.clause_key,
        'clauseTitleEn',    c.clause_title_en,
        'clauseTitleAr',    c.clause_title_ar,
        'criticality',      c.criticality,
        'displayOrder',     c.display_order,
        'standardPosition', c.standard_position,
        'fallbackPosition', c.fallback_position,
        'nonNegotiables',   c.non_negotiables,
        'redFlags',         c.red_flags,
        'guidanceNotes',    c.guidance_notes
      ) ORDER BY c.display_order, c.id)
      FROM tpa_playbook_clause c
      WHERE c.playbook_id = p.id AND c.is_active = TRUE
    ), '[]'::jsonb)
  ) INTO v_result
  FROM tpa_playbook p
  WHERE p.id = p_playbook_id
    AND p.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    AND p.is_active = TRUE;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'tpa_playbook % not found', p_playbook_id USING ERRCODE = 'P0002';
  END IF;
  RETURN v_result;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION fn_tpa_playbook_get(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tpa_playbook_get(BIGINT, BIGINT) TO neondb_owner;


-- ============================================================
-- fn_tpa_review_create — create a new review header
-- ============================================================
CREATE OR REPLACE FUNCTION fn_tpa_review_create(
  p_actor_id           BIGINT,
  p_playbook_id        BIGINT,
  p_counterparty_name  TEXT,
  p_counterparty_email TEXT,
  p_agreement_title    TEXT,
  p_agreement_type     TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_tenant_id  UUID;
  v_id         BIGINT;
  v_ref        TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  IF NOT fn_has_permission(p_actor_id, 'tpa.review.create') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_counterparty_name IS NULL OR length(trim(p_counterparty_name)) = 0 THEN
    RAISE EXCEPTION 'counterparty_name required' USING ERRCODE = '22023';
  END IF;
  IF p_agreement_title IS NULL OR length(trim(p_agreement_title)) = 0 THEN
    RAISE EXCEPTION 'agreement_title required' USING ERRCODE = '22023';
  END IF;

  -- Confirm playbook exists in this tenant.
  IF NOT EXISTS (
    SELECT 1 FROM tpa_playbook
    WHERE id = p_playbook_id AND tenant_id = v_tenant_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'tpa_playbook % not found', p_playbook_id USING ERRCODE = 'P0002';
  END IF;

  -- Build a human-readable reference code: TPA-<yymm>-<seq>
  v_ref := 'TPA-' || to_char(NOW(), 'YYMM') || '-' ||
           lpad((COALESCE((
              SELECT MAX(NULLIF(regexp_replace(reference_code, '^TPA-\d{4}-', ''), '')::int)
              FROM tpa_review
              WHERE tenant_id = v_tenant_id
                AND reference_code LIKE 'TPA-' || to_char(NOW(), 'YYMM') || '-%'
           ), 0) + 1)::text, 4, '0');

  INSERT INTO tpa_review (
    tenant_id, playbook_id, reference_code,
    counterparty_name, counterparty_email,
    agreement_title, agreement_type, status,
    created_by, updated_by
  ) VALUES (
    v_tenant_id, p_playbook_id, v_ref,
    trim(p_counterparty_name), NULLIF(trim(COALESCE(p_counterparty_email, '')), ''),
    trim(p_agreement_title), p_agreement_type, 'pending_analysis',
    p_actor_id, p_actor_id
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id',            v_id,
    'referenceCode', v_ref,
    'status',        'pending_analysis'
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION fn_tpa_review_create(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tpa_review_create(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT) TO neondb_owner;


-- ============================================================
-- fn_tpa_review_attach_document — record an uploaded file
-- ============================================================
CREATE OR REPLACE FUNCTION fn_tpa_review_attach_document(
  p_actor_id        BIGINT,
  p_review_id       BIGINT,
  p_kind            TEXT,
  p_file_name       TEXT,
  p_mime            TEXT,
  p_size_bytes      INTEGER,
  p_storage_uri     TEXT,
  p_page_count      INTEGER,
  p_extraction_eng  TEXT,
  p_sha256_hex      TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_tenant_id UUID;
  v_id        BIGINT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  IF NOT (fn_has_permission(p_actor_id, 'tpa.review.create')
       OR fn_has_permission(p_actor_id, 'tpa.review.amend')) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM tpa_review
    WHERE id = p_review_id AND tenant_id = v_tenant_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'tpa_review % not found', p_review_id USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO tpa_review_document (
    tenant_id, review_id, document_kind, file_name, mime_type,
    size_bytes, storage_uri, page_count, extraction_engine, sha256_hex, created_by
  ) VALUES (
    v_tenant_id, p_review_id, p_kind, p_file_name, p_mime,
    p_size_bytes, p_storage_uri, p_page_count, p_extraction_eng, p_sha256_hex, p_actor_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION fn_tpa_review_attach_document(BIGINT, BIGINT, TEXT, TEXT, TEXT, INTEGER, TEXT, INTEGER, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tpa_review_attach_document(BIGINT, BIGINT, TEXT, TEXT, TEXT, INTEGER, TEXT, INTEGER, TEXT, TEXT) TO neondb_owner;


-- ============================================================
-- fn_tpa_review_record_analysis — persist LLM result
--   p_findings is JSONB[] with shape:
--     [{
--       playbookClauseId, clauseKey, clauseTitle, displayOrder,
--       extractedText, extractedLocation,
--       aiVerdict, aiRationale, aiSeverity, aiSuggestedRedline, aiConflictsWith
--     }, ...]
-- ============================================================
CREATE OR REPLACE FUNCTION fn_tpa_review_record_analysis(
  p_actor_id          BIGINT,
  p_review_id         BIGINT,
  p_findings          JSONB,
  p_overall_verdict   TEXT,
  p_overall_risk      TEXT,
  p_risk_score        INTEGER,
  p_executive_summary TEXT,
  p_model_version     TEXT,
  p_prompt_hash       TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_tenant_id   UUID;
  v_finding     JSONB;
  v_inserted    INTEGER := 0;
  v_accept_n    INTEGER := 0;
  v_amend_n     INTEGER := 0;
  v_reject_n    INTEGER := 0;
  v_conflict_n  INTEGER := 0;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  IF NOT (fn_has_permission(p_actor_id, 'tpa.review.create')
       OR fn_has_permission(p_actor_id, 'tpa.review.amend')) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM tpa_review
    WHERE id = p_review_id AND tenant_id = v_tenant_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'tpa_review % not found', p_review_id USING ERRCODE = 'P0002';
  END IF;

  -- Wipe prior findings (analysis is replace-on-rerun)
  DELETE FROM tpa_review_finding
  WHERE review_id = p_review_id AND tenant_id = v_tenant_id;

  FOR v_finding IN SELECT * FROM jsonb_array_elements(COALESCE(p_findings, '[]'::jsonb))
  LOOP
    INSERT INTO tpa_review_finding (
      tenant_id, review_id, playbook_clause_id, clause_key, clause_title,
      display_order, extracted_text, extracted_location,
      ai_verdict, ai_rationale, ai_severity, ai_suggested_redline, ai_conflicts_with,
      resolution_status, created_by, updated_by
    ) VALUES (
      v_tenant_id, p_review_id,
      NULLIF((v_finding->>'playbookClauseId'), '')::bigint,
      v_finding->>'clauseKey',
      COALESCE(v_finding->>'clauseTitle', 'Untitled clause'),
      COALESCE((v_finding->>'displayOrder')::int, 100),
      v_finding->>'extractedText',
      v_finding->>'extractedLocation',
      COALESCE(v_finding->>'aiVerdict', 'info'),
      v_finding->>'aiRationale',
      NULLIF(v_finding->>'aiSeverity', ''),
      v_finding->>'aiSuggestedRedline',
      COALESCE((SELECT array_agg(value::text) FROM jsonb_array_elements_text(
        COALESCE(v_finding->'aiConflictsWith', '[]'::jsonb))), '{}'),
      CASE WHEN v_finding->>'aiVerdict' = 'accept' THEN 'accepted_ai' ELSE 'open' END,
      p_actor_id, p_actor_id
    );
    v_inserted := v_inserted + 1;

    CASE COALESCE(v_finding->>'aiVerdict', 'info')
      WHEN 'accept' THEN v_accept_n := v_accept_n + 1;
      WHEN 'amend'  THEN v_amend_n  := v_amend_n  + 1;
                        v_conflict_n := v_conflict_n + 1;
      WHEN 'reject' THEN v_reject_n := v_reject_n + 1;
                        v_conflict_n := v_conflict_n + 1;
      ELSE NULL;
    END CASE;
  END LOOP;

  UPDATE tpa_review SET
    status              = 'awaiting_review',
    overall_verdict     = NULLIF(p_overall_verdict, ''),
    overall_risk        = NULLIF(p_overall_risk, ''),
    risk_score          = p_risk_score,
    accept_count        = v_accept_n,
    amend_count         = v_amend_n,
    reject_count        = v_reject_n,
    conflict_count      = v_conflict_n,
    executive_summary   = p_executive_summary,
    llm_model_version   = p_model_version,
    llm_prompt_hash     = p_prompt_hash,
    llm_analysed_at     = NOW(),
    llm_error           = NULL,
    updated_at          = NOW(),
    updated_by          = p_actor_id
  WHERE id = p_review_id AND tenant_id = v_tenant_id;

  RETURN jsonb_build_object(
    'reviewId',     p_review_id,
    'findingsCount', v_inserted,
    'acceptCount',  v_accept_n,
    'amendCount',   v_amend_n,
    'rejectCount',  v_reject_n,
    'overallVerdict', p_overall_verdict,
    'overallRisk',  p_overall_risk
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION fn_tpa_review_record_analysis(BIGINT, BIGINT, JSONB, TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tpa_review_record_analysis(BIGINT, BIGINT, JSONB, TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT) TO neondb_owner;


-- ============================================================
-- fn_tpa_review_record_failure — mark review as failed
-- ============================================================
CREATE OR REPLACE FUNCTION fn_tpa_review_record_failure(
  p_actor_id  BIGINT,
  p_review_id BIGINT,
  p_error     TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_tenant_id UUID;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF NOT (fn_has_permission(p_actor_id, 'tpa.review.create')
       OR fn_has_permission(p_actor_id, 'tpa.review.amend')) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  UPDATE tpa_review SET
    status      = 'failed',
    llm_error   = p_error,
    updated_at  = NOW(),
    updated_by  = p_actor_id
  WHERE id = p_review_id AND tenant_id = v_tenant_id;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION fn_tpa_review_record_failure(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tpa_review_record_failure(BIGINT, BIGINT, TEXT) TO neondb_owner;


-- ============================================================
-- fn_tpa_review_set_status — generic status transition
-- ============================================================
CREATE OR REPLACE FUNCTION fn_tpa_review_set_status(
  p_actor_id  BIGINT,
  p_review_id BIGINT,
  p_status    TEXT,
  p_notes     TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_tenant_id UUID;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  IF NOT fn_has_permission(p_actor_id, 'tpa.review.amend') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_status NOT IN ('awaiting_review','reviewed','redline_sent','closed_accepted','closed_rejected') THEN
    RAISE EXCEPTION 'invalid status %', p_status USING ERRCODE = '22023';
  END IF;

  UPDATE tpa_review SET
    status      = p_status,
    notes       = COALESCE(p_notes, notes),
    updated_at  = NOW(),
    updated_by  = p_actor_id
  WHERE id = p_review_id
    AND tenant_id = v_tenant_id
    AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'tpa_review % not found', p_review_id USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('reviewId', p_review_id, 'status', p_status);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION fn_tpa_review_set_status(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tpa_review_set_status(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;


-- ============================================================
-- fn_tpa_finding_update_verdict — Layla overrides AI / writes redline
-- ============================================================
CREATE OR REPLACE FUNCTION fn_tpa_finding_update_verdict(
  p_actor_id     BIGINT,
  p_finding_id   BIGINT,
  p_user_verdict TEXT,
  p_user_redline TEXT,
  p_user_notes   TEXT,
  p_resolution   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_tenant_id UUID;
  v_review_id BIGINT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  IF NOT fn_has_permission(p_actor_id, 'tpa.review.amend') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_user_verdict IS NOT NULL AND p_user_verdict NOT IN ('accept','amend','reject','missing','info') THEN
    RAISE EXCEPTION 'invalid user_verdict %', p_user_verdict USING ERRCODE = '22023';
  END IF;
  IF p_resolution IS NOT NULL AND p_resolution NOT IN ('open','accepted_ai','amended_by_user','dismissed','escalated') THEN
    RAISE EXCEPTION 'invalid resolution %', p_resolution USING ERRCODE = '22023';
  END IF;

  UPDATE tpa_review_finding SET
    user_verdict      = COALESCE(p_user_verdict, user_verdict),
    user_redline      = COALESCE(p_user_redline, user_redline),
    user_notes        = COALESCE(p_user_notes, user_notes),
    resolution_status = COALESCE(p_resolution, resolution_status),
    updated_at        = NOW(),
    updated_by        = p_actor_id
  WHERE id = p_finding_id
    AND tenant_id = v_tenant_id
    AND is_active = TRUE
  RETURNING review_id INTO v_review_id;

  IF v_review_id IS NULL THEN
    RAISE EXCEPTION 'tpa_review_finding % not found', p_finding_id USING ERRCODE = 'P0002';
  END IF;

  UPDATE tpa_review SET updated_at = NOW(), updated_by = p_actor_id WHERE id = v_review_id;

  RETURN jsonb_build_object('findingId', p_finding_id, 'reviewId', v_review_id);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION fn_tpa_finding_update_verdict(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tpa_finding_update_verdict(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT) TO neondb_owner;


-- ============================================================
-- fn_tpa_review_list — paginated list with optional status filter
-- ============================================================
CREATE OR REPLACE FUNCTION fn_tpa_review_list(
  p_actor_id BIGINT,
  p_status   TEXT,
  p_limit    INTEGER,
  p_offset   INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_data  JSONB;
  v_total INTEGER;
  v_lim   INTEGER := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
  v_off   INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF NOT fn_has_permission(p_actor_id, 'tpa.review.read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM tpa_review r
  WHERE r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    AND r.is_active = TRUE
    AND (p_status IS NULL OR p_status = '' OR r.status = p_status);

  SELECT COALESCE(jsonb_agg(item ORDER BY (item->>'createdAt') DESC), '[]'::jsonb)
  INTO v_data
  FROM (
    SELECT jsonb_build_object(
      'id',                 r.id,
      'referenceCode',      r.reference_code,
      'counterpartyName',   r.counterparty_name,
      'agreementTitle',     r.agreement_title,
      'agreementType',      r.agreement_type,
      'status',             r.status,
      'overallVerdict',     r.overall_verdict,
      'overallRisk',        r.overall_risk,
      'riskScore',          r.risk_score,
      'acceptCount',        r.accept_count,
      'amendCount',         r.amend_count,
      'rejectCount',        r.reject_count,
      'conflictCount',      r.conflict_count,
      'createdAt',          r.created_at,
      'createdByName',      (SELECT concat_ws(' ', u.first_name, u.last_name)
                              FROM "user" u WHERE u.id = r.created_by),
      'llmAnalysedAt',      r.llm_analysed_at,
      'playbookId',         r.playbook_id,
      'playbookNameEn',     (SELECT name_en FROM tpa_playbook
                              WHERE id = r.playbook_id)
    ) AS item
    FROM tpa_review r
    WHERE r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND r.is_active = TRUE
      AND (p_status IS NULL OR p_status = '' OR r.status = p_status)
    ORDER BY r.created_at DESC
    LIMIT v_lim OFFSET v_off
  ) sub;

  RETURN jsonb_build_object(
    'data',     v_data,
    'pagination', jsonb_build_object(
      'total',  v_total, 'limit', v_lim, 'offset', v_off,
      'hasMore', v_off + v_lim < v_total
    )
  );
END;
$fn$;
REVOKE EXECUTE ON FUNCTION fn_tpa_review_list(BIGINT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tpa_review_list(BIGINT, TEXT, INTEGER, INTEGER) TO neondb_owner;


-- ============================================================
-- fn_tpa_review_get_by_id — full detail with findings + documents
-- ============================================================
CREATE OR REPLACE FUNCTION fn_tpa_review_get_by_id(p_actor_id BIGINT, p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_result JSONB;
BEGIN
  IF NOT fn_has_permission(p_actor_id, 'tpa.review.read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',                 r.id,
    'referenceCode',      r.reference_code,
    'counterpartyName',   r.counterparty_name,
    'counterpartyEmail',  r.counterparty_email,
    'agreementTitle',     r.agreement_title,
    'agreementType',      r.agreement_type,
    'status',             r.status,
    'overallVerdict',     r.overall_verdict,
    'overallRisk',        r.overall_risk,
    'riskScore',          r.risk_score,
    'acceptCount',        r.accept_count,
    'amendCount',         r.amend_count,
    'rejectCount',        r.reject_count,
    'conflictCount',      r.conflict_count,
    'executiveSummary',   r.executive_summary,
    'llmModelVersion',    r.llm_model_version,
    'llmAnalysedAt',      r.llm_analysed_at,
    'llmError',           r.llm_error,
    'notes',              r.notes,
    'createdAt',          r.created_at,
    'updatedAt',          r.updated_at,
    'createdBy',          r.created_by,
    'createdByName',      (SELECT concat_ws(' ', u.first_name, u.last_name)
                            FROM "user" u WHERE u.id = r.created_by),
    'playbook', (SELECT jsonb_build_object(
                    'id',            p.id,
                    'playbookKey',   p.playbook_key,
                    'agreementType', p.agreement_type,
                    'nameEn',        p.name_en,
                    'nameAr',        p.name_ar,
                    'version',       p.version
                 ) FROM tpa_playbook p WHERE p.id = r.playbook_id),
    'findings', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id',                  f.id,
        'playbookClauseId',    f.playbook_clause_id,
        'clauseKey',           f.clause_key,
        'clauseTitle',         f.clause_title,
        'displayOrder',        f.display_order,
        'extractedText',       f.extracted_text,
        'extractedLocation',   f.extracted_location,
        'aiVerdict',           f.ai_verdict,
        'aiRationale',         f.ai_rationale,
        'aiSeverity',          f.ai_severity,
        'aiSuggestedRedline',  f.ai_suggested_redline,
        'aiConflictsWith',     f.ai_conflicts_with,
        'userVerdict',         f.user_verdict,
        'userRedline',         f.user_redline,
        'userNotes',           f.user_notes,
        'resolutionStatus',    f.resolution_status,
        'playbookStandard',    (SELECT pc.standard_position
                                  FROM tpa_playbook_clause pc
                                  WHERE pc.id = f.playbook_clause_id),
        'playbookFallback',    (SELECT pc.fallback_position
                                  FROM tpa_playbook_clause pc
                                  WHERE pc.id = f.playbook_clause_id),
        'playbookCriticality', (SELECT pc.criticality
                                  FROM tpa_playbook_clause pc
                                  WHERE pc.id = f.playbook_clause_id)
      ) ORDER BY f.display_order, f.id)
      FROM tpa_review_finding f
      WHERE f.review_id = r.id AND f.is_active = TRUE
    ), '[]'::jsonb),
    'documents', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id',              d.id,
        'documentKind',    d.document_kind,
        'fileName',        d.file_name,
        'mimeType',        d.mime_type,
        'sizeBytes',       d.size_bytes,
        'storageUri',      d.storage_uri,
        'pageCount',       d.page_count,
        'extractionEngine',d.extraction_engine,
        'createdAt',       d.created_at
      ) ORDER BY d.created_at DESC)
      FROM tpa_review_document d
      WHERE d.review_id = r.id AND d.is_active = TRUE
    ), '[]'::jsonb)
  ) INTO v_result
  FROM tpa_review r
  WHERE r.id = p_id
    AND r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    AND r.is_active = TRUE;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'tpa_review % not found', p_id USING ERRCODE = 'P0002';
  END IF;
  RETURN v_result;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION fn_tpa_review_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_tpa_review_get_by_id(BIGINT, BIGINT) TO neondb_owner;


-- ============================================================
-- Bookkeeping
-- ============================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (517, 'tpa_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
