-- ============================================================================
-- 065_contract_comments.sql
-- ============================================================================
-- Module:    M_parity (R4 — Comments tab feature for contract detail)
-- Owner:     Direct work — no orchestrator pipeline
-- Depends:   003 (contract), 014 (user role/permission scaffolding)
-- ----------------------------------------------------------------------------
-- R4 audit gap 8.2.1: contract detail "Comments" tab missing entirely.
-- Lovable hosts a full thread UI with filter pills (All / Unresolved / Mine
-- / Mentions me) + composer with @-mention + Reply/Resolve actions.
--
-- Schema:
--   contract_comment — top-level comments + threaded replies via parent_id
--   comment.body is plain text (sanitized FE-side); @mentions extracted
--   into mentioned_user_ids[] for indexing and the "Mentions me" filter.
--
-- Permissions: comment.read / comment.write / comment.resolve / comment.delete
-- granted to all 7 roles (everyone who can read a contract can comment).
-- ----------------------------------------------------------------------------

BEGIN;

CREATE TABLE IF NOT EXISTS contract_comment (
  id                  BIGSERIAL PRIMARY KEY,
  contract_id         BIGINT NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
  parent_id           BIGINT REFERENCES contract_comment(id) ON DELETE CASCADE,
  body                TEXT NOT NULL CHECK (length(body) > 0 AND length(body) <= 4000),
  mentioned_user_ids  BIGINT[] NOT NULL DEFAULT '{}',
  resolved_at         TIMESTAMPTZ,
  resolved_by         BIGINT REFERENCES "user"(id),
  -- audit columns (v2.6 standard)
  created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by          BIGINT NOT NULL REFERENCES "user"(id),
  updated_by          BIGINT REFERENCES "user"(id),
  is_active           BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS idx_contract_comment_contract ON contract_comment(contract_id) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_contract_comment_parent ON contract_comment(parent_id) WHERE parent_id IS NOT NULL AND is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_contract_comment_mentions ON contract_comment USING GIN (mentioned_user_ids);

-- ============================================================================
-- fn_contract_comment_list — paginated thread for a contract.
-- ============================================================================
-- Returns top-level comments (parent_id IS NULL) with replies nested as a
-- jsonb array. Filters: all / unresolved / mine / mentions_me.
CREATE OR REPLACE FUNCTION fn_contract_comment_list(
  p_actor_id    BIGINT,
  p_contract_id BIGINT,
  p_filter      TEXT DEFAULT 'all'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_data JSONB;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_comment_list: %', 'actorId:Actor id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_contract_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_comment_list: %', 'contractId:Contract id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_filter NOT IN ('all','unresolved','mine','mentions_me') THEN
    RAISE EXCEPTION 'fn_contract_comment_list: %', 'filter:Invalid filter'
      USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY created_at), '[]'::jsonb)
    INTO v_data
    FROM (
      SELECT
        jsonb_build_object(
          'id',                c.id,
          'contractId',        c.contract_id,
          'body',              c.body,
          'mentionedUserIds',  c.mentioned_user_ids,
          'resolvedAt',        c.resolved_at,
          'resolvedBy',        c.resolved_by,
          'createdAt',         c.created_at,
          'updatedAt',         c.updated_at,
          'createdBy',         fn_user_get_by_id(c.created_by),
          'replies',           (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'id',               r.id,
              'parentId',         r.parent_id,
              'body',             r.body,
              'mentionedUserIds', r.mentioned_user_ids,
              'createdAt',        r.created_at,
              'createdBy',        fn_user_get_by_id(r.created_by)
            ) ORDER BY r.created_at), '[]'::jsonb)
            FROM contract_comment r
            WHERE r.parent_id = c.id
              AND r.is_active = TRUE
          )
        ) AS row_data,
        c.created_at AS created_at
      FROM contract_comment c
      WHERE c.contract_id = p_contract_id
        AND c.parent_id IS NULL
        AND c.is_active = TRUE
        AND CASE p_filter
              WHEN 'unresolved'   THEN c.resolved_at IS NULL
              WHEN 'mine'         THEN c.created_by = p_actor_id
              WHEN 'mentions_me'  THEN p_actor_id = ANY(c.mentioned_user_ids)
              ELSE TRUE
            END
    ) sub;

  RETURN jsonb_build_object('data', v_data);
