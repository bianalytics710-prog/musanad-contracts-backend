-- MIGRATION: 685_lc_insights_dashboard.sql
-- Date: 2026-06-15
-- Module: LC Insights Dashboard
-- Description:
--   New fn_dashboard_legal_counsel_insights(p_actor_id BIGINT) RETURNS JSONB.
--   Replaces the cross-role noise (risk donut, regulatory updates, obligations,
--   open impacts) on the LC Insights page with metrics relevant to LC's actual
--   modules: advisory/notices, third-party review, risk cases, templates/clauses.
--
--   Does NOT modify fn_dashboard_legal_counsel — that function is kept intact
--   for the approvalQueue5 / avgReview12w / contractTypes / activityFeed widgets
--   which the FE continues to consume.
--
--   Schema notes (verified from DDL migrations):
--     advisory_draft   — approval_status ('unapproved'|'approved'|'rejected'|'modified'),
--                        dispatched_at TIMESTAMPTZ, is_active BOOLEAN, tenant_id UUID,
--                        template_context JSONB ('currentReviewer', 'reviewPath')
--     tpa_review       — status ('pending_analysis'|'analyzing'|'awaiting_review'|
--                        'reviewed'|'redline_sent'|'closed_accepted'|'closed_rejected'|'failed'),
--                        is_active BOOLEAN, tenant_id UUID
--     risk_case        — assigned_user_id BIGINT, status ('open'|'in_review'|...),
--                        title TEXT, case_type TEXT, priority TEXT, is_active BOOLEAN,
--                        tenant_id UUID
--     contract_template — is_active BOOLEAN (no tenant_id — global catalog)
--     contract_clause   — variant ('standard'|'alternative'|'fallback'), is_active BOOLEAN
--                         (no status column; variant='standard' is the "approved" proxy)
--     approval_step     — approver_role TEXT, status TEXT, approval_chain_id BIGINT,
--                         is_active BOOLEAN

BEGIN;

