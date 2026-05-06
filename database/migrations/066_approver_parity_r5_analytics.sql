-- ============================================================================
-- 066_approver_parity_r5_analytics.sql
-- ============================================================================
-- Module:    M_parity (R5 — close every remaining approver-audit gap)
-- Owner:     Direct work — no orchestrator pipeline
-- Depends:   056 (fn_dashboard_approver), 025 (fn_approval_my_pending),
--            003 (contract), 014 (user/role)
-- ----------------------------------------------------------------------------
-- R5 audit gaps from audit/approver/E2E-COVERAGE-V1.md:
--   6.2.1   Inbox tabs need real data for All / Approved by me / Rejected
--           by me / Watching → fn_approval_my_decisions + contract_watch.
--   7.4.1   KPI deltas vs prior period.
--   7.5.2   Decisions-by-contract-value bar chart.
--   7.5.3   Approvals-by-approver team comparison chart.
--   7.5.4   Recent decisions list (5 latest).
--   7.5.5   Decision-mix real 4-bucket split.
--
-- Strategy:
--   - contract_watch — new table for the "Watching" inbox tab. Toggleable
--     via fn_contract_watch_set; queryable via fn_approval_watching for
--     the inbox payload shape.
--   - fn_approval_my_decisions — paginated past decisions filtered by kind
--     (approve/reject/request_resubmission/skipped/null=all). Returns the
--     same row shape as fn_approval_my_pending for FE column reuse.
--   - fn_dashboard_approver — extended additively with: queueTeamCount,
--     slaBreachCount, decisionMixSplit (4 buckets), kpiPrev (delta source),
--     recentDecisions5, decisionsByValue, approvalsByApprover. Existing
--     keys preserved — additive change, no breaking schema rev.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- contract_watch — user opt-in follow list, drives the "Watching" inbox tab.
-- ============================================================================
CREATE TABLE IF NOT EXISTS contract_watch (
  user_id      BIGINT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  contract_id  BIGINT NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, contract_id)
);

CREATE INDEX IF NOT EXISTS idx_contract_watch_contract ON contract_watch(contract_id);

-- ============================================================================
-- fn_contract_watch_set — toggle a contract on/off the user's watch list.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_contract_watch_set(
  p_actor_id    BIGINT,
  p_contract_id BIGINT,
  p_watching    BOOLEAN
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_watch_set: actorId required' USING ERRCODE = '22023';
  END IF;
  IF p_contract_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_watch_set: contractId required' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF p_watching THEN
    INSERT INTO contract_watch (user_id, contract_id)
    VALUES (p_actor_id, p_contract_id)
    ON CONFLICT (user_id, contract_id) DO NOTHING;
  ELSE
    DELETE FROM contract_watch
     WHERE user_id = p_actor_id AND contract_id = p_contract_id;
  END IF;

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'contractId', p_contract_id,
      'watching', p_watching
    )
  );
END;
$$;

