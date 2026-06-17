-- ============================================================================
-- Migration 687 — Anchored redline comments for the LC / Approver review loop
-- ============================================================================
-- WHY: Legal Counsel and Contract Approver need to pin comments to specific
-- parts of a contract (a clause + the exact quoted passage) while it sits in
-- their approval queue, then push the contract back to the drafter via the
-- existing `request_resubmission` decision. The drafter addresses each pinned
-- comment (Mark done) or replies, and resubmits for re-approval.
--
-- The `contract_comment` table already supports threading (parent_id) and a
-- resolved state (resolved_at / resolved_by); the Reply + Resolve UI was just
-- stripped out earlier (v611.4). This migration adds the ONE genuinely missing
-- capability — ANCHORING — plus re-activates the resolve/reopen surface:
--
--   • 6 new columns on contract_comment: comment_kind ('general' | 'redline')
--     + anchor_clause_id / _heading / _quote / _side / _version_number.
--   • fn_contract_comment_create — extended to accept the anchor (existing
--     positional callers keep working: the new params are all defaulted).
--     Preserves the mig 613 notification fan-out verbatim.
--   • fn_contract_comment_list — now returns the anchor fields, comment_kind,
--     resolver name, and a 'redlines' filter. Replies unchanged.
--   • fn_contract_comment_reopen — NEW. Clears resolved_at/_by so a reviewer
--     can re-open a thread the drafter marked done but didn't satisfy.
--
-- Anchoring is QUOTE-based (store the selected text + clause id), NOT a
-- character-offset range — robust to body edits and fits the existing
-- markdown clause renderer (ContractDocumentTab parses `## ` sections into
-- id'd <section> blocks; anchor_clause_id stores that slug).
--
-- S2-21: fn_contract_comment_create's signature changes (5 → 11 params), so
-- the old grant target (mig 083) disappears. We DROP the 5-arg function and
-- re-issue REVOKE PUBLIC / GRANT neondb_owner on the new signature + reopen.
-- ============================================================================

BEGIN;

-- 1. Anchor columns ----------------------------------------------------------
ALTER TABLE contract_comment
  ADD COLUMN IF NOT EXISTS comment_kind           TEXT NOT NULL DEFAULT 'general'
                             CHECK (comment_kind IN ('general', 'redline')),
  ADD COLUMN IF NOT EXISTS anchor_clause_id       TEXT,
  ADD COLUMN IF NOT EXISTS anchor_clause_heading  TEXT,
  ADD COLUMN IF NOT EXISTS anchor_quote           TEXT,
  ADD COLUMN IF NOT EXISTS anchor_side            TEXT
                             CHECK (anchor_side IS NULL OR anchor_side IN ('en', 'ar')),
  ADD COLUMN IF NOT EXISTS anchor_version_number  INTEGER;

COMMENT ON COLUMN contract_comment.comment_kind IS
  'general = free chat (legacy); redline = pinned to a document region (anchor_* populated).';
COMMENT ON COLUMN contract_comment.anchor_clause_id IS
  'Slug id of the `## ` clause section the comment is pinned to (matches ContractDocumentTab parseClauses ids).';
COMMENT ON COLUMN contract_comment.anchor_quote IS
  'Exact text the reviewer selected. Used to re-locate + highlight the passage even after the body is edited.';
COMMENT ON COLUMN contract_comment.anchor_side IS
  'Which body column the selection came from: en or ar.';
COMMENT ON COLUMN contract_comment.anchor_version_number IS
  'contract.current_version at the time the comment was anchored (the drafter sees "made on v3").';

-- Partial index for the redline filter / open-redline counts.
CREATE INDEX IF NOT EXISTS idx_contract_comment_redline
  ON contract_comment (contract_id)
  WHERE comment_kind = 'redline' AND is_active = TRUE;

-- 2. fn_contract_comment_create — anchor-aware, fan-out preserved -------------
-- Signature changes (adds 6 defaulted params after the original 5), so the old
-- 5-arg function must be dropped to avoid an overload-ambiguity error on the
-- existing 5-positional-arg call sites.
DROP FUNCTION IF EXISTS fn_contract_comment_create(BIGINT, BIGINT, TEXT, BIGINT, BIGINT[]);

CREATE OR REPLACE FUNCTION public.fn_contract_comment_create(
  p_actor_id              BIGINT,
  p_contract_id           BIGINT,
  p_body                  TEXT,
  p_parent_id             BIGINT   DEFAULT NULL::BIGINT,
  p_mentioned_user_ids    BIGINT[] DEFAULT '{}'::BIGINT[],
  p_comment_kind          TEXT     DEFAULT 'general',
  p_anchor_clause_id      TEXT     DEFAULT NULL,
  p_anchor_clause_heading TEXT     DEFAULT NULL,
  p_anchor_quote          TEXT     DEFAULT NULL,
  p_anchor_side           TEXT     DEFAULT NULL,
  p_anchor_version_number INTEGER  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_id              BIGINT;
  v_kind            TEXT;
  -- 613 fan-out locals
  v_drafted_by      BIGINT;
  v_contract_number TEXT;
  v_contract_title  TEXT;
  v_recipient_id    BIGINT;
  v_actor_first     TEXT;
  v_actor_last      TEXT;
  v_subject         TEXT;
  v_body_rendered   TEXT;
  v_mentioned       BIGINT[];
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

  v_kind := COALESCE(p_comment_kind, 'general');
  IF v_kind NOT IN ('general', 'redline') THEN
    RAISE EXCEPTION 'fn_contract_comment_create: %', 'commentKind:Invalid comment kind'
      USING ERRCODE = '22023';
  END IF;
  -- A redline comment must be anchored to something the drafter can locate.
  IF v_kind = 'redline'
     AND p_parent_id IS NULL
     AND p_anchor_clause_id IS NULL
     AND (p_anchor_quote IS NULL OR length(trim(p_anchor_quote)) = 0) THEN
    RAISE EXCEPTION 'fn_contract_comment_create: %', 'anchor:A redline comment must reference a clause or quoted text'
      USING ERRCODE = '22023';
  END IF;
  IF p_anchor_side IS NOT NULL AND p_anchor_side NOT IN ('en', 'ar') THEN
    RAISE EXCEPTION 'fn_contract_comment_create: %', 'anchorSide:Invalid anchor side'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF p_parent_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM contract_comment
    WHERE id = p_parent_id AND contract_id = p_contract_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'parent_comment_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- 613 — resolve drafter + contract identity once for both fan-out branches.
  SELECT drafted_by, contract_number, title_en
    INTO v_drafted_by, v_contract_number, v_contract_title
    FROM contract WHERE id = p_contract_id;

  -- 613 — decide who needs to be told. Commenter = drafter → ping the current
  -- pending approver; otherwise ping the drafter. NULL = page nobody.
  IF p_actor_id = v_drafted_by THEN
    SELECT s.approver_user_id INTO v_recipient_id
      FROM approval_chain ch
      JOIN approval_step  s ON s.approval_chain_id = ch.id
     WHERE ch.contract_id = p_contract_id
       AND ch.status = 'in_progress'
       AND ch.is_active = TRUE
       AND s.status = 'pending'
       AND s.is_active = TRUE
     ORDER BY s.step_order ASC, s.id ASC
     LIMIT 1;
  ELSE
    v_recipient_id := v_drafted_by;
  END IF;

  -- 613 — fold the recipient into mentioned_user_ids (de-duped union).
  v_mentioned := COALESCE(p_mentioned_user_ids, '{}'::BIGINT[]);
  IF v_recipient_id IS NOT NULL
     AND v_recipient_id <> p_actor_id
     AND NOT (v_recipient_id = ANY(v_mentioned)) THEN
    v_mentioned := v_mentioned || v_recipient_id;
  END IF;

  INSERT INTO contract_comment (
    contract_id, parent_id, body, mentioned_user_ids,
    comment_kind, anchor_clause_id, anchor_clause_heading,
    anchor_quote, anchor_side, anchor_version_number,
    created_by, updated_by
  ) VALUES (
    p_contract_id, p_parent_id, p_body, v_mentioned,
    v_kind, p_anchor_clause_id, p_anchor_clause_heading,
    p_anchor_quote, p_anchor_side, p_anchor_version_number,
    p_actor_id, p_actor_id
  ) RETURNING id INTO v_id;

  -- 613 — fire the dispatch. Wrapped: the comment must persist even if the
  -- notification path hiccups.
  IF v_recipient_id IS NOT NULL AND v_recipient_id <> p_actor_id THEN
    SELECT first_name, last_name INTO v_actor_first, v_actor_last
      FROM "user" WHERE id = p_actor_id;
    v_subject := format(
      'New comment on %s by %s',
      COALESCE(v_contract_number, '#'||p_contract_id::TEXT),
      COALESCE(concat_ws(' ', v_actor_first, v_actor_last), 'someone')
    );
    v_body_rendered := format(
      '%s commented: %s',
      COALESCE(concat_ws(' ', v_actor_first, v_actor_last), 'Someone'),
      CASE WHEN length(p_body) <= 240 THEN p_body
           ELSE substr(p_body, 1, 240) || '…' END
    );
    BEGIN
      PERFORM fn_notification_dispatch(
        p_actor_id,
        'comment.mention',
        jsonb_build_object(
          'subject',        v_subject,
          'bodyRendered',   v_body_rendered,
          'contractId',     p_contract_id,
          'contractNumber', v_contract_number,
          'contractTitle',  v_contract_title,
          'commentId',      v_id,
          'actorUserId',    p_actor_id,
          'actorName',      concat_ws(' ', v_actor_first, v_actor_last),
          'source',         'contract.comment.create'
        ),
        'approval_request',
        'medium',
        v_recipient_id,
        NULL::TEXT
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_contract_comment_create(687): dispatch failed: %', SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'id', v_id,
      'contractId', p_contract_id,
      'parentId', p_parent_id,
      'commentKind', v_kind,
      'body', p_body
    )
  );
END;
$function$;

-- 3. fn_contract_comment_list — return anchor + kind + resolver, add filter ---
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
  IF p_filter NOT IN ('all','unresolved','mine','mentions_me','redlines') THEN
    RAISE EXCEPTION 'fn_contract_comment_list: %', 'filter:Invalid filter'
      USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY created_at), '[]'::jsonb)
    INTO v_data
    FROM (
      SELECT
        jsonb_build_object(
          'id',                  c.id,
          'contractId',          c.contract_id,
          'body',                c.body,
          'commentKind',         c.comment_kind,
          'anchorClauseId',      c.anchor_clause_id,
          'anchorClauseHeading', c.anchor_clause_heading,
          'anchorQuote',         c.anchor_quote,
          'anchorSide',          c.anchor_side,
          'anchorVersionNumber', c.anchor_version_number,
          'mentionedUserIds',    c.mentioned_user_ids,
          'resolvedAt',          c.resolved_at,
          'resolvedBy',          c.resolved_by,
          'resolvedByUser',      CASE WHEN c.resolved_by IS NOT NULL
                                      THEN fn_user_get_by_id(c.resolved_by) END,
          'createdAt',           c.created_at,
          'updatedAt',           c.updated_at,
          'createdBy',           fn_user_get_by_id(c.created_by),
          'replies',             (
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
              WHEN 'redlines'     THEN c.comment_kind = 'redline'
              ELSE TRUE
            END
    ) sub;

  RETURN jsonb_build_object('data', v_data);
END;
$$;

-- 4. fn_contract_comment_reopen — clear the resolved state (NEW) --------------
-- Mirror of fn_contract_comment_resolve. Lets a reviewer re-open a thread the
-- drafter marked done but didn't actually address. Idempotent.
CREATE OR REPLACE FUNCTION fn_contract_comment_reopen(
  p_actor_id   BIGINT,
  p_comment_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_is_resolved BOOLEAN;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_comment_reopen: %', 'actorId:Actor id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_comment_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_comment_reopen: %', 'commentId:Comment id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT resolved_at IS NOT NULL INTO v_is_resolved
    FROM contract_comment
    WHERE id = p_comment_id AND parent_id IS NULL AND is_active = TRUE;

  IF v_is_resolved IS NULL THEN
    RAISE EXCEPTION 'comment_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT v_is_resolved THEN
    -- idempotent — already open
    RETURN jsonb_build_object('data', jsonb_build_object('id', p_comment_id, 'resolved', FALSE));
  END IF;

  UPDATE contract_comment
     SET resolved_at = NULL,
         resolved_by = NULL,
         updated_at  = CURRENT_TIMESTAMP,
         updated_by  = p_actor_id
   WHERE id = p_comment_id;

  RETURN jsonb_build_object('data', jsonb_build_object('id', p_comment_id, 'resolved', FALSE));
END;
$$;

-- 5. S2-21 — REVOKE PUBLIC / GRANT neondb_owner on touched + new signatures ---
REVOKE ALL ON FUNCTION fn_contract_comment_create(
  BIGINT, BIGINT, TEXT, BIGINT, BIGINT[], TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_comment_create(
  BIGINT, BIGINT, TEXT, BIGINT, BIGINT[], TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER) TO neondb_owner;

REVOKE ALL ON FUNCTION fn_contract_comment_list(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_comment_list(BIGINT, BIGINT, TEXT) TO neondb_owner;

REVOKE ALL ON FUNCTION fn_contract_comment_reopen(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_comment_reopen(BIGINT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (687, 'contract_comment redline anchors + reopen', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
