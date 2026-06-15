-- ============================================================================
-- Migration 682 — fix fn_my_work_list_v2: restore dropped column aliases
-- ============================================================================
-- WHY: mig 669 (advisory_executive_review_path) re-created fn_my_work_list_v2
-- and, collapsing the first SELECT of the all_rows UNION onto fewer lines,
-- silently dropped the column aliases on the work_order branch
-- (work_item_type, source_contract_number, source_contract_title_en, … ).
-- In a UNION the column names come from the FIRST select, so the downstream
-- filtered/totals/paged CTEs (which reference work_item_type,
-- source_contract_number, …) raised at RUNTIME:
--     column "work_item_type" does not exist        (42703)
--     column "source_contract_number" does not exist (42703)
-- CREATE OR REPLACE does not validate SQL inside plpgsql, so 669 applied but
-- GET /api/v1/my-work returned 500 for EVERY persona — a Legal Counsel could
-- not see an exec-approved advisory in My Work and was pushed to re-draft.
-- This restores the full aliased column list from mig 666 verbatim; the rest
-- of the body (advisory_draft review-path branch etc.) is the live 669 body.
-- Lesson (feedback_fn_rewrites_lose_safety_guards): diff fn rewrites against
-- the immediate predecessor — re-flowing a SELECT drops aliases silently.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_my_work_list_v2(p_actor_id bigint, p_status text[] DEFAULT NULL::text[], p_type text[] DEFAULT NULL::text[], p_search text DEFAULT NULL::text, p_page integer DEFAULT 1, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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
      wo.id                                          AS id,
      wo.work_order_type::TEXT                       AS work_item_type,
      wo.status::TEXT                                AS status,
      wo.priority::TEXT                              AS priority,
      wo.source_contract_id                          AS source_contract_id,
      sc.contract_number                             AS source_contract_number,
      sc.title_en                                    AS source_contract_title_en,
      sc.title_ar                                    AS source_contract_title_ar,
      wo.target_contract_id                          AS target_contract_id,
      tc.contract_number                             AS target_contract_number,
      tc.title_en                                    AS target_contract_title_en,
      tc.title_ar                                    AS target_contract_title_ar,
      tc.status::TEXT                                AS target_contract_status,
      COALESCE(cp_tgt.name_en, cp_src.name_en, cp_wo.name_en, wo.counterparty_prospect_name)
                                                     AS counterparty_name,
      wo.assigned_by_user_id                         AS assigned_by_user_id,
      CASE WHEN ab.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(ab.first_name, ' ', ab.last_name)) END AS assigned_by_name,
      wo.payload                                     AS payload,
      wo.related_comment_id                          AS related_comment_id,
      wo.manual_stage::TEXT                          AS manual_stage,
      wo.created_at                                  AS created_at,
      wo.completed_at                                AS completed_at,
      wo.due_at                                      AS due_at,
      EXTRACT(DAY FROM (now() - wo.created_at))::INT AS age_days,
      '/app/work'                                    AS action_url
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
$function$
;

-- S2-21 — keep EXECUTE off PUBLIC (CREATE OR REPLACE preserves ACL; be explicit).
REVOKE ALL ON FUNCTION public.fn_my_work_list_v2(BIGINT, TEXT[], TEXT[], TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_my_work_list_v2(BIGINT, TEXT[], TEXT[], TEXT, INTEGER, INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (682, 'fix_my_work_list_v2_restore_column_aliases', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