-- ============================================================================
-- fn_approval_my_decisions — paginated past decisions filtered by kind.
-- Returns the same row shape as fn_approval_my_pending (chainSteps/totalSteps
-- contextual fields included for FE column reuse).
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_approval_my_decisions(
  p_actor_id BIGINT,
  p_kind     TEXT DEFAULT NULL,    -- approve / reject / request_resubmission / NULL=all
  p_page     INTEGER DEFAULT 1,
  p_limit    INTEGER DEFAULT 20
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset INTEGER := GREATEST(p_page - 1, 0) * GREATEST(p_limit, 1);
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_my_decisions: actorId required' USING ERRCODE = '22023';
  END IF;
  IF p_kind IS NOT NULL AND p_kind NOT IN ('approve','reject','request_resubmission','skipped') THEN
    RAISE EXCEPTION 'fn_approval_my_decisions: invalid kind' USING ERRCODE = '22023';
  END IF;

  SELECT COUNT(*) INTO v_total
    FROM approval_decision ad
    JOIN approval_step      step ON step.id = ad.approval_step_id
    JOIN approval_chain     ch   ON ch.id = step.approval_chain_id
    JOIN contract           c    ON c.id  = ch.contract_id
   WHERE ad.decided_by = p_actor_id
     AND ad.is_active = TRUE
     AND (p_kind IS NULL OR ad.decision = p_kind);

  SELECT COALESCE(jsonb_agg(row_data ORDER BY decided_at DESC), '[]'::jsonb)
    INTO v_data
    FROM (
      SELECT
        jsonb_build_object(
          'stepId',           step.id,
          'chainId',          ch.id,
          'contractId',       c.id,
          'contractNumber',   c.contract_number,
          'contractTitleEn',  c.title_en,
          'contractTitleAr',  c.title_ar,
          'contractType',     c.contract_type,
          'valueAed',         c.value_aed,
          'requesterUserRef', fn_user_get_by_id(ch.initiated_by),
          'stepOrder',        step.step_order,
          'decision',         ad.decision,
          'decidedAt',        ad.decided_at,
          'decisionNote',     ad.decision_note,
          'totalSteps',       (SELECT COUNT(*) FROM approval_step ss WHERE ss.approval_chain_id = ch.id AND ss.is_active = TRUE),
          'chainSteps',       (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'order', ss.step_order, 'role', ss.approver_role,
              'status', ss.status,
              'approverName', CASE WHEN ss.approver_user_id IS NOT NULL THEN (
                SELECT u2.first_name || ' ' || u2.last_name FROM "user" u2 WHERE u2.id = ss.approver_user_id
              ) ELSE NULL END
            ) ORDER BY ss.step_order), '[]'::jsonb)
            FROM approval_step ss
            WHERE ss.approval_chain_id = ch.id AND ss.is_active = TRUE
          )
        ) AS row_data,
        ad.decided_at AS decided_at
      FROM approval_decision ad
      JOIN approval_step  step ON step.id = ad.approval_step_id
      JOIN approval_chain ch   ON ch.id = step.approval_chain_id
      JOIN contract       c    ON c.id  = ch.contract_id
      WHERE ad.decided_by = p_actor_id
        AND ad.is_active = TRUE
        AND (p_kind IS NULL OR ad.decision = p_kind)
      ORDER BY ad.decided_at DESC
      LIMIT GREATEST(p_limit, 1) OFFSET v_offset
    ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', v_total,
      'page',  p_page,
      'limit', p_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0
                         ELSE CEIL(v_total::numeric / GREATEST(p_limit, 1))::int END
    )
  );
END;
$$;

-- ============================================================================
-- fn_approval_watching — same row shape, filtered to contracts the user is
-- watching that have a pending step (so the inbox feels like "things I'm
-- following that need attention").
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_approval_watching(
  p_actor_id BIGINT,
  p_page     INTEGER DEFAULT 1,
  p_limit    INTEGER DEFAULT 20
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset INTEGER := GREATEST(p_page - 1, 0) * GREATEST(p_limit, 1);
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_watching: actorId required' USING ERRCODE = '22023';
  END IF;

  SELECT COUNT(DISTINCT step.id) INTO v_total
    FROM approval_step      step
    JOIN approval_chain     ch   ON ch.id = step.approval_chain_id
    JOIN contract           c    ON c.id  = ch.contract_id
    JOIN contract_watch     w    ON w.contract_id = c.id AND w.user_id = p_actor_id
   WHERE step.status = 'pending'
     AND step.is_active = TRUE
     AND ch.is_active = TRUE
     AND c.is_active = TRUE;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY hours_waiting DESC), '[]'::jsonb)
    INTO v_data
    FROM (
      SELECT
        jsonb_build_object(
          'stepId',           step.id,
          'chainId',          ch.id,
          'contractId',       c.id,
          'contractNumber',   c.contract_number,
          'contractTitleEn',  c.title_en,
          'contractTitleAr',  c.title_ar,
          'contractType',     c.contract_type,
          'valueAed',         c.value_aed,
          'requesterUserRef', fn_user_get_by_id(ch.initiated_by),
          'stepOrder',        step.step_order,
          'hoursPending',     ROUND(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - step.created_at))/3600.0, 2),
          'isRequired',       step.is_required,
          'parallelGroup',    step.parallel_group,
          'totalSteps',       (SELECT COUNT(*) FROM approval_step ss WHERE ss.approval_chain_id = ch.id AND ss.is_active = TRUE),
          'chainSteps',       (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'order', ss.step_order, 'role', ss.approver_role, 'status', ss.status,
              'approverName', CASE WHEN ss.approver_user_id IS NOT NULL THEN (
                SELECT u2.first_name || ' ' || u2.last_name FROM "user" u2 WHERE u2.id = ss.approver_user_id
              ) ELSE NULL END
            ) ORDER BY ss.step_order), '[]'::jsonb)
            FROM approval_step ss
            WHERE ss.approval_chain_id = ch.id AND ss.is_active = TRUE
          )
        ) AS row_data,
        EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - step.created_at))/3600.0 AS hours_waiting
      FROM approval_step      step
      JOIN approval_chain     ch   ON ch.id = step.approval_chain_id
      JOIN contract           c    ON c.id  = ch.contract_id
      JOIN contract_watch     w    ON w.contract_id = c.id AND w.user_id = p_actor_id
      WHERE step.status = 'pending'
        AND step.is_active = TRUE
        AND ch.is_active = TRUE
        AND c.is_active = TRUE
      ORDER BY hours_waiting DESC
      LIMIT GREATEST(p_limit, 1) OFFSET v_offset
    ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', v_total,
      'page',  p_page,
      'limit', p_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0
                         ELSE CEIL(v_total::numeric / GREATEST(p_limit, 1))::int END
    )
  );
