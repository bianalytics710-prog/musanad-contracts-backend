-- MIGRATION: 533_approver_median_rolling_window.sql
-- Date: 2026-06-03
-- Description:
--   Patch fn_dashboard_approver so the "Median decision time" KPI shows
--   a meaningful value early in the month. Previously used calendar-month
--   windows (this-month vs last-month) which read empty for any approver
--   who hasn't decided anything since the 1st.
--
--   New windowing:
--     - thisMonth   → rolling last 30 days
--     - lastMonth   → prior 30 days (31..60 days ago)
--     - If rolling 30d is empty, fall back to all-time median and surface
--       the fallback flag so the FE can label the tile honestly.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_dashboard_approver(p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $fn$
DECLARE
  v_user_id            BIGINT;
  v_role               TEXT;
  v_bands              JSONB;
  v_low_max            INTEGER;
  v_med_max            INTEGER;

  v_awaiting_curr      INTEGER;
  v_awaiting_prev      INTEGER;
  v_sla_at_risk        INTEGER;
  v_hv_count           INTEGER;
  v_hv_total           NUMERIC;
  v_median_curr        NUMERIC;
  v_median_prev        NUMERIC;
  v_median_alltime     NUMERIC;
  v_median_source      TEXT := 'rolling_30d';

  v_next_up            JSONB;
  v_pending_queue      JSONB;
  v_decision_velocity  JSONB;
  v_queue_risk         JSONB;
  v_counterparty_conc  JSONB;
  v_recent_decisions   JSONB;
  v_decision_mix       JSONB;
  v_unused             INTEGER;
BEGIN
  v_unused := p_window_days;  -- preserved for compat; no longer used

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_approver: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('contract_approver', 'contract_approver_2', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_approver: forbidden — restricted to approver roles'
      USING ERRCODE = '42501';
  END IF;

  SELECT value INTO v_bands FROM system_setting
    WHERE key = 'scoring.v2.bands' AND is_active = TRUE LIMIT 1;
  v_low_max := COALESCE((v_bands->>'lowMax')::int, 29);
  v_med_max := COALESCE((v_bands->>'mediumMax')::int, 59);

  -- ============================================================
  -- KPIs
  -- ============================================================
  SELECT COUNT(*) INTO v_awaiting_curr
    FROM approval_step step
    JOIN approval_chain ch ON ch.id = step.approval_chain_id AND ch.is_active = TRUE AND ch.status = 'in_progress'
   WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
     AND step.status = 'pending' AND step.is_active = TRUE;

  SELECT COUNT(*) INTO v_awaiting_prev
    FROM approval_step step
    JOIN approval_chain ch ON ch.id = step.approval_chain_id AND ch.is_active = TRUE
   WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
     AND step.is_active = TRUE
     AND step.created_at <= fn_demo_now() - INTERVAL '30 days'
     AND (step.decided_at IS NULL OR step.decided_at >= fn_demo_now() - INTERVAL '30 days');

  SELECT COUNT(*) INTO v_sla_at_risk
    FROM approval_step step
    JOIN approval_chain ch ON ch.id = step.approval_chain_id AND ch.is_active = TRUE AND ch.status = 'in_progress'
   WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
     AND step.status = 'pending' AND step.is_active = TRUE
     AND EXTRACT(EPOCH FROM (fn_demo_now() - step.created_at))/3600.0 >= 48;

  SELECT COUNT(*), COALESCE(SUM(c.value_aed), 0)
    INTO v_hv_count, v_hv_total
    FROM approval_step step
    JOIN approval_chain ch ON ch.id = step.approval_chain_id AND ch.is_active = TRUE AND ch.status = 'in_progress'
    JOIN contract c ON c.id = ch.contract_id AND c.is_active = TRUE
   WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
     AND step.status = 'pending' AND step.is_active = TRUE
     AND COALESCE(c.value_aed, 0) >= 5000000;

  -- Median decision time — rolling 30-day windows.
  WITH rolling_curr AS (
    SELECT EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0 AS hours
      FROM approval_decision ad
      JOIN approval_step step ON step.id = ad.approval_step_id
     WHERE ad.decided_by = v_user_id
       AND ad.is_active = TRUE
       AND ad.decided_at >= fn_demo_now() - INTERVAL '30 days'
  ),
  rolling_prev AS (
    SELECT EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0 AS hours
      FROM approval_decision ad
      JOIN approval_step step ON step.id = ad.approval_step_id
     WHERE ad.decided_by = v_user_id
       AND ad.is_active = TRUE
       AND ad.decided_at >= fn_demo_now() - INTERVAL '60 days'
       AND ad.decided_at <  fn_demo_now() - INTERVAL '30 days'
  ),
  alltime AS (
    SELECT EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0 AS hours
      FROM approval_decision ad
      JOIN approval_step step ON step.id = ad.approval_step_id
     WHERE ad.decided_by = v_user_id
       AND ad.is_active = TRUE
  )
  SELECT
    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY hours) FROM rolling_curr),
    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY hours) FROM rolling_prev),
    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY hours) FROM alltime)
  INTO v_median_curr, v_median_prev, v_median_alltime;

  -- Fallback: if no decisions in last 30 days, surface all-time median so
  -- the tile still has a value once the approver has decided anything.
  IF v_median_curr IS NULL AND v_median_alltime IS NOT NULL THEN
    v_median_curr   := v_median_alltime;
    v_median_source := 'all_time';
  END IF;

  -- ============================================================
  -- nextUp
  -- ============================================================
  SELECT jsonb_build_object(
    'contractId',        c.id,
    'contractNumber',    c.contract_number,
    'titleEn',           c.title_en,
    'titleAr',           c.title_ar,
    'valueAed',          c.value_aed,
    'counterpartyName',  p.name_en,
    'riskScore',         lrs.health_score,
    'riskBand',          CASE
                           WHEN lrs.health_score IS NULL                THEN NULL
                           WHEN lrs.health_score <= v_low_max            THEN 'Low'
                           WHEN lrs.health_score <= v_med_max            THEN 'Medium'
                           ELSE                                              'High'
                         END,
    'hoursWaiting',      ROUND(EXTRACT(EPOCH FROM (fn_demo_now() - step.created_at))/3600.0, 1),
    'submittedByName',   COALESCE(u.first_name || ' ' || u.last_name, NULL),
    'stepId',            step.id
  )
  INTO v_next_up
  FROM approval_step step
  JOIN approval_chain ch ON ch.id = step.approval_chain_id AND ch.is_active = TRUE AND ch.status = 'in_progress'
  JOIN contract c ON c.id = ch.contract_id AND c.is_active = TRUE
  LEFT JOIN party p ON p.id = c.counterparty_id
  LEFT JOIN latest_risk_score lrs ON lrs.contract_id = c.id
  LEFT JOIN "user" u ON u.id = ch.initiated_by
  WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
    AND step.status = 'pending' AND step.is_active = TRUE
  ORDER BY
    (COALESCE(c.value_aed, 0) * (EXTRACT(EPOCH FROM (fn_demo_now() - step.created_at))/3600.0)) DESC,
    step.created_at ASC
  LIMIT 1;

  -- ============================================================
  -- pendingQueue
  -- ============================================================
  SELECT COALESCE(jsonb_agg(row_obj ORDER BY priority DESC, requested_at ASC), '[]'::jsonb)
  INTO v_pending_queue
  FROM (
    SELECT
      jsonb_build_object(
        'stepId',           step.id,
        'contractId',       c.id,
        'contractNumber',   c.contract_number,
        'titleEn',          c.title_en,
        'titleAr',          c.title_ar,
        'valueAed',         c.value_aed,
        'counterpartyName', p.name_en,
        'riskScore',        lrs.health_score,
        'riskBand',         CASE
                              WHEN lrs.health_score IS NULL                THEN NULL
                              WHEN lrs.health_score <= v_low_max            THEN 'Low'
                              WHEN lrs.health_score <= v_med_max            THEN 'Medium'
                              ELSE                                              'High'
                            END,
        'hoursWaiting',     ROUND(EXTRACT(EPOCH FROM (fn_demo_now() - step.created_at))/3600.0, 1),
        'slaAtRisk',        (EXTRACT(EPOCH FROM (fn_demo_now() - step.created_at))/3600.0) >= 48,
        'submittedByName',  COALESCE(u.first_name || ' ' || u.last_name, NULL),
        'requestedAt',      step.created_at
      ) AS row_obj,
      step.created_at AS requested_at,
      (COALESCE(c.value_aed, 0) * (EXTRACT(EPOCH FROM (fn_demo_now() - step.created_at))/3600.0)) AS priority
    FROM approval_step step
    JOIN approval_chain ch ON ch.id = step.approval_chain_id AND ch.is_active = TRUE AND ch.status = 'in_progress'
    JOIN contract c ON c.id = ch.contract_id AND c.is_active = TRUE
    LEFT JOIN party p ON p.id = c.counterparty_id
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id = c.id
    LEFT JOIN "user" u ON u.id = ch.initiated_by
    WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
      AND step.status = 'pending' AND step.is_active = TRUE
  ) q;

  -- ============================================================
  -- Insights — velocity, queue risk, concentration, recent, mix
  -- ============================================================
  WITH days AS (
    SELECT generate_series(
      (fn_demo_now() - INTERVAL '29 days')::date,
      fn_demo_now()::date,
      INTERVAL '1 day'
    )::date AS day
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'day',           to_char(d.day, 'YYYY-MM-DD'),
    'decisionCount', COALESCE(c.cnt, 0),
    'medianHours',   c.median_hours
  ) ORDER BY d.day), '[]'::jsonb)
  INTO v_decision_velocity
  FROM days d
  LEFT JOIN (
    SELECT ad.decided_at::date AS day,
           COUNT(*)::int AS cnt,
           ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0)::numeric, 1) AS median_hours
      FROM approval_decision ad
      JOIN approval_step step ON step.id = ad.approval_step_id
     WHERE ad.decided_by = v_user_id
       AND ad.is_active = TRUE
       AND ad.decided_at >= fn_demo_now() - INTERVAL '30 days'
     GROUP BY ad.decided_at::date
  ) c ON c.day = d.day;

  SELECT jsonb_build_object(
    'low',    COALESCE(SUM(CASE WHEN lrs.health_score IS NOT NULL AND lrs.health_score <= v_low_max THEN 1 ELSE 0 END), 0),
    'medium', COALESCE(SUM(CASE WHEN lrs.health_score IS NOT NULL AND lrs.health_score > v_low_max AND lrs.health_score <= v_med_max THEN 1 ELSE 0 END), 0),
    'high',   COALESCE(SUM(CASE WHEN lrs.health_score IS NOT NULL AND lrs.health_score > v_med_max THEN 1 ELSE 0 END), 0),
    'unrated',COALESCE(SUM(CASE WHEN lrs.health_score IS NULL THEN 1 ELSE 0 END), 0),
    'total',  COUNT(*)
  )
  INTO v_queue_risk
  FROM approval_step step
  JOIN approval_chain ch ON ch.id = step.approval_chain_id AND ch.is_active = TRUE AND ch.status = 'in_progress'
  JOIN contract c ON c.id = ch.contract_id AND c.is_active = TRUE
  LEFT JOIN latest_risk_score lrs ON lrs.contract_id = c.id
  WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
    AND step.status = 'pending' AND step.is_active = TRUE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'counterpartyId', counterparty_id,
    'name',           name_en,
    'contractsCount', cnt,
    'totalAed',       total_aed
  ) ORDER BY total_aed DESC NULLS LAST), '[]'::jsonb)
  INTO v_counterparty_conc
  FROM (
    SELECT c.counterparty_id, p.name_en, COUNT(*)::int AS cnt, SUM(c.value_aed) AS total_aed
      FROM approval_step step
      JOIN approval_chain ch ON ch.id = step.approval_chain_id AND ch.is_active = TRUE AND ch.status = 'in_progress'
      JOIN contract c ON c.id = ch.contract_id AND c.is_active = TRUE
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
       AND step.status = 'pending' AND step.is_active = TRUE
       AND c.counterparty_id IS NOT NULL
     GROUP BY c.counterparty_id, p.name_en
     ORDER BY total_aed DESC NULLS LAST
     LIMIT 5
  ) t;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractId',       contract_id,
    'contractNumber',   contract_number,
    'titleEn',          title_en,
    'titleAr',          title_ar,
    'counterpartyName', counterparty_name,
    'decision',         decision,
    'decisionNote',     CASE WHEN decision_note IS NULL THEN NULL ELSE LEFT(decision_note, 120) END,
    'decidedAt',        decided_at,
    'valueAed',         value_aed
  ) ORDER BY decided_at DESC), '[]'::jsonb)
  INTO v_recent_decisions
  FROM (
    SELECT c.id AS contract_id, c.contract_number, c.title_en, c.title_ar, c.value_aed,
           p.name_en AS counterparty_name,
           ad.decision, ad.decision_note, ad.decided_at
      FROM approval_decision ad
      JOIN approval_step step ON step.id = ad.approval_step_id
      JOIN approval_chain ch ON ch.id = step.approval_chain_id
      JOIN contract c ON c.id = ch.contract_id
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE ad.decided_by = v_user_id
       AND ad.is_active = TRUE
     ORDER BY ad.decided_at DESC
     LIMIT 8
  ) t;

  SELECT jsonb_build_object(
    'approved',      COALESCE(SUM(CASE WHEN decision = 'approve' THEN 1 ELSE 0 END), 0),
    'rejected',      COALESCE(SUM(CASE WHEN decision = 'reject' THEN 1 ELSE 0 END), 0),
    'requestedInfo', COALESCE(SUM(CASE WHEN decision = 'request_info' OR decision = 'request_resubmission' THEN 1 ELSE 0 END), 0),
    'total',         COUNT(*)
  )
  INTO v_decision_mix
  FROM approval_decision
  WHERE decided_by = v_user_id
    AND is_active = TRUE
    AND decided_at >= fn_demo_now() - INTERVAL '90 days';

  RETURN jsonb_build_object(
    'kpis', jsonb_build_object(
      'awaitingMyDecision', jsonb_build_object('current', v_awaiting_curr, 'previous', v_awaiting_prev),
      'slaAtRisk',          v_sla_at_risk,
      'highValueInQueue',   jsonb_build_object('count', v_hv_count, 'totalAed', v_hv_total),
      'medianDecisionHours', jsonb_build_object(
        'thisMonth', v_median_curr,
        'lastMonth', v_median_prev,
        'source',    v_median_source
      )
    ),
    'nextUp',         v_next_up,
    'pendingQueue',   v_pending_queue,
    'insights', jsonb_build_object(
      'decisionVelocity30d',      v_decision_velocity,
      'queueRiskProfile',         v_queue_risk,
      'counterpartyConcentration',v_counterparty_conc,
      'recentDecisions',          v_recent_decisions,
      'decisionMix90d',           v_decision_mix
    )
  );
END;
$fn$;

REVOKE EXECUTE ON FUNCTION fn_dashboard_approver(integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_approver(integer) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (533, 'approver_median_rolling_window', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
