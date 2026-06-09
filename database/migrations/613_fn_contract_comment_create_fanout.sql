-- Migration: 613_fn_contract_comment_create_fanout.sql
-- Module: Comment notifications — fan out to the next actor
-- Date: 2026-06-09
--
-- Drafter feedback: any comment added by any persona who has access to
-- the contract should (a) appear in the Comments tab (already works,
-- the table is the source of truth) and (b) trigger a notification to
-- the persona who needs to act next.
--
-- Rewrites fn_contract_comment_create so that after the insert, it
-- dispatches a comment.mention notification to a deterministic
-- recipient set:
--
--   • If the commenter IS the drafter → notify the current pending
--     approver (lookup via the active approval_chain + approval_step
--     where status='pending'). If no active chain, notify nobody — the
--     drafter is talking to themselves.
--
--   • If the commenter is anyone else → notify the drafter
--     (contract.drafted_by). Covers legal / approver / executive /
--     admin commenting back to the originator.
--
-- The dispatch reuses the existing seeded `comment.mention` rule
-- (id=20, in_app, enabled) + `comment.mention.in_app` template — no
-- new rules or templates needed. Recipient also gets added to
-- mentioned_user_ids so the @-mention feed treats them consistently.
--
-- Wrapped in BEGIN/EXCEPTION (matches the proven 611 pattern) so a
-- dispatch failure can't void the comment.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_contract_comment_create(
  p_actor_id BIGINT,
  p_contract_id BIGINT,
  p_body TEXT,
  p_parent_id BIGINT DEFAULT NULL::BIGINT,
  p_mentioned_user_ids BIGINT[] DEFAULT '{}'::BIGINT[]
)
RETURNS JSONB
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_id              BIGINT;
  -- 613 additions
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
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF p_parent_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM contract_comment
    WHERE id = p_parent_id AND contract_id = p_contract_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'parent_comment_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- 613 — resolve drafter + contract identity once for both branches.
  SELECT drafted_by, contract_number, title_en
    INTO v_drafted_by, v_contract_number, v_contract_title
    FROM contract WHERE id = p_contract_id;

  -- 613 — decide who needs to be told. If the commenter is the drafter
  -- we ping the current pending approver; otherwise we ping the
  -- drafter. v_recipient_id stays NULL when nobody should be paged
  -- (e.g. drafter commenting on a contract with no active chain).
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

  -- 613 — fold the recipient into mentioned_user_ids so the @-mention
  -- feed surfaces it for the recipient too. De-duped via array union.
  v_mentioned := COALESCE(p_mentioned_user_ids, '{}'::BIGINT[]);
  IF v_recipient_id IS NOT NULL
     AND v_recipient_id <> p_actor_id
     AND NOT (v_recipient_id = ANY(v_mentioned)) THEN
    v_mentioned := v_mentioned || v_recipient_id;
  END IF;

  INSERT INTO contract_comment (
    contract_id, parent_id, body, mentioned_user_ids,
    created_by, updated_by
  ) VALUES (
    p_contract_id, p_parent_id, p_body, v_mentioned,
    p_actor_id, p_actor_id
  ) RETURNING id INTO v_id;

  -- 613 — fire the dispatch. Wrapped: comment must succeed even if
  -- the notification path has a hiccup.
  IF v_recipient_id IS NOT NULL AND v_recipient_id <> p_actor_id THEN
    SELECT first_name, last_name INTO v_actor_first, v_actor_last
      FROM "user" WHERE id = p_actor_id;
    v_subject := format(
      'New comment on %s by %s',
      COALESCE(v_contract_number, '#'||p_contract_id::TEXT),
      COALESCE(concat_ws(' ', v_actor_first, v_actor_last), 'someone')
    );
    -- Trim the body excerpt to keep the in-app card compact; full body
    -- always lives in the Comments tab.
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
        'approval_request',   -- notification_kind (valid enum, already opted in via mig 612)
        'medium',             -- priority (valid: low/medium/high/critical)
        v_recipient_id,       -- caller_user_id → resolver returns this
        NULL::TEXT
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'fn_contract_comment_create(613): dispatch failed: %', SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'id', v_id,
      'contractId', p_contract_id,
      'parentId', p_parent_id,
      'body', p_body
    )
  );
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (613, '613_fn_contract_comment_create_fanout', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
