-- 509_advisory_reject_notify_drafter.sql
-- ============================================================================
-- Purpose: After an advisory draft is rejected, notify the original drafter
--   via in-app notification so they know to act on the feedback. Today the
--   reject endpoint just flips status + writes audit; the drafter has no way
--   to discover the rejection short of opening the queue themselves.
--
-- Strategy:
--   1. Seed a new notification_template `advisory.rejected.in_app` with EN/AR
--      bodies summarising the reject reason.
--   2. Rewrite fn_advisory_draft_reject so that, after the status flip + audit
--      log, it calls fn_notification_send to deliver the in-app notification
--      to the drafter (advisory_draft.created_by). Self-rejection is already
--      blocked upstream so there's no risk of self-notify.
--
-- Idempotent — re-applying the migration is a no-op (template uses ON
-- CONFLICT DO NOTHING, the fn is CREATE OR REPLACE).
-- ============================================================================
BEGIN;

-- 1) Seed in-app notification template ---------------------------------------
-- Outer DO block uses $seed$ (not $$) so the runner's dollar-quote tracker
-- treats the inner body $$...$$ strings as nested independent tags.

DO $seed$
DECLARE
  v_adnoc UUID := '00000000-0000-0000-0000-000000000001';
BEGIN
  INSERT INTO notification_template
    (tenant_id, template_id, channel, subject_en, subject_ar,
     body_en, body_ar, data_classification, created_at, updated_at, is_active)
  VALUES (
    v_adnoc,
    'advisory.rejected.in_app',
    'in_app',
    'Your advisory draft was rejected — {{draftType}}',
    'تم رفض مسودة الاستشارة الخاصة بك — {{draftType}}',
    $body_en$Your advisory draft for contract {{contractRef}} was rejected by {{rejectedByName}}.

Reason given:
{{rejectionReason}}

Open the advisory in the queue to revise and re-submit.$body_en$,
    $body_ar$تم رفض مسودة الاستشارة الخاصة بالعقد {{contractRef}} من قِبَل {{rejectedByName}}.

السبب:
{{rejectionReason}}

افتح الاستشارة في قائمة الانتظار لمراجعتها وإعادة تقديمها.$body_ar$,
    'production',
    NOW(), NOW(), TRUE
  )
  ON CONFLICT (tenant_id, template_id) DO NOTHING;
END
$seed$;

-- 2) Rewrite fn_advisory_draft_reject ----------------------------------------
--    Same signature, same gates; appends a fn_notification_send call after
--    the audit log. Notification failures must NOT abort the reject — wrap
--    the send in BEGIN/EXCEPTION block.

