-- ============================================================================
-- Migration 666 — risk_case branch of fn_my_work_list_v2 reads ASSIGNMENT
--                 metadata for From + Created (not original creation metadata)
-- ============================================================================
-- WHY: the unified inbox renders two columns from each UNION branch's
-- SELECT projection:
--   - "From"    ← assigned_by_user_id + assigned_by_name
--   - "Created" ← created_at
--
-- For 6 of the 7 branches (work_order / approval_step / tpa_review /
-- advisory_draft / comment_mention / signature_required) the record's
-- creation moment IS the routing-to-receiver moment, so source.created_by
-- / source.created_at are the correct values to show.
--
-- For risk_case alone, creation and assignment are separate events. A
-- correlation auto-creates the case (often with created_by=NULL), it
-- sits in Tier-2 for days/weeks, then the executive promotes it to a
-- person — possibly across roles. Reading rc.created_by / rc.created_at
-- here produces:
--   - From    = NULL → renders as "—"
--   - Created = the original case-creation date (often weeks stale)
-- when the receiver actually wants:
--   - From    = the executive who routed it to them
--   - Created = when that routing happened
--
-- WHAT: rewrite ONLY the risk_case UNION branch to use metadata.promotedBy
-- / metadata.promotedFromTier2At (or metadata.lastReassignedBy /
-- metadata.lastReassignedAt if the case was later reassigned). Falls back
-- to rc.created_by / rc.created_at when neither marker is present
-- (manually-created cases where creation = assignment).
--
-- The age_days calculation and the ORDER BY sort key now operate on the
-- same assignment timestamp, so freshly-routed cases sit at the top of
-- the receiver's inbox — which is what they want.
--
-- The other 6 UNION branches are untouched.
--
-- PRINCIPLE codified for future maintainers (see header comment): every
-- branch's From + Created columns must reflect the moment the work was
-- routed to the receiver, not the moment the underlying record came into
-- existence. For records where those moments coincide, source.created_by/
-- _at is fine. For records where they diverge, use the routing-event
-- metadata.
-- ============================================================================

BEGIN;

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

    -- ─── 1. work_order ─────────────────────────────────────────────────
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

    -- ─── 2. approval_step ─────────────────────────────────────────────
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

    -- ─── 3. risk_case (mig 666 — From + Created use assignment metadata)
    --
    -- The receiver's view of a risk case is shaped by the executive's
    -- assignment, not the engine's original creation. So:
    --   From    = COALESCE(lastReassignedBy, promotedBy, created_by)
    --   Created = COALESCE(lastReassignedAt, promotedFromTier2At, created_at)
    --   ageDays uses the same expression so "days since I got it" is the
    --   meaningful age, not "days since the case existed somewhere".
    -- Fallback to rc.created_by / rc.created_at covers manual-create
    -- cases where the assignment moment == creation moment.
    SELECT
      (-2000000 - rc.id)                             AS id,
      'risk_case_assigned'::TEXT                     AS work_item_type,
      CASE rc.status WHEN 'in_review' THEN 'in_progress' ELSE 'open' END,
      CASE
        WHEN (rc.metadata ? 'tier2AutoEscalatedAt')
          OR (rc.metadata ? 'autoEscalatedAt')
          OR ((rc.metadata->>'autoEscalated')::boolean IS TRUE)
        THEN 'urgent'
        ELSE COALESCE(rc.priority, 'normal')::TEXT
      END                                            AS priority,
      rc.contract_id, c.contract_number, c.title_en, c.title_ar,
      NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT,
      NULL::TEXT                                     AS counterparty_name,
      COALESCE(
        (rc.metadata->>'lastReassignedBy')::bigint,
        (rc.metadata->>'promotedBy')::bigint,
        rc.created_by
      )                                              AS assigned_by_user_id,
      CASE
        WHEN actor.id IS NULL THEN NULL
        ELSE TRIM(CONCAT(actor.first_name, ' ', actor.last_name))
      END                                            AS assigned_by_name,
      jsonb_build_object(
        'riskCaseId',  rc.id,
        'caseType',    rc.case_type,
        'title',       rc.title,
        'autoEscalated', COALESCE(
                          (rc.metadata->>'autoEscalated')::boolean,
                          rc.metadata ? 'tier2AutoEscalatedAt'
                                OR rc.metadata ? 'autoEscalatedAt'
                        )
      )                                              AS payload,
      NULL::BIGINT, NULL::TEXT,
      COALESCE(
        (rc.metadata->>'lastReassignedAt')::timestamptz,
        (rc.metadata->>'promotedFromTier2At')::timestamptz,
        rc.created_at
      )                                              AS created_at,
      NULL::TIMESTAMPTZ, rc.due_at,
      EXTRACT(DAY FROM (now() - COALESCE(
        (rc.metadata->>'lastReassignedAt')::timestamptz,
        (rc.metadata->>'promotedFromTier2At')::timestamptz,
        rc.created_at
      )))::INT                                       AS age_days,
      ('/app/risk-cases/' || rc.id)                  AS action_url
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

    -- ─── 4. tpa_review ─────────────────────────────────────────────────
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

    -- ─── 5. advisory_draft ────────────────────────────────────────────
    SELECT
      (-4000000 - ad.id), 'advisory_draft'::TEXT, 'open'::TEXT, 'normal'::TEXT,
      ad.contract_id, c.contract_number, c.title_en, c.title_ar,
      NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT,
      NULL::TEXT, ad.created_by,
      CASE WHEN cb.id IS NULL THEN NULL
           ELSE TRIM(CONCAT(cb.first_name, ' ', cb.last_name)) END,
      jsonb_build_object('advisoryDraftId', ad.id,
                         'draftType', ad.draft_type,
                         'templateId', ad.template_id),
      NULL::BIGINT, NULL::TEXT,
      ad.created_at, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ,
      EXTRACT(DAY FROM (now() - ad.created_at))::INT,
      ('/app/legal/advisory-queue/' || ad.id)
    FROM advisory_draft ad
    INNER JOIN advisory_template at ON at.id = ad.template_id
    LEFT  JOIN contract           c  ON c.id  = ad.contract_id
    LEFT  JOIN "user"             cb ON cb.id = ad.created_by
    WHERE ad.is_active = TRUE
      AND ad.approval_status = 'unapproved'
      AND COALESCE(at.assigned_approver_role, 'legal_counsel') = ANY(v_roles)

    UNION ALL

    -- ─── 6. comment_mention ────────────────────────────────────────────
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

    -- ─── 7. signature_required ────────────────────────────────────────
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
  'mig 666 — codified principle: From + Created always reflect the moment the '
  'work was routed to the receiver, not the moment the underlying record was '
  'first created. For risk_case (where the two moments diverge), reads '
  'metadata.promotedBy / promotedFromTier2At (or lastReassignedBy / '
  'lastReassignedAt). For the other 6 branches creation == assignment so '
  'source.created_by / created_at remain correct.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (666, 'fn_my_work_list_v2_risk_from_assignment', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
