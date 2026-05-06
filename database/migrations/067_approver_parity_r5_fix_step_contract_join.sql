-- ============================================================================
-- 067_approver_parity_r5_fix_step_contract_join.sql
-- ============================================================================
-- Module:    M_parity (R5 — fix-up)
-- Owner:     Direct work
-- Depends:   066 (fn_dashboard_approver R5 extension)
-- ----------------------------------------------------------------------------
-- DEFECT: Migration 066 re-defined fn_dashboard_approver with new R5 keys
-- (queueQuickApprove + recentDecisions5) but two of the new sub-queries
-- joined contract via `step.contract_id` — the same S2-22b escape M6
-- patched in migration 057 (approval_step has NO contract_id column;
-- contract_id lives on approval_chain).
--
-- FIX: re-create fn_dashboard_approver with correct join path everywhere:
--   approval_step (chain_id) → approval_chain (contract_id) → contract (id)
-- ----------------------------------------------------------------------------

BEGIN;

CREATE OR REPLACE FUNCTION fn_dashboard_approver(
  p_window_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id          BIGINT;
  v_role             TEXT;
  v_window           INTEGER;
  v_kpis             JSONB;
  v_lists            JSONB;
  v_charts           JSONB;
  v_pending_mine     INTEGER;
  v_pending_team     INTEGER;
  v_pending_quick    INTEGER;
  v_sla_breach       INTEGER;
  v_decided_mine     INTEGER;
  v_decided_prev     INTEGER;
  v_avg_mine         NUMERIC;
  v_avg_prev         NUMERIC;
  v_pending_prev     INTEGER;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_approver: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_approver: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('contract_approver', 'contract_approver_2', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_approver: forbidden — approver dashboard restricted to contract_approver, contract_approver_2, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_pending_mine
    FROM approval_step
    WHERE COALESCE(delegated_to, reassigned_to, approver_user_id) IS NOT DISTINCT FROM v_user_id
      AND status = 'pending' AND is_active = TRUE;

  SELECT COUNT(*) INTO v_pending_team
    FROM approval_step step
    LEFT JOIN "user" u ON u.id = step.approver_user_id
    LEFT JOIN role r ON r.id = u.role_id
    WHERE step.status = 'pending' AND step.is_active = TRUE
      AND (
        (step.approver_user_id IS NOT NULL AND step.approver_user_id <> v_user_id AND r.name = v_role)
        OR (step.approver_user_id IS NULL AND step.approver_role = v_role)
      );

  -- FIX: chain → contract
  SELECT COUNT(*) INTO v_pending_quick
    FROM approval_step step
    JOIN approval_chain ch ON ch.id = step.approval_chain_id AND ch.is_active = TRUE
    JOIN contract c ON c.id = ch.contract_id AND c.is_active = TRUE
    WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
      AND step.status = 'pending' AND step.is_active = TRUE
      AND COALESCE(c.value_aed, 0) < 100000;

  SELECT COUNT(*) INTO v_sla_breach
    FROM approval_step step
    WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
      AND step.status = 'pending' AND step.is_active = TRUE
      AND EXTRACT(EPOCH FROM (NOW() - step.created_at))/3600.0 > 24;

  SELECT COUNT(*) INTO v_decided_mine
    FROM approval_decision
    WHERE decided_by = v_user_id
      AND decided_at >= NOW() - (v_window || ' days')::INTERVAL
      AND is_active = TRUE;
  SELECT COUNT(*) INTO v_decided_prev
    FROM approval_decision
    WHERE decided_by = v_user_id
      AND decided_at >= NOW() - (2 * v_window || ' days')::INTERVAL
      AND decided_at <  NOW() - (v_window || ' days')::INTERVAL
      AND is_active = TRUE;

  v_pending_prev := v_decided_prev;

  SELECT AVG(EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0)::NUMERIC(12,2)
    INTO v_avg_mine
    FROM approval_decision ad
    JOIN approval_step step ON step.id = ad.approval_step_id
    WHERE ad.decided_by = v_user_id
      AND ad.decided_at >= NOW() - (v_window || ' days')::INTERVAL
      AND ad.is_active = TRUE;
  SELECT AVG(EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0)::NUMERIC(12,2)
    INTO v_avg_prev
    FROM approval_decision ad
    JOIN approval_step step ON step.id = ad.approval_step_id
    WHERE ad.decided_by = v_user_id
      AND ad.decided_at >= NOW() - (2 * v_window || ' days')::INTERVAL
      AND ad.decided_at <  NOW() - (v_window || ' days')::INTERVAL
      AND ad.is_active = TRUE;

  v_kpis := jsonb_build_object(
    'pendingMyApprovalCount',    v_pending_mine,
    'decidedByMeCount',          v_decided_mine,
    'averageDecisionHoursMine',  v_avg_mine,
    'averageDecisionHoursTeam', (SELECT AVG(EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0)::NUMERIC(12,2)
                                 FROM approval_decision ad
                                 JOIN approval_step step ON step.id = ad.approval_step_id
                                 JOIN "user" u ON u.id = ad.decided_by
                                 JOIN role  r ON r.id = u.role_id
                                 WHERE ad.decided_by != v_user_id
                                   AND r.name = v_role
                                   AND ad.decided_at >= NOW() - (v_window || ' days')::INTERVAL
                                   AND ad.is_active = TRUE),
    'queueTeamCount',            v_pending_team,
    'queueQuickApproveCount',    v_pending_quick,
    'slaBreachCount',            v_sla_breach,
    'kpiPrev', jsonb_build_object(
      'decidedByMeCount',         v_decided_prev,
      'averageDecisionHoursMine', v_avg_prev,
      'pendingMyApprovalCount',   v_pending_prev
    )
  );

  v_lists := jsonb_build_object(
    'pendingQueue5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'stepId', q.step_id,
          'contractId', q.contract_id,
          'contractNumber', q.contract_number,
          'titleEn', q.title_en,
          'titleAr', q.title_ar,
          'valueAed', q.value_aed,
          'requestedAt', q.requested_at,
          'hoursWaiting', q.hours_waiting
        ) ORDER BY q.requested_at ASC)
        FROM (
          SELECT step.id AS step_id,
                 c.id AS contract_id,
                 c.contract_number,
                 c.title_en,
                 c.title_ar,
                 c.value_aed,
                 step.created_at AS requested_at,
                 ROUND((EXTRACT(EPOCH FROM (NOW() - step.created_at))/3600.0)::NUMERIC, 2) AS hours_waiting
          FROM approval_step step
          JOIN approval_chain ch ON ch.id = step.approval_chain_id AND ch.is_active = TRUE
          JOIN contract c ON c.id = ch.contract_id AND c.is_active = TRUE
          WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
            AND step.status = 'pending'
            AND step.is_active = TRUE
          ORDER BY step.created_at ASC
          LIMIT 5
        ) q
      ), '[]'::jsonb),
    -- FIX: Recent decisions list — chain → contract
    'recentDecisions5',
      COALESCE((
        SELECT jsonb_agg(row_data ORDER BY decided_at DESC)
        FROM (
          SELECT
            jsonb_build_object(
              'stepId',          ad.approval_step_id,
              'contractId',      c.id,
              'contractNumber',  c.contract_number,
              'titleEn',         c.title_en,
              'decision',        ad.decision,
              'decidedAt',       ad.decided_at,
              'hoursAgo',        ROUND(EXTRACT(EPOCH FROM (NOW() - ad.decided_at))/3600.0, 2)
            ) AS row_data,
            ad.decided_at AS decided_at
          FROM approval_decision ad
          JOIN approval_step step ON step.id = ad.approval_step_id
          JOIN approval_chain ch  ON ch.id = step.approval_chain_id
          JOIN contract c         ON c.id = ch.contract_id AND c.is_active = TRUE
          WHERE ad.decided_by = v_user_id
            AND ad.is_active = TRUE
          ORDER BY ad.decided_at DESC
          LIMIT 5
        ) sub
      ), '[]'::jsonb)
  );

  v_charts := jsonb_build_object(
    'decisionMixSplit', (
      SELECT jsonb_build_object(
        'approve',
          COALESCE(SUM(CASE WHEN decision = 'approve' THEN 1 ELSE 0 END), 0),
        'reject',
          COALESCE(SUM(CASE WHEN decision = 'reject' THEN 1 ELSE 0 END), 0),
        'requestResubmission',
          COALESCE(SUM(CASE WHEN decision = 'request_resubmission' THEN 1 ELSE 0 END), 0),
        'skipped',
          COALESCE(SUM(CASE WHEN decision = 'skipped' THEN 1 ELSE 0 END), 0)
      )
      FROM approval_decision
      WHERE decided_by = v_user_id
        AND decided_at >= NOW() - (v_window || ' days')::INTERVAL
        AND is_active = TRUE
    ),
    -- FIX: Decisions by value — chain → contract
    'decisionsByValue', (
      WITH buckets AS (
        SELECT
          CASE
            WHEN COALESCE(c.value_aed, 0) < 100000          THEN 'lt100k'
            WHEN COALESCE(c.value_aed, 0) < 500000          THEN 'p100to500'
            WHEN COALESCE(c.value_aed, 0) < 1000000         THEN 'p500to1m'
            ELSE                                                 'gt1m'
          END AS bucket,
          ad.decision
        FROM approval_decision ad
        JOIN approval_step step ON step.id = ad.approval_step_id
        JOIN approval_chain ch  ON ch.id = step.approval_chain_id
        JOIN contract c         ON c.id = ch.contract_id
        WHERE ad.decided_by = v_user_id
          AND ad.decided_at >= NOW() - (v_window || ' days')::INTERVAL
          AND ad.is_active = TRUE
      )
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'bucket',   bucket,
        'approved', SUM(CASE WHEN decision = 'approve' THEN 1 ELSE 0 END),
        'rejected', SUM(CASE WHEN decision = 'reject'  THEN 1 ELSE 0 END),
        'other',    SUM(CASE WHEN decision NOT IN ('approve','reject') THEN 1 ELSE 0 END)
      ) ORDER BY
        CASE bucket WHEN 'lt100k' THEN 1 WHEN 'p100to500' THEN 2 WHEN 'p500to1m' THEN 3 ELSE 4 END
      ), '[]'::jsonb)
      FROM buckets GROUP BY bucket
    ),
    'approvalsByApprover', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'userId',     u.id,
        'name',       u.first_name || ' ' || u.last_name,
        'count',      cnt
      ) ORDER BY cnt DESC), '[]'::jsonb)
      FROM (
        SELECT ad.decided_by AS uid, COUNT(*) AS cnt
        FROM approval_decision ad
        JOIN "user" u2 ON u2.id = ad.decided_by
        JOIN role r ON r.id = u2.role_id
        WHERE r.name = v_role
          AND ad.decided_at >= NOW() - (v_window || ' days')::INTERVAL
          AND ad.is_active = TRUE
        GROUP BY ad.decided_by
        ORDER BY COUNT(*) DESC
        LIMIT 8
      ) agg
      JOIN "user" u ON u.id = agg.uid
    )
  );

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists, 'charts', v_charts);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_approver: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_approver(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_approver(INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (67, 'M_parity R5 fix: fn_dashboard_approver step.contract_id → chain.contract_id (S2-22b)', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