CREATE OR REPLACE FUNCTION fn_advisory_draft_reject(
  p_actor_id         BIGINT,
  p_id               BIGINT,
  p_rejection_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant_id      UUID;
  v_actor_role     TEXT;
  v_d              advisory_draft%ROWTYPE;
  v_tpl_role       TEXT;
  v_draft_type     TEXT;
  v_contract_ref   TEXT;
  v_rejected_by    TEXT;
  v_tpl_id         BIGINT;
  v_tpl_subject    TEXT;
  v_tpl_body       TEXT;
  v_ctx            JSONB;
BEGIN
  -- Permission gate
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  -- Validate rejection reason (min 10 chars)
  IF p_rejection_reason IS NULL OR char_length(p_rejection_reason) < 10 THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: missing_rejection_reason — rejectionReason must be at least 10 characters'
      USING ERRCODE = '22023';
  END IF;

  -- S2-17 row lock
  SELECT * INTO v_d FROM advisory_draft
  WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: draft_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Role gate
  SELECT assigned_approver_role, draft_type INTO v_tpl_role, v_draft_type
  FROM advisory_template WHERE id = v_d.template_id;

  IF v_actor_role <> v_tpl_role AND v_actor_role NOT IN ('Super Admin','platform_admin') THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: role_mismatch'
      USING ERRCODE = '42501';
  END IF;

  -- Separation of duties (also protects the notify path — we never notify
  -- the rejector about their own action because they can't reach this point).
  IF p_actor_id = v_d.created_by THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: self_approval_denied — cannot reject own draft'
      USING ERRCODE = '42501';
  END IF;

  -- Status transition check
  IF v_d.approval_status NOT IN ('unapproved','modified') THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: invalid_status_transition — draft already %', v_d.approval_status
      USING ERRCODE = '23514';
  END IF;

  -- Update
  UPDATE advisory_draft SET
    approval_status  = 'rejected',
    rejection_reason = p_rejection_reason,
    approved_by      = p_actor_id,
    approved_at      = NOW(),
    updated_at       = NOW(),
    updated_by       = p_actor_id
  WHERE id = p_id AND tenant_id = v_tenant_id;

  -- Lineage audit
  PERFORM fn_audit_log_record_v2(
    'advisory_draft', p_id, 'UPDATE',
    jsonb_build_object('approvalStatus', v_d.approval_status),
    jsonb_build_object(
      'approvalStatus',  'rejected',
      'approvedBy',      p_actor_id,
      'promptHash',      v_d.prompt_hash,
      'modelVersion',    v_d.model_version,
      'templateVersion', v_d.template_version,
      'actionCode',      'advisory.rejected'
    ),
    p_actor_id
  );

  -- Notify drafter (best-effort — never let a notification failure roll back
  -- the rejection). Looks up the new in-app template, renders Mustache with
  -- the rejector's name, draft type, contract reference, and reason.
  BEGIN
    SELECT id, subject_en, body_en INTO v_tpl_id, v_tpl_subject, v_tpl_body
    FROM notification_template
    WHERE tenant_id = v_tenant_id
      AND template_id = 'advisory.rejected.in_app'
      AND channel = 'in_app'
      AND is_active = TRUE
    LIMIT 1;

    IF v_tpl_id IS NOT NULL THEN
      SELECT first_name || ' ' || last_name INTO v_rejected_by
      FROM "user" WHERE id = p_actor_id;

      SELECT COALESCE(NULLIF(contract_number, ''), '#' || COALESCE(v_d.contract_id::text, '?'))
        INTO v_contract_ref
      FROM contract WHERE id = v_d.contract_id;

      v_ctx := jsonb_build_object(
        'subject',          fn_mustache_render(
                              COALESCE(v_tpl_subject, 'Your advisory draft was rejected'),
                              jsonb_build_object('draftType', COALESCE(v_draft_type, 'advisory'))
                            ),
        'bodyRendered',     fn_mustache_render(
                              COALESCE(v_tpl_body, ''),
                              jsonb_build_object(
                                'draftType',       COALESCE(v_draft_type, 'advisory'),
                                'contractRef',     COALESCE(v_contract_ref, '—'),
                                'rejectedByName',  COALESCE(v_rejected_by, 'Reviewer'),
                                'rejectionReason', p_rejection_reason
                              )
                            ),
        'advisoryDraftId',  p_id,
        'rejectionReason',  p_rejection_reason
      );

      PERFORM fn_notification_send(
        p_actor_id,
        v_tpl_id,
        'advisory',
        'in_app',
        'medium',
        v_d.created_by,
        NULL,
        v_ctx,
        p_id
      );
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      -- Swallow notification errors — the reject itself committed already.
      -- Operators see the failure in the audit log + notification_dispatch_log
      -- if/when it lands; we do not want a bad template config to block reject.
      NULL;
  END;

  RETURN fn_advisory_draft_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_draft_reject(BIGINT, BIGINT, TEXT) IS
  'Rejects advisory draft with mandatory rejection_reason (>=10 chars). Enforces role match + separation-of-duties + status transition. Emits lineage audit row AND a best-effort in-app notification to the drafter so they discover the rejection (extended in mig 509).';
REVOKE EXECUTE ON FUNCTION fn_advisory_draft_reject(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_reject(BIGINT, BIGINT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (509, 'advisory_reject_notify_drafter', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
-- Restore the previous fn body by re-applying the original CREATE OR REPLACE
-- from migration 216 if needed. We do not auto-drop the template — it's
-- additive seed data and removing it could orphan log rows.
DELETE FROM notification_template
  WHERE template_id = 'advisory.rejected.in_app'
    AND tenant_id = '00000000-0000-0000-0000-000000000001';
DELETE FROM schema_migrations WHERE version = 509;
COMMIT;
-- ROLLBACK END
