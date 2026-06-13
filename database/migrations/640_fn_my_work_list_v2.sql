-- ============================================================================
-- Migration 640 — fn_my_work_list_v2 (Phase A of Persona+Risk My Work)
-- ============================================================================
--
-- WHY: Today /api/v1/work-orders only surfaces work_order rows (draft-request /
-- returned / comment-response). Drafter has a unified inbox; Legal Counsel and
-- Contract Approver don't. Their pending approvals, assigned risk cases, TPA
-- reviews and advisory drafts each live behind separate pages, leaving them
-- without a single "what do I owe?" view.
--
-- WHAT: A new STABLE SECURITY DEFINER function that returns one envelope
-- matching the existing /work-orders shape, UNION-ing 5 sources:
--   1. work_order            — existing materialized rows for the actor
--   2. approval_step         — pending steps where actor is the approver
--   3. risk_case             — open/in_review cases assigned to actor
--   4. tpa_review            — awaiting-review TPAs (legal_counsel role)
--   5. advisory_draft        — unapproved drafts (template's approver role)
--
-- HOW it stays clean:
--   - No fan-out triggers; source tables remain authoritative.
--   - Synthetic ids are negative integer offsets per source so they never
--     collide with real work_order.id values. The action_url field tells the
--     FE where to navigate; the synthetic id is only used as a React key.
--   - Same camelCase envelope ({data, totalCount, openCount, page, pageSize,
--     totalPages}) so the existing FE service can consume both endpoints
--     interchangeably.
--   - Drafter path (/api/v1/work-orders) is unchanged. This function powers a
--     new endpoint that Legal Counsel and Approver use; we'll migrate other
--     personas onto it in later phases.
--
-- RBAC: SECURITY DEFINER, filters by p_actor_id. Tenant isolation flows
-- through the underlying tables' RLS policies (no GUC override needed — the
-- caller is the actor and the role check uses the user's assigned role).
-- ============================================================================

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

  -- Resolve actor's role(s). One role per user in this model, but we accept
  -- arrays to mirror fn_approval_my_pending's shape so future multi-role
  -- support drops in cleanly.
  SELECT ARRAY[r.name]
    INTO v_roles
    FROM "user" u
    INNER JOIN role r ON r.id = u.role_id
    WHERE u.id = p_actor_id
      AND u.is_active = TRUE;
  IF v_roles IS NULL THEN
    v_roles := ARRAY[]::TEXT[];
  END IF;

  -- Build the unified row set in one CTE chain so we can compute totals AND
  -- the paged data slice from the same materialisation.
  WITH all_rows AS (

    -- ─── 1. Existing work_order rows (materialised) ──────────────────────
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
      -- counterparty resolution: target contract → source contract → party
      -- linked from work_order itself → prospect name stored on work_order.
      COALESCE(cp_tgt.name_en, cp_src.name_en, cp_wo.name_en, wo.counterparty_prospect_name)
                                                     AS counterparty_name,
      wo.assigned_by_user_id                         AS assigned_by_user_id,
      CASE
        WHEN ab.id IS NULL THEN NULL
        ELSE TRIM(CONCAT(ab.first_name, ' ', ab.last_name))
      END                                            AS assigned_by_name,
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

    -- ─── 2. Approval steps pending (approval_awaiting) ───────────────────
    SELECT
      (-1000000 - s.id)                              AS id,
      'approval_awaiting'::TEXT                      AS work_item_type,
      'open'::TEXT                                   AS status,
      'normal'::TEXT                                 AS priority,
      c.id                                           AS source_contract_id,
      c.contract_number                              AS source_contract_number,
      c.title_en                                     AS source_contract_title_en,
      c.title_ar                                     AS source_contract_title_ar,
      NULL::BIGINT                                   AS target_contract_id,
      NULL::TEXT                                     AS target_contract_number,
      NULL::TEXT                                     AS target_contract_title_en,
      NULL::TEXT                                     AS target_contract_title_ar,
      NULL::TEXT                                     AS target_contract_status,
      NULL::TEXT                                     AS counterparty_name,
      ch.initiated_by                                AS assigned_by_user_id,
      CASE WHEN ib.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(ib.first_name, ' ', ib.last_name)) END AS assigned_by_name,
      jsonb_build_object(
        'stepId',       s.id,
        'chainId',      ch.id,
        'stepOrder',    s.step_order,
        'approverRole', s.approver_role
      )                                              AS payload,
      NULL::BIGINT                                   AS related_comment_id,
      NULL::TEXT                                     AS manual_stage,
      s.created_at                                   AS created_at,
      NULL::TIMESTAMPTZ                              AS completed_at,
      NULL::TIMESTAMPTZ                              AS due_at,
      EXTRACT(DAY FROM (now() - s.created_at))::INT  AS age_days,
      '/app/approvals'                               AS action_url
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

    -- ─── 3. Risk cases assigned (risk_case_assigned) ─────────────────────
    SELECT
      (-2000000 - rc.id)                             AS id,
      'risk_case_assigned'::TEXT                     AS work_item_type,
      CASE rc.status
        WHEN 'in_review' THEN 'in_progress'
        ELSE 'open'
      END::TEXT                                      AS status,
      COALESCE(rc.priority, 'normal')::TEXT          AS priority,
      rc.contract_id                                 AS source_contract_id,
      c.contract_number                              AS source_contract_number,
      c.title_en                                     AS source_contract_title_en,
      c.title_ar                                     AS source_contract_title_ar,
      NULL::BIGINT                                   AS target_contract_id,
      NULL::TEXT                                     AS target_contract_number,
      NULL::TEXT                                     AS target_contract_title_en,
      NULL::TEXT                                     AS target_contract_title_ar,
      NULL::TEXT                                     AS target_contract_status,
      NULL::TEXT                                     AS counterparty_name,
      rc.created_by                                  AS assigned_by_user_id,
      CASE WHEN cb.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(cb.first_name, ' ', cb.last_name)) END AS assigned_by_name,
      jsonb_build_object(
        'riskCaseId', rc.id,
        'caseType',   rc.case_type,
        'title',      rc.title
      )                                              AS payload,
      NULL::BIGINT                                   AS related_comment_id,
      NULL::TEXT                                     AS manual_stage,
      rc.created_at                                  AS created_at,
      NULL::TIMESTAMPTZ                              AS completed_at,
      rc.due_at                                      AS due_at,
      EXTRACT(DAY FROM (now() - rc.created_at))::INT AS age_days,
      ('/app/risk-cases/' || rc.id)                  AS action_url
    FROM risk_case rc
    LEFT JOIN contract c  ON c.id  = rc.contract_id
    LEFT JOIN "user"   cb ON cb.id = rc.created_by
    WHERE rc.is_active = TRUE
      AND rc.assigned_user_id = p_actor_id
      AND rc.status IN ('open', 'in_review')

    UNION ALL

    -- ─── 4. TPA reviews (third_party_review) ─────────────────────────────
    -- Surface awaiting-review TPAs to any user with the legal_counsel role.
    -- No per-user assignment field exists today; the queue is role-scoped.
    SELECT
      (-3000000 - tpa.id)                            AS id,
      'third_party_review'::TEXT                     AS work_item_type,
      'open'::TEXT                                   AS status,
      CASE tpa.overall_risk
        WHEN 'critical' THEN 'urgent'
        WHEN 'high'     THEN 'high'
        WHEN 'medium'   THEN 'normal'
        ELSE 'low'
      END::TEXT                                      AS priority,
      NULL::BIGINT                                   AS source_contract_id,
      tpa.reference_code                             AS source_contract_number,
      tpa.agreement_title                            AS source_contract_title_en,
      NULL::TEXT                                     AS source_contract_title_ar,
      NULL::BIGINT                                   AS target_contract_id,
      NULL::TEXT                                     AS target_contract_number,
      NULL::TEXT                                     AS target_contract_title_en,
      NULL::TEXT                                     AS target_contract_title_ar,
      NULL::TEXT                                     AS target_contract_status,
      tpa.counterparty_name                          AS counterparty_name,
      tpa.created_by                                 AS assigned_by_user_id,
      CASE WHEN cb.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(cb.first_name, ' ', cb.last_name)) END AS assigned_by_name,
      jsonb_build_object(
        'tpaReviewId',     tpa.id,
        'agreementType',   tpa.agreement_type,
        'overallVerdict',  tpa.overall_verdict,
        'overallRisk',     tpa.overall_risk
      )                                              AS payload,
      NULL::BIGINT                                   AS related_comment_id,
      NULL::TEXT                                     AS manual_stage,
      tpa.created_at                                 AS created_at,
      NULL::TIMESTAMPTZ                              AS completed_at,
      NULL::TIMESTAMPTZ                              AS due_at,
      EXTRACT(DAY FROM (now() - tpa.created_at))::INT AS age_days,
      ('/app/legal/third-party-review/' || tpa.id)   AS action_url
    FROM tpa_review tpa
    LEFT JOIN "user" cb ON cb.id = tpa.created_by
    WHERE tpa.is_active = TRUE
      AND tpa.status IN ('awaiting_review', 'pending_analysis')
      AND 'legal_counsel' = ANY(v_roles)

    UNION ALL

    -- ─── 5. Advisory drafts (advisory_draft) ─────────────────────────────
    -- Drafts are unapproved + the template's assigned_approver_role matches
    -- the actor's role. Templates without an approver role fall back to the
    -- legal_counsel queue (mirrors today's Advisory Queue UI).
    SELECT
      (-4000000 - ad.id)                             AS id,
      'advisory_draft'::TEXT                         AS work_item_type,
      'open'::TEXT                                   AS status,
      'normal'::TEXT                                 AS priority,
      ad.contract_id                                 AS source_contract_id,
      c.contract_number                              AS source_contract_number,
      c.title_en                                     AS source_contract_title_en,
      c.title_ar                                     AS source_contract_title_ar,
      NULL::BIGINT                                   AS target_contract_id,
      NULL::TEXT                                     AS target_contract_number,
      NULL::TEXT                                     AS target_contract_title_en,
      NULL::TEXT                                     AS target_contract_title_ar,
      NULL::TEXT                                     AS target_contract_status,
      NULL::TEXT                                     AS counterparty_name,
      ad.created_by                                  AS assigned_by_user_id,
      CASE WHEN cb.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(cb.first_name, ' ', cb.last_name)) END AS assigned_by_name,
      jsonb_build_object(
        'advisoryDraftId', ad.id,
        'draftType',       ad.draft_type,
        'templateId',      ad.template_id
      )                                              AS payload,
      NULL::BIGINT                                   AS related_comment_id,
      NULL::TEXT                                     AS manual_stage,
      ad.created_at                                  AS created_at,
      NULL::TIMESTAMPTZ                              AS completed_at,
      NULL::TIMESTAMPTZ                              AS due_at,
      EXTRACT(DAY FROM (now() - ad.created_at))::INT AS age_days,
      ('/app/legal/advisory-queue/' || ad.id)        AS action_url
    FROM advisory_draft ad
    INNER JOIN advisory_template at ON at.id = ad.template_id
    LEFT  JOIN contract           c  ON c.id  = ad.contract_id
    LEFT  JOIN "user"             cb ON cb.id = ad.created_by
    WHERE ad.is_active = TRUE
      AND ad.approval_status = 'unapproved'
      AND COALESCE(at.assigned_approver_role, 'legal_counsel') = ANY(v_roles)
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
    SELECT
      COUNT(*)                                                         AS total_count,
      COUNT(*) FILTER (WHERE status IN ('open', 'in_progress'))         AS open_count
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

REVOKE EXECUTE ON FUNCTION public.fn_my_work_list_v2(
  BIGINT, TEXT[], TEXT[], TEXT, INTEGER, INTEGER
) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_my_work_list_v2(
  BIGINT, TEXT[], TEXT[], TEXT, INTEGER, INTEGER
) TO neondb_owner;

COMMENT ON FUNCTION public.fn_my_work_list_v2(BIGINT, TEXT[], TEXT[], TEXT, INTEGER, INTEGER) IS
  'Phase A (mig 640, 2026-06-13) — Persona-aware My Work UNION. Returns one '
  'envelope across work_order + approval_step + risk_case + tpa_review + '
  'advisory_draft, matching the existing /work-orders FE shape so Legal '
  'Counsel and Contract Approver can use a single inbox.';
