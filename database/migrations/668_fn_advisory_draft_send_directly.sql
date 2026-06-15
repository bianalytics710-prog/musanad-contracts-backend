-- ============================================================================
-- Migration 668 — fn_advisory_draft_send_directly
-- ============================================================================
-- Single-shot approve + dispatch path for the LC's "Send directly" choice.
-- Skips the executive-review hop entirely:
--   1. Flips approval_status='approved' (LC is both drafter + approver here)
--   2. Stamps approved_by + approved_at + dispatched_at + dispatch_channel
--      + dispatch_recipients on advisory_draft
--   3. Writes an advisory_dispatch_log row (status='captured_only' —
--      simulated send; matches the existing CR-H notification-dispatcher
--      semantics for non-SMTP environments)
--   4. Writes a notification_dispatch_log row addressed to the resolved
--      counterparty email
--   5. Inserts a risk_case_event ('comment_added', kind='advisory_sent')
--      so the risk case's timeline reflects the dispatch.
--
-- Guards:
--   - Only callable when the draft's metadata.reviewPath = 'send_directly'.
--     A draft that LC explicitly routed for executive review can't be
--     short-circuited here.
--   - Tenant-scoped via GUC.
--   - Recipient address required (caller resolves it via the BE recipient
--     helper).
--
-- The Resend path uses this same fn with p_is_resend=TRUE — it skips the
-- status flip + risk_case_event (already audited at original send) and
-- only writes a fresh dispatch_log row so the "sent N times" history is
-- preserved.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_advisory_draft_send_directly(
  p_actor_id          BIGINT,
  p_advisory_draft_id BIGINT,
  p_recipient_address TEXT,
  p_recipient_name    TEXT DEFAULT NULL,
  p_is_resend         BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant_id     UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  v_draft         RECORD;
  v_risk_case_id  BIGINT;
  v_dispatch_id   BIGINT;
  v_notif_id      BIGINT;
  v_payload       JSONB;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'actorId required' USING ERRCODE = '22023';
  END IF;
  IF p_advisory_draft_id IS NULL THEN
    RAISE EXCEPTION 'advisoryDraftId required' USING ERRCODE = '22023';
  END IF;
  IF p_recipient_address IS NULL OR p_recipient_address = '' THEN
    RAISE EXCEPTION 'recipientAddress required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_draft
    FROM advisory_draft
   WHERE id = p_advisory_draft_id
     AND tenant_id = v_tenant_id
     AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'advisory draft not found' USING ERRCODE = 'P0002';
  END IF;

  v_risk_case_id := NULLIF(v_draft.template_context->>'linkedRiskCaseId', '')::bigint;

  -- Guard: only allow send-directly for drafts that were generated under
  -- the send_directly path. On resend, we accept already-approved drafts
  -- regardless of their original review path.
  IF NOT p_is_resend THEN
    IF COALESCE(v_draft.template_context->>'reviewPath', '') <> 'send_directly' THEN
      RAISE EXCEPTION 'draft is not on the send_directly path (reviewPath=%)',
        COALESCE(v_draft.template_context->>'reviewPath', 'null')
        USING ERRCODE = '22023';
    END IF;
    IF v_draft.approval_status <> 'unapproved' THEN
      RAISE EXCEPTION 'draft already in terminal state (status=%)', v_draft.approval_status
        USING ERRCODE = '22023';
    END IF;
  ELSE
    IF v_draft.approval_status <> 'approved' OR v_draft.dispatched_at IS NULL THEN
      RAISE EXCEPTION 'cannot resend — draft was never dispatched' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Stage 1 — approve + stamp dispatch fields on the draft (skip on resend).
  IF NOT p_is_resend THEN
    UPDATE advisory_draft
       SET approval_status     = 'approved',
           approved_by         = p_actor_id,
           approved_at         = now(),
           final_text_en       = COALESCE(final_text_en, generated_text_en),
           final_text_ar       = COALESCE(final_text_ar, generated_text_ar),
           dispatched_at       = now(),
           dispatch_channel    = 'email',
           dispatch_recipients = jsonb_build_array(
                                   jsonb_build_object(
                                     'address', p_recipient_address,
                                     'name',    p_recipient_name
                                   )),
           updated_at          = now(),
           updated_by          = p_actor_id
     WHERE id = p_advisory_draft_id;
  END IF;

  -- Stage 2 — advisory_dispatch_log row (the canonical "we tried to send"
  -- audit). 'captured_only' means: rendered + addressed + would-have-sent,
  -- but no real SMTP wired in the demo environment.
  v_payload := jsonb_build_object(
    'recipientAddress', p_recipient_address,
    'recipientName',    p_recipient_name,
    'subject',          'Advisory notice — ' || v_draft.draft_type,
    'bodyEn',           COALESCE(v_draft.final_text_en, v_draft.generated_text_en),
    'bodyAr',           COALESCE(v_draft.final_text_ar, v_draft.generated_text_ar)
  );
  INSERT INTO advisory_dispatch_log (
    tenant_id, advisory_draft_id, channel, recipient_address,
    rendered_payload, status,
    delivery_attempted_at, delivery_completed_at,
    retry_count, data_classification, created_by
  ) VALUES (
    v_tenant_id, p_advisory_draft_id, 'email', p_recipient_address,
    v_payload, 'captured_only',
    now(), now(),
    0, 'demo', p_actor_id
  ) RETURNING id INTO v_dispatch_id;

  -- Stage 3 — notification_dispatch_log mirrors the same event for the
  -- platform's notification timeline (used by admin governance + audit).
  INSERT INTO notification_dispatch_log (
    tenant_id, notification_kind, priority, channel,
    recipient_address, subject, body_rendered, context_payload,
    status, delivery_attempted_at, delivery_completed_at,
    retry_count, advisory_draft_id, data_classification, created_by
  ) VALUES (
    v_tenant_id, 'advisory', 'medium', 'email',
    p_recipient_address,
    'Advisory notice — ' || v_draft.draft_type,
    COALESCE(v_draft.final_text_en, v_draft.generated_text_en),
    v_payload, 'captured_only', now(), now(),
    0, p_advisory_draft_id, 'demo', p_actor_id
  ) RETURNING id INTO v_notif_id;

  -- Stage 4 — risk case timeline event so the case detail's Timeline tab
  -- shows the dispatch. Re-uses the existing 'comment_added' event_type
  -- with a discriminator in payload.kind to avoid altering the CHECK.
  IF v_risk_case_id IS NOT NULL THEN
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, v_risk_case_id, 'comment_added', p_actor_id,
            jsonb_build_object(
              'kind',             CASE WHEN p_is_resend THEN 'advisory_resent' ELSE 'advisory_sent' END,
              'advisoryDraftId',  p_advisory_draft_id,
              'recipientAddress', p_recipient_address,
              'recipientName',    p_recipient_name,
              'dispatchLogId',    v_dispatch_id
            ));
  END IF;

  RETURN jsonb_build_object(
    'id',                     p_advisory_draft_id,
    'dispatched',             TRUE,
    'isResend',               p_is_resend,
    'advisoryDispatchLogId',  v_dispatch_id,
    'notificationLogId',      v_notif_id,
    'recipientAddress',       p_recipient_address
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_send_directly(BIGINT, BIGINT, TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_send_directly(BIGINT, BIGINT, TEXT, TEXT, BOOLEAN) TO neondb_owner;

COMMENT ON FUNCTION public.fn_advisory_draft_send_directly(BIGINT, BIGINT, TEXT, TEXT, BOOLEAN) IS
  'mig 668 — LC send-directly + resend path. Approves + dispatches in one shot; '
  'writes advisory_dispatch_log + notification_dispatch_log (captured_only = '
  'simulated email). On resend, skips status flip and only writes new logs.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (668, 'fn_advisory_draft_send_directly', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
