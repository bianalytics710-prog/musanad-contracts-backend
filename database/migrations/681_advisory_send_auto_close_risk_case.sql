-- ============================================================================
-- Migration 681 — Auto-close linked risk case when its notice is dispatched
-- ============================================================================
-- Closes the loop on the FM/Sanctions/Cure workflow: once Legal Counsel
-- dispatches the advisory notice to the counterparty, the underlying risk
-- case has been actioned, so it should be marked 'closed'.
--
-- Applies to:
--   fn_advisory_draft_send_directly    — LC short-circuit path
--   fn_advisory_draft_send_after_review — exec-reviewed path
--
-- Guards:
--   - Only acts when metadata.linkedRiskCaseId is present (i.e. the
--     notice originated from a risk case; ad-hoc contract notices don't
--     close anything).
--   - Only flips status when the case is still in an OPEN-ish state
--     ('open' / 'in_review' / 'approved'). Already-closed / risk-accepted
--     cases stay where they are.
--   - Resend doesn't re-close (the case stays closed from the first send).
-- ============================================================================

BEGIN;

-- ─── 1. send_directly: auto-close on first dispatch ────────────────────
CREATE OR REPLACE FUNCTION public.fn_advisory_draft_send_directly(
  p_actor_id          BIGINT,
  p_advisory_draft_id BIGINT,
  p_recipient_address TEXT,
  p_recipient_name    TEXT DEFAULT NULL,
  p_is_resend         BOOLEAN DEFAULT FALSE,
  p_additional_recipients JSONB DEFAULT '[]'::jsonb
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
  v_recipients    JSONB;
  v_extra         JSONB;
  v_case_closed   BOOLEAN := FALSE;
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
   WHERE id = p_advisory_draft_id AND tenant_id = v_tenant_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'advisory draft not found' USING ERRCODE = 'P0002';
  END IF;

  v_risk_case_id := NULLIF(v_draft.template_context->>'linkedRiskCaseId', '')::bigint;

  IF NOT p_is_resend THEN
    IF v_draft.approval_status <> 'unapproved' THEN
      RAISE EXCEPTION 'draft already in terminal state (status=%)', v_draft.approval_status
        USING ERRCODE = '22023';
    END IF;
    IF COALESCE(v_draft.template_context->>'currentReviewer', '') = 'executive' THEN
      RAISE EXCEPTION 'draft is awaiting executive review — use exec-approve first'
        USING ERRCODE = '22023';
    END IF;
  ELSE
    IF v_draft.approval_status <> 'approved' OR v_draft.dispatched_at IS NULL THEN
      RAISE EXCEPTION 'cannot resend — draft was never dispatched' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_extra := COALESCE(p_additional_recipients, '[]'::jsonb);
  v_recipients := jsonb_build_array(jsonb_build_object(
                    'address', p_recipient_address,
                    'name',    p_recipient_name
                  )) || v_extra;

  IF NOT p_is_resend THEN
    UPDATE advisory_draft
       SET approval_status     = 'approved',
           approved_by         = p_actor_id,
           approved_at         = now(),
           final_text_en       = COALESCE(final_text_en, generated_text_en),
           final_text_ar       = COALESCE(final_text_ar, generated_text_ar),
           dispatched_at       = now(),
           dispatch_channel    = 'email',
           dispatch_recipients = v_recipients,
           template_context    = template_context
                                 || jsonb_build_object(
                                      'reviewPath',      'send_directly',
                                      'currentReviewer', 'legal_counsel',
                                      'sendDirectlyAt',  now()
                                    ),
           updated_at          = now(),
           updated_by          = p_actor_id
     WHERE id = p_advisory_draft_id;
  END IF;

  v_payload := jsonb_build_object(
    'recipients',       v_recipients,
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
    now(), now(), 0, 'demo', p_actor_id
  ) RETURNING id INTO v_dispatch_id;

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

  -- ── mig 681: auto-close the linked risk case on FIRST dispatch ─────
  -- Skip on resend (case already closed) and skip if the case is already
  -- in a terminal state.
  IF NOT p_is_resend AND v_risk_case_id IS NOT NULL THEN
    UPDATE risk_case
       SET status            = 'closed',
           closed_at         = now(),
           closed_by         = p_actor_id,
           closure_outcome   = 'advisory_dispatched',
           updated_at        = now(),
           updated_by        = p_actor_id,
           metadata          = COALESCE(metadata, '{}'::jsonb)
                              || jsonb_build_object(
                                   'closedReason',         'advisory_dispatched',
                                   'closedAdvisoryDraftId', p_advisory_draft_id
                                 )
     WHERE id = v_risk_case_id
       AND tenant_id = v_tenant_id
       AND status IN ('open', 'in_review', 'approved');
    IF FOUND THEN
      v_case_closed := TRUE;
      INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
      VALUES (v_tenant_id, v_risk_case_id, 'closed', p_actor_id,
              jsonb_build_object(
                'kind',            'auto_close_on_advisory_dispatch',
                'advisoryDraftId', p_advisory_draft_id,
                'dispatchLogId',   v_dispatch_id
              ));
    END IF;
  END IF;

  IF v_risk_case_id IS NOT NULL THEN
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, v_risk_case_id, 'comment_added', p_actor_id,
            jsonb_build_object(
              'kind',             CASE WHEN p_is_resend THEN 'advisory_resent' ELSE 'advisory_sent' END,
              'advisoryDraftId',  p_advisory_draft_id,
              'recipients',       v_recipients,
              'dispatchLogId',    v_dispatch_id
            ));
  END IF;

  RETURN jsonb_build_object(
    'id',                     p_advisory_draft_id,
    'dispatched',             TRUE,
    'isResend',               p_is_resend,
    'advisoryDispatchLogId',  v_dispatch_id,
    'notificationLogId',      v_notif_id,
    'recipients',             v_recipients,
    'riskCaseClosed',         v_case_closed,
    'riskCaseId',             v_risk_case_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_send_directly(BIGINT, BIGINT, TEXT, TEXT, BOOLEAN, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_send_directly(BIGINT, BIGINT, TEXT, TEXT, BOOLEAN, JSONB) TO neondb_owner;

-- ─── 2. send_after_review: same auto-close ─────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_advisory_draft_send_after_review(
  p_actor_id          BIGINT,
  p_advisory_draft_id BIGINT,
  p_recipient_address TEXT,
  p_recipient_name    TEXT DEFAULT NULL,
  p_additional_recipients JSONB DEFAULT '[]'::jsonb
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
  v_recipients    JSONB;
  v_extra         JSONB;
  v_case_closed   BOOLEAN := FALSE;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;
  IF p_recipient_address IS NULL OR p_recipient_address = '' THEN
    RAISE EXCEPTION 'recipientAddress required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_draft FROM advisory_draft
   WHERE id = p_advisory_draft_id AND tenant_id = v_tenant_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'advisory draft not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_draft.approval_status <> 'approved' THEN
    RAISE EXCEPTION 'draft not approved yet (status=%)', v_draft.approval_status USING ERRCODE = '22023';
  END IF;
  IF v_draft.dispatched_at IS NOT NULL THEN
    RAISE EXCEPTION 'draft already dispatched at %', v_draft.dispatched_at USING ERRCODE = '22023';
  END IF;
  IF COALESCE(v_draft.template_context->>'currentReviewer', '') <> 'legal_counsel' THEN
    RAISE EXCEPTION 'draft not handed back to legal counsel yet' USING ERRCODE = '22023';
  END IF;

  v_risk_case_id := NULLIF(v_draft.template_context->>'linkedRiskCaseId', '')::bigint;
  v_extra := COALESCE(p_additional_recipients, '[]'::jsonb);
  v_recipients := jsonb_build_array(jsonb_build_object(
                    'address', p_recipient_address,
                    'name',    p_recipient_name
                  )) || v_extra;

  UPDATE advisory_draft
     SET dispatched_at       = now(),
         dispatch_channel    = 'email',
         dispatch_recipients = v_recipients,
         updated_at = now(),
         updated_by = p_actor_id
   WHERE id = p_advisory_draft_id;

  v_payload := jsonb_build_object(
    'recipients',       v_recipients,
    'recipientAddress', p_recipient_address,
    'recipientName',    p_recipient_name,
    'subject',          'Advisory notice — ' || v_draft.draft_type,
    'bodyEn',           COALESCE(v_draft.final_text_en, v_draft.generated_text_en),
    'bodyAr',           COALESCE(v_draft.final_text_ar, v_draft.generated_text_ar)
  );
  INSERT INTO advisory_dispatch_log (
    tenant_id, advisory_draft_id, channel, recipient_address,
    rendered_payload, status, delivery_attempted_at, delivery_completed_at,
    retry_count, data_classification, created_by
  ) VALUES (
    v_tenant_id, p_advisory_draft_id, 'email', p_recipient_address,
    v_payload, 'captured_only', now(), now(), 0, 'demo', p_actor_id
  ) RETURNING id INTO v_dispatch_id;

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

  -- mig 681: auto-close linked risk case
  IF v_risk_case_id IS NOT NULL THEN
    UPDATE risk_case
       SET status            = 'closed',
           closed_at         = now(),
           closed_by         = p_actor_id,
           closure_outcome   = 'advisory_dispatched',
           updated_at        = now(),
           updated_by        = p_actor_id,
           metadata          = COALESCE(metadata, '{}'::jsonb)
                              || jsonb_build_object(
                                   'closedReason',         'advisory_dispatched',
                                   'closedAdvisoryDraftId', p_advisory_draft_id
                                 )
     WHERE id = v_risk_case_id
       AND tenant_id = v_tenant_id
       AND status IN ('open', 'in_review', 'approved');
    IF FOUND THEN
      v_case_closed := TRUE;
      INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
      VALUES (v_tenant_id, v_risk_case_id, 'closed', p_actor_id,
              jsonb_build_object(
                'kind',            'auto_close_on_advisory_dispatch',
                'advisoryDraftId', p_advisory_draft_id,
                'dispatchLogId',   v_dispatch_id
              ));
    END IF;

    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, v_risk_case_id, 'comment_added', p_actor_id,
            jsonb_build_object(
              'kind',             'advisory_sent',
              'advisoryDraftId',  p_advisory_draft_id,
              'recipients',       v_recipients,
              'dispatchLogId',    v_dispatch_id,
              'reviewPath',       'executive_review'
            ));
  END IF;

  RETURN jsonb_build_object(
    'id',                    p_advisory_draft_id,
    'dispatched',            TRUE,
    'advisoryDispatchLogId', v_dispatch_id,
    'notificationLogId',     v_notif_id,
    'recipients',            v_recipients,
    'riskCaseClosed',        v_case_closed,
    'riskCaseId',            v_risk_case_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_send_after_review(BIGINT, BIGINT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_send_after_review(BIGINT, BIGINT, TEXT, TEXT, JSONB) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (681, 'advisory_send_auto_close_risk_case', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
