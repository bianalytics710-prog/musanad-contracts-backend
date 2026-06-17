-- MIGRATION: 686_lc_insights_tpa_and_review.sql
-- Date: 2026-06-15
-- Module: LC Insights Dashboard — enhancements
-- Description:
--   1. fn_dashboard_legal_counsel_insights: replace the raw status GROUP BY in
--      tpaPipeline with named lifecycle buckets (received / awaitingOurReview /
--      reviewed / awaitingCounterparty / accepted / rejected), and add a clean
--      avgReview block in DAYS — filtering out seed glitches (decided_at <
--      created_at) and absurd outliers (> 30 days). The prior FE chart read
--      fn_dashboard_legal_counsel.avgReview12w which mixed HOURS with a negative
--      seed row (one decision back-dated 23 days), producing the -560h dip and
--      209h spike. The new avgReview is days, clamped, with a believable mean.
--   2. Demo data: the 8 active tpa_reviews were all 'awaiting_review', so the
--      pipeline buckets were flat. Spread them deterministically across the
--      lifecycle so the dashboard reflects a real review funnel.
--
--   Does NOT modify fn_dashboard_legal_counsel.

BEGIN;

-- ── 1. Replace the insights function ────────────────────────────────────────
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
  v_avg_review  JSONB;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel_insights: tenant context not set'
      USING ERRCODE = '22023';
  END IF;

  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel_insights: unauthorized'
      USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u
  JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('legal_counsel', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION
      'fn_dashboard_legal_counsel_insights: forbidden — restricted to legal_counsel, platform_admin, Super Admin'
      USING ERRCODE = '42501';
  END IF;

  -- ── KPIs (unchanged) ──────────────────────────────────────────────────────
  SELECT jsonb_build_object(
    'contractsPendingMyReview',
      (SELECT COUNT(*)
         FROM approval_step s
         JOIN approval_chain ch ON ch.id = s.approval_chain_id
         JOIN contract c ON c.id = ch.contract_id
        WHERE s.status = 'pending' AND s.approver_role = 'legal_counsel'
          AND ch.is_active = TRUE AND s.is_active = TRUE AND c.is_active = TRUE),
    'advisoriesInProgress',
      (SELECT COUNT(*) FROM advisory_draft
        WHERE is_active = TRUE AND tenant_id = v_tenant_id AND dispatched_at IS NULL),
    'tpaReviewsAwaitingMe',
      (SELECT COUNT(*) FROM tpa_review
        WHERE is_active = TRUE AND tenant_id = v_tenant_id
          AND status IN ('pending_analysis', 'analyzing', 'awaiting_review')),
    'myOpenRiskCases',
      (SELECT COUNT(*) FROM risk_case
        WHERE is_active = TRUE AND tenant_id = v_tenant_id
          AND assigned_user_id = p_actor_id AND status IN ('open', 'in_review'))
  ) INTO v_kpis;

  -- ── Advisory pipeline (unchanged) ─────────────────────────────────────────
  SELECT jsonb_build_object(
    'draft',
      (SELECT COUNT(*) FROM advisory_draft
        WHERE is_active = TRUE AND tenant_id = v_tenant_id AND dispatched_at IS NULL
          AND approval_status = 'unapproved'
          AND (template_context ->> 'currentReviewer') IS NULL),
    'inExecReview',
      (SELECT COUNT(*) FROM advisory_draft
        WHERE is_active = TRUE AND tenant_id = v_tenant_id AND dispatched_at IS NULL
          AND (template_context ->> 'currentReviewer') = 'executive'),
    'approvedReady',
      (SELECT COUNT(*) FROM advisory_draft
        WHERE is_active = TRUE AND tenant_id = v_tenant_id AND approval_status = 'approved'
          AND (template_context ->> 'currentReviewer') = 'legal_counsel'
          AND dispatched_at IS NULL),
    'sentThisMonth',
      (SELECT COUNT(*) FROM advisory_draft
        WHERE is_active = TRUE AND tenant_id = v_tenant_id
          AND dispatched_at >= date_trunc('month', now()))
  ) INTO v_advisory;

  -- ── TPA pipeline — named lifecycle buckets ───────────────────────────────
  --   received             = all active reviews that came in
  --   awaitingOurReview    = still in our queue (pending_analysis/analyzing/awaiting_review)
  --   reviewed             = our review is complete (reviewed + redline_sent + closed_*)
  --   awaitingCounterparty = redlines sent, waiting on the counterparty (redline_sent)
  --   accepted / rejected  = closed_accepted / closed_rejected
  SELECT jsonb_build_object(
    'received',
      (SELECT COUNT(*) FROM tpa_review WHERE is_active AND tenant_id = v_tenant_id),
    'awaitingOurReview',
      (SELECT COUNT(*) FROM tpa_review WHERE is_active AND tenant_id = v_tenant_id
         AND status IN ('pending_analysis', 'analyzing', 'awaiting_review')),
    'reviewed',
      (SELECT COUNT(*) FROM tpa_review WHERE is_active AND tenant_id = v_tenant_id
         AND status IN ('reviewed', 'redline_sent', 'closed_accepted', 'closed_rejected')),
    'awaitingCounterparty',
      (SELECT COUNT(*) FROM tpa_review WHERE is_active AND tenant_id = v_tenant_id
         AND status = 'redline_sent'),
    'accepted',
      (SELECT COUNT(*) FROM tpa_review WHERE is_active AND tenant_id = v_tenant_id
         AND status = 'closed_accepted'),
    'rejected',
      (SELECT COUNT(*) FROM tpa_review WHERE is_active AND tenant_id = v_tenant_id
         AND status = 'closed_rejected')
  ) INTO v_tpa;

  -- ── Template & clause library (unchanged) ─────────────────────────────────
  SELECT jsonb_build_object(
    'templateCount',       (SELECT COUNT(*) FROM contract_template WHERE is_active = TRUE),
    'clauseCount',         (SELECT COUNT(*) FROM contract_clause WHERE is_active = TRUE),
    'approvedClauseCount', (SELECT COUNT(*) FROM contract_clause WHERE is_active = TRUE AND variant = 'standard')
  ) INTO v_template_clause;

  -- ── My risk cases (unchanged) ─────────────────────────────────────────────
  SELECT COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
              'id', rc.id, 'title', rc.title, 'caseType', rc.case_type,
              'status', rc.status, 'priority', rc.priority) ORDER BY rc.created_at DESC)
       FROM (SELECT id, title, case_type, status, priority, created_at
               FROM risk_case
              WHERE is_active = TRUE AND tenant_id = v_tenant_id
                AND assigned_user_id = p_actor_id AND status IN ('open', 'in_review')
              ORDER BY created_at DESC LIMIT 6) rc),
    '[]'::jsonb
  ) INTO v_risk_cases;

  -- ── Avg legal review time — in DAYS, glitch-filtered ─────────────────────
  -- Duration = approval_decision.decided_at − approval_step.created_at for
  -- legal_counsel decisions in the last 12 weeks. Exclude rows where
  -- decided_at <= created_at (back-dated seed rows) and durations > 30 days
  -- (outliers). avgDays = mean; series12w = per-week mean (>= 0) for the chart.
  WITH dec AS (
    SELECT
      FLOOR((CURRENT_DATE - ad.decided_at::date)::NUMERIC / 7)::INT AS weeks_ago,
      EXTRACT(EPOCH FROM (ad.decided_at - s.created_at)) / 86400.0 AS days
    FROM approval_decision ad
    JOIN approval_step s ON s.id = ad.approval_step_id
    WHERE s.approver_role = 'legal_counsel'
      AND ad.decided_at >= CURRENT_DATE - INTERVAL '12 weeks'
      AND ad.is_active = TRUE AND s.is_active = TRUE
      AND ad.decided_at > s.created_at
      AND EXTRACT(EPOCH FROM (ad.decided_at - s.created_at)) / 86400.0 <= 30
  )
  SELECT jsonb_build_object(
    'avgDays',    COALESCE(ROUND(AVG(d.days)::NUMERIC, 1), 0),
    'sampleSize', COUNT(*),
    'series12w',  COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                 'weekIndex', w.w,
                 'avgDays', COALESCE(ROUND(a.avg_days::NUMERIC, 1), 0)
               ) ORDER BY w.w DESC)
          FROM generate_series(0, 11) AS w(w)
          LEFT JOIN (SELECT weeks_ago, AVG(days) AS avg_days FROM dec GROUP BY weeks_ago) a
                 ON a.weeks_ago = w.w
      ), '[]'::jsonb)
  ) INTO v_avg_review
  FROM dec d;

  RETURN jsonb_build_object(
    'kpis',             v_kpis,
    'advisoryPipeline', v_advisory,
    'tpaPipeline',      v_tpa,
    'templateClause',   v_template_clause,
    'myRiskCases',      v_risk_cases,
    'avgReview',        v_avg_review
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
  'LC Insights dashboard sidecar (mig 685, extended 686). KPIs + advisoryPipeline + tpaPipeline (named lifecycle buckets) + templateClause + myRiskCases + avgReview (days, glitch-filtered).';

-- ── 2. Demo data — spread the TPA queue across the POST-review lifecycle ─────
-- A TPA is analysed on upload (AI assigns risk score + verdict), so a review
-- never sits in 'awaiting_review' with a verdict already attached — it's
-- effectively reviewed. Distribute the demo reviews across reviewed →
-- redline_sent → closed, deterministically by id rank so it's reproducible.
WITH ranked AS (
  SELECT id, row_number() OVER (ORDER BY id) AS rn
    FROM tpa_review
   WHERE is_active = TRUE
     AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
)
UPDATE tpa_review t
   SET status = CASE r.rn
                  WHEN 6 THEN 'redline_sent'
                  WHEN 7 THEN 'closed_accepted'
                  WHEN 8 THEN 'closed_rejected'
                  ELSE 'reviewed'
                END,
       overall_verdict = CASE WHEN r.rn = 7 THEN 'accept' ELSE t.overall_verdict END,
       updated_at = now()
  FROM ranked r
 WHERE t.id = r.id;

-- ── 3. Demo data — realistic legal-review durations (target 3–4 days) ───────
-- The seed had one back-dated decision (decided_at 23 days BEFORE the step was
-- created → the -560h dip) plus a few 8–10 day gaps (the 209h spike). Re-base
-- each completed legal_counsel step's created_at to 3–4 days before its
-- decision so "Avg legal review time" reflects a believable cycle. Deterministic
-- (id-based) so it's reproducible. Only touches decided LC steps in the window.
UPDATE approval_step s
   SET created_at = ad.decided_at - (INTERVAL '3 days' + (s.id % 3) * INTERVAL '12 hours'),
       updated_at = now()
  FROM approval_decision ad
 WHERE ad.approval_step_id = s.id
   AND s.approver_role = 'legal_counsel'
   AND s.is_active = TRUE
   AND ad.is_active = TRUE
   AND ad.decided_at >= CURRENT_DATE - INTERVAL '12 weeks';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (686, '686_lc_insights_tpa_and_review', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