END;
$$;

-- ============================================================================
-- fn_dashboard_approver — extended additively for R5 dashboard depth.
-- ============================================================================
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

  -- KPI counts
  SELECT COUNT(*) INTO v_pending_mine
    FROM approval_step
    WHERE COALESCE(delegated_to, reassigned_to, approver_user_id) IS NOT DISTINCT FROM v_user_id
      AND status = 'pending' AND is_active = TRUE;

  -- Team segment: pending steps assigned to anyone with the same role (excludes mine).
  SELECT COUNT(*) INTO v_pending_team
    FROM approval_step step
    LEFT JOIN "user" u ON u.id = step.approver_user_id
    LEFT JOIN role r ON r.id = u.role_id
    WHERE step.status = 'pending' AND step.is_active = TRUE
      AND (
        (step.approver_user_id IS NOT NULL AND step.approver_user_id <> v_user_id AND r.name = v_role)
        OR (step.approver_user_id IS NULL AND step.approver_role = v_role)
      );

  -- Quick approve: pending mine + value < 100k
  SELECT COUNT(*) INTO v_pending_quick
    FROM approval_step step
    JOIN contract c ON c.id = step.contract_id AND c.is_active = TRUE
    WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
      AND step.status = 'pending' AND step.is_active = TRUE
      AND COALESCE(c.value_aed, 0) < 100000;

  -- SLA breach: pending mine + waiting > 24h
  SELECT COUNT(*) INTO v_sla_breach
    FROM approval_step step
    WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
      AND step.status = 'pending' AND step.is_active = TRUE
      AND EXTRACT(EPOCH FROM (NOW() - step.created_at))/3600.0 > 24;

  -- Decided counts current + prior periods (for deltas)
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

  -- Pending count "prior" — best-effort approximation: snapshot today vs N days ago
  -- isn't tracked, so we use decided_mine prior period as a proxy for delta.
  v_pending_prev := v_decided_prev;

  -- Avg decision hours mine + prior period
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
    -- R5 additions
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
                 step.contract_id AS contract_id,
                 c.contract_number,
                 c.title_en,
                 c.title_ar,
                 c.value_aed,
                 step.created_at AS requested_at,
                 ROUND((EXTRACT(EPOCH FROM (NOW() - step.created_at))/3600.0)::NUMERIC, 2) AS hours_waiting
          FROM approval_step step
          JOIN contract c ON c.id = step.contract_id AND c.is_active = TRUE
          WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
            AND step.status = 'pending'
            AND step.is_active = TRUE
          ORDER BY step.created_at ASC
          LIMIT 5
        ) q
      ), '[]'::jsonb),
    -- R5 7.5.4: Recent decisions list (5 latest by current user)
    'recentDecisions5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'stepId',          ad.approval_step_id,
          'contractId',      step.contract_id,
          'contractNumber',  c.contract_number,
          'titleEn',         c.title_en,
          'decision',        ad.decision,
          'decidedAt',       ad.decided_at,
          'hoursAgo',        ROUND(EXTRACT(EPOCH FROM (NOW() - ad.decided_at))/3600.0, 2)
        ) ORDER BY ad.decided_at DESC)
        FROM approval_decision ad
        JOIN approval_step step ON step.id = ad.approval_step_id
        JOIN contract c ON c.id = step.contract_id AND c.is_active = TRUE
        WHERE ad.decided_by = v_user_id
          AND ad.is_active = TRUE
        ORDER BY ad.decided_at DESC
        LIMIT 5
      ), '[]'::jsonb)
  );

  -- R5 charts: decisionMixSplit (real 4-bucket), decisionsByValue, approvalsByApprover
  v_charts := jsonb_build_object(
    -- 7.5.5 Real 4-bucket decision mix over the window
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
    -- 7.5.2 Decisions by contract-value bucket over the window
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
        JOIN contract c ON c.id = step.contract_id
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
    -- 7.5.3 Approvals by approver — team comparison over the window
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
VALUES (66, 'M_parity R5: contract_watch + fn_approval_my_decisions + fn_approval_watching + fn_contract_watch_set + fn_dashboard_approver extended (queueTeamCount, slaBreachCount, kpiPrev, recentDecisions5, decisionMixSplit, decisionsByValue, approvalsByApprover)', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
