-- ============================================================================
-- Migration 669 — Executive review path for advisory drafts
-- ============================================================================
-- Three new fn_'s + 1 extension that complete the "Executive review" path:
--
--   1. fn_advisory_draft_route_for_review(actor, id)
--      LC sends a draft to Eman for review. Sets metadata.currentReviewer
--      = 'executive' so My Work's advisory_draft branch surfaces it on
--      Eman's inbox. Inserts a risk_case_event + notification_dispatch_log
--      addressed to executive role users.
--
--   2. fn_advisory_draft_exec_approve(actor, id)
--      Eman approves. Sets approval_status='approved' + currentReviewer
--      flips back to 'legal_counsel' so the draft appears on Layla's
--      My Work as "ready to send". Inserts risk_case_event + notif to LC.
--
--   3. fn_advisory_draft_send_after_review(actor, id, recipient, name)
--      LC dispatches the exec-approved draft. Similar to send_directly
--      (mig 668) but expects status='approved' already; only writes the
--      dispatch logs + stamps dispatched_at.
--
--   4. fn_my_work_list_v2 — advisory_draft branch extended to surface:
--        - drafts where metadata.currentReviewer = my role (new workflow)
--        - keeps legacy filter intact (template assigned_approver_role)
--      The branch filters out dispatched drafts so completed work doesn't
--      clutter the inbox.
-- ============================================================================

BEGIN;

