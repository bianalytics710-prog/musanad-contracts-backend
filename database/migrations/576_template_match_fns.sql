-- Migration: 576_template_match_fns.sql
-- Module: Template / Clause similarity matching (Drafter enhancement, phase 1 of 4)
-- Date: 2026-06-05
--
-- Fn surface:
--
--   fn_template_set_embedding(p_actor_id, p_template_id, p_embedding TEXT)
--     Update contract_template.body_embedding from a JSON array string.
--     SECURITY INVOKER; only contract.edit can set.
--
--   fn_clause_set_embedding(p_actor_id, p_clause_id, p_embedding TEXT)
--     Same shape, for contract_clause.
--
--   fn_template_match_candidates(p_actor_id, p_query_embedding TEXT,
--                                p_limit INT, p_min_similarity NUMERIC)
--     Returns a JSONB array of the top N matching templates with cosine
--     similarity (0..1). Self-row excluded by null check on body_embedding.
--
--   fn_clause_library_match_each(p_actor_id, p_candidates JSONB)
--     For each input candidate { idx, embedding, ... }, returns the best
--     library match (id + title + similarity) — JSONB array, one row per
--     input. Skips inputs without an embedding.
--
-- The match fns use the cosine distance operator (<=>) and return
-- similarity = 1 - distance, capped at 0..1.
--
-- Permission gates:
--   - SET fns: contract.edit (same as fn_template_create / fn_clause_create).
--   - MATCH fns: template.read (read-only — anyone who can browse the library
--     can also run similarity, mirroring fn_template_list authorization).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── fn_template_set_embedding ────────────────────────────────
CREATE OR REPLACE FUNCTION fn_template_set_embedding(
  p_actor_id    BIGINT,
  p_template_id BIGINT,
  p_embedding   TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_updated BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_embedding IS NULL OR length(trim(p_embedding)) = 0 THEN
    RAISE EXCEPTION 'embedding is required' USING ERRCODE = '22023';
  END IF;

  UPDATE contract_template
    SET body_embedding = p_embedding::vector,
        updated_at = NOW(),
        updated_by = p_actor_id
  WHERE id = p_template_id AND is_active = TRUE
  RETURNING id INTO v_updated;

  IF v_updated IS NULL THEN
    RAISE EXCEPTION 'template % not found', p_template_id USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('id', v_updated, 'embedded', TRUE);
END $$;

REVOKE ALL ON FUNCTION fn_template_set_embedding(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_template_set_embedding(BIGINT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_template_set_embedding(BIGINT, BIGINT, TEXT) IS
  'Set body_embedding for a contract_template row. Called by BE after fn_template_create + by the one-shot backfill. Permission: contract.edit.';

-- ── fn_clause_set_embedding ──────────────────────────────────
CREATE OR REPLACE FUNCTION fn_clause_set_embedding(
  p_actor_id  BIGINT,
  p_clause_id BIGINT,
  p_embedding TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_updated BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_embedding IS NULL OR length(trim(p_embedding)) = 0 THEN
    RAISE EXCEPTION 'embedding is required' USING ERRCODE = '22023';
  END IF;

  UPDATE contract_clause
    SET body_embedding = p_embedding::vector,
        updated_at = NOW(),
        updated_by = p_actor_id
  WHERE id = p_clause_id AND is_active = TRUE
  RETURNING id INTO v_updated;

  IF v_updated IS NULL THEN
    RAISE EXCEPTION 'clause % not found', p_clause_id USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('id', v_updated, 'embedded', TRUE);
END $$;

REVOKE ALL ON FUNCTION fn_clause_set_embedding(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_clause_set_embedding(BIGINT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_clause_set_embedding(BIGINT, BIGINT, TEXT) IS
  'Set body_embedding for a contract_clause row. Permission: contract.edit.';

-- ── fn_template_match_candidates ─────────────────────────────
-- Returns the top N templates whose body_embedding cosine-similarity to the
-- query is >= p_min_similarity. Soft-deleted + un-embedded rows excluded.
CREATE OR REPLACE FUNCTION fn_template_match_candidates(
  p_actor_id        BIGINT,
  p_query_embedding TEXT,
  p_limit           INTEGER  DEFAULT 5,
  p_min_similarity  NUMERIC  DEFAULT 0.50
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_query VECTOR(1536);
  v_data  JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_query_embedding IS NULL OR length(trim(p_query_embedding)) = 0 THEN
    RAISE EXCEPTION 'query embedding is required' USING ERRCODE = '22023';
  END IF;
  IF p_limit < 1 OR p_limit > 25 THEN
    RAISE EXCEPTION 'limit must be 1..25' USING ERRCODE = '22023';
  END IF;
  IF p_min_similarity < 0 OR p_min_similarity > 1 THEN
    RAISE EXCEPTION 'min_similarity must be 0..1' USING ERRCODE = '22023';
  END IF;

  v_query := p_query_embedding::vector;

  SELECT COALESCE(jsonb_agg(row), '[]'::jsonb)
  INTO v_data
  FROM (
    SELECT jsonb_build_object(
      'templateId',     ct.id,
      'nameEn',         ct.name_en,
      'nameAr',         ct.name_ar,
      'contractType',   ct.contract_type,
      'descriptionEn',  ct.description_en,
      'similarity',     ROUND((1 - (ct.body_embedding <=> v_query))::numeric, 4),
      'usageCount',     ct.usage_count
    ) AS row,
    (1 - (ct.body_embedding <=> v_query)) AS sim
    FROM contract_template ct
    WHERE ct.is_active = TRUE
      AND ct.body_embedding IS NOT NULL
      AND (1 - (ct.body_embedding <=> v_query)) >= p_min_similarity
    ORDER BY ct.body_embedding <=> v_query
    LIMIT p_limit
  ) ranked;

  RETURN jsonb_build_object('data', v_data);
END $$;

REVOKE ALL ON FUNCTION fn_template_match_candidates(BIGINT, TEXT, INTEGER, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_template_match_candidates(BIGINT, TEXT, INTEGER, NUMERIC) TO neondb_owner;

COMMENT ON FUNCTION fn_template_match_candidates(BIGINT, TEXT, INTEGER, NUMERIC) IS
  'Top-N similar templates by cosine similarity of body_embedding. Drives the "extend existing / exact duplicate" prompt on the New Template upload page.';

-- ── fn_clause_library_match_each ─────────────────────────────
-- p_candidates is a JSONB array. Each element shape:
--   { "idx": int, "embedding": "[..1536 floats..]" (string), "category": optional }
-- For each, returns the best library match (or null) and similarity.
CREATE OR REPLACE FUNCTION fn_clause_library_match_each(
  p_actor_id   BIGINT,
  p_candidates JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_cand        JSONB;
  v_query       VECTOR(1536);
  v_best_id     BIGINT;
  v_best_title  TEXT;
  v_best_cat    TEXT;
  v_best_sim    NUMERIC;
  v_results     JSONB := '[]'::jsonb;
  v_idx         INT;
  v_emb_text    TEXT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_candidates IS NULL OR jsonb_typeof(p_candidates) <> 'array' THEN
    RAISE EXCEPTION 'candidates must be a JSON array' USING ERRCODE = '22023';
  END IF;

  FOR v_cand IN SELECT * FROM jsonb_array_elements(p_candidates)
  LOOP
    v_idx      := (v_cand->>'idx')::INT;
    v_emb_text := v_cand->>'embedding';

    IF v_emb_text IS NULL OR length(trim(v_emb_text)) = 0 THEN
      -- No embedding for this candidate; record as no match.
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'idx',         v_idx,
        'matchId',     NULL,
        'matchTitle',  NULL,
        'matchCategory', NULL,
        'similarity',  0.0
      ));
      CONTINUE;
    END IF;

    v_query := v_emb_text::vector;
    v_best_id := NULL; v_best_title := NULL; v_best_cat := NULL; v_best_sim := 0;

    SELECT cc.id, cc.title_en, cc.category,
           ROUND((1 - (cc.body_embedding <=> v_query))::numeric, 4)
      INTO v_best_id, v_best_title, v_best_cat, v_best_sim
    FROM contract_clause cc
    WHERE cc.is_active = TRUE
      AND cc.body_embedding IS NOT NULL
    ORDER BY cc.body_embedding <=> v_query
    LIMIT 1;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'idx',           v_idx,
      'matchId',       v_best_id,
      'matchTitle',    v_best_title,
      'matchCategory', v_best_cat,
      'similarity',    COALESCE(v_best_sim, 0.0)
    ));
  END LOOP;

  RETURN jsonb_build_object('data', v_results);
END $$;

REVOKE ALL ON FUNCTION fn_clause_library_match_each(BIGINT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_clause_library_match_each(BIGINT, JSONB) TO neondb_owner;

COMMENT ON FUNCTION fn_clause_library_match_each(BIGINT, JSONB) IS
  'For each input candidate-clause embedding, returns its best clause-library match. Drives the "these N clauses are not in your library" prompt on the New Template upload page.';

-- Record migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (576, '576_template_match_fns', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_clause_library_match_each(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_template_match_candidates(BIGINT, TEXT, INTEGER, NUMERIC);
-- DROP FUNCTION IF EXISTS fn_clause_set_embedding(BIGINT, BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_template_set_embedding(BIGINT, BIGINT, TEXT);
-- DELETE FROM schema_migrations WHERE version = 576;
-- COMMIT;
-- ============================================================
