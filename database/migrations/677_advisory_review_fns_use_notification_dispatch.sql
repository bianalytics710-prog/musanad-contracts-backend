-- ============================================================================
-- Migration 677 — Advisory review fns go through fn_notification_dispatch
-- ============================================================================
-- Replaces the direct INSERT INTO notification_dispatch_log calls in
-- fn_advisory_draft_route_for_review + fn_advisory_draft_exec_approve so
-- the platform-admin notification module (events → rules → audiences) is
-- the single source of truth. The rules seeded in mig 676 deliver the
-- in-app notification to the right role.
--
-- Plus: NEW fn_advisory_draft_exec_modify for Phase 2 — executive edits
-- the EN/AR body before approving. Fires advisory.modified_by_exec.
--
-- Payloads passed to fn_notification_dispatch include the Mustache vars
-- referenced by the templates seeded in mig 676: actorName, advisoryTitle,
-- contractNumber, advisoryLink, recipientName, and identifiers used by
-- downstream renderers.
-- ============================================================================

BEGIN;

-- Helper to build the standard advisory payload — DRY across the 3 fns.
CREATE OR REPLACE FUNCTION public.fn_internal_advisory_notification_payload(
  p_advisory_draft_id BIGINT,
  p_actor_id          BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_draft RECORD;
  v_contract RECORD;
  v_actor_name TEXT;
  v_template_label TEXT;
BEGIN
  SELECT ad.*, at.display_name_en AS template_display
    INTO v_draft
    FROM advisory_draft ad
    JOIN advisory_template at ON at.id = ad.template_id
   WHERE ad.id = p_advisory_draft_id;
  IF v_draft.id IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;
  SELECT contract_number, COALESCE(title_en, title_ar) AS title
    INTO v_contract FROM contract WHERE id = v_draft.contract_id;
  SELECT TRIM(CONCAT_WS(' ', u.first_name, u.last_name))
    INTO v_actor_name FROM "user" u WHERE u.id = p_actor_id;
  v_template_label := COALESCE(v_draft.template_display, v_draft.draft_type);
  RETURN jsonb_build_object(
    'advisoryDraftId', p_advisory_draft_id,
    'advisoryTitle',   v_template_label,
    'draftType',       v_draft.draft_type,
    'contractId',      v_draft.contract_id,
    'contractNumber',  COALESCE(v_contract.contract_number, ''),
    'contractTitle',   COALESCE(v_contract.title, ''),
    'actorId',         p_actor_id,
    'actorName',       COALESCE(v_actor_name, 'System'),
    'linkedRiskCaseId', v_draft.template_context->>'linkedRiskCaseId',
    'advisoryLink',    '/app/contracts/' || v_draft.contract_id || '?tab=notices'
  );
END;
$function$;

-- ─── 1. route_for_review ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_advisory_draft_route_for_review(
  p_actor_id          BIGINT,
  p_advisory_draft_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant_id     UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  v_draft         RECORD;
  v_risk_case_id  BIGINT;
  v_payload       JSONB;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;
  IF p_actor_id IS NULL OR p_advisory_draft_id IS NULL THEN
    RAISE EXCEPTION 'actorId + advisoryDraftId required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_draft FROM advisory_draft
   WHERE id = p_advisory_draft_id AND tenant_id = v_tenant_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'advisory draft not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_draft.approval_status <> 'unapproved' THEN
    RAISE EXCEPTION 'cannot route — draft already in terminal state (%)', v_draft.approval_status
      USING ERRCODE = '22023';
  END IF;

  v_risk_case_id := NULLIF(v_draft.template_context->>'linkedRiskCaseId', '')::bigint;

  UPDATE advisory_draft
     SET template_context = template_context
                            || jsonb_build_object(
                                 'reviewPath',      'executive_review',
                                 'currentReviewer', 'executive',
                                 'routedAt',        now(),
                                 'routedBy',        p_actor_id
                               ),
         updated_at = now(),
         updated_by = p_actor_id
   WHERE id = p_advisory_draft_id;

  -- Notification via the platform-admin notification module (mig 676).
  v_payload := fn_internal_advisory_notification_payload(p_advisory_draft_id, p_actor_id);
  PERFORM fn_notification_dispatch(
    p_actor_id,
    'advisory.routed_for_review',
    v_payload,
    'approval_request',
    'high',
    p_actor_id,
    NULL
  );

  IF v_risk_case_id IS NOT NULL THEN
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, v_risk_case_id, 'comment_added', p_actor_id,
            jsonb_build_object(
              'kind',           'advisory_routed_for_review',
              'advisoryDraftId', p_advisory_draft_id,
              'reviewer',        'executive'
            ));
  END IF;

  RETURN jsonb_build_object(
    'id',              p_advisory_draft_id,
    'routedTo',        'executive',
    'eventDispatched', 'advisory.routed_for_review'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_route_for_review(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_route_for_review(BIGINT, BIGINT) TO neondb_owner;

-- ─── 2. exec_approve ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_advisory_draft_exec_approve(
  p_actor_id          BIGINT,
  p_advisory_draft_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant_id     UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  v_draft         RECORD;
  v_risk_case_id  BIGINT;
  v_payload       JSONB;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;
  IF p_actor_id IS NULL OR p_advisory_draft_id IS NULL THEN
    RAISE EXCEPTION 'actorId + advisoryDraftId required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_draft FROM advisory_draft
   WHERE id = p_advisory_draft_id AND tenant_id = v_tenant_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'advisory draft not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_draft.approval_status <> 'unapproved' THEN
    RAISE EXCEPTION 'draft already in terminal state (%)', v_draft.approval_status
      USING ERRCODE = '22023';
  END IF;
  IF COALESCE(v_draft.template_context->>'currentReviewer', '') <> 'executive' THEN
    RAISE EXCEPTION 'draft is not awaiting executive review (currentReviewer=%)',
      COALESCE(v_draft.template_context->>'currentReviewer', 'null')
      USING ERRCODE = '22023';
  END IF;

  v_risk_case_id := NULLIF(v_draft.template_context->>'linkedRiskCaseId', '')::bigint;

  UPDATE advisory_draft
     SET approval_status = 'approved',
         approved_by     = p_actor_id,
         approved_at     = now(),
         final_text_en   = COALESCE(final_text_en, generated_text_en),
         final_text_ar   = COALESCE(final_text_ar, generated_text_ar),
         template_context = template_context
                            || jsonb_build_object(
                                 'currentReviewer', 'legal_counsel',
                                 'execApprovedAt',  now(),
                                 'execApprovedBy',  p_actor_id
                               ),
         updated_at = now(),
         updated_by = p_actor_id
   WHERE id = p_advisory_draft_id;

  v_payload := fn_internal_advisory_notification_payload(p_advisory_draft_id, p_actor_id);
  PERFORM fn_notification_dispatch(
    p_actor_id,
    'advisory.approved_for_send',
    v_payload,
    'advisory',
    'high',
    p_actor_id,
    NULL
  );

  IF v_risk_case_id IS NOT NULL THEN
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, v_risk_case_id, 'comment_added', p_actor_id,
            jsonb_build_object(
              'kind',           'advisory_exec_approved',
              'advisoryDraftId', p_advisory_draft_id
            ));
  END IF;

  RETURN jsonb_build_object(
    'id',              p_advisory_draft_id,
    'approved',        TRUE,
    'handedBackTo',    'legal_counsel',
    'eventDispatched', 'advisory.approved_for_send'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_exec_approve(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_exec_approve(BIGINT, BIGINT) TO neondb_owner;

-- ─── 3. exec_modify (NEW for Phase 2) ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_advisory_draft_exec_modify(
  p_actor_id          BIGINT,
  p_advisory_draft_id BIGINT,
  p_modified_text_en  TEXT,
  p_modified_text_ar  TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
  v_tenant_id     UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  v_draft         RECORD;
  v_risk_case_id  BIGINT;
  v_payload       JSONB;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;
  IF p_actor_id IS NULL OR p_advisory_draft_id IS NULL THEN
    RAISE EXCEPTION 'actorId + advisoryDraftId required' USING ERRCODE = '22023';
  END IF;
  IF p_modified_text_en IS NULL OR p_modified_text_en = '' THEN
    RAISE EXCEPTION 'modifiedTextEn required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_draft FROM advisory_draft
   WHERE id = p_advisory_draft_id AND tenant_id = v_tenant_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'advisory draft not found' USING ERRCODE = 'P0002';
  END IF;
  IF COALESCE(v_draft.template_context->>'currentReviewer', '') <> 'executive' THEN
    RAISE EXCEPTION 'draft is not awaiting executive review' USING ERRCODE = '22023';
  END IF;

  v_risk_case_id := NULLIF(v_draft.template_context->>'linkedRiskCaseId', '')::bigint;

  -- Save modified text + flip approval_status to 'modified'. We then
  -- promote to 'approved' so LC can send. (Could also leave at 'modified'
  -- and require a separate Approve click — but the demo flow says modify
  -- = approve+edit in one step.)
  UPDATE advisory_draft
     SET modified_text_en = p_modified_text_en,
         modified_text_ar = p_modified_text_ar,
         final_text_en    = p_modified_text_en,
         final_text_ar    = COALESCE(p_modified_text_ar, v_draft.final_text_ar, v_draft.generated_text_ar),
         approval_status  = 'approved',
         approved_by      = p_actor_id,
         approved_at      = now(),
         template_context = template_context
                            || jsonb_build_object(
                                 'currentReviewer', 'legal_counsel',
                                 'execApprovedAt',  now(),
                                 'execApprovedBy',  p_actor_id,
                                 'execModified',    TRUE,
                                 'execModifiedAt',  now()
                               ),
         updated_at = now(),
         updated_by = p_actor_id
   WHERE id = p_advisory_draft_id;

  v_payload := fn_internal_advisory_notification_payload(p_advisory_draft_id, p_actor_id);
  PERFORM fn_notification_dispatch(
    p_actor_id,
    'advisory.modified_by_exec',
    v_payload,
    'advisory',
    'high',
    p_actor_id,
    NULL
  );

  IF v_risk_case_id IS NOT NULL THEN
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, v_risk_case_id, 'comment_added', p_actor_id,
            jsonb_build_object(
              'kind',           'advisory_exec_modified',
              'advisoryDraftId', p_advisory_draft_id
            ));
  END IF;

  RETURN jsonb_build_object(
    'id',              p_advisory_draft_id,
    'modified',        TRUE,
    'approved',        TRUE,
    'handedBackTo',    'legal_counsel',
    'eventDispatched', 'advisory.modified_by_exec'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_exec_modify(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_exec_modify(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (677, 'advisory_review_fns_use_notification_dispatch', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