-- ─── 1. route_for_review ─────────────────────────────────────────────────
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
  v_exec_user_id  BIGINT;
  v_exec_email    TEXT;
  v_notif_id      BIGINT;
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

  -- Flip metadata.reviewPath + currentReviewer. We keep the rest of the
  -- template_context (Mustache variables) intact.
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

  -- Notification → first active executive user (single-exec demo). We
  -- still write the log even if no executive exists; recipient_address
  -- is populated as a sentinel so the recipient_present CHECK holds.
  SELECT u.id, u.email INTO v_exec_user_id, v_exec_email
    FROM "user" u
    JOIN role r ON r.id = u.role_id
   WHERE r.name = 'executive' AND u.is_active = TRUE
   ORDER BY u.id ASC
   LIMIT 1;

  INSERT INTO notification_dispatch_log (
    tenant_id, notification_kind, priority, channel,
    recipient_user_id, recipient_address, subject, body_rendered, context_payload,
    status, delivery_attempted_at, delivery_completed_at,
    retry_count, advisory_draft_id, data_classification, created_by
  ) VALUES (
    v_tenant_id, 'approval_request', 'high', 'in_app',
    v_exec_user_id,
    COALESCE(v_exec_email, 'executive@demo.local'),
    'Advisory draft awaiting your review',
    'Legal Counsel routed advisory #' || p_advisory_draft_id || ' for your review before dispatch.',
    jsonb_build_object('advisoryDraftId', p_advisory_draft_id,
                       'riskCaseId',      v_risk_case_id,
                       'reviewPath',      'executive_review'),
    'captured_only', now(), now(),
    0, p_advisory_draft_id, 'demo', p_actor_id
  ) RETURNING id INTO v_notif_id;

  -- Risk-case timeline event
  IF v_risk_case_id IS NOT NULL THEN
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, v_risk_case_id, 'comment_added', p_actor_id,
            jsonb_build_object(
              'kind',            'advisory_routed_for_review',
              'advisoryDraftId',  p_advisory_draft_id,
              'reviewer',         'executive',
              'reviewerUserId',   v_exec_user_id
            ));
  END IF;

  RETURN jsonb_build_object(
    'id',               p_advisory_draft_id,
    'routedTo',         'executive',
    'reviewerUserId',   v_exec_user_id,
    'notificationLogId', v_notif_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_route_for_review(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_route_for_review(BIGINT, BIGINT) TO neondb_owner;

-- ─── 2. exec_approve ─────────────────────────────────────────────────────
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
  v_lc_user_id    BIGINT;
  v_lc_email      TEXT;
  v_notif_id      BIGINT;
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

  -- Notify the LC who originally drafted it; fall back to first active LC.
  SELECT u.id, u.email INTO v_lc_user_id, v_lc_email
    FROM "user" u
    JOIN role r ON r.id = u.role_id
   WHERE u.id = v_draft.created_by AND u.is_active = TRUE AND r.name = 'legal_counsel';
  IF v_lc_user_id IS NULL THEN
    SELECT u.id, u.email INTO v_lc_user_id, v_lc_email
      FROM "user" u
      JOIN role r ON r.id = u.role_id
     WHERE r.name = 'legal_counsel' AND u.is_active = TRUE
     ORDER BY u.id ASC
     LIMIT 1;
  END IF;

  INSERT INTO notification_dispatch_log (
    tenant_id, notification_kind, priority, channel,
    recipient_user_id, recipient_address, subject, body_rendered, context_payload,
    status, delivery_attempted_at, delivery_completed_at,
    retry_count, advisory_draft_id, data_classification, created_by
  ) VALUES (
    v_tenant_id, 'advisory', 'high', 'in_app',
    v_lc_user_id,
    COALESCE(v_lc_email, 'legal@demo.local'),
    'Executive approved your advisory — ready to send',
    'Executive review passed on advisory #' || p_advisory_draft_id || '. You can now dispatch it.',
    jsonb_build_object('advisoryDraftId', p_advisory_draft_id,
                       'riskCaseId',      v_risk_case_id),
    'captured_only', now(), now(),
    0, p_advisory_draft_id, 'demo', p_actor_id
  ) RETURNING id INTO v_notif_id;

  IF v_risk_case_id IS NOT NULL THEN
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, v_risk_case_id, 'comment_added', p_actor_id,
            jsonb_build_object(
              'kind',           'advisory_exec_approved',
              'advisoryDraftId', p_advisory_draft_id
            ));
  END IF;

  RETURN jsonb_build_object(
    'id',                p_advisory_draft_id,
    'approved',          TRUE,
    'handedBackTo',      'legal_counsel',
    'notificationLogId', v_notif_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_exec_approve(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_exec_approve(BIGINT, BIGINT) TO neondb_owner;

-- ─── 3. send_after_review (LC dispatches an exec-approved draft) ─────────
CREATE OR REPLACE FUNCTION public.fn_advisory_draft_send_after_review(
  p_actor_id          BIGINT,
  p_advisory_draft_id BIGINT,
  p_recipient_address TEXT,
  p_recipient_name    TEXT DEFAULT NULL
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
  IF p_actor_id IS NULL OR p_advisory_draft_id IS NULL THEN
    RAISE EXCEPTION 'actorId + advisoryDraftId required' USING ERRCODE = '22023';
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
    RAISE EXCEPTION 'draft not approved yet (status=%)', v_draft.approval_status
      USING ERRCODE = '22023';
  END IF;
  IF v_draft.dispatched_at IS NOT NULL THEN
    RAISE EXCEPTION 'draft already dispatched at %', v_draft.dispatched_at
      USING ERRCODE = '22023';
  END IF;
  IF COALESCE(v_draft.template_context->>'currentReviewer', '') <> 'legal_counsel' THEN
    RAISE EXCEPTION 'draft not handed back to legal counsel yet' USING ERRCODE = '22023';
  END IF;

  v_risk_case_id := NULLIF(v_draft.template_context->>'linkedRiskCaseId', '')::bigint;

  UPDATE advisory_draft
     SET dispatched_at       = now(),
         dispatch_channel    = 'email',
         dispatch_recipients = jsonb_build_array(
                                 jsonb_build_object(
                                   'address', p_recipient_address,
                                   'name',    p_recipient_name
                                 )),
         updated_at = now(),
         updated_by = p_actor_id
   WHERE id = p_advisory_draft_id;

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

  IF v_risk_case_id IS NOT NULL THEN
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, v_risk_case_id, 'comment_added', p_actor_id,
            jsonb_build_object(
              'kind',             'advisory_sent',
              'advisoryDraftId',  p_advisory_draft_id,
              'recipientAddress', p_recipient_address,
              'recipientName',    p_recipient_name,
              'dispatchLogId',    v_dispatch_id,
              'reviewPath',       'executive_review'
            ));
  END IF;

  RETURN jsonb_build_object(
    'id',                    p_advisory_draft_id,
    'dispatched',            TRUE,
    'advisoryDispatchLogId', v_dispatch_id,
    'notificationLogId',     v_notif_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_send_after_review(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_send_after_review(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

-- ─── 4. fn_my_work_list_v2 — advisory_draft branch extension ─────────────
-- Extends the existing branch (from mig 666) to ALSO surface drafts where
-- template_context.currentReviewer = my role. Original filter (template
-- assigned_approver_role) preserved for legacy unrouted drafts.
-- Dispatched drafts hidden — they're done work, not work-in-progress.
CREATE OR REPLACE FUNCTION public.fn_my_work_list_v2(
  p_actor_id  BIGINT,
  p_status    TEXT[] DEFAULT NULL,
  p_type      TEXT[] DEFAULT NULL,
  p_search    TEXT   DEFAULT NULL,
  p_page      INTEGER DEFAULT 1,
  p_limit     INTEGER DEFAULT 20
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_offset  INTEGER := GREATEST(p_page - 1, 0) * GREATEST(p_limit, 1);
  v_roles   TEXT[];
  v_total   INTEGER;
  v_open    INTEGER;
  v_data    JSONB;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_my_work_list_v2: %', 'actorId:Actor id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT ARRAY[r.name]
    INTO v_roles
    FROM "user" u
    INNER JOIN role r ON r.id = u.role_id
    WHERE u.id = p_actor_id
      AND u.is_active = TRUE;
  IF v_roles IS NULL THEN
    v_roles := ARRAY[]::TEXT[];
  END IF;

  WITH all_rows AS (

    -- ─── 1. work_order ───────────────────────────────────────────────────
    SELECT
      wo.id, wo.work_order_type::TEXT, wo.status::TEXT, wo.priority::TEXT,
      wo.source_contract_id, sc.contract_number, sc.title_en, sc.title_ar,
      wo.target_contract_id, tc.contract_number, tc.title_en, tc.title_ar, tc.status::TEXT,
      COALESCE(cp_tgt.name_en, cp_src.name_en, cp_wo.name_en, wo.counterparty_prospect_name)
                                                     AS counterparty_name,
      wo.assigned_by_user_id,
      CASE WHEN ab.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(ab.first_name, ' ', ab.last_name)) END,
      wo.payload, wo.related_comment_id, wo.manual_stage::TEXT,
      wo.created_at, wo.completed_at, wo.due_at,
      EXTRACT(DAY FROM (now() - wo.created_at))::INT, '/app/work'
    FROM work_order wo
    LEFT JOIN contract sc      ON sc.id     = wo.source_contract_id
    LEFT JOIN contract tc      ON tc.id     = wo.target_contract_id
    LEFT JOIN party    cp_src  ON cp_src.id = sc.counterparty_id
    LEFT JOIN party    cp_tgt  ON cp_tgt.id = tc.counterparty_id
    LEFT JOIN party    cp_wo   ON cp_wo.id  = wo.counterparty_id
    LEFT JOIN "user"   ab      ON ab.id     = wo.assigned_by_user_id
    WHERE wo.is_active = TRUE
      AND wo.assigned_to_user_id = p_actor_id
      AND (p_status IS NULL OR wo.status::TEXT = ANY(p_status))

    UNION ALL

    -- ─── 2. approval_step ───────────────────────────────────────────────
    SELECT
      (-1000000 - s.id), 'approval_awaiting'::TEXT, 'open'::TEXT, 'normal'::TEXT,
      c.id, c.contract_number, c.title_en, c.title_ar,
      NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT,
      NULL::TEXT,
      ch.initiated_by,
      CASE WHEN ib.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(ib.first_name, ' ', ib.last_name)) END,
      jsonb_build_object('stepId', s.id, 'chainId', ch.id,
                         'stepOrder', s.step_order,
                         'approverRole', s.approver_role),
      NULL::BIGINT, NULL::TEXT,
      s.created_at, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ,
      EXTRACT(DAY FROM (now() - s.created_at))::INT, '/app/approvals'
    FROM approval_step s
    INNER JOIN approval_chain ch ON ch.id = s.approval_chain_id
    INNER JOIN contract       c  ON c.id  = ch.contract_id
    LEFT  JOIN "user"         ib ON ib.id = ch.initiated_by
    WHERE s.is_active = TRUE
      AND s.status = 'pending'
      AND ch.is_active = TRUE
      AND ch.status = 'in_progress'
      AND c.is_active = TRUE
      AND (
        s.approver_user_id = p_actor_id
        OR (s.approver_user_id IS NULL AND s.approver_role = ANY(v_roles))
        OR s.delegated_to = p_actor_id
        OR s.reassigned_to = p_actor_id
      )

    UNION ALL

    -- ─── 3. risk_case (mig 666 — from-assignment metadata) ──────────────
    SELECT
      (-2000000 - rc.id),
      'risk_case_assigned'::TEXT,
      CASE rc.status WHEN 'in_review' THEN 'in_progress' ELSE 'open' END,
      CASE
        WHEN (rc.metadata ? 'tier2AutoEscalatedAt')
          OR (rc.metadata ? 'autoEscalatedAt')
          OR ((rc.metadata->>'autoEscalated')::boolean IS TRUE)
        THEN 'urgent'
        ELSE COALESCE(rc.priority, 'normal')::TEXT
      END,
      rc.contract_id, c.contract_number, c.title_en, c.title_ar,
      NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT,
      NULL::TEXT,
      COALESCE(
        (rc.metadata->>'lastReassignedBy')::bigint,
        (rc.metadata->>'promotedBy')::bigint,
        rc.created_by
      ),
      CASE WHEN actor.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(actor.first_name, ' ', actor.last_name)) END,
      jsonb_build_object(
        'riskCaseId',  rc.id,
        'caseType',    rc.case_type,
        'title',       rc.title,
        'autoEscalated', COALESCE(
                          (rc.metadata->>'autoEscalated')::boolean,
                          rc.metadata ? 'tier2AutoEscalatedAt'
                                OR rc.metadata ? 'autoEscalatedAt'
                        )
      ),
      NULL::BIGINT, NULL::TEXT,
      COALESCE(
        (rc.metadata->>'lastReassignedAt')::timestamptz,
        (rc.metadata->>'promotedFromTier2At')::timestamptz,
        rc.created_at
      ),
      NULL::TIMESTAMPTZ, rc.due_at,
      EXTRACT(DAY FROM (now() - COALESCE(
        (rc.metadata->>'lastReassignedAt')::timestamptz,
        (rc.metadata->>'promotedFromTier2At')::timestamptz,
        rc.created_at
      )))::INT,
      ('/app/risk-cases/' || rc.id)
    FROM risk_case rc
    LEFT JOIN contract c     ON c.id  = rc.contract_id
    LEFT JOIN "user"   actor ON actor.id = COALESCE(
                                  (rc.metadata->>'lastReassignedBy')::bigint,
                                  (rc.metadata->>'promotedBy')::bigint,
                                  rc.created_by
                                )
    WHERE rc.is_active = TRUE
      AND rc.assigned_user_id = p_actor_id
      AND rc.status IN ('open', 'in_review')

    UNION ALL

    -- ─── 4. tpa_review ──────────────────────────────────────────────────
    SELECT
      (-3000000 - tpa.id), 'third_party_review'::TEXT, 'open'::TEXT,
      CASE tpa.overall_risk
        WHEN 'critical' THEN 'urgent' WHEN 'high' THEN 'high'
        WHEN 'medium'   THEN 'normal' ELSE 'low' END,
      NULL::BIGINT, tpa.reference_code, tpa.agreement_title, NULL::TEXT,
      NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT,
      tpa.counterparty_name, tpa.created_by,
      CASE WHEN cb.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(cb.first_name, ' ', cb.last_name)) END,
      jsonb_build_object('tpaReviewId', tpa.id,
                         'agreementType', tpa.agreement_type,
                         'overallVerdict', tpa.overall_verdict,
                         'overallRisk', tpa.overall_risk),
      NULL::BIGINT, NULL::TEXT,
      tpa.created_at, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ,
      EXTRACT(DAY FROM (now() - tpa.created_at))::INT,
      ('/app/legal/third-party-review/' || tpa.id)
    FROM tpa_review tpa
    LEFT JOIN "user" cb ON cb.id = tpa.created_by
    WHERE tpa.is_active = TRUE
      AND tpa.status IN ('awaiting_review', 'pending_analysis')
      AND 'legal_counsel' = ANY(v_roles)

    UNION ALL

    -- ─── 5. advisory_draft (mig 669 — review-path-aware) ─────────────────
    -- A draft shows up for actor A when:
    --   (legacy) approval_status='unapproved' AND template approver role = A's role
    --   (v2)     template_context.currentReviewer = A's role AND not yet dispatched
    -- Dispatched drafts are hidden (done work).
    SELECT
      (-4000000 - ad.id), 'advisory_draft'::TEXT,
      CASE
        WHEN ad.template_context->>'currentReviewer' IS NOT NULL
             AND ad.approval_status = 'approved'
             AND ad.dispatched_at IS NULL
        THEN 'in_progress'  -- exec-approved, awaiting LC send
        ELSE 'open'
      END,
      CASE
        WHEN ad.template_context->>'reviewPath' = 'executive_review' THEN 'high'
        ELSE 'normal'
      END,
      ad.contract_id, c.contract_number, c.title_en, c.title_ar,
      NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT,
      NULL::TEXT, ad.created_by,
      CASE WHEN cb.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(cb.first_name, ' ', cb.last_name)) END,
      jsonb_build_object(
        'advisoryDraftId', ad.id,
        'draftType',       ad.draft_type,
        'templateId',      ad.template_id,
        'reviewPath',      ad.template_context->>'reviewPath',
        'currentReviewer', ad.template_context->>'currentReviewer',
        'linkedRiskCaseId', ad.template_context->>'linkedRiskCaseId'
      ),
      NULL::BIGINT, NULL::TEXT,
      ad.created_at, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ,
      EXTRACT(DAY FROM (now() - ad.created_at))::INT,
      ('/app/legal/advisory-queue/' || ad.id)
    FROM advisory_draft ad
    INNER JOIN advisory_template at ON at.id = ad.template_id
    LEFT  JOIN contract           c  ON c.id  = ad.contract_id
    LEFT  JOIN "user"             cb ON cb.id = ad.created_by
    WHERE ad.is_active = TRUE
      AND ad.dispatched_at IS NULL
      AND (
        -- Legacy unrouted path: any LC sees any unapproved draft targeting LC role.
        (
          ad.approval_status = 'unapproved'
          AND (ad.template_context->>'currentReviewer') IS NULL
          AND COALESCE(at.assigned_approver_role, 'legal_counsel') = ANY(v_roles)
        )
        OR
        -- v2 routed path: surface to whoever the metadata says is up next.
        (
          (ad.template_context->>'currentReviewer') = ANY(v_roles)
          AND ad.approval_status IN ('unapproved', 'approved')
        )
      )

    UNION ALL

    -- ─── 6. comment_mention ─────────────────────────────────────────────
    SELECT
      (-5000000 - cc.id), 'comment_mention'::TEXT, 'open'::TEXT, 'normal'::TEXT,
      cc.contract_id, c.contract_number, c.title_en, c.title_ar,
      NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT,
      cp.name_en, cc.created_by,
      CASE WHEN au.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(au.first_name, ' ', au.last_name)) END,
      jsonb_build_object(
        'commentId',    cc.id,
        'snippet',      LEFT(cc.body, 140),
        'mentionedBy',  cc.created_by
      ),
      cc.id, NULL::TEXT,
      cc.created_at, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ,
      EXTRACT(DAY FROM (now() - cc.created_at))::INT,
      ('/app/contracts/' || cc.contract_id || '?comment=' || cc.id)
    FROM contract_comment cc
    INNER JOIN contract c  ON c.id  = cc.contract_id AND c.is_active = TRUE
    LEFT  JOIN party    cp ON cp.id = c.counterparty_id
    LEFT  JOIN "user"   au ON au.id = cc.created_by
    WHERE cc.is_active = TRUE
      AND cc.resolved_at IS NULL
      AND cc.created_at > now() - INTERVAL '30 days'
      AND p_actor_id = ANY(cc.mentioned_user_ids)
      AND cc.created_by <> p_actor_id

    UNION ALL

    -- ─── 7. signature_required ──────────────────────────────────────────
    SELECT
      (-6000000 - si.id), 'signature_required'::TEXT, 'open'::TEXT, 'high'::TEXT,
      si.contract_id, c.contract_number, c.title_en, c.title_ar,
      NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT,
      cp.name_en, NULL::BIGINT, 'System'::TEXT,
      jsonb_build_object(
        'invitationId', si.id,
        'signerSide',   sp.signer_side,
        'stepOrder',    sp.step_order,
        'sigStatus',    si.status
      ),
      NULL::BIGINT, NULL::TEXT,
      COALESCE(si.invitation_sent_at, si.created_at),
      NULL::TIMESTAMPTZ, si.invitation_expires_at,
      EXTRACT(DAY FROM (now() - COALESCE(si.invitation_sent_at, si.created_at)))::INT,
      ('/app/contracts/' || si.contract_id || '#sign')
    FROM signature_invitation si
    INNER JOIN signature_party sp ON sp.id = si.signature_party_id
    INNER JOIN contract        c  ON c.id  = si.contract_id AND c.is_active = TRUE
    LEFT  JOIN party           cp ON cp.id = c.counterparty_id
    WHERE si.is_active = TRUE
      AND sp.is_active = TRUE
      AND si.status IN ('pending','sent','viewed')
      AND sp.signer_user_id = p_actor_id
  ),

  filtered AS (
    SELECT *
    FROM all_rows
    WHERE (p_type   IS NULL OR work_item_type = ANY(p_type))
      AND (
        p_search IS NULL
        OR source_contract_number ILIKE '%' || p_search || '%'
        OR source_contract_title_en ILIKE '%' || p_search || '%'
        OR counterparty_name ILIKE '%' || p_search || '%'
      )
  ),

  totals AS (
    SELECT COUNT(*)::INT AS total_count,
           COUNT(*) FILTER (WHERE status IN ('open', 'in_progress'))::INT AS open_count
    FROM filtered
  ),

  paged AS (
    SELECT
      jsonb_build_object(
        'id',                       id,
        'workOrderType',            work_item_type,
        'status',                   status,
        'priority',                 priority,
        'sourceContractId',         source_contract_id,
        'sourceContractNumber',     source_contract_number,
        'sourceContractTitleEn',    source_contract_title_en,
        'sourceContractTitleAr',    source_contract_title_ar,
        'targetContractId',         target_contract_id,
        'targetContractNumber',     target_contract_number,
        'targetContractTitleEn',    target_contract_title_en,
        'targetContractTitleAr',    target_contract_title_ar,
        'targetContractStatus',     target_contract_status,
        'counterpartyName',         counterparty_name,
        'assignedByUserId',         assigned_by_user_id,
        'assignedByName',           assigned_by_name,
        'payload',                  COALESCE(payload, '{}'::jsonb),
        'relatedCommentId',         related_comment_id,
        'manualStage',              manual_stage,
        'createdAt',                created_at,
        'completedAt',              completed_at,
        'dueAt',                    due_at,
        'ageDays',                  age_days,
        'actionUrl',                action_url
      )                                                                AS row_obj,
      created_at                                                       AS ord_key
    FROM filtered
    ORDER BY created_at DESC NULLS LAST
    LIMIT p_limit OFFSET v_offset
  )

  SELECT
    (SELECT total_count FROM totals),
    (SELECT open_count  FROM totals),
    COALESCE((SELECT jsonb_agg(row_obj ORDER BY ord_key DESC) FROM paged), '[]'::jsonb)
  INTO v_total, v_open, v_data;

  RETURN jsonb_build_object(
    'data',       v_data,
    'totalCount', v_total,
    'openCount',  v_open,
    'page',       p_page,
    'pageSize',   p_limit,
    'totalPages', CASE WHEN p_limit > 0
                       THEN CEIL(v_total::DECIMAL / p_limit)
                       ELSE 0
                  END
  );
END;
$function$;

COMMENT ON FUNCTION public.fn_my_work_list_v2(BIGINT, TEXT[], TEXT[], TEXT, INTEGER, INTEGER) IS
  'mig 669 — advisory_draft branch surfaces drafts to template approver role '
  '(legacy) OR to whoever metadata.currentReviewer names (v2 review-path workflow). '
  'Dispatched drafts hidden. Risk_case branch unchanged (mig 666 logic intact).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (669, 'advisory_executive_review_path', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