END;
$$;

-- ============================================================================
-- fn_contract_comment_create — append a comment (top-level or threaded reply).
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_contract_comment_create(
  p_actor_id            BIGINT,
  p_contract_id         BIGINT,
  p_body                TEXT,
  p_parent_id           BIGINT DEFAULT NULL,
  p_mentioned_user_ids  BIGINT[] DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_comment_create: %', 'actorId:Actor id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_contract_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_comment_create: %', 'contractId:Contract id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_body IS NULL OR length(trim(p_body)) = 0 THEN
    RAISE EXCEPTION 'fn_contract_comment_create: %', 'body:Body is required'
      USING ERRCODE = '22023';
  END IF;
  IF length(p_body) > 4000 THEN
    RAISE EXCEPTION 'fn_contract_comment_create: %', 'body:Max 4000 chars'
      USING ERRCODE = '22023';
  END IF;
  -- FK pre-check (S2-23 pattern)
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF p_parent_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM contract_comment
    WHERE id = p_parent_id AND contract_id = p_contract_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'parent_comment_not_found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO contract_comment (
    contract_id, parent_id, body, mentioned_user_ids,
    created_by, updated_by
  ) VALUES (
    p_contract_id, p_parent_id, p_body, COALESCE(p_mentioned_user_ids, '{}'),
    p_actor_id, p_actor_id
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'id', v_id,
      'contractId', p_contract_id,
      'parentId', p_parent_id,
      'body', p_body
    )
  );
END;
$$;

-- ============================================================================
-- fn_contract_comment_resolve — mark a top-level comment thread as resolved.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_contract_comment_resolve(
  p_actor_id  BIGINT,
  p_comment_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_already_resolved BOOLEAN;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_comment_resolve: %', 'actorId:Actor id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_comment_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_comment_resolve: %', 'commentId:Comment id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT resolved_at IS NOT NULL INTO v_already_resolved
    FROM contract_comment
    WHERE id = p_comment_id AND parent_id IS NULL AND is_active = TRUE;

  IF v_already_resolved IS NULL THEN
    RAISE EXCEPTION 'comment_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_already_resolved THEN
    -- idempotent — return the existing state
    RETURN jsonb_build_object('data', jsonb_build_object('id', p_comment_id, 'resolved', TRUE));
  END IF;

  UPDATE contract_comment
     SET resolved_at = CURRENT_TIMESTAMP,
         resolved_by = p_actor_id,
         updated_at  = CURRENT_TIMESTAMP,
         updated_by  = p_actor_id
   WHERE id = p_comment_id;

  RETURN jsonb_build_object('data', jsonb_build_object('id', p_comment_id, 'resolved', TRUE));
END;
$$;

-- ============================================================================
-- fn_contract_comment_delete — soft-delete a comment (creator or admin).
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_contract_comment_delete(
  p_actor_id  BIGINT,
  p_comment_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_creator BIGINT;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_comment_delete: %', 'actorId:Actor id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_comment_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_comment_delete: %', 'commentId:Comment id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT created_by INTO v_creator
    FROM contract_comment
    WHERE id = p_comment_id AND is_active = TRUE;
  IF v_creator IS NULL THEN
    RAISE EXCEPTION 'comment_not_found' USING ERRCODE = 'P0002';
  END IF;
  -- Only the creator can delete (admin override would go here when wired).
  IF v_creator <> p_actor_id THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE contract_comment
     SET is_active  = FALSE,
         updated_at = CURRENT_TIMESTAMP,
         updated_by = p_actor_id
   WHERE id = p_comment_id;

  RETURN jsonb_build_object('data', jsonb_build_object('id', p_comment_id, 'deleted', TRUE));
END;
$$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (65, 'M_parity R4: contract_comment table + 4 fn_''s for thread + filter + resolve + delete', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