CREATE OR REPLACE FUNCTION fn_dashboard_legal_counsel_insights(
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id   UUID;
  v_role        TEXT;
  v_kpis        JSONB;
  v_advisory    JSONB;
  v_tpa         JSONB;
  v_template_clause JSONB;
  v_risk_cases  JSONB;
BEGIN
  -- ── Tenant context ──────────────────────────────────────────────────────
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel_insights: tenant context not set'
      USING ERRCODE = '22023';
  END IF;

  -- ── Actor identity + role gate ──────────────────────────────────────────
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel_insights: unauthorized'
      USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u
  JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id
    AND u.is_active = TRUE
    AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('legal_counsel', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION
      'fn_dashboard_legal_counsel_insights: forbidden — restricted to legal_counsel, platform_admin, Super Admin'
      USING ERRCODE = '42501';
  END IF;

  -- ── KPIs ────────────────────────────────────────────────────────────────
  -- contractsPendingMyReview: reuse fn_dashboard_legal_counsel pendingReview
  --   subquery exactly (approval_step where approver_role='legal_counsel' AND
  --   status='pending'; joined to active chain + active contract).
  -- advisoriesInProgress: active advisory_drafts not yet dispatched
  -- tpaReviewsAwaitingMe: active tpa_review in the "still needs work" statuses
  -- myOpenRiskCases: risk_case assigned to p_actor_id in open/in_review
  SELECT jsonb_build_object(
    'contractsPendingMyReview',
      (SELECT COUNT(*)
         FROM approval_step s
         JOIN approval_chain ch ON ch.id = s.approval_chain_id
         JOIN contract c ON c.id = ch.contract_id
        WHERE s.status = 'pending'
          AND s.approver_role = 'legal_counsel'
          AND ch.is_active = TRUE
          AND s.is_active = TRUE
          AND c.is_active = TRUE),

    'advisoriesInProgress',
      (SELECT COUNT(*)
         FROM advisory_draft
        WHERE is_active = TRUE
          AND tenant_id = v_tenant_id
          AND dispatched_at IS NULL),

    'tpaReviewsAwaitingMe',
      (SELECT COUNT(*)
         FROM tpa_review
        WHERE is_active = TRUE
          AND tenant_id = v_tenant_id
          AND status IN ('pending_analysis', 'analyzing', 'awaiting_review')),

    'myOpenRiskCases',
      (SELECT COUNT(*)
         FROM risk_case
        WHERE is_active = TRUE
          AND tenant_id = v_tenant_id
          AND assigned_user_id = p_actor_id
          AND status IN ('open', 'in_review'))
  ) INTO v_kpis;

  -- ── Advisory pipeline ────────────────────────────────────────────────────
  -- 4 stage counts:
  --   draft        = is_active, not dispatched, approval_status='unapproved',
  --                  currentReviewer IS NULL (no reviewer set yet)
  --   inExecReview = is_active, not dispatched, currentReviewer='executive'
  --   approvedReady= is_active, not dispatched, approval_status='approved',
  --                  currentReviewer='legal_counsel'
  --   sentThisMonth= is_active, dispatched_at in current calendar month
  SELECT jsonb_build_object(
    'draft',
      (SELECT COUNT(*)
         FROM advisory_draft
        WHERE is_active = TRUE
          AND tenant_id = v_tenant_id
          AND dispatched_at IS NULL
          AND approval_status = 'unapproved'
          AND (template_context ->> 'currentReviewer') IS NULL),

    'inExecReview',
      (SELECT COUNT(*)
         FROM advisory_draft
        WHERE is_active = TRUE
          AND tenant_id = v_tenant_id
          AND dispatched_at IS NULL
          AND (template_context ->> 'currentReviewer') = 'executive'),

    'approvedReady',
      (SELECT COUNT(*)
         FROM advisory_draft
        WHERE is_active = TRUE
          AND tenant_id = v_tenant_id
          AND approval_status = 'approved'
          AND (template_context ->> 'currentReviewer') = 'legal_counsel'
          AND dispatched_at IS NULL),

    'sentThisMonth',
      (SELECT COUNT(*)
         FROM advisory_draft
        WHERE is_active = TRUE
          AND tenant_id = v_tenant_id
          AND dispatched_at >= date_trunc('month', now()))
  ) INTO v_advisory;

  -- ── TPA pipeline (GROUP BY status, avoid nested agg via subquery) ────────
  SELECT COALESCE(
    (
      SELECT jsonb_agg(jsonb_build_object('status', status, 'count', cnt)
                       ORDER BY cnt DESC)
        FROM (
          SELECT status, COUNT(*) AS cnt
            FROM tpa_review
           WHERE is_active = TRUE
             AND tenant_id = v_tenant_id
           GROUP BY status
        ) s
    ),
    '[]'::jsonb
  ) INTO v_tpa;

  -- ── Template & clause library ────────────────────────────────────────────
  -- contract_template has no tenant_id — it's a global catalog.
  -- contract_clause has no status column; variant='standard' is the
  -- "canonical / approved" clause proxy.
  SELECT jsonb_build_object(
    'templateCount',
      (SELECT COUNT(*) FROM contract_template WHERE is_active = TRUE),

    'clauseCount',
      (SELECT COUNT(*) FROM contract_clause WHERE is_active = TRUE),

    'approvedClauseCount',
      (SELECT COUNT(*) FROM contract_clause WHERE is_active = TRUE AND variant = 'standard')
  ) INTO v_template_clause;

  -- ── My risk cases (LIMIT 6, avoid nested agg via subquery) ──────────────
  SELECT COALESCE(
    (
      SELECT jsonb_agg(
               jsonb_build_object(
                 'id',       rc.id,
                 'title',    rc.title,
                 'caseType', rc.case_type,
                 'status',   rc.status,
                 'priority', rc.priority
               )
               ORDER BY rc.created_at DESC
             )
        FROM (
          SELECT id, title, case_type, status, priority, created_at
            FROM risk_case
           WHERE is_active = TRUE
             AND tenant_id = v_tenant_id
             AND assigned_user_id = p_actor_id
             AND status IN ('open', 'in_review')
           ORDER BY created_at DESC
           LIMIT 6
        ) rc
    ),
    '[]'::jsonb
  ) INTO v_risk_cases;

  -- ── Compose ──────────────────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'kpis',           v_kpis,
    'advisoryPipeline', v_advisory,
    'tpaPipeline',    v_tpa,
    'templateClause', v_template_clause,
    'myRiskCases',    v_risk_cases
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel_insights: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_dashboard_legal_counsel_insights(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_legal_counsel_insights(BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_dashboard_legal_counsel_insights(BIGINT) IS
  'LC Insights dashboard sidecar (mig 685). Returns KPIs + advisoryPipeline + tpaPipeline + templateClause + myRiskCases relevant to legal_counsel''s own modules. Does not modify fn_dashboard_legal_counsel.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (685, '685_lc_insights_dashboard', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
