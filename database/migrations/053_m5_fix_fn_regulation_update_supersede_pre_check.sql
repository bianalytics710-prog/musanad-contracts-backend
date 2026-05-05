-- ============================================================================
-- 053_m5_fix_fn_regulation_update_supersede_pre_check.sql
-- ============================================================================
-- Module:    M5 (Regulatory Radar) — DEFECT-1 patch
-- Owner:     Agent 6 — DB Implementation (patch follow-up)
-- Depends:   050 (fn_regulation_update canonical body).
-- ----------------------------------------------------------------------------
-- M5-PROD-DEFECT-1: fn_regulation_update returns 422 instead of AC-S4-04
-- mandated 400 when p_patch.supersededById points to a non-existent (or
-- inactive) regulation. Root cause: fn body lacked a structured-raise
-- pre-validation block on the supersededById FK. The raw Postgres FK
-- violation (SQLSTATE 23503, constraint name fk_regulation_superseded_by_id)
-- surfaced through translatePgError's default 23503 path, which falls back
-- to UnprocessableEntityError(422) when no structured 'field:message' body
-- is present. AC-S4-04 expects 400 VALIDATION_ERROR with field-keyed inline
-- error envelope.
--
-- Fix: mirror the structured-raise FK pre-check pattern used by
-- fn_regulatory_impact_create_bulk (migration 050 lines 499-505 — Validate
-- regulation block). Add a PERFORM 1 + IF NOT FOUND + RAISE block inside
-- the existing 'supersededById' branch, after the self-supersede guard,
-- before the UPDATE. ERRCODE 23503 + 'supersededById:Referenced regulation
-- not found' body matches the STRUCTURED_RAISE_RE pattern translatePgError
-- evaluates first for case '23503', returning ValidationError(400) with
-- { supersededById: <msg> } envelope.
--
-- Diff vs canonical 050 body:
--   - Argument list:                PRESERVED byte-for-byte
--   - Security mode (INVOKER):      PRESERVED
--   - search_path:                  PRESERVED
--   - DECLARE block:                PRESERVED
--   - Permission gate:              PRESERVED
--   - referenceCode immutable:      PRESERVED
--   - SELECT FOR UPDATE row lock:   PRESERVED
--   - Self-supersede guard:         PRESERVED
--   - UPDATE + auto-flip status:    PRESERVED
--   - RETURN fn_regulation_get_by_id: PRESERVED
--   + ADDED: PERFORM/IF NOT FOUND/RAISE pre-check on v_new_superseded_by
--           when non-NULL — emits 23503 + 'supersededById:Referenced
--           regulation not found' BEFORE the UPDATE so the constraint-name
--           branch in translatePgError never executes.
--
-- S2-23 codification (this defect's pattern lesson):
--   For every fn_ that accepts a foreign-key id parameter, verify a
--   structured-raise pre-check exists before the UPDATE/INSERT. Raw 23503
--   surfaces map ambiguously through fk_constraint-name disambiguation;
--   structured-raise lets translatePgError emit field-keyed 400.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- PATCH: fn_regulation_update — add supersededById FK pre-validation block
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
    -- M5-PROD-DEFECT-1 patch (S2-23): structured-raise FK pre-check.
    -- Mirrors fn_regulatory_impact_create_bulk (050 lines 499-505) so
    -- translatePgError's case '23503' STRUCTURED_RAISE_RE branch fires,
    -- returning ValidationError(400) with { supersededById: <msg> }.
    -- Without this block the raw FK violation (constraint
    -- fk_regulation_superseded_by_id) falls through translatePgError's
    -- 23503 fallback to UnprocessableEntityError(422), failing AC-S4-04.
    IF v_new_superseded_by IS NOT NULL THEN
      PERFORM 1 FROM regulation
        WHERE id = v_new_superseded_by AND is_active = TRUE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_regulation_update: %',
          'supersededById:Referenced regulation not found'
          USING ERRCODE = '23503';
      END IF;
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


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (53, 'm5_fix_fn_regulation_update_supersede_pre_check', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- Restores the canonical pre-defect body (the 050-original, without the
-- new pre-check block). Use this only if the patch must be reverted.
BEGIN;

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

DELETE FROM schema_migrations WHERE version = 53;
COMMIT;
-- ============================================================================
-- ROLLBACK END
-- ============================================================================
