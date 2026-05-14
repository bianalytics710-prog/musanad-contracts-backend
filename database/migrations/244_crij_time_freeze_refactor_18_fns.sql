-- Migration 244: CR-I+J DEBT-CRIJ-1 -- 18-fn time-freeze refactor
-- Replaces time-sensitive NOW() calls with fn_demo_now() in 15 fns.
-- 3 fns (fn_signature_invitation_expire_due, fn_obligations_derive_from_clause, fn_source_health_record)
--   contain only audit timestamps (created_at/updated_at/checked_at) -- SKIPPED.

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (244, 'CR-I+J DEBT-CRIJ-1 -- 18-fn time-freeze refactor', now());
CREATE OR REPLACE FUNCTION public.fn_dashboard_admin(p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_user_id        BIGINT;
  v_role           TEXT;
  v_window         INTEGER;
  v_kpis           JSONB;
  v_kpi_prev       JSONB;
  v_trends         JSONB;
  v_system_health  JSONB;
  v_pending        JSONB;
  v_top_types      JSONB;
  v_activity       JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_admin: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_admin: unauthorized' USING ERRCODE = '42501';
  END IF;
  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;
  IF v_role IS NULL OR v_role NOT IN ('platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_admin: forbidden — admin dashboard restricted to platform_admin and Super Admin' USING ERRCODE = '42501';
  END IF;
  SELECT jsonb_build_object(
    'totalContractsActive', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE),
    'totalContractsByStatus', COALESCE((SELECT jsonb_object_agg(status, contract_count) FROM vw_contract_status_summary), '{}'::jsonb),
    'expiringWithin30d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days'),
    'expiringWithin90d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'),
    'pendingApprovals', (SELECT COUNT(*) FROM approval_step WHERE status = 'pending' AND is_active = TRUE),
    'pendingSignatures', (SELECT COUNT(*) FROM signature_invitation WHERE status = 'pending' AND is_active = TRUE),
    'openRegulatoryImpacts', (SELECT COUNT(*) FROM regulatory_impact WHERE resolved = FALSE AND is_active = TRUE),
    'recentAuditEvents', (SELECT COUNT(*) FROM audit_log WHERE changed_at >= fn_demo_now() - (v_window || ' days')::INTERVAL),
    'totalActiveUsers', (SELECT COUNT(*) FROM "user" WHERE is_active = TRUE)
  ) INTO v_kpis;
  SELECT jsonb_build_object(
    'totalContractsActive', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND created_at <= fn_demo_now() - (v_window || ' days')::INTERVAL),
    'expiringWithin30d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND created_at <= fn_demo_now() - (v_window || ' days')::INTERVAL AND end_date BETWEEN CURRENT_DATE - (v_window || ' days')::INTERVAL AND CURRENT_DATE - (v_window || ' days')::INTERVAL + INTERVAL '30 days'),
    'expiringWithin90d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND created_at <= fn_demo_now() - (v_window || ' days')::INTERVAL AND end_date BETWEEN CURRENT_DATE - (v_window || ' days')::INTERVAL AND CURRENT_DATE - (v_window || ' days')::INTERVAL + INTERVAL '90 days'),
    'pendingApprovals', (SELECT COUNT(*) FROM approval_step WHERE status = 'pending' AND is_active = TRUE AND created_at <= fn_demo_now() - (v_window || ' days')::INTERVAL),
    'pendingSignatures', (SELECT COUNT(*) FROM signature_invitation WHERE status = 'pending' AND is_active = TRUE AND created_at <= fn_demo_now() - (v_window || ' days')::INTERVAL),
    'openRegulatoryImpacts', (SELECT COUNT(*) FROM regulatory_impact WHERE resolved = FALSE AND is_active = TRUE AND created_at <= fn_demo_now() - (v_window || ' days')::INTERVAL),
    'recentAuditEvents', (SELECT COUNT(*) FROM audit_log WHERE changed_at BETWEEN fn_demo_now() - (2 * v_window || ' days')::INTERVAL AND fn_demo_now() - (v_window || ' days')::INTERVAL),
    'totalActiveUsers', (SELECT COUNT(*) FROM "user" WHERE is_active = TRUE AND created_at <= fn_demo_now() - (v_window || ' days')::INTERVAL)
  ) INTO v_kpi_prev;
  SELECT jsonb_build_object(
    'contractsCreatedByDay', COALESCE((SELECT jsonb_agg(jsonb_build_object('date', to_char(d, 'YYYY-MM-DD'), 'count', COALESCE(c.cnt, 0)) ORDER BY d) FROM generate_series(CURRENT_DATE - v_window, CURRENT_DATE, INTERVAL '1 day') AS gs(d) LEFT JOIN (SELECT date_trunc('day', created_at)::DATE AS dd, COUNT(*) AS cnt FROM contract WHERE created_at >= CURRENT_DATE - v_window AND is_active = TRUE GROUP BY 1) c ON c.dd = gs.d), '[]'::jsonb),
    'approvalDecisionsByDay', COALESCE((SELECT jsonb_agg(jsonb_build_object('date', to_char(d, 'YYYY-MM-DD'), 'approved', COALESCE(ad.approved_cnt, 0), 'rejected', COALESCE(ad.rejected_cnt, 0)) ORDER BY d) FROM generate_series(CURRENT_DATE - v_window, CURRENT_DATE, INTERVAL '1 day') AS gs(d) LEFT JOIN (SELECT date_trunc('day', decided_at)::DATE AS dd, COUNT(*) FILTER (WHERE decision = 'approve') AS approved_cnt, COUNT(*) FILTER (WHERE decision = 'reject') AS rejected_cnt FROM approval_decision WHERE decided_at >= CURRENT_DATE - v_window AND is_active = TRUE GROUP BY 1) ad ON ad.dd = gs.d), '[]'::jsonb)
  ) INTO v_trends;
  SELECT jsonb_build_object(
    'dbStatus', 'ok',
    'latestMigration', COALESCE((SELECT MAX(version) FROM schema_migrations), 0),
    'auditEvents24h', (SELECT COUNT(*) FROM audit_log WHERE changed_at >= fn_demo_now() - INTERVAL '24 hours'),
    'aiErrors24h', (SELECT COUNT(*) FROM ai_request_log WHERE outcome <> 'success' AND is_active = TRUE AND created_at >= fn_demo_now() - INTERVAL '24 hours')
  ) INTO v_system_health;
  SELECT jsonb_build_object(
    'pendingApprovals', (SELECT COUNT(*) FROM approval_step WHERE status = 'pending' AND is_active = TRUE),
    'pendingSignatures', (SELECT COUNT(*) FROM signature_invitation WHERE status = 'pending' AND is_active = TRUE),
    'pendingImports', (SELECT COUNT(*) FROM import_batch WHERE status IN ('in_progress', 'paused') AND is_active = TRUE),
    'openImpacts', (SELECT COUNT(*) FROM regulatory_impact WHERE resolved = FALSE AND is_active = TRUE)
  ) INTO v_pending;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('contractType', t.contract_type, 'count', t.cnt) ORDER BY t.cnt DESC, t.contract_type ASC), '[]'::jsonb) INTO v_top_types
  FROM (SELECT contract_type, COUNT(*) AS cnt FROM contract WHERE is_active = TRUE AND contract_type IS NOT NULL GROUP BY contract_type ORDER BY cnt DESC, contract_type ASC LIMIT 5) t;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('eventType', a."eventType", 'headline', a.headline, 'occurredAt', a."occurredAt", 'entityType', a."entityType", 'entityId', a."entityId") ORDER BY a."occurredAt" DESC), '[]'::jsonb) INTO v_activity
  FROM (
    SELECT
      al.table_name || '.' || lower(al.action) AS "eventType",
      CASE al.table_name
        WHEN 'user' THEN 'User ' || lower(al.action) || 'd'
        WHEN 'role' THEN 'Role ' || lower(al.action) || 'd'
        WHEN 'role_permission' THEN 'Role permissions updated'
        WHEN 'contract' THEN 'Contract ' || lower(al.action) || 'd'
        WHEN 'regulation' THEN 'Regulation ' || lower(al.action) || 'd'
        WHEN 'approval_matrix' THEN 'Approval matrix changed'
        ELSE al.table_name || ' ' || lower(al.action) || 'd'
      END AS headline,
      al.changed_at AS "occurredAt",
      al.table_name AS "entityType",
      al.record_id  AS "entityId"
    FROM audit_log al
    WHERE al.changed_at >= fn_demo_now() - INTERVAL '14 days'
      AND al.table_name IN ('user', 'role', 'role_permission', 'contract', 'regulation', 'approval_matrix')
    ORDER BY al.changed_at DESC
    LIMIT 8
  ) a;
  RETURN jsonb_build_object('kpis', v_kpis, 'kpiPrev', v_kpi_prev, 'trends', v_trends, 'systemHealth', v_system_health, 'pendingAdminActions', v_pending, 'topContractTypes5', v_top_types, 'systemActivity14d', v_activity);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_admin: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_dashboard_admin FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_admin TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_admin IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_dashboard_approver(p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
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
      AND EXTRACT(EPOCH FROM (fn_demo_now() - step.created_at))/3600.0 > 24;

  SELECT COUNT(*) INTO v_decided_mine
    FROM approval_decision
    WHERE decided_by = v_user_id
      AND decided_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
      AND is_active = TRUE;
  SELECT COUNT(*) INTO v_decided_prev
    FROM approval_decision
    WHERE decided_by = v_user_id
      AND decided_at >= fn_demo_now() - (2 * v_window || ' days')::INTERVAL
      AND decided_at <  fn_demo_now() - (v_window || ' days')::INTERVAL
      AND is_active = TRUE;

  v_pending_prev := v_decided_prev;

  SELECT AVG(EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0)::NUMERIC(12,2)
    INTO v_avg_mine
    FROM approval_decision ad
    JOIN approval_step step ON step.id = ad.approval_step_id
    WHERE ad.decided_by = v_user_id
      AND ad.decided_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
      AND ad.is_active = TRUE;
  SELECT AVG(EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0)::NUMERIC(12,2)
    INTO v_avg_prev
    FROM approval_decision ad
    JOIN approval_step step ON step.id = ad.approval_step_id
    WHERE ad.decided_by = v_user_id
      AND ad.decided_at >= fn_demo_now() - (2 * v_window || ' days')::INTERVAL
      AND ad.decided_at <  fn_demo_now() - (v_window || ' days')::INTERVAL
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
                                   AND ad.decided_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
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
                 ROUND((EXTRACT(EPOCH FROM (fn_demo_now() - step.created_at))/3600.0)::NUMERIC, 2) AS hours_waiting
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
              'hoursAgo',        ROUND(EXTRACT(EPOCH FROM (fn_demo_now() - ad.decided_at))/3600.0, 2)
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
        AND decided_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
        AND is_active = TRUE
    ),
    -- FIX: split aggregation — inner subquery aggregates with GROUP BY,
    -- outer jsonb_aggs the pre-aggregated rows. No nested aggregates.
    'decisionsByValue', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'bucket',   bucket,
        'approved', approved,
        'rejected', rejected,
        'other',    other
      ) ORDER BY bucket_order), '[]'::jsonb)
      FROM (
        SELECT
          bucket,
          SUM(CASE WHEN decision = 'approve' THEN 1 ELSE 0 END) AS approved,
          SUM(CASE WHEN decision = 'reject'  THEN 1 ELSE 0 END) AS rejected,
          SUM(CASE WHEN decision NOT IN ('approve','reject') THEN 1 ELSE 0 END) AS other,
          CASE bucket WHEN 'lt100k' THEN 1 WHEN 'p100to500' THEN 2 WHEN 'p500to1m' THEN 3 ELSE 4 END AS bucket_order
        FROM (
          SELECT
            CASE
              WHEN COALESCE(c.value_aed, 0) < 100000  THEN 'lt100k'
              WHEN COALESCE(c.value_aed, 0) < 500000  THEN 'p100to500'
              WHEN COALESCE(c.value_aed, 0) < 1000000 THEN 'p500to1m'
              ELSE                                          'gt1m'
            END AS bucket,
            ad.decision
          FROM approval_decision ad
          JOIN approval_step step ON step.id = ad.approval_step_id
          JOIN approval_chain ch  ON ch.id = step.approval_chain_id
          JOIN contract c         ON c.id = ch.contract_id
          WHERE ad.decided_by = v_user_id
            AND ad.decided_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
            AND ad.is_active = TRUE
        ) raw
        GROUP BY bucket
      ) agg
    ),
    'approvalsByApprover', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'userId', u.id,
        'name',   u.first_name || ' ' || u.last_name,
        'count',  agg.cnt
      ) ORDER BY agg.cnt DESC), '[]'::jsonb)
      FROM (
        SELECT ad.decided_by AS uid, COUNT(*) AS cnt
        FROM approval_decision ad
        JOIN "user" u2 ON u2.id = ad.decided_by
        JOIN role r ON r.id = u2.role_id
        WHERE r.name = v_role
          AND ad.decided_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
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
$function$
;

REVOKE ALL ON FUNCTION fn_dashboard_approver FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_approver TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_approver IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_dashboard_drafter(p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_user_id BIGINT;
  v_role    TEXT;
  v_window  INTEGER;
  v_kpis    JSONB;
  v_lists   JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('contract_drafter', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: forbidden — drafter dashboard restricted to contract_drafter, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'myDraftsCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id AND status = 'draft' AND is_active = TRUE),
    'awaitingMyActionCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('draft','resubmission_requested')
          AND is_active = TRUE),
    'readyToSendCount',
      (SELECT COUNT(*) FROM contract c
        WHERE c.drafted_by = v_user_id
          AND c.status = 'approved'
          AND c.is_active = TRUE
          AND NOT EXISTS (
            SELECT 1 FROM signature_invitation si
            WHERE si.contract_id = c.id AND si.is_active = TRUE
          )),
    'myRecentlyApprovedCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id AND status = 'approved'
          AND updated_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
          AND is_active = TRUE)
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'myDrafts5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'status', c.status,
          'valueAed', c.value_aed,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id AND status = 'draft' AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb),
    'awaitingMyAction5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'status', c.status,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id
            AND status IN ('draft','resubmission_requested')
            AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_dashboard_drafter FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_drafter TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_drafter IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_dashboard_executive(p_window_days integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_user_id     BIGINT;
  v_role        TEXT;
  v_window      INTEGER;
  v_has_ai_obs  BOOLEAN;
  v_has_exec    BOOLEAN;
  v_from        DATE;
  v_to          DATE;
  v_cost_report JSONB;
  v_ai_cost     NUMERIC;
  v_kpis        JSONB;
  v_trends      JSONB;
  v_charts      JSONB;
  v_lists       JSONB;
  v_events      JSONB;
  v_kpi_prev    JSONB;
  v_drafting    NUMERIC;
  v_legal       NUMERIC;
  v_approval    NUMERIC;
  v_signing     NUMERIC;
  v_total_value NUMERIC;
BEGIN
  v_window := COALESCE(p_window_days, 90);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_executive: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  v_has_exec := fn_current_user_has_permission('insights.executive');

  IF NOT (
    (v_role IS NOT NULL AND v_role IN ('executive', 'platform_admin', 'Super Admin'))
    OR v_has_exec
  ) THEN
    RAISE EXCEPTION 'fn_dashboard_executive: forbidden — executive dashboard restricted to executive, platform_admin, Super Admin or insights.executive permission' USING ERRCODE = '42501';
  END IF;

  v_has_ai_obs := fn_current_user_has_permission('ai.observability.read');
  IF v_has_ai_obs THEN
    v_to   := CURRENT_DATE;
    v_from := CURRENT_DATE - LEAST(v_window, 90);
    BEGIN
      v_cost_report := fn_ai_request_log_cost_report(v_from, v_to, FALSE);
      SELECT COALESCE(SUM((elem->>'totalCostUsdMicros')::BIGINT), 0) / 1000000.0
      INTO v_ai_cost
      FROM jsonb_array_elements(COALESCE(v_cost_report->'data', '[]'::jsonb)) AS elem;
    EXCEPTION WHEN OTHERS THEN v_ai_cost := NULL; END;
  ELSE v_ai_cost := NULL; END IF;

  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (sa.first_review - c.created_at)) / 86400.0), 0)
  INTO v_drafting
  FROM contract c
  JOIN LATERAL (SELECT MIN(ca.created_at) AS first_review FROM contract_activity ca
    WHERE ca.contract_id = c.id AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus','') = 'in_review') sa ON sa.first_review IS NOT NULL
  WHERE c.is_active = TRUE AND c.created_at >= CURRENT_DATE - v_window;

  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (b.first_in_approval - a.first_in_review)) / 86400.0), 0)
  INTO v_legal
  FROM contract c
  JOIN LATERAL (SELECT MIN(ca.created_at) AS first_in_review FROM contract_activity ca
    WHERE ca.contract_id = c.id AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus','') = 'in_review') a ON a.first_in_review IS NOT NULL
  JOIN LATERAL (SELECT MIN(ca.created_at) AS first_in_approval FROM contract_activity ca
    WHERE ca.contract_id = c.id AND ca.activity_type = 'status_changed'
      AND COALESCE(ca.metadata->>'toStatus','') = 'in_approval') b ON b.first_in_approval IS NOT NULL
  WHERE c.is_active = TRUE AND c.created_at >= CURRENT_DATE - v_window;

  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (ad.decided_at - s.created_at)) / 86400.0), 0)
  INTO v_approval
  FROM approval_step s JOIN approval_decision ad ON ad.approval_step_id = s.id AND ad.is_active = TRUE
  WHERE s.is_active = TRUE AND ad.decided_at >= CURRENT_DATE - v_window;

  SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (se.signed_at - si.invitation_sent_at)) / 86400.0), 0)
  INTO v_signing
  FROM signature_invitation si
  JOIN LATERAL (SELECT MIN(created_at) AS signed_at FROM signature_event sev
    WHERE sev.signature_invitation_id = si.id AND sev.event_type = 'signed' AND sev.is_active = TRUE) se ON se.signed_at IS NOT NULL
  WHERE si.is_active = TRUE AND si.invitation_sent_at >= CURRENT_DATE - v_window;

  SELECT jsonb_build_object(
    'totalActiveValueAed', (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected')),
    'activeContractsCount', (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE AND status IN ('active','fully_signed','expiring_soon')),
    'avgCycleTimeDays', ROUND((COALESCE(v_drafting,0) + COALESCE(v_legal,0)
                              + COALESCE(v_approval,0) + COALESCE(v_signing,0))::NUMERIC, 2),
    'renewalsCount90d', (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE AND status IN ('active','fully_signed','expiring_soon')
          AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'),
    'renewalValueAed90d', (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE AND status IN ('active','fully_signed','expiring_soon')
          AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'),
    'cycleTimeFunnel', jsonb_build_object(
      'draftingDays',              ROUND(COALESCE(v_drafting, 0)::NUMERIC, 2),
      'legalReviewDays',           ROUND(COALESCE(v_legal,    0)::NUMERIC, 2),
      'approvalChainDays',         ROUND(COALESCE(v_approval, 0)::NUMERIC, 2),
      'counterpartySignatureDays', ROUND(COALESCE(v_signing,  0)::NUMERIC, 2)),
    'contractsByStatus', COALESCE((SELECT jsonb_object_agg(status, contract_count) FROM vw_contract_status_summary), '{}'::jsonb),
    'expiryCliffs', jsonb_build_object(
        'next30d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days'),
        'next60d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '60 days'),
        'next90d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days')),
    'topCounterpartiesByValue5', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('counterpartyId', x.counterparty_id,
          'totalValueAed', x.total_value_aed, 'contractCount', x.contract_count) ORDER BY x.total_value_aed DESC)
        FROM (SELECT counterparty_id, COALESCE(SUM(value_aed), 0) AS total_value_aed, COUNT(*) AS contract_count
              FROM contract WHERE is_active = TRUE AND counterparty_id IS NOT NULL
              GROUP BY counterparty_id ORDER BY total_value_aed DESC LIMIT 5) x), '[]'::jsonb),
    'valueDistribution', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('bucket', bucket, 'count', cnt) ORDER BY ord)
        FROM (
          SELECT '<100k'::TEXT AS bucket, 1 AS ord,
                 (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND COALESCE(value_aed,0) < 100000) AS cnt
          UNION ALL SELECT '100k-1M', 2,
            (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND value_aed >= 100000 AND value_aed < 1000000)
          UNION ALL SELECT '1M-10M', 3,
            (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND value_aed >= 1000000 AND value_aed < 10000000)
          UNION ALL SELECT '10M+', 4,
            (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND value_aed >= 10000000)
        ) buckets), '[]'::jsonb),
    'openRegulatoryImpactsCritical', (SELECT COUNT(*) FROM regulatory_impact ri
       JOIN regulatory_update ru ON ru.id = ri.regulatory_update_id
       WHERE ri.resolved = FALSE AND ri.is_active = TRUE
         AND ru.severity = 'critical' AND ru.is_active = TRUE),
    'aiCostUsdWindow', v_ai_cost
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'totalActiveValueAed', (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected')
          AND created_at < CURRENT_DATE - v_window),
    'activeContractsCount', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
        AND status IN ('active','fully_signed','expiring_soon')
        AND created_at < CURRENT_DATE - v_window),
    'renewalsCount90d', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
        AND status IN ('active','fully_signed','expiring_soon')
        AND end_date BETWEEN CURRENT_DATE - v_window AND CURRENT_DATE - v_window + INTERVAL '90 days'),
    'renewalValueAed90d', (SELECT COALESCE(SUM(value_aed), 0) FROM contract WHERE is_active = TRUE
        AND status IN ('active','fully_signed','expiring_soon')
        AND end_date BETWEEN CURRENT_DATE - v_window AND CURRENT_DATE - v_window + INTERVAL '90 days')
  ) INTO v_kpi_prev;

  SELECT jsonb_build_object(
    'valueOverTimeByMonth', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('month', to_char(month_start, 'YYYY-MM'),
          'totalValueAed', COALESCE(c.total_value_aed, 0)) ORDER BY month_start)
        FROM generate_series(date_trunc('month', CURRENT_DATE - v_window),
          date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS gs(month_start)
        LEFT JOIN (SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS total_value_aed
                   FROM contract WHERE is_active = TRUE AND created_at >= CURRENT_DATE - v_window
                   GROUP BY 1) c ON c.m = month_start), '[]'::jsonb),
    'contractsCreatedByMonth', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('month', to_char(month_start, 'YYYY-MM'),
          'count', COALESCE(c.cnt, 0)) ORDER BY month_start)
        FROM generate_series(date_trunc('month', CURRENT_DATE - v_window),
          date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS gs(month_start)
        LEFT JOIN (SELECT date_trunc('month', created_at) AS m, COUNT(*) AS cnt
                   FROM contract WHERE is_active = TRUE AND created_at >= CURRENT_DATE - v_window
                   GROUP BY 1) c ON c.m = month_start), '[]'::jsonb)
  ) INTO v_trends;

  SELECT COALESCE(SUM(value_aed), 0) INTO v_total_value FROM contract
  WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected');

  SELECT jsonb_build_object(
    'spendByCategory', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('category', x.contract_type, 'valueAed', x.value_aed,
          'pct', CASE WHEN v_total_value > 0 THEN ROUND((x.value_aed / v_total_value * 100)::NUMERIC, 2) ELSE 0 END
        ) ORDER BY x.value_aed DESC)
        FROM (SELECT contract_type, COALESCE(SUM(value_aed), 0) AS value_aed FROM contract
              WHERE is_active = TRUE AND status NOT IN ('cancelled','expired','rejected')
              GROUP BY contract_type ORDER BY value_aed DESC LIMIT 8) x), '[]'::jsonb),
    'topSuppliers', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'counterpartyId', x.counterparty_id,
          'name', COALESCE(p.name_en, 'Unknown #' || x.counterparty_id),
          'contractCount', x.contract_count, 'totalValueAed', x.value_aed,
          'pctOfSpend', CASE WHEN v_total_value > 0 THEN ROUND((x.value_aed / v_total_value * 100)::NUMERIC, 2) ELSE 0 END,
          'sparkline12m', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('month', to_char(spm.month_start, 'YYYY-MM'),
              'valueAed', COALESCE(sub.v, 0)) ORDER BY spm.month_start)
            FROM generate_series(date_trunc('month', CURRENT_DATE - INTERVAL '11 months'),
              date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS spm(month_start)
            LEFT JOIN (SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS v
                       FROM contract WHERE is_active = TRUE AND counterparty_id = x.counterparty_id
                         AND created_at >= CURRENT_DATE - INTERVAL '12 months' GROUP BY 1) sub ON sub.m = spm.month_start), '[]'::jsonb)
        ) ORDER BY x.value_aed DESC)
        FROM (SELECT counterparty_id, COALESCE(SUM(value_aed), 0) AS value_aed, COUNT(*) AS contract_count
              FROM contract WHERE is_active = TRUE AND counterparty_id IS NOT NULL
                AND status NOT IN ('cancelled','expired','rejected')
              GROUP BY counterparty_id ORDER BY value_aed DESC LIMIT 10) x
        LEFT JOIN party p ON p.id = x.counterparty_id), '[]'::jsonb),
    'revenueUnderContract12m', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('month', to_char(rm.month_start, 'YYYY-MM'),
          'activeValueAed', COALESCE(av.v, 0), 'pipelineValueAed', COALESCE(pv.v, 0)
        ) ORDER BY rm.month_start)
        FROM generate_series(date_trunc('month', CURRENT_DATE - INTERVAL '11 months'),
          date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS rm(month_start)
        LEFT JOIN (
          SELECT date_trunc('month', d.day) AS m, SUM(c.value_aed) AS v
          FROM contract c, LATERAL generate_series(
            GREATEST(date_trunc('month', c.start_date), date_trunc('month', CURRENT_DATE - INTERVAL '11 months')),
            LEAST(date_trunc('month', COALESCE(c.end_date, CURRENT_DATE + INTERVAL '12 months')), date_trunc('month', CURRENT_DATE)),
            INTERVAL '1 month') AS d(day)
          WHERE c.is_active = TRUE AND c.status IN ('active','fully_signed','expiring_soon') AND c.start_date IS NOT NULL
          GROUP BY 1) av ON av.m = rm.month_start
        LEFT JOIN (SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS v FROM contract
                   WHERE is_active = TRUE AND status IN ('draft','in_review','in_approval')
                     AND created_at >= CURRENT_DATE - INTERVAL '12 months' GROUP BY 1) pv ON pv.m = rm.month_start), '[]'::jsonb),
    'contractThroughput12m', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('month', to_char(tm.month_start, 'YYYY-MM'),
          'initiated', COALESCE(ini.cnt, 0), 'signed', COALESCE(sgn.cnt, 0)
        ) ORDER BY tm.month_start)
        FROM generate_series(date_trunc('month', CURRENT_DATE - INTERVAL '11 months'),
          date_trunc('month', CURRENT_DATE), INTERVAL '1 month') AS tm(month_start)
        LEFT JOIN (SELECT date_trunc('month', created_at) AS m, COUNT(*) AS cnt FROM contract
                   WHERE is_active = TRUE AND created_at >= CURRENT_DATE - INTERVAL '12 months' GROUP BY 1) ini ON ini.m = tm.month_start
        LEFT JOIN (SELECT date_trunc('month', ca.created_at) AS m, COUNT(DISTINCT ca.contract_id) AS cnt
                   FROM contract_activity ca WHERE ca.activity_type = 'status_changed'
                     AND COALESCE(ca.metadata->>'toStatus','') = 'fully_signed'
                     AND ca.created_at >= CURRENT_DATE - INTERVAL '12 months' GROUP BY 1) sgn ON sgn.m = tm.month_start), '[]'::jsonb),
    'expiryCliff', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('horizon', horizon, 'valueAedAtRisk', COALESCE(value_aed, 0)) ORDER BY ord)
        FROM (
          SELECT '30d'::TEXT AS horizon, 1 AS ord, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days') AS value_aed
          UNION ALL SELECT '60d', 2, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date BETWEEN CURRENT_DATE + INTERVAL '30 days' AND CURRENT_DATE + INTERVAL '60 days')
          UNION ALL SELECT '90d', 3, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date BETWEEN CURRENT_DATE + INTERVAL '60 days' AND CURRENT_DATE + INTERVAL '90 days')
          UNION ALL SELECT '180d', 4, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date BETWEEN CURRENT_DATE + INTERVAL '90 days' AND CURRENT_DATE + INTERVAL '180 days')
          UNION ALL SELECT '365d', 5, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date BETWEEN CURRENT_DATE + INTERVAL '180 days' AND CURRENT_DATE + INTERVAL '365 days')
          UNION ALL SELECT '>365d', 6, (SELECT SUM(value_aed) FROM contract WHERE is_active = TRUE
              AND end_date > CURRENT_DATE + INTERVAL '365 days')) horizons), '[]'::jsonb)
  ) INTO v_charts;

  SELECT jsonb_build_object(
    'highRiskContracts8', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', c.id, 'contractNumber', c.contract_number,
          'titleEn', c.title_en, 'titleAr', c.title_ar, 'valueAed', c.value_aed, 'riskScore', c.ai_risk_score
        ) ORDER BY c.ai_risk_score DESC NULLS LAST)
        FROM (SELECT id, contract_number, title_en, title_ar, value_aed, ai_risk_score FROM contract
              WHERE is_active = TRUE AND ai_risk_score IS NOT NULL
              ORDER BY ai_risk_score DESC NULLS LAST LIMIT 8) c), '[]'::jsonb),
    'mostUsedTemplates8', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('templateId', x.template_id, 'nameEn', t.name_en,
          'nameAr', t.name_ar, 'usageCount', x.cnt) ORDER BY x.cnt DESC)
        FROM (SELECT template_id, COUNT(*) AS cnt FROM contract
              WHERE is_active = TRUE AND template_id IS NOT NULL
                AND created_at >= CURRENT_DATE - INTERVAL '90 days'
              GROUP BY template_id ORDER BY cnt DESC LIMIT 8) x
        LEFT JOIN contract_template t ON t.id = x.template_id), '[]'::jsonb),
    'mostAmendedContracts5', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', c.id, 'contractNumber', c.contract_number,
          'titleEn', c.title_en, 'titleAr', c.title_ar, 'currentVersion', c.current_version,
          'amendmentCount', GREATEST(c.current_version - 1, 0)
        ) ORDER BY c.current_version DESC NULLS LAST)
        FROM (SELECT id, contract_number, title_en, title_ar, current_version FROM contract
              WHERE is_active = TRUE AND current_version IS NOT NULL
              ORDER BY current_version DESC NULLS LAST LIMIT 5) c), '[]'::jsonb)
  ) INTO v_lists;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'eventType',  ev.event_type,
    'headline',   ev.headline,
    'subRef',     ev.sub_ref,
    'occurredAt', ev.occurred_at,
    'severity',   ev.severity
  ) ORDER BY ev.occurred_at DESC), '[]'::jsonb) INTO v_events
  FROM (
    SELECT event_type, headline, sub_ref, occurred_at, severity
    FROM (
      SELECT
        'regulatory_update'::TEXT AS event_type,
        ru.title_en AS headline,
        COALESCE(ru.reference_number, 'REG-' || ru.id::TEXT) AS sub_ref,
        ru.published_date::TIMESTAMPTZ AS occurred_at,
        CASE
          WHEN ru.severity = 'critical' THEN 'critical'
          WHEN ru.severity IN ('major','high') THEN 'high'
          ELSE 'low'
        END AS severity
      FROM regulatory_update ru
      WHERE ru.is_active = TRUE
        AND ru.published_date >= CURRENT_DATE - INTERVAL '14 days'
      UNION ALL
      SELECT
        ca.activity_type AS event_type,
        CASE ca.activity_type
          WHEN 'fully_executed'              THEN 'Contract fully executed'
          WHEN 'sent_for_signature'          THEN 'Sent for signature'
          WHEN 'submitted_for_approval'      THEN 'Submitted for approval'
          WHEN 'ai_risk_score_updated'       THEN 'AI risk score updated'
          WHEN 'regulatory_impact_detected'  THEN 'Regulatory impact detected'
          WHEN 'regulatory_impact_resolved'  THEN 'Regulatory impact resolved'
          ELSE ca.activity_type
        END AS headline,
        c.contract_number AS sub_ref,
        ca.created_at AS occurred_at,
        CASE
          WHEN ca.activity_type IN ('regulatory_impact_detected','ai_risk_score_updated') THEN 'high'
          WHEN ca.activity_type = 'fully_executed' THEN 'low'
          ELSE 'low'
        END AS severity
      FROM contract_activity ca
      JOIN contract c ON c.id = ca.contract_id AND c.is_active = TRUE
      WHERE ca.activity_type IN (
          'fully_executed','sent_for_signature','submitted_for_approval',
          'ai_risk_score_updated','regulatory_impact_detected','regulatory_impact_resolved')
        AND ca.created_at >= CURRENT_DATE - INTERVAL '14 days'
    ) all_events
    WHERE occurred_at IS NOT NULL
    ORDER BY occurred_at DESC
    LIMIT 8
  ) ev;

  RETURN jsonb_build_object(
    'kpis',     v_kpis,
    'kpiPrev',  v_kpi_prev,
    'trends',   v_trends,
    'charts',   v_charts,
    'lists',    v_lists,
    'events14d', v_events,
    'whatChangedToday',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'correlationId', rc.correlation_id::text,'contractId',rc.contract_id::text,
            'ruleId',rc.rule_id,'headline',rc.headline,'scenario',rc.scenario,
            'severity',rc.severity,'marAed',rc.mar_aed::text,'occurredAt',rc.occurred_at)
          ORDER BY rc.mar_aed DESC NULLS LAST, rc.occurred_at DESC)
        FROM (SELECT c.id AS correlation_id,c.contract_id,c.rule_id,c.match_reason AS headline,
            NULL::text AS scenario,
            c.created_at AS occurred_at,
            COALESCE((SELECT lrs.mar_value FROM latest_risk_score lrs
              WHERE lrs.contract_id=c.contract_id
                AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid LIMIT 1),0::numeric) AS mar_aed,
            CASE
              WHEN c.rule_id LIKE 'rule.sanctions.%' THEN 'critical'
              WHEN c.rule_id LIKE 'rule.hormuz.%' THEN 'high'
              WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN 'medium'
              WHEN c.rule_id LIKE 'rule.epc_sla.%' THEN 'medium'
              ELSE 'low'
            END AS severity
          FROM correlation c
          WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid
            AND c.created_at>=fn_demo_now()-INTERVAL '24 hours' AND c.status='active' AND c.is_active=TRUE
          ORDER BY mar_aed DESC NULLS LAST, c.created_at DESC LIMIT 8) rc
      ), '[]'::jsonb),
    'recommendedActions',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'correlationId',ra.correlation_id::text,'contractId',ra.contract_id::text,
            'ruleId',ra.rule_id,'action',ra.action,'assignedRoles',ra.assigned_roles,
            'slaHours',ra.sla_hours,'marAed',ra.mar_aed::text)
          ORDER BY ra.mar_aed DESC NULLS LAST)
        FROM (SELECT c.id AS correlation_id,c.contract_id,c.rule_id,
            COALESCE((SELECT lrs.mar_value FROM latest_risk_score lrs
              WHERE lrs.contract_id=c.contract_id
                AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid LIMIT 1),0::numeric) AS mar_aed,
            CASE
              WHEN c.rule_id LIKE 'rule.sanctions.%' THEN 'Review counterparty + obtain compliance sign-off'
              WHEN c.rule_id LIKE 'rule.hormuz.%' THEN 'Review charter party + activate alt-route clauses'
              WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN 'Trigger price review + notify counterparty'
              WHEN c.rule_id LIKE 'rule.epc_sla.%' THEN 'Review SLA breach + assess penalty exposure'
              ELSE 'Review correlation'
            END AS action,
            CASE
              WHEN c.rule_id LIKE 'rule.sanctions.%' THEN '["compliance_esg","legal_counsel"]'::jsonb
              WHEN c.rule_id LIKE 'rule.hormuz.%' THEN '["operations","legal_counsel"]'::jsonb
              WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN '["finance_treasury"]'::jsonb
              WHEN c.rule_id LIKE 'rule.epc_sla.%' THEN '["operations","contract_approver"]'::jsonb
              ELSE '["legal_counsel"]'::jsonb
            END AS assigned_roles,
            CASE
              WHEN c.rule_id LIKE 'rule.sanctions.%' THEN 4
              WHEN c.rule_id LIKE 'rule.hormuz.%' THEN 24
              WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN 72
              WHEN c.rule_id LIKE 'rule.epc_sla.%' THEN 48
              ELSE 168
            END AS sla_hours
          FROM correlation c
          WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid
            AND c.created_at>=fn_demo_now()-INTERVAL '24 hours' AND c.status='active' AND c.is_active=TRUE
          ORDER BY mar_aed DESC NULLS LAST LIMIT 8) ra
      ), '[]'::jsonb),
    'clausesTriggered',
      jsonb_build_object(
        'last7d', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'clauseFamily',cpb.clause_family,'clauseType',cpb.clause_type,
            'count',cpb.cnt,'contractsAffected',cpb.contracts_affected,'totalMarAed',cpb.total_mar_aed::text)
          ORDER BY cpb.cnt DESC, cpb.clause_type ASC)
          FROM (SELECT ct.family AS clause_family,cce.clause_type_v2 AS clause_type,
            COUNT(*)::integer AS cnt,COUNT(DISTINCT cce.contract_id)::integer AS contracts_affected,
            COALESCE(SUM((SELECT lrs.mar_value FROM latest_risk_score lrs
              WHERE lrs.contract_id=cce.contract_id
                AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid LIMIT 1)),0::numeric) AS total_mar_aed
            FROM contract_clause_extracted cce
            JOIN clause_taxonomy ct ON ct.clause_type_id=cce.clause_type_v2 AND ct.tenant_id=cce.tenant_id
            WHERE cce.tenant_id=current_setting('app.current_tenant_id',true)::uuid
              AND cce.is_active=TRUE AND cce.created_at>=fn_demo_now()-INTERVAL '7 days'
            GROUP BY ct.family,cce.clause_type_v2 ORDER BY cnt DESC LIMIT 10) cpb
        ), '[]'::jsonb),
        'last30d', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'clauseFamily',cpb.clause_family,'clauseType',cpb.clause_type,
            'count',cpb.cnt,'contractsAffected',cpb.contracts_affected,'totalMarAed',cpb.total_mar_aed::text)
          ORDER BY cpb.cnt DESC, cpb.clause_type ASC)
          FROM (SELECT ct.family AS clause_family,cce.clause_type_v2 AS clause_type,
            COUNT(*)::integer AS cnt,COUNT(DISTINCT cce.contract_id)::integer AS contracts_affected,
            COALESCE(SUM((SELECT lrs.mar_value FROM latest_risk_score lrs
              WHERE lrs.contract_id=cce.contract_id
                AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid LIMIT 1)),0::numeric) AS total_mar_aed
            FROM contract_clause_extracted cce
            JOIN clause_taxonomy ct ON ct.clause_type_id=cce.clause_type_v2 AND ct.tenant_id=cce.tenant_id
            WHERE cce.tenant_id=current_setting('app.current_tenant_id',true)::uuid
              AND cce.is_active=TRUE AND cce.created_at>=fn_demo_now()-INTERVAL '30 days'
            GROUP BY ct.family,cce.clause_type_v2 ORDER BY cnt DESC LIMIT 10) cpb
        ), '[]'::jsonb)
      )
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_executive: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_dashboard_executive FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_executive TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_executive IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_dashboard_legal_counsel(p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_user_id        BIGINT;
  v_role           TEXT;
  v_window         INTEGER;
  v_has_audit_read BOOLEAN;
  v_kpis           JSONB;
  v_lists          JSONB;
  v_approval_queue JSONB;
  v_risk           JSONB;
  v_avg_review     JSONB;
  v_reg_updates_12w JSONB;
  v_contract_types JSONB;
  v_obligations    JSONB;
  v_activity_feed  JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('legal_counsel', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: forbidden — legal counsel dashboard restricted to legal_counsel, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  v_has_audit_read := fn_current_user_has_permission('audit.read');

  SELECT jsonb_build_object(
    'regulatoryUpdatesThisWindow',
      (SELECT COUNT(*) FROM regulatory_update
        WHERE published_date >= CURRENT_DATE - v_window
          AND is_active = TRUE),
    'openRegulatoryImpacts',
      (SELECT COUNT(*) FROM regulatory_impact
        WHERE resolved = FALSE AND is_active = TRUE),
    'criticalSeverityCount',
      (SELECT COUNT(*) FROM regulatory_update ru
       JOIN regulatory_impact ri ON ri.regulatory_update_id = ru.id
       WHERE ru.severity = 'critical'
         AND ri.resolved = FALSE
         AND ru.is_active = TRUE
         AND ri.is_active = TRUE),
    'regulationCatalogSize',
      (SELECT COUNT(*) FROM regulation WHERE is_active = TRUE),
    'auditSummary',
      CASE WHEN v_has_audit_read THEN
        COALESCE((
          SELECT jsonb_object_agg(table_name, cnt)
          FROM (
            SELECT table_name, COUNT(*) AS cnt
            FROM audit_log
            WHERE changed_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
            GROUP BY table_name
          ) s
        ), '{}'::jsonb)
      ELSE NULL END,
    'activeContracts',
      (SELECT COUNT(*) FROM contract
        WHERE status IN ('active', 'fully_signed') AND is_active = TRUE),
    'expiringIn30d',
      (SELECT COUNT(*) FROM contract
        WHERE status IN ('active', 'fully_signed', 'expiring_soon')
          AND end_date IS NOT NULL
          AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days'
          AND is_active = TRUE),
    'pendingReview',
      (SELECT COUNT(*) FROM approval_step s
       JOIN approval_chain ch ON ch.id = s.approval_chain_id
       JOIN contract c ON c.id = ch.contract_id
       WHERE s.status = 'pending'
         AND s.approver_role = 'legal_counsel'
         AND ch.is_active = TRUE
         AND s.is_active = TRUE
         AND c.is_active = TRUE)
  ) INTO v_kpis;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                s.id,
    'contractId',        c.id,
    'contractNumber',    c.contract_number,
    'titleEn',           c.title_en,
    'titleAr',           c.title_ar,
    'contractType',      c.contract_type,
    'valueAed',          c.value_aed,
    'currency',          c.currency,
    'submittedAt',       ch.initiated_at,
    'drafterFirstName',  du.first_name,
    'drafterLastName',   du.last_name,
    'stepOrder',         s.step_order,
    'totalSteps',        (SELECT COUNT(*) FROM approval_step ss
                          WHERE ss.approval_chain_id = ch.id AND ss.is_active = TRUE)
  ) ORDER BY ch.initiated_at DESC NULLS LAST), '[]'::jsonb) INTO v_approval_queue
  FROM (
    SELECT id, step_order, approval_chain_id
    FROM approval_step
    WHERE status = 'pending'
      AND approver_role = 'legal_counsel'
      AND is_active = TRUE
    LIMIT 5
  ) s
  JOIN approval_chain ch ON ch.id = s.approval_chain_id
  JOIN contract c ON c.id = ch.contract_id
  LEFT JOIN "user" du ON du.id = ch.initiated_by
  WHERE c.is_active = TRUE AND ch.is_active = TRUE;

  WITH scored AS (
    SELECT c.id,
           c.contract_number,
           c.title_en,
           LEAST(100, GREATEST(0,
             20
             + CASE WHEN c.value_aed >= 1000000 THEN 25
                    WHEN c.value_aed >= 500000  THEN 15
                    ELSE 0 END
             + CASE WHEN c.contract_type IN ('vendor_services', 'consultancy', 'service', 'advisory') THEN 10 ELSE 0 END
             + CASE WHEN c.status IN ('in_approval', 'in_review') THEN 5 ELSE 0 END
             + CASE WHEN c.end_date IS NOT NULL THEN
                 CASE WHEN c.end_date < CURRENT_DATE THEN 25
                      WHEN c.end_date < CURRENT_DATE + INTERVAL '30 days' THEN 15
                      ELSE 0 END
                 ELSE 0 END
             + CASE WHEN c.governing_law IN ('ADGM', 'DIFC') THEN 5 ELSE 0 END
           )) AS risk
    FROM contract c
    WHERE c.is_active = TRUE
      AND c.status IN ('active', 'fully_signed', 'in_approval', 'in_review', 'awaiting_signature_employer', 'awaiting_signature_counterparty', 'expiring_soon')
  )
  SELECT jsonb_build_object(
    'lowCount',    (SELECT COUNT(*) FROM scored WHERE risk < 30),
    'mediumCount', (SELECT COUNT(*) FROM scored WHERE risk BETWEEN 30 AND 59),
    'highCount',   (SELECT COUNT(*) FROM scored WHERE risk >= 60),
    'totalActive', (SELECT COUNT(*) FROM scored),
    'top5HighRisk', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id',             s.id,
        'contractNumber', s.contract_number,
        'titleEn',        s.title_en,
        'risk',           s.risk
      ) ORDER BY s.risk DESC, s.contract_number)
      FROM (SELECT * FROM scored ORDER BY risk DESC, contract_number LIMIT 5) s
    ), '[]'::jsonb)
  ) INTO v_risk;

  -- R-LC1 fix: DATE - DATE returns INT in days; integer-divide by 7 directly.
  WITH weeks AS (
    SELECT generate_series(0, 11) AS w
  ), decisions AS (
    SELECT
      ((CURRENT_DATE - ad.decided_at::DATE) / 7)::INT AS weeks_ago,
      EXTRACT(EPOCH FROM (ad.decided_at - s.created_at)) / 3600.0 AS hours
    FROM approval_decision ad
    JOIN approval_step s ON s.id = ad.approval_step_id
    WHERE s.approver_role = 'legal_counsel'
      AND ad.decided_at >= CURRENT_DATE - INTERVAL '12 weeks'
      AND ad.is_active = TRUE
      AND s.is_active = TRUE
  ), agg AS (
    SELECT weeks_ago, AVG(hours) AS avg_hours
    FROM decisions
    WHERE weeks_ago >= 0 AND weeks_ago < 12
    GROUP BY weeks_ago
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'weekIndex', weeks.w,
    'avgHours', COALESCE(ROUND(agg.avg_hours::NUMERIC, 1), 0)
  ) ORDER BY weeks.w DESC), '[]'::jsonb) INTO v_avg_review
  FROM weeks LEFT JOIN agg ON agg.weeks_ago = weeks.w;

  WITH updates AS (
    SELECT
      ru.id,
      r.code AS authority,
      ((CURRENT_DATE - ru.published_date) / 7)::INT AS weeks_ago
    FROM regulatory_update ru
    LEFT JOIN regulator r ON r.id = ru.regulator_id
    WHERE ru.published_date >= CURRENT_DATE - INTERVAL '12 weeks'
      AND ru.is_active = TRUE
  )
  SELECT jsonb_build_object(
    'totalUpdates', (SELECT COUNT(*) FROM updates),
    'authoritiesActive', (SELECT COUNT(DISTINCT authority) FROM updates WHERE authority IS NOT NULL),
    'weeklyByAuthority', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'weekIndex', weeks_ago,
        'authority', authority,
        'count', cnt
      ) ORDER BY weeks_ago DESC)
      FROM (
        SELECT weeks_ago, authority, COUNT(*) AS cnt
        FROM updates
        WHERE weeks_ago >= 0 AND weeks_ago < 12
        GROUP BY 1, 2
      ) g
    ), '[]'::jsonb)
  ) INTO v_reg_updates_12w;

  WITH typed AS (
    SELECT contract_type, COUNT(*) AS cnt
    FROM contract
    WHERE status IN ('active', 'fully_signed', 'in_approval', 'awaiting_signature_employer', 'awaiting_signature_counterparty')
      AND is_active = TRUE
    GROUP BY contract_type
  ), tot AS (
    SELECT COALESCE(SUM(cnt), 0) AS total FROM typed
  )
  SELECT jsonb_build_object(
    'total', (SELECT total FROM tot),
    'rows', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'type', contract_type,
        'count', cnt,
        'pct', CASE WHEN (SELECT total FROM tot) > 0
                    THEN ROUND(100.0 * cnt / (SELECT total FROM tot), 1)
                    ELSE 0 END
      ) ORDER BY cnt DESC)
      FROM typed
    ), '[]'::jsonb)
  ) INTO v_contract_types;

  SELECT jsonb_build_object(
    'overdueCount',
      (SELECT COUNT(*) FROM contract_obligation
        WHERE status = 'overdue' AND is_active = TRUE),
    'dueThisWeekCount',
      (SELECT COUNT(*) FROM contract_obligation
        WHERE status IN ('open', 'in_progress')
          AND due_date IS NOT NULL
          AND due_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '7 days'
          AND is_active = TRUE),
    'top5', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id',              o.id,
        'titleEn',         o.title_en,
        'contractId',      o.contract_id,
        'contractNumber',  c.contract_number,
        'dueDate',         o.due_date,
        'status',          o.status,
        'daysOverdue',     CASE WHEN o.due_date < CURRENT_DATE
                                 THEN (CURRENT_DATE - o.due_date)::INT
                                 ELSE 0 END,
        'daysLeft',        CASE WHEN o.due_date >= CURRENT_DATE
                                 THEN (o.due_date - CURRENT_DATE)::INT
                                 ELSE 0 END
      ) ORDER BY
        CASE WHEN o.status = 'overdue' THEN 0 ELSE 1 END,
        o.due_date ASC NULLS LAST)
      FROM (
        SELECT id, title_en, contract_id, due_date, status
        FROM contract_obligation
        WHERE is_active = TRUE
          AND status IN ('open', 'in_progress', 'overdue')
        ORDER BY
          CASE WHEN status = 'overdue' THEN 0 ELSE 1 END,
          due_date ASC NULLS LAST
        LIMIT 5
      ) o
      JOIN contract c ON c.id = o.contract_id
    ), '[]'::jsonb)
  ) INTO v_obligations;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             a.id,
    'activityType',   a.activity_type,
    'contractId',     a.contract_id,
    'contractNumber', c.contract_number,
    'description',    COALESCE(a.metadata->>'description', a.activity_type),
    'createdAt',      a.created_at,
    'actorUserId',    a.actor_id
  ) ORDER BY a.created_at DESC), '[]'::jsonb) INTO v_activity_feed
  FROM (
    SELECT id, activity_type, contract_id, metadata, created_at, actor_id
    FROM contract_activity
    WHERE created_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
      AND is_active = TRUE
      AND activity_type IN (
        'submitted_for_approval', 'approval_decided', 'approval_reassigned',
        'approval_escalated', 'approval_delegated',
        'regulatory_impact_detected', 'regulatory_impact_resolved',
        'ai_summary_generated', 'ai_risk_score_updated', 'ai_diff_summary_generated',
        'sent_for_signature', 'signer_signed', 'fully_executed',
        'status_changed', 'version_created'
      )
    ORDER BY created_at DESC
    LIMIT 50
  ) a
  JOIN contract c ON c.id = a.contract_id
  WHERE c.is_active = TRUE;

  SELECT jsonb_build_object(
    'recentRegulatoryUpdates5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', x.id,
          'titleEn', x.title_en,
          'severity', x.severity,
          'effectiveDate', x.effective_date,
          'regulator', CASE WHEN x.reg_id IS NULL THEN NULL ELSE
            jsonb_build_object('id', x.reg_id, 'nameEn', x.reg_name_en)
          END
        ) ORDER BY x.effective_date DESC NULLS LAST, x.published_date DESC)
        FROM (
          SELECT ru.id, ru.title_en, ru.severity, ru.effective_date, ru.published_date,
                 r.id AS reg_id, r.name_en AS reg_name_en
          FROM regulatory_update ru
          LEFT JOIN regulator r ON r.id = ru.regulator_id
          WHERE ru.is_active = TRUE
          ORDER BY ru.effective_date DESC NULLS LAST, ru.published_date DESC
          LIMIT 5
        ) x
      ), '[]'::jsonb),
    'openImpacts5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', x.id,
          'contractId', x.contract_id,
          'contractNumber', x.contract_number,
          'regulationTitleEn', x.regulation_title_en,
          'severity', COALESCE(x.severity, 'unknown'),
          'detectedAt', x.detected_at
        ) ORDER BY x.detected_at DESC)
        FROM (
          SELECT ri.id, ri.contract_id, c.contract_number,
                 reg.title_en AS regulation_title_en,
                 ru.severity, ri.detected_at
          FROM regulatory_impact ri
          JOIN contract c ON c.id = ri.contract_id
          JOIN regulation reg ON reg.id = ri.regulation_id
          LEFT JOIN regulatory_update ru ON ru.id = ri.regulatory_update_id
          WHERE ri.resolved = FALSE AND ri.is_active = TRUE
          ORDER BY ri.detected_at DESC
          LIMIT 5
        ) x
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object(
    'kpis',             v_kpis,
    'lists',            v_lists,
    'approvalQueue5',   v_approval_queue,
    'risk',             v_risk,
    'avgReview12w',     v_avg_review,
    'regulatoryUpdates12w', v_reg_updates_12w,
    'contractTypes',    v_contract_types,
    'obligations',      v_obligations,
    'activityFeed',     v_activity_feed
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_dashboard_legal_counsel FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_legal_counsel TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_legal_counsel IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_dashboard_recipient(p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_user_id BIGINT;
  v_email   TEXT;
  v_role    TEXT;
  v_window  INTEGER;
  v_kpis    JSONB;
  v_lists   JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name, u.email INTO v_role, v_email
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('contract_recipient', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: forbidden — recipient dashboard restricted to contract_recipient, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'myContractsCount',
      (SELECT COUNT(DISTINCT c.id) FROM contract c
        WHERE c.is_active = TRUE
          AND v_email IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM signature_party sp
            WHERE sp.contract_id = c.id
              AND lower(sp.signer_email) = lower(v_email)
              AND sp.is_active = TRUE
          )),
    'pendingMySignatureCount',
      (SELECT COUNT(*) FROM signature_invitation si
       JOIN signature_party sp ON sp.id = si.signature_party_id
       WHERE v_email IS NOT NULL
         AND lower(sp.signer_email) = lower(v_email)
         AND si.status = 'pending'
         AND si.is_active = TRUE
         AND sp.is_active = TRUE),
    'signedByMeWindow',
      (SELECT COUNT(*) FROM signature_event se
       WHERE se.actor_user_id = v_user_id
         AND se.created_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
         AND se.event_type = 'signed'
         AND se.is_active = TRUE),
    'myObligationsCount',
      jsonb_build_object('value', 0, 'placeholder', true)
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'myContracts5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', x.id,
          'contractNumber', x.contract_number,
          'titleEn', x.title_en,
          'titleAr', x.title_ar,
          'status', x.status,
          'ourPartyId', x.our_party_id,
          'counterpartyId', NULL
        ) ORDER BY x.updated_at DESC)
        FROM (
          SELECT DISTINCT ON (c.id)
                 c.id, c.contract_number, c.title_en, c.title_ar,
                 c.status, c.updated_at, sp.id AS our_party_id
          FROM contract c
          JOIN signature_party sp ON sp.contract_id = c.id
          WHERE c.is_active = TRUE
            AND v_email IS NOT NULL
            AND lower(sp.signer_email) = lower(v_email)
            AND sp.is_active = TRUE
          ORDER BY c.id, c.updated_at DESC
          LIMIT 5
        ) x
      ), '[]'::jsonb),
    'pendingSignatures5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'invitationId', x.invitation_id,
          'contractId', x.contract_id,
          'contractNumber', x.contract_number,
          'sentAt', x.sent_at,
          'expiresAt', x.expires_at
        ) ORDER BY x.sent_at DESC)
        FROM (
          SELECT si.id AS invitation_id,
                 si.contract_id,
                 c.contract_number,
                 si.invitation_sent_at AS sent_at,
                 si.invitation_expires_at AS expires_at
          FROM signature_invitation si
          JOIN signature_party sp ON sp.id = si.signature_party_id
          JOIN contract c ON c.id = si.contract_id
          WHERE v_email IS NOT NULL
            AND lower(sp.signer_email) = lower(v_email)
            AND si.status = 'pending'
            AND si.is_active = TRUE
            AND sp.is_active = TRUE
          ORDER BY si.invitation_sent_at DESC
          LIMIT 5
        ) x
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_dashboard_recipient FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_recipient TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_recipient IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_dashboard_operations(p_actor_id bigint, p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_result JSONB;
BEGIN
  IF NOT (fn_current_user_has_permission('insights.operations') OR fn_current_user_has_permission('insights.executive')) THEN
    RAISE EXCEPTION 'permission_denied: insights.operations required' USING ERRCODE = '42501';
  END IF;
  IF p_actor_id IS NULL OR p_actor_id <= 0 THEN
    RAISE EXCEPTION 'invalid_actor_id: p_actor_id must be a positive integer' USING ERRCODE = '22023';
  END IF;
  IF p_window_days NOT BETWEEN 7 AND 365 THEN
    RAISE EXCEPTION 'invalid_window_days: p_window_days must be between 7 and 365' USING ERRCODE = '22023';
  END IF;
  WITH ops_corrs AS (
    SELECT c.id AS correlation_id,c.contract_id,c.created_at AS occurred_at,c.rule_id,c.match_reason AS headline,
      os.id AS signal_id,os.signal_kind_subtype AS subtype,os.severity_v2 AS severity,
      CASE WHEN c.created_at>=fn_demo_now()-p_window_days*INTERVAL '1 day' THEN 'current'
           WHEN c.created_at>=fn_demo_now()-(2*p_window_days)*INTERVAL '1 day' THEN 'previous' END AS bucket
    FROM correlation c
    JOIN osint_signal os ON os.id=c.signal_id AND os.tenant_id=c.tenant_id
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active'
      AND os.kind='internal' AND os.signal_kind_subtype IN ('sla_breach','milestone_slippage','vendor_incident','ics_incident')
      AND c.created_at>=fn_demo_now()-(2*p_window_days)*INTERVAL '1 day'
  ),
  ops_corrs_with_mar AS (
    SELECT oc.*,COALESCE(lrs.mar_value,0::numeric) AS mar_aed,co.contract_number,co.title_en AS contract_title,co.counterparty_id,p.name_en AS counterparty_name
    FROM ops_corrs oc
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id=oc.contract_id AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    JOIN contract co ON co.id=oc.contract_id AND co.is_active=TRUE
    LEFT JOIN party p ON p.id=co.counterparty_id
  ),
  kpi_current AS (
    SELECT COUNT(*) FILTER (WHERE subtype='sla_breach' AND bucket='current')::integer AS open_sla_breaches,
      COALESCE(SUM(mar_aed) FILTER (WHERE subtype='sla_breach' AND bucket='current'),0) AS open_sla_breaches_mar,
      COUNT(*) FILTER (WHERE subtype IN ('milestone_slippage','sla_breach') AND bucket='current')::integer AS delivery_delays,
      COALESCE(SUM(mar_aed) FILTER (WHERE bucket='current'),0) AS penalty_exposure,
      COUNT(DISTINCT counterparty_id) FILTER (WHERE bucket='current')::integer AS vendors_with_breaches
    FROM ops_corrs_with_mar
  ),
  kpi_previous AS (
    SELECT COUNT(*) FILTER (WHERE subtype='sla_breach' AND bucket='previous')::integer AS open_sla_breaches,
      COALESCE(SUM(mar_aed) FILTER (WHERE subtype='sla_breach' AND bucket='previous'),0) AS open_sla_breaches_mar,
      COUNT(*) FILTER (WHERE subtype IN ('milestone_slippage','sla_breach') AND bucket='previous')::integer AS delivery_delays,
      COALESCE(SUM(mar_aed) FILTER (WHERE bucket='previous'),0) AS penalty_exposure,
      COUNT(DISTINCT counterparty_id) FILTER (WHERE bucket='previous')::integer AS vendors_with_breaches
    FROM ops_corrs_with_mar
  ),
  sla_breaches_top8 AS (SELECT contract_id,contract_number,contract_title,counterparty_name,subtype AS breach_kind,signal_id,occurred_at,severity,mar_aed FROM ops_corrs_with_mar WHERE subtype='sla_breach' AND bucket='current' ORDER BY mar_aed DESC NULLS LAST,occurred_at DESC LIMIT 8),
  delivery_delays_per_contract AS (SELECT contract_id,contract_number,counterparty_name,COUNT(*)::integer AS signal_count_180d,MAX(occurred_at) AS last_delayed_at,MAX(severity) AS max_severity,(ARRAY_AGG(headline ORDER BY occurred_at DESC))[1] AS last_milestone FROM ops_corrs_with_mar WHERE subtype IN ('milestone_slippage','sla_breach') AND bucket='current' GROUP BY contract_id,contract_number,counterparty_name ORDER BY signal_count_180d DESC,MAX(mar_aed) DESC LIMIT 8),
  penalty_exposure_per_contract AS (SELECT contract_id,contract_number,counterparty_name,SUM(mar_aed) AS exposure_aed,STRING_AGG(headline,'; ' ORDER BY occurred_at DESC) AS penalty_clause_summary FROM ops_corrs_with_mar WHERE bucket='current' GROUP BY contract_id,contract_number,counterparty_name ORDER BY exposure_aed DESC NULLS LAST LIMIT 8),
  vendor_scorecards AS (
    SELECT co.counterparty_id,p.name_en AS counterparty_name,
      COUNT(*) FILTER (WHERE oc.subtype='sla_breach')::integer AS sla_breach_count_180d,
      COUNT(*) FILTER (WHERE oc.subtype IN ('milestone_slippage','sla_breach'))::integer AS delivery_delay_count_180d,
      COALESCE(AVG(lrs.health_score),0)::integer AS risk_score,
      CASE WHEN COALESCE(AVG(lrs.health_score),100)<50 THEN 'high' WHEN COALESCE(AVG(lrs.health_score),100)<75 THEN 'medium' ELSE 'low' END AS performance_tier
    FROM ops_corrs oc JOIN contract co ON co.id=oc.contract_id JOIN party p ON p.id=co.counterparty_id
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id=oc.contract_id AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    WHERE oc.bucket='current' GROUP BY co.counterparty_id,p.name_en ORDER BY risk_score ASC NULLS LAST,sla_breach_count_180d DESC LIMIT 8
  )
  SELECT jsonb_build_object(
    'windowDays',p_window_days,'asOf',fn_demo_now(),
    'kpi',(SELECT jsonb_build_object('openSlaBreaches',open_sla_breaches,'openSlaBreachesMarAed',open_sla_breaches_mar::text,'deliveryDelaysCount',delivery_delays,'contractPenaltyExposureAed',penalty_exposure::text,'vendorsWithBreaches',vendors_with_breaches) FROM kpi_current),
    'kpiPrev',(SELECT jsonb_build_object('openSlaBreaches',open_sla_breaches,'openSlaBreachesMarAed',open_sla_breaches_mar::text,'deliveryDelaysCount',delivery_delays,'contractPenaltyExposureAed',penalty_exposure::text,'vendorsWithBreaches',vendors_with_breaches) FROM kpi_previous),
    'slaBreachesList',COALESCE((SELECT jsonb_agg(jsonb_build_object('contractId',contract_id::text,'contractNumber',contract_number,'contractTitle',contract_title,'counterpartyName',counterparty_name,'breachKind',breach_kind,'signalId',signal_id::text,'occurredAt',occurred_at,'severity',severity,'marAed',mar_aed::text) ORDER BY mar_aed DESC NULLS LAST) FROM sla_breaches_top8),'[]'::jsonb),
    'deliveryDelayTracker',COALESCE((SELECT jsonb_agg(jsonb_build_object('contractId',contract_id::text,'contractNumber',contract_number,'counterpartyName',counterparty_name,'lastDelayedMilestone',last_milestone,'delayDays',CASE WHEN last_delayed_at IS NOT NULL THEN (CURRENT_DATE-last_delayed_at::date)::integer ELSE NULL END,'signalCount180d',signal_count_180d,'severity',max_severity) ORDER BY signal_count_180d DESC) FROM delivery_delays_per_contract),'[]'::jsonb),
    'penaltyExposureByContract',COALESCE((SELECT jsonb_agg(jsonb_build_object('contractId',contract_id::text,'contractNumber',contract_number,'counterpartyName',counterparty_name,'penaltyClauseSummary',penalty_clause_summary,'exposureAed',exposure_aed::text) ORDER BY exposure_aed DESC NULLS LAST) FROM penalty_exposure_per_contract),'[]'::jsonb),
    'opsEventsFeed',COALESCE((SELECT jsonb_agg(jsonb_build_object('eventType',rule_id,'contractId',contract_id::text,'counterpartyName',counterparty_name,'headline',headline,'occurredAt',occurred_at,'severity',severity,'sourceRef',signal_id::text) ORDER BY occurred_at DESC) FROM (SELECT * FROM ops_corrs_with_mar WHERE bucket='current' ORDER BY occurred_at DESC LIMIT 15) ev),'[]'::jsonb),
    'vendorScorecards',COALESCE((SELECT jsonb_agg(jsonb_build_object('counterpartyId',counterparty_id::text,'counterpartyName',counterparty_name,'slaBreachCount180d',sla_breach_count_180d,'deliveryDelayCount180d',delivery_delay_count_180d,'riskScore',risk_score,'performanceTier',performance_tier) ORDER BY risk_score ASC NULLS LAST) FROM vendor_scorecards),'[]'::jsonb)
  ) INTO v_result;
  RETURN v_result;
EXCEPTION
  WHEN OTHERS THEN RAISE EXCEPTION 'fn_dashboard_operations: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_dashboard_operations FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_operations TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_operations IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_dashboard_finance_treasury(p_actor_id bigint, p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE v_result JSONB;
BEGIN
  IF NOT (fn_current_user_has_permission('insights.finance_treasury') OR fn_current_user_has_permission('insights.executive')) THEN
    RAISE EXCEPTION 'permission_denied: insights.finance_treasury required' USING ERRCODE='42501';
  END IF;
  IF p_actor_id IS NULL OR p_actor_id<=0 THEN RAISE EXCEPTION 'invalid_actor_id' USING ERRCODE='22023'; END IF;
  IF p_window_days NOT BETWEEN 7 AND 365 THEN RAISE EXCEPTION 'invalid_window_days' USING ERRCODE='22023'; END IF;
  WITH price_review_corr AS (
    SELECT c.id AS correlation_id,c.contract_id,c.rule_id,c.match_reason AS trigger_headline,c.created_at AS occurred_at,
      cr.scenario AS index_name,COALESCE(lrs.mar_value,0::numeric) AS mar_aed,
      CASE
        WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN 'Trigger price review + notify counterparty'
        ELSE 'Review correlation'
      END AS recommended_action,
      co.contract_number,p.name_en AS counterparty_name,
      NULLIF(cr.meta->>'index_move_bps','')::integer AS index_move_bps,os.id AS trigger_signal_ref
    FROM correlation c JOIN correlation_rule cr ON cr.rule_id=c.rule_id AND cr.tenant_id=c.tenant_id
    LEFT JOIN osint_signal os ON os.id=c.signal_id
    JOIN contract co ON co.id=c.contract_id AND co.is_active=TRUE
    LEFT JOIN party p ON p.id=co.counterparty_id
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id=c.contract_id AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active'
      AND c.created_at>=fn_demo_now()-p_window_days*INTERVAL '1 day' AND c.rule_id LIKE ANY (ARRAY['rule.brent.%','rule.dubai.%','rule.murban.%'])
    ORDER BY mar_aed DESC NULLS LAST LIMIT 8
  ),
  payment_delay_corr AS (
    SELECT c.id AS correlation_id,c.contract_id,c.created_at AS occurred_at,c.match_reason AS headline,
      os.id AS signal_id,os.severity_v2 AS severity,co.contract_number,p.name_en AS counterparty_name,
      COALESCE(lrs.mar_value,0::numeric) AS amount_aed,
      NULLIF(os.metadata->>'days_overdue','')::integer AS days_overdue,NULLIF(os.metadata->>'invoice_ref','') AS invoice_ref
    FROM correlation c JOIN osint_signal os ON os.id=c.signal_id AND os.tenant_id=c.tenant_id
    JOIN contract co ON co.id=c.contract_id LEFT JOIN party p ON p.id=co.counterparty_id
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id=c.contract_id AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active'
      AND os.kind='internal' AND os.signal_kind_subtype IN ('payment_delay','invoice_dispute')
      AND c.created_at>=fn_demo_now()-p_window_days*INTERVAL '1 day'
    ORDER BY occurred_at DESC LIMIT 8
  ),
  payment_delay_corr_prev AS (
    SELECT c.id FROM correlation c JOIN osint_signal os ON os.id=c.signal_id AND os.tenant_id=c.tenant_id
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active'
      AND os.kind='internal' AND os.signal_kind_subtype IN ('payment_delay','invoice_dispute')
      AND c.created_at BETWEEN fn_demo_now()-(2*p_window_days)*INTERVAL '1 day' AND fn_demo_now()-p_window_days*INTERVAL '1 day'
  ),
  price_review_corr_prev AS (
    SELECT c.id FROM correlation c
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active'
      AND c.rule_id LIKE ANY (ARRAY['rule.brent.%','rule.dubai.%','rule.murban.%'])
      AND c.created_at BETWEEN fn_demo_now()-(2*p_window_days)*INTERVAL '1 day' AND fn_demo_now()-p_window_days*INTERVAL '1 day'
  ),
  currency_breakdown AS (
    SELECT co.currency,COUNT(*)::integer AS contract_count,COALESCE(SUM(co.value_aed),0) AS aggregate_value_aed
    FROM contract co WHERE co.is_active=TRUE AND co.status IN ('active','pending_review','signed','fully_signed') GROUP BY co.currency
    UNION ALL SELECT 'AED'::text,0,0::numeric WHERE NOT EXISTS (SELECT 1 FROM contract co2 WHERE co2.currency='AED' AND co2.is_active=TRUE)
  ),
  total_value AS (SELECT COALESCE(SUM(aggregate_value_aed),0) AS grand_total FROM currency_breakdown),
  commodity_series_raw AS (
    SELECT
      os.raw_payload->>'marker' AS marker,
      DATE(COALESCE(os.event_date_v2, os.fetched_at, os.created_at)) AS observed_date,
      AVG(NULLIF(os.raw_payload->>'price','')::numeric) AS price_usd
    FROM osint_signal os
    WHERE os.tenant_id=current_setting('app.current_tenant_id',true)::uuid
      AND os.is_active=TRUE
      AND os.source_id='commodity_crude'
      AND os.raw_payload?'marker'
      AND os.raw_payload->>'marker' IN ('BRENT','DUBAI','MURBAN')
      AND COALESCE(os.event_date_v2, os.fetched_at, os.created_at) >= fn_demo_now() - INTERVAL '30 days'
    GROUP BY os.raw_payload->>'marker', DATE(COALESCE(os.event_date_v2, os.fetched_at, os.created_at))
  ),
  commodity_series_agg AS (
    SELECT marker, jsonb_agg(jsonb_build_object('date', observed_date, 'priceUsd', price_usd) ORDER BY observed_date ASC) AS trend30d
    FROM commodity_series_raw
    GROUP BY marker
  ),
  commodity_current AS (
    SELECT DISTINCT ON (os.raw_payload->>'marker')
      os.raw_payload->>'marker' AS marker,
      NULLIF(os.raw_payload->>'price','')::numeric AS current_price_usd,
      NULLIF(os.raw_payload->>'threshold_proximity_bps','')::integer AS threshold_proximity_bps
    FROM osint_signal os
    WHERE os.tenant_id=current_setting('app.current_tenant_id',true)::uuid
      AND os.is_active=TRUE
      AND os.source_id='commodity_crude'
      AND os.raw_payload?'marker'
      AND os.raw_payload->>'marker' IN ('BRENT','DUBAI','MURBAN')
    ORDER BY os.raw_payload->>'marker', COALESCE(os.event_date_v2, os.fetched_at, os.created_at) DESC
  ),
  commodity_contracts AS (
    SELECT
      UPPER(cr.scenario) AS marker,
      jsonb_agg(jsonb_build_object(
        'contractId',  co.id::text,
        'contractNumber', co.contract_number,
        'counterpartyName', p.name_en,
        'valueAed', co.value_aed::text
      ) ORDER BY co.value_aed DESC NULLS LAST) AS contracts_exposed
    FROM correlation c
    JOIN correlation_rule cr ON cr.rule_id=c.rule_id AND cr.tenant_id=c.tenant_id
    JOIN contract co ON co.id=c.contract_id AND co.is_active=TRUE
    LEFT JOIN party p ON p.id=co.counterparty_id
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid
      AND c.is_active=TRUE AND c.status='active'
      AND cr.scenario IN ('brent','dubai','murban')
    GROUP BY UPPER(cr.scenario)
  ),
  fx_signals_raw AS (
    SELECT
      DATE(COALESCE(os.event_date_v2, os.fetched_at, os.created_at)) AS observed_date,
      COALESCE(os.event_date_v2, os.fetched_at, os.created_at) AS observed_at,
      NULLIF(os.metadata->>'peg_deviation_bps','')::integer AS meta_dev_bps,
      NULLIF(os.raw_payload->>'rate','')::numeric AS rate
    FROM osint_signal os
    WHERE os.tenant_id=current_setting('app.current_tenant_id',true)::uuid
      AND os.is_active=TRUE
      AND os.source_id='fx_usd_aed'
      AND (
        os.raw_payload->>'pair'='AED'
        OR os.affected_entities @> '[{"identifier":"USD_AED"}]'::jsonb
      )
      AND COALESCE(os.event_date_v2, os.fetched_at, os.created_at) >= fn_demo_now() - INTERVAL '30 days'
  ),
  fx_signals_resolved AS (
    SELECT
      observed_date,
      observed_at,
      CASE
        WHEN meta_dev_bps IS NOT NULL THEN meta_dev_bps
        WHEN rate IS NOT NULL THEN ROUND(((rate - 3.6725) / 3.6725 * 10000)::numeric, 0)::integer
        ELSE NULL
      END AS deviation_bps
    FROM fx_signals_raw
  ),
  fx_series_day AS (
    SELECT observed_date, AVG(deviation_bps)::numeric AS deviation_bps
    FROM fx_signals_resolved
    WHERE deviation_bps IS NOT NULL
    GROUP BY observed_date
  ),
  fx_series_agg AS (
    SELECT jsonb_agg(jsonb_build_object('date', observed_date, 'deviationBps', deviation_bps) ORDER BY observed_date ASC) AS series30d
    FROM fx_series_day
  ),
  fx_current AS (
    SELECT deviation_bps
    FROM fx_signals_resolved
    WHERE deviation_bps IS NOT NULL
    ORDER BY observed_at DESC
    LIMIT 1
  ),
  kpi_current AS (
    SELECT COALESCE((SELECT SUM(value_aed) FROM contract WHERE is_active=TRUE AND status IN ('active','fully_signed','signed')),0) AS total_exposure_aed,
      COALESCE((SELECT SUM(value_aed) FROM contract WHERE is_active=TRUE AND currency<>'AED' AND status IN ('active','fully_signed','signed')),0) AS fx_exposure_non_aed_aed,
      (SELECT COUNT(*) FROM price_review_corr)::integer AS price_review_triggered_count,
      (SELECT COUNT(*) FROM payment_delay_corr)::integer AS payment_delays_count,
      COALESCE((SELECT SUM(amount_aed) FROM payment_delay_corr),0) AS payment_delays_aed
  ),
  kpi_previous AS (
    SELECT COALESCE((SELECT SUM(value_aed) FROM contract WHERE is_active=TRUE AND status IN ('active','fully_signed','signed') AND created_at<fn_demo_now()-p_window_days*INTERVAL '1 day'),0) AS total_exposure_aed,
      COALESCE((SELECT SUM(value_aed) FROM contract WHERE is_active=TRUE AND currency<>'AED' AND status IN ('active','fully_signed','signed') AND created_at<fn_demo_now()-p_window_days*INTERVAL '1 day'),0) AS fx_exposure_non_aed_aed,
      (SELECT COUNT(*) FROM price_review_corr_prev)::integer AS price_review_triggered_count,
      (SELECT COUNT(*) FROM payment_delay_corr_prev)::integer AS payment_delays_count,
      0::numeric AS payment_delays_aed
  )
  SELECT jsonb_build_object(
    'windowDays',p_window_days,'asOf',fn_demo_now(),
    'kpi',(SELECT jsonb_build_object('totalExposureAed',total_exposure_aed::text,'fxExposureNonAedAed',fx_exposure_non_aed_aed::text,'priceReviewTriggeredCount',price_review_triggered_count,'paymentDelaysCount',payment_delays_count,'paymentDelaysAed',payment_delays_aed::text) FROM kpi_current),
    'kpiPrev',(SELECT jsonb_build_object('totalExposureAed',total_exposure_aed::text,'fxExposureNonAedAed',fx_exposure_non_aed_aed::text,'priceReviewTriggeredCount',price_review_triggered_count,'paymentDelaysCount',payment_delays_count,'paymentDelaysAed',payment_delays_aed::text) FROM kpi_previous),
    'fxVolatilityTile',jsonb_build_object('aedPegStatus','stable','pegDeviationBps',NULL,'lastCheckedAt',fn_demo_now(),'nonAedContractCount',(SELECT COUNT(*) FROM contract WHERE currency<>'AED' AND is_active=TRUE)::integer,'nonAedContractValueAed',COALESCE((SELECT SUM(value_aed) FROM contract WHERE currency<>'AED' AND is_active=TRUE),0)::text),
    'priceReviewTriggerQueue',COALESCE((SELECT jsonb_agg(jsonb_build_object('correlationId',correlation_id::text,'contractId',contract_id::text,'contractNumber',contract_number,'counterpartyName',counterparty_name,'triggerSignalRef',trigger_signal_ref::text,'triggerHeadline',trigger_headline,'indexName',index_name,'indexMoveBps',index_move_bps,'marAed',mar_aed::text,'recommendedAction',recommended_action,'occurredAt',occurred_at) ORDER BY mar_aed DESC NULLS LAST) FROM price_review_corr),'[]'::jsonb),
    'paymentDelayRegister',COALESCE((SELECT jsonb_agg(jsonb_build_object('correlationId',correlation_id::text,'contractId',contract_id::text,'contractNumber',contract_number,'counterpartyName',counterparty_name,'signalId',signal_id::text,'invoiceRef',invoice_ref,'daysOverdue',days_overdue,'amountAed',amount_aed::text,'severity',severity) ORDER BY occurred_at DESC) FROM payment_delay_corr),'[]'::jsonb),
    'currencyExposureBreakdown',COALESCE((SELECT jsonb_agg(jsonb_build_object('currency',cb.currency,'contractCount',cb.contract_count,'aggregateValueOriginal',cb.aggregate_value_aed::text,'aggregateValueAed',cb.aggregate_value_aed::text,'percentOfTotal',CASE WHEN tv.grand_total>0 THEN ROUND((cb.aggregate_value_aed/tv.grand_total)::numeric,4) ELSE 0 END) ORDER BY cb.aggregate_value_aed DESC) FROM currency_breakdown cb CROSS JOIN total_value tv),'[]'::jsonb),
    'commodityExposure', jsonb_build_object(
      'brent', (SELECT jsonb_build_object('currentPriceUsd', cc.current_price_usd,'trend30d',COALESCE(csa.trend30d, '[]'::jsonb),'thresholdProximityBps', cc.threshold_proximity_bps,'contractsExposed', COALESCE(cco.contracts_exposed, '[]'::jsonb)) FROM (SELECT NULL::numeric AS current_price_usd, NULL::integer AS threshold_proximity_bps) base LEFT JOIN commodity_current cc ON cc.marker='BRENT' LEFT JOIN commodity_series_agg csa ON csa.marker='BRENT' LEFT JOIN commodity_contracts cco ON cco.marker='BRENT'),
      'dubai', (SELECT jsonb_build_object('currentPriceUsd', cc.current_price_usd,'trend30d',COALESCE(csa.trend30d, '[]'::jsonb),'thresholdProximityBps', cc.threshold_proximity_bps,'contractsExposed', COALESCE(cco.contracts_exposed, '[]'::jsonb)) FROM (SELECT NULL::numeric AS current_price_usd, NULL::integer AS threshold_proximity_bps) base LEFT JOIN commodity_current cc ON cc.marker='DUBAI' LEFT JOIN commodity_series_agg csa ON csa.marker='DUBAI' LEFT JOIN commodity_contracts cco ON cco.marker='DUBAI'),
      'murban',(SELECT jsonb_build_object('currentPriceUsd', cc.current_price_usd,'trend30d',COALESCE(csa.trend30d, '[]'::jsonb),'thresholdProximityBps', cc.threshold_proximity_bps,'contractsExposed', COALESCE(cco.contracts_exposed, '[]'::jsonb)) FROM (SELECT NULL::numeric AS current_price_usd, NULL::integer AS threshold_proximity_bps) base LEFT JOIN commodity_current cc ON cc.marker='MURBAN' LEFT JOIN commodity_series_agg csa ON csa.marker='MURBAN' LEFT JOIN commodity_contracts cco ON cco.marker='MURBAN')
    ),
    'fxHistory', jsonb_build_object(
      'pair', 'USD/AED',
      'currentDeviationBps', (SELECT deviation_bps FROM fx_current),
      'series30d', COALESCE((SELECT series30d FROM fx_series_agg), '[]'::jsonb),
      'severityThresholdBps', 50
    )
  ) INTO v_result;
  RETURN v_result;
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_dashboard_finance_treasury: %', SQLERRM USING ERRCODE=SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_dashboard_finance_treasury FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_finance_treasury TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_finance_treasury IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_dashboard_compliance_esg(p_actor_id bigint, p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_result JSONB; v_chain_rows JSONB; v_chain_row JSONB;
  v_chain_sanctions_count INTEGER := 0; v_party BIGINT; v_chain_summary JSONB;
  v_sanctions_chain_items JSONB[] := ARRAY[]::JSONB[]; v_contract_count INTEGER; v_chain_row_built JSONB;
BEGIN
  IF NOT (fn_current_user_has_permission('insights.compliance_esg') OR fn_current_user_has_permission('insights.executive')) THEN
    RAISE EXCEPTION 'permission_denied: insights.compliance_esg required' USING ERRCODE='42501';
  END IF;
  IF p_actor_id IS NULL OR p_actor_id<=0 THEN RAISE EXCEPTION 'invalid_actor_id' USING ERRCODE='22023'; END IF;
  IF p_window_days NOT BETWEEN 7 AND 365 THEN RAISE EXCEPTION 'invalid_window_days' USING ERRCODE='22023'; END IF;
  FOR v_party IN SELECT DISTINCT co.counterparty_id FROM contract co WHERE co.is_active=TRUE AND co.counterparty_id IS NOT NULL
  LOOP
    BEGIN v_chain_summary := fn_party_chain_summary(p_actor_id,v_party,5);
    EXCEPTION WHEN OTHERS THEN v_chain_summary := NULL; END;
    IF v_chain_summary IS NOT NULL AND (v_chain_summary->>'sanctionedNodesCount')::integer>0 THEN
      SELECT COUNT(DISTINCT co.id)::integer INTO v_contract_count FROM contract co WHERE co.counterparty_id=v_party AND co.is_active=TRUE;
      v_chain_row_built := jsonb_build_object('chainRootCounterpartyId',v_party::text,'chainRootName',COALESCE((SELECT name_en FROM party WHERE id=v_party),'Unknown'),'depthReached',COALESCE((v_chain_summary->>'chainDepth')::integer,0),'sanctionedNodesCount',(v_chain_summary->>'sanctionedNodesCount')::integer,'affectedContractsCount',v_contract_count,'chainTruncated',COALESCE((v_chain_summary->>'chainTruncated')::boolean,FALSE));
      v_sanctions_chain_items := array_append(v_sanctions_chain_items,v_chain_row_built);
      v_chain_sanctions_count := v_chain_sanctions_count+1;
    END IF;
  END LOOP;
  IF array_length(v_sanctions_chain_items,1)>0 THEN
    SELECT jsonb_agg(item ORDER BY (item->>'affectedContractsCount')::integer DESC) INTO v_chain_rows FROM unnest(v_sanctions_chain_items) AS item LIMIT 8;
  ELSE v_chain_rows := '[]'::jsonb; END IF;
  WITH direct_sanctions AS (
    SELECT co.id AS contract_id,co.contract_number,p.id AS counterparty_id,p.name_en AS counterparty_name,
      p.sanctions_status,'direct'::text AS exposure_kind,NULL::text[] AS chain_path,FALSE AS chain_truncated,
      COALESCE(lrs.mar_value,0::numeric) AS mar_aed
    FROM contract co JOIN party p ON p.id=co.counterparty_id
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id=co.id AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    WHERE co.is_active=TRUE AND p.sanctions_status<>'clean' AND p.is_active=TRUE ORDER BY mar_aed DESC NULLS LAST LIMIT 10
  ),
  audit_rights AS (
    SELECT cce.contract_id,co.contract_number,p.name_en AS counterparty_name,cce.clause_type_v2 AS audit_clause_type,
      (cce.parameters->>'endDate')::date AS expires_on,((cce.parameters->>'endDate')::date-CURRENT_DATE)::integer AS days_to_expiry,
      CASE WHEN ((cce.parameters->>'endDate')::date-CURRENT_DATE)<30 THEN 'high' WHEN ((cce.parameters->>'endDate')::date-CURRENT_DATE)<90 THEN 'medium' ELSE 'low' END AS severity
    FROM contract_clause_extracted cce JOIN contract co ON co.id=cce.contract_id LEFT JOIN party p ON p.id=co.counterparty_id
    WHERE cce.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND cce.is_active=TRUE AND cce.clause_type_v2='audit_rights' AND cce.parameters?'endDate'
    ORDER BY expires_on ASC NULLS LAST LIMIT 15
  ),
  reg_updates AS (
    SELECT ru.id AS regulatory_update_id,ru.title_en AS headline,ru.severity,ru.published_date AS occurred_at,
      COALESCE((SELECT r2.name_en FROM regulator r2 WHERE r2.id=ru.regulator_id LIMIT 1),COALESCE(ru.sub_source,'Regulator-'||ru.regulator_id::text)) AS regulator_name,
      (SELECT COUNT(*) FROM regulatory_impact ri WHERE ri.regulatory_update_id=ru.id)::integer AS affected_contracts_count
    FROM regulatory_update ru
    WHERE ru.is_active=TRUE AND ru.published_date>=fn_demo_now()-p_window_days*INTERVAL '1 day'
    ORDER BY ru.published_date DESC LIMIT 8
  ),
  esg_corrs AS (
    SELECT c.id AS correlation_id,c.match_reason AS headline,c.contract_id,p.name_en AS counterparty_name,COALESCE(lrs.mar_value,0::numeric) AS mar_aed,c.created_at AS occurred_at,
      CASE
        WHEN c.rule_id LIKE 'rule.sanctions.%' THEN 'critical'
        WHEN c.rule_id LIKE 'rule.hormuz.%' THEN 'high'
        WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN 'medium'
        WHEN c.rule_id LIKE 'rule.epc_sla.%' THEN 'medium'
        ELSE 'medium'
      END AS severity
    FROM correlation c
    JOIN contract co ON co.id=c.contract_id LEFT JOIN party p ON p.id=co.counterparty_id
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id=c.contract_id AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active' AND c.rule_id LIKE 'rule.esg.%'
    ORDER BY mar_aed DESC NULLS LAST LIMIT 8
  ),
  direct_sanctions_prev AS (SELECT co.id FROM contract co JOIN party p ON p.id=co.counterparty_id WHERE co.is_active=TRUE AND p.sanctions_status<>'clean' AND p.is_active=TRUE AND co.created_at<fn_demo_now()-p_window_days*INTERVAL '1 day'),
  audit_rights_prev AS (SELECT cce.contract_id FROM contract_clause_extracted cce WHERE cce.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND cce.is_active=TRUE AND cce.clause_type_v2='audit_rights' AND cce.parameters?'endDate' AND ((cce.parameters->>'endDate')::date-CURRENT_DATE) BETWEEN 0 AND 90 AND cce.created_at<fn_demo_now()-p_window_days*INTERVAL '1 day'),
  reg_updates_prev AS (SELECT ru.id FROM regulatory_update ru WHERE ru.is_active=TRUE AND ru.published_date>=fn_demo_now()-(2*p_window_days)*INTERVAL '1 day' AND ru.published_date<fn_demo_now()-p_window_days*INTERVAL '1 day'),
  esg_corrs_prev AS (SELECT c.id FROM correlation c WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active' AND c.rule_id LIKE 'rule.esg.%' AND c.created_at>=fn_demo_now()-(2*p_window_days)*INTERVAL '1 day' AND c.created_at<fn_demo_now()-p_window_days*INTERVAL '1 day'),
  icv_per_contract AS (
    SELECT ca.contract_id, MAX(CASE WHEN ca.description ~ 'valid_until=\d{4}-\d{2}-\d{2}' THEN substring(ca.description from 'valid_until=(\d{4}-\d{2}-\d{2})')::date ELSE NULL END) AS valid_until
    FROM contract_attachment ca WHERE ca.is_active = TRUE AND ca.kind = 'icv_certificate' GROUP BY ca.contract_id
  ),
  contracts_in_scope AS (
    SELECT co.id AS contract_id, co.contract_number, p.name_en AS counterparty_name
    FROM contract co LEFT JOIN party p ON p.id = co.counterparty_id
    WHERE co.is_active = TRUE AND co.counterparty_id IS NOT NULL AND co.status IN ('active','fully_signed','signed','pending_review')
  ),
  icv_status_per_contract AS (
    SELECT cs.contract_id, cs.contract_number, cs.counterparty_name, ipc.valid_until,
      CASE
        WHEN ipc.valid_until IS NULL THEN 'missing'
        WHEN ipc.valid_until < CURRENT_DATE THEN 'expired'
        WHEN ipc.valid_until <= CURRENT_DATE + INTERVAL '90 days' THEN 'expiringWithin90d'
        ELSE 'upToDate'
      END AS icv_status
    FROM contracts_in_scope cs LEFT JOIN icv_per_contract ipc ON ipc.contract_id = cs.contract_id
  ),
  icv_summary_kpi AS (
    SELECT
      COUNT(*) FILTER (WHERE icv_status='upToDate')::integer        AS up_to_date,
      COUNT(*) FILTER (WHERE icv_status='expiringWithin90d')::integer AS expiring_within_90d,
      COUNT(*) FILTER (WHERE icv_status='expired')::integer          AS expired,
      COUNT(*) FILTER (WHERE icv_status='missing')::integer          AS missing,
      COUNT(*)::integer                                              AS total_scoped
    FROM icv_status_per_contract
  ),
  icv_list AS (
    SELECT jsonb_agg(item ORDER BY (item->>'daysToExpiry')::integer NULLS FIRST) AS list
    FROM (
      SELECT jsonb_build_object(
        'contractId',       contract_id::text,
        'contractNumber',   contract_number,
        'counterpartyName', counterparty_name,
        'icvStatus',        icv_status,
        'validUntil',       valid_until,
        'daysToExpiry',     CASE WHEN valid_until IS NOT NULL THEN (valid_until - CURRENT_DATE)::integer ELSE NULL END
      ) AS item
      FROM icv_status_per_contract
      WHERE icv_status IN ('expired','expiringWithin90d','missing')
      ORDER BY CASE icv_status WHEN 'expired' THEN 0 WHEN 'expiringWithin90d' THEN 1 ELSE 2 END, valid_until ASC NULLS LAST
      LIMIT 10
    ) sub
  ),
  kpi_current AS (SELECT (SELECT COUNT(*) FROM direct_sanctions)::integer AS sanctions_direct,v_chain_sanctions_count AS sanctions_chain,(SELECT COUNT(*) FROM audit_rights WHERE days_to_expiry BETWEEN 0 AND 90)::integer AS audit_rights_expiring,(SELECT COUNT(*) FROM reg_updates)::integer AS open_reg_updates,(SELECT COUNT(*) FROM esg_corrs)::integer AS open_esg_corrs),
  kpi_previous AS (SELECT (SELECT COUNT(*) FROM direct_sanctions_prev)::integer AS sanctions_direct,0::integer AS sanctions_chain,(SELECT COUNT(*) FROM audit_rights_prev)::integer AS audit_rights_expiring,(SELECT COUNT(*) FROM reg_updates_prev)::integer AS open_reg_updates,(SELECT COUNT(*) FROM esg_corrs_prev)::integer AS open_esg_corrs)
  SELECT jsonb_build_object(
    'windowDays',p_window_days,'asOf',fn_demo_now(),
    'kpi',(SELECT jsonb_build_object('sanctionsExposureDirectCount',sanctions_direct,'sanctionsExposureChainCount',sanctions_chain,'auditRightsExpiringCount',audit_rights_expiring,'openRegulatoryUpdatesCount',open_reg_updates,'openEsgCorrelationsCount',open_esg_corrs) FROM kpi_current),
    'kpiPrev',(SELECT jsonb_build_object('sanctionsExposureDirectCount',sanctions_direct,'sanctionsExposureChainCount',sanctions_chain,'auditRightsExpiringCount',audit_rights_expiring,'openRegulatoryUpdatesCount',open_reg_updates,'openEsgCorrelationsCount',open_esg_corrs) FROM kpi_previous),
    'sanctionsExposureList',COALESCE((SELECT jsonb_agg(jsonb_build_object('contractId',contract_id::text,'contractNumber',contract_number,'counterpartyId',counterparty_id::text,'counterpartyName',counterparty_name,'sanctionsStatus',sanctions_status,'exposureKind',exposure_kind,'chainPath',chain_path,'chainTruncated',chain_truncated,'marAed',mar_aed::text) ORDER BY mar_aed DESC NULLS LAST) FROM direct_sanctions),'[]'::jsonb),
    'auditRightsTracker',COALESCE((SELECT jsonb_agg(jsonb_build_object('contractId',contract_id::text,'contractNumber',contract_number,'counterpartyName',counterparty_name,'auditClauseType',audit_clause_type,'expiresOnIso',expires_on,'daysToExpiry',days_to_expiry,'severity',severity) ORDER BY days_to_expiry ASC) FROM audit_rights),'[]'::jsonb),
    'subContractorChainView',COALESCE(v_chain_rows,'[]'::jsonb),
    'regulatoryUpdatesMonitor',COALESCE((SELECT jsonb_agg(jsonb_build_object('regulatoryUpdateId',regulatory_update_id::text,'regulatorName',regulator_name,'headline',headline,'severity',severity,'occurredAt',occurred_at,'affectedContractsCount',affected_contracts_count) ORDER BY occurred_at DESC) FROM reg_updates),'[]'::jsonb),
    'esgCorrelations',COALESCE((SELECT jsonb_agg(jsonb_build_object('correlationId',correlation_id::text,'headline',headline,'contractId',contract_id::text,'counterpartyName',counterparty_name,'marAed',mar_aed::text,'occurredAt',occurred_at,'severity',severity) ORDER BY mar_aed DESC NULLS LAST) FROM esg_corrs),'[]'::jsonb),
    'icvCertificateSummary', jsonb_build_object(
      'upToDate',             (SELECT up_to_date FROM icv_summary_kpi),
      'expiringWithin90d',    (SELECT expiring_within_90d FROM icv_summary_kpi),
      'expired',              (SELECT expired FROM icv_summary_kpi),
      'missing',              (SELECT missing FROM icv_summary_kpi),
      'totalContractsScoped', (SELECT total_scoped FROM icv_summary_kpi),
      'list',                 COALESCE((SELECT list FROM icv_list), '[]'::jsonb)
    )
  ) INTO v_result;
  RETURN v_result;
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_dashboard_compliance_esg: %', SQLERRM USING ERRCODE=SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_dashboard_compliance_esg FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_compliance_esg TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_compliance_esg IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_dashboard_procurement_supplier_risk(p_actor_id bigint, p_window_days integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_result JSONB;
BEGIN
  IF p_actor_id IS NULL OR p_actor_id<=0 THEN RAISE EXCEPTION 'fn_dashboard_procurement_supplier_risk: p_actor_id must be a positive integer' USING ERRCODE='22023'; END IF;
  IF p_window_days NOT BETWEEN 7 AND 365 THEN RAISE EXCEPTION 'fn_dashboard_procurement_supplier_risk: p_window_days must be BETWEEN 7 AND 365' USING ERRCODE='22023'; END IF;
  IF NOT (fn_current_user_has_permission('insights.procurement_supplier_risk') OR fn_current_user_has_permission('insights.executive')
    OR EXISTS (SELECT 1 FROM "user" u JOIN role r ON r.id=u.role_id WHERE u.id=p_actor_id AND r.name IN ('Super Admin','platform_admin') AND u.is_active=TRUE)) THEN
    RAISE EXCEPTION 'permission_denied: insights.procurement_supplier_risk required' USING ERRCODE='42501';
  END IF;
  WITH
  supplier_risk AS (
    SELECT p.id AS counterparty_id,p.name_en AS counterparty_name,p.party_type,p.sanctions_status,p.icv_status,p.icv_pct,p.icv_last_checked,
      AVG(lrs.health_score)::integer AS composite_risk_score,AVG(lrs.dim_legal)::integer AS dim_legal,AVG(lrs.dim_financial)::integer AS dim_financial,
      AVG(lrs.dim_operational)::integer AS dim_operational,AVG(lrs.dim_reputational)::integer AS dim_reputational,AVG(lrs.dim_compliance)::integer AS dim_compliance,
      COUNT(DISTINCT co.id)::integer AS active_contract_count,COALESCE(SUM(co.value_aed),0) AS total_contract_value_aed,
      CASE WHEN AVG(lrs.health_score)<50 THEN 'high' WHEN AVG(lrs.health_score)<75 THEN 'medium' ELSE 'low' END AS risk_tier
    FROM party p JOIN contract co ON co.counterparty_id=p.id AND co.is_active=TRUE
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id=co.id AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    WHERE p.is_active=TRUE GROUP BY p.id,p.name_en,p.party_type,p.sanctions_status,p.icv_status,p.icv_pct,p.icv_last_checked
  ),
  supplier_breach_count AS (
    SELECT co.counterparty_id,COUNT(*) FILTER (WHERE os.signal_kind_subtype IN ('sla_breach','milestone_slippage'))::integer AS sla_breach_count_180d
    FROM correlation c JOIN osint_signal os ON os.id=c.signal_id JOIN contract co ON co.id=c.contract_id
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.created_at>=fn_demo_now()-180*INTERVAL '1 day' AND os.kind='internal'
    GROUP BY co.counterparty_id
  ),
  backup_suggestions AS (
    SELECT primary_party.counterparty_id AS primary_counterparty_id,primary_party.counterparty_name AS primary_name,primary_party.composite_risk_score AS primary_risk_score,primary_party.party_type AS category,
      (SELECT jsonb_agg(jsonb_build_object('counterpartyId',alt.counterparty_id::text,'counterpartyName',alt.counterparty_name,'riskScore',alt.composite_risk_score,'cleanStatus','clean') ORDER BY alt.composite_risk_score DESC)
       FROM (SELECT alt2.counterparty_id,alt2.counterparty_name,alt2.composite_risk_score FROM supplier_risk alt2
         WHERE alt2.party_type=primary_party.party_type AND alt2.counterparty_id<>primary_party.counterparty_id AND alt2.sanctions_status='clean'
           AND (alt2.composite_risk_score IS NULL OR primary_party.composite_risk_score IS NULL OR alt2.composite_risk_score>primary_party.composite_risk_score)
         ORDER BY alt2.composite_risk_score DESC NULLS LAST LIMIT 3) alt) AS suggested_alternatives
    FROM supplier_risk primary_party ORDER BY primary_party.composite_risk_score ASC NULLS FIRST LIMIT 5
  ),
  icv_tracker AS (SELECT sr.counterparty_id,sr.counterparty_name,sr.icv_status,sr.icv_pct,sr.icv_last_checked,sr.active_contract_count,sr.total_contract_value_aed FROM supplier_risk sr WHERE sr.icv_status='non_compliant' OR sr.icv_pct<60 ORDER BY sr.icv_pct ASC NULLS FIRST LIMIT 15),
  financial_health AS (
    SELECT co.counterparty_id,p.name_en AS counterparty_name,os.signal_kind_subtype AS signal_kind,os.title AS signal_headline,os.fetched_at AS occurred_at,os.severity_v2 AS severity,os.url AS source_ref
    FROM osint_signal os JOIN correlation c ON c.signal_id=os.id JOIN contract co ON co.id=c.contract_id JOIN party p ON p.id=co.counterparty_id
    WHERE os.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND os.kind='news' AND os.signal_kind_subtype IN ('financial_distress','downgrade','default') AND os.fetched_at>=fn_demo_now()-p_window_days*INTERVAL '1 day'
    ORDER BY os.fetched_at DESC LIMIT 8
  ),
  kpi_current AS (
    SELECT (SELECT COUNT(*) FROM supplier_risk)::integer AS total_supplier_count,
      (SELECT COUNT(DISTINCT counterparty_id) FROM supplier_breach_count WHERE sla_breach_count_180d>0)::integer AS supplier_breaches_count,
      (SELECT COUNT(*) FROM supplier_risk WHERE icv_status='non_compliant' OR icv_pct<60)::integer AS icv_non_compliant_count,
      (SELECT COUNT(DISTINCT counterparty_id) FROM financial_health)::integer AS supplier_financial_distress_count,
      (SELECT AVG(composite_risk_score)::numeric(5,2) FROM supplier_risk WHERE composite_risk_score IS NOT NULL) AS avg_supplier_risk_score
  ),
  kpi_prev_window AS (
    SELECT COUNT(DISTINCT p.id)::integer AS total_supplier_count,
      COUNT(DISTINCT CASE WHEN sla_hist.has_breach THEN co.counterparty_id END)::integer AS supplier_breaches_count,
      COUNT(DISTINCT CASE WHEN p.icv_status='non_compliant' OR p.icv_pct<60 THEN p.id END)::integer AS icv_non_compliant_count,
      COUNT(DISTINCT fin_prev.counterparty_id)::integer AS supplier_financial_distress_count,
      AVG(lrs_prev.health_score)::numeric(5,2) AS avg_supplier_risk_score
    FROM party p JOIN contract co ON co.counterparty_id=p.id AND co.is_active=TRUE
    LEFT JOIN latest_risk_score lrs_prev ON lrs_prev.contract_id=co.id AND lrs_prev.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    LEFT JOIN LATERAL (SELECT TRUE AS has_breach FROM correlation c2 JOIN osint_signal os2 ON os2.id=c2.signal_id
      WHERE c2.contract_id=co.id AND c2.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c2.is_active=TRUE
        AND c2.created_at BETWEEN fn_demo_now()-2*p_window_days*INTERVAL '1 day' AND fn_demo_now()-p_window_days*INTERVAL '1 day'
        AND os2.kind='internal' AND os2.signal_kind_subtype IN ('sla_breach','milestone_slippage') LIMIT 1) sla_hist ON TRUE
    LEFT JOIN LATERAL (SELECT DISTINCT co2.counterparty_id FROM osint_signal os3 JOIN correlation c3 ON c3.signal_id=os3.id JOIN contract co2 ON co2.id=c3.contract_id
      WHERE co2.counterparty_id=p.id AND os3.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND os3.kind='news'
        AND os3.signal_kind_subtype IN ('financial_distress','downgrade','default') AND os3.fetched_at BETWEEN fn_demo_now()-2*p_window_days*INTERVAL '1 day' AND fn_demo_now()-p_window_days*INTERVAL '1 day' LIMIT 1) fin_prev ON TRUE
    WHERE p.is_active=TRUE
  )
  SELECT jsonb_build_object(
    'windowDays',p_window_days,'asOf',fn_demo_now(),
    'kpi',(SELECT jsonb_build_object('totalSupplierCount',kc.total_supplier_count,'supplierBreachesCount',kc.supplier_breaches_count,'icvNonCompliantCount',kc.icv_non_compliant_count,'supplierFinancialDistressCount',kc.supplier_financial_distress_count,'avgSupplierRiskScore',kc.avg_supplier_risk_score::text) FROM kpi_current kc),
    'kpiPrev',(SELECT jsonb_build_object('totalSupplierCount',kp.total_supplier_count,'supplierBreachesCount',kp.supplier_breaches_count,'icvNonCompliantCount',kp.icv_non_compliant_count,'supplierFinancialDistressCount',kp.supplier_financial_distress_count,'avgSupplierRiskScore',kp.avg_supplier_risk_score::text) FROM kpi_prev_window kp),
    'supplierRiskScorecard',COALESCE((SELECT jsonb_agg(jsonb_build_object('counterpartyId',sr.counterparty_id::text,'counterpartyName',sr.counterparty_name,'compositeRiskScore',sr.composite_risk_score,'dimLegal',sr.dim_legal,'dimFinancial',sr.dim_financial,'dimOperational',sr.dim_operational,'dimReputational',sr.dim_reputational,'dimCompliance',sr.dim_compliance,'slaBreachCount180d',COALESCE(sbc.sla_breach_count_180d,0),'activeContractCount',sr.active_contract_count,'totalContractValueAed',sr.total_contract_value_aed::text,'riskTier',sr.risk_tier)) FROM (SELECT sr2.*,ROW_NUMBER() OVER (ORDER BY sr2.composite_risk_score ASC NULLS FIRST) AS rn FROM supplier_risk sr2 LIMIT 20) sr LEFT JOIN supplier_breach_count sbc ON sbc.counterparty_id=sr.counterparty_id),'[]'::jsonb),
    'icvComplianceTracker',COALESCE((SELECT jsonb_agg(jsonb_build_object('counterpartyId',it.counterparty_id::text,'counterpartyName',it.counterparty_name,'icvStatus',it.icv_status,'icvPct',it.icv_pct,'icvLastChecked',it.icv_last_checked,'activeContractCount',it.active_contract_count,'contractValueAed',it.total_contract_value_aed::text)) FROM icv_tracker it),'[]'::jsonb),
    'backupSupplierSuggestions',COALESCE((SELECT jsonb_agg(jsonb_build_object('primaryCounterpartyId',bs.primary_counterparty_id::text,'primaryName',bs.primary_name,'primaryRiskScore',bs.primary_risk_score,'category',bs.category,'suggestedAlternatives',COALESCE(bs.suggested_alternatives,'[]'::jsonb))) FROM backup_suggestions bs),'[]'::jsonb),
    'vendorFinancialHealthSummary',COALESCE((SELECT jsonb_agg(jsonb_build_object('counterpartyId',fh.counterparty_id::text,'counterpartyName',fh.counterparty_name,'signalKind',fh.signal_kind,'signalHeadline',fh.signal_headline,'occurredAt',fh.occurred_at,'severity',fh.severity,'sourceRef',fh.source_ref)) FROM financial_health fh),'[]'::jsonb)
  ) INTO v_result;
  RETURN v_result;
EXCEPTION
  WHEN SQLSTATE '42501' THEN RAISE;
  WHEN SQLSTATE '22023' THEN RAISE;
  WHEN OTHERS THEN RAISE EXCEPTION 'fn_dashboard_procurement_supplier_risk: %', SQLERRM USING ERRCODE=SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_dashboard_procurement_supplier_risk FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_procurement_supplier_risk TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_procurement_supplier_risk IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_risk_score_compute(p_contract_id bigint, p_triggered_by text, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_contract_row         RECORD;
  v_tenant_id            UUID;
  v_actor_id             BIGINT;
  v_existing_id          BIGINT;
  v_risk_score_id        BIGINT;
  v_correlations         JSONB[];
  v_weights              JSONB;
  v_weights_version      TEXT;
  v_weights_sum          NUMERIC;
  v_exposure_defaults    JSONB;
  v_impact_multipliers   JSONB;
  v_contract_type_key    TEXT;
  v_exposure_fraction    NUMERIC;
  v_clause_signals       RECORD;
  v_prob_legal           NUMERIC := 0;
  v_prob_financial       NUMERIC := 0;
  v_prob_operational     NUMERIC := 0;
  v_prob_reputational    NUMERIC := 0;
  v_prob_compliance      NUMERIC := 0;
  v_impact_legal         NUMERIC := 0;
  v_impact_financial     NUMERIC := 0;
  v_impact_operational   NUMERIC := 0;
  v_impact_reputational  NUMERIC := 0;
  v_impact_compliance    NUMERIC := 0;
  v_dim_legal            INTEGER;
  v_dim_financial        INTEGER;
  v_dim_operational      INTEGER;
  v_dim_reputational     INTEGER;
  v_dim_compliance       INTEGER;
  v_health_score         INTEGER;
  v_reasons_legal        JSONB := '[]'::jsonb;
  v_reasons_financial    JSONB := '[]'::jsonb;
  v_reasons_operational  JSONB := '[]'::jsonb;
  v_reasons_reputational JSONB := '[]'::jsonb;
  v_reasons_compliance   JSONB := '[]'::jsonb;
  v_mar_total                 NUMERIC := NULL;
  v_mar_currency              CHAR(3) := 'AED';
  v_contributing_correlations JSONB   := '[]'::jsonb;
  v_clause_id_array           JSONB   := '[]'::jsonb;
  v_corr                 JSONB;
  v_impact_mult          NUMERIC;
  v_corr_mar             NUMERIC;
  v_rule_id              TEXT;
  v_confidence           NUMERIC;
  v_source_rel           NUMERIC;
  v_prob_contrib         NUMERIC;
  v_explanation          JSONB;
  v_result               JSONB;
BEGIN
  IF p_triggered_by NOT IN ('signal','clause_change','weight_change','scheduled','manual','bootstrap') THEN
    RAISE EXCEPTION 'invalid triggered_by: %', p_triggered_by USING ERRCODE = '22023';
  END IF;
  SELECT id, value_aed, currency, contract_type, emirate
  INTO   v_contract_row
  FROM   contract
  WHERE  id = p_contract_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract with id % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_contract_row.currency IS NOT NULL AND v_contract_row.currency != 'AED' THEN
    RAISE EXCEPTION 'contract currency must be AED in v1 (got %)', v_contract_row.currency USING ERRCODE = '22023';
  END IF;
  v_actor_id := p_actor_id;
  IF v_actor_id = 0 THEN v_actor_id := NULL; END IF;
  SELECT id INTO v_existing_id
  FROM   risk_score
  WHERE  contract_id  = p_contract_id
    AND  triggered_by = p_triggered_by
    AND  calculated_at >= fn_demo_now() - INTERVAL '60 seconds'
  ORDER BY calculated_at DESC
  LIMIT 1
  FOR UPDATE;
  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object('riskScoreId', v_existing_id, 'contractId', p_contract_id, 'deduplicated', TRUE, 'note', 'snapshot exists within 60s dedup window');
  END IF;
  SELECT array_agg(jsonb_build_object('correlationId', c.id, 'ruleId', c.rule_id, 'signalId', c.signal_id, 'confidence', c.confidence, 'matchReason', c.match_reason, 'matchEntities', c.match_entities, 'sourceReliability', COALESCE(s.source_reliability, 1.0))) INTO v_correlations
  FROM   correlation c
  JOIN   osint_signal sig ON sig.id = c.signal_id
  JOIN   osint_source s   ON s.id   = sig.osint_source_id
  WHERE  c.tenant_id   = v_tenant_id
    AND  c.contract_id = p_contract_id
    AND  c.status      = 'active'
    AND  c.is_active   = TRUE;
  SELECT value INTO v_weights FROM system_setting WHERE key = 'scoring.weights' AND is_active = TRUE;
  IF v_weights IS NULL THEN RAISE EXCEPTION 'scoring.weights config missing' USING ERRCODE = '22023'; END IF;
  v_weights_version := v_weights->>'version';
  v_weights_sum := (v_weights->>'legal')::numeric + (v_weights->>'financial')::numeric + (v_weights->>'operational')::numeric + (v_weights->>'reputational')::numeric + (v_weights->>'compliance')::numeric;
  IF ABS(v_weights_sum - 1.0) > 0.001 THEN RAISE EXCEPTION 'scoring.weights sum != 1.0 (actual: %)', v_weights_sum USING ERRCODE = '22023'; END IF;
  SELECT value INTO v_exposure_defaults FROM system_setting WHERE key = 'scoring.exposure_fraction_defaults' AND is_active = TRUE;
  SELECT value INTO v_impact_multipliers FROM system_setting WHERE key = 'scoring.impact_multipliers' AND is_active = TRUE;
  v_exposure_defaults  := COALESCE(v_exposure_defaults,  '{}'::jsonb);
  v_impact_multipliers := COALESCE(v_impact_multipliers, '{}'::jsonb);
  v_contract_type_key := lower(COALESCE(v_contract_row.contract_type, ''));
  v_exposure_fraction := COALESCE(NULLIF(v_exposure_defaults->>v_contract_type_key, '')::numeric, (v_exposure_defaults->>'default')::numeric, 0.10);
  SELECT bool_or((parameters->>'indemnity_scope')::text = 'broad') AS has_broad_indemnity, COALESCE(SUM((parameters->>'liability_cap_value')::numeric), 0) AS total_liability_cap, bool_or(COALESCE((parameters->>'public_visibility')::boolean, FALSE)) AS is_public, COUNT(*) FILTER (WHERE COALESCE((parameters->>'regulatory_linkage')::boolean, FALSE)) AS regulatory_clauses, COUNT(*) FILTER (WHERE COALESCE((parameters->>'critical_path_impact')::boolean, FALSE)) AS critical_path_clauses, bool_or(COALESCE((parameters->>'single_source_dependency')::boolean, FALSE)) AS has_single_source
  INTO v_clause_signals FROM contract_clause_extracted WHERE contract_id = p_contract_id AND is_active = TRUE;
  IF v_correlations IS NOT NULL THEN
    FOREACH v_corr IN ARRAY v_correlations LOOP
      v_rule_id := v_corr->>'ruleId'; v_confidence := (v_corr->>'confidence')::numeric; v_source_rel := (v_corr->>'sourceReliability')::numeric; v_prob_contrib := v_confidence * v_source_rel;
      IF v_rule_id LIKE 'rule.sanctions.%' OR v_rule_id LIKE 'rule.regulatory.%' THEN
        v_prob_legal := v_prob_legal + 100 * v_prob_contrib; v_prob_compliance := v_prob_compliance + 100 * v_prob_contrib;
        v_reasons_legal := v_reasons_legal || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_compliance := v_reasons_compliance || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSIF v_rule_id LIKE 'rule.market.%' THEN
        v_prob_financial := v_prob_financial + 100 * v_prob_contrib; v_reasons_financial := v_reasons_financial || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSIF v_rule_id LIKE 'rule.geopolitical.%' THEN
        v_prob_operational := v_prob_operational + 100 * v_prob_contrib; v_prob_reputational := v_prob_reputational + 100 * v_prob_contrib;
        v_reasons_operational := v_reasons_operational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_reputational := v_reasons_reputational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSIF v_rule_id LIKE 'rule.cyber.%' THEN
        v_prob_operational := v_prob_operational + 100 * v_prob_contrib; v_prob_reputational := v_prob_reputational + 100 * v_prob_contrib; v_prob_compliance := v_prob_compliance + 100 * v_prob_contrib;
        v_reasons_operational := v_reasons_operational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_reputational := v_reasons_reputational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_compliance := v_reasons_compliance || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSIF v_rule_id LIKE 'rule.disruption.%' THEN
        v_prob_operational := v_prob_operational + 100 * v_prob_contrib; v_prob_financial := v_prob_financial + 100 * v_prob_contrib;
        v_reasons_operational := v_reasons_operational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_financial := v_reasons_financial || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSIF v_rule_id LIKE 'rule.counterparty.%' THEN
        v_prob_financial := v_prob_financial + 100 * v_prob_contrib; v_prob_legal := v_prob_legal + 100 * v_prob_contrib; v_prob_reputational := v_prob_reputational + 100 * v_prob_contrib;
        v_reasons_financial := v_reasons_financial || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_legal := v_reasons_legal || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')'); v_reasons_reputational := v_reasons_reputational || jsonb_build_array(v_rule_id || ' (confidence ' || ROUND(v_confidence, 2) || ')');
      ELSE
        v_prob_legal := v_prob_legal + 100 * v_prob_contrib / 5; v_prob_financial := v_prob_financial + 100 * v_prob_contrib / 5; v_prob_operational := v_prob_operational + 100 * v_prob_contrib / 5; v_prob_reputational := v_prob_reputational + 100 * v_prob_contrib / 5; v_prob_compliance := v_prob_compliance + 100 * v_prob_contrib / 5;
      END IF;
    END LOOP;
  END IF;
  v_prob_legal := LEAST(100, GREATEST(0, ROUND(v_prob_legal))); v_prob_financial := LEAST(100, GREATEST(0, ROUND(v_prob_financial))); v_prob_operational := LEAST(100, GREATEST(0, ROUND(v_prob_operational))); v_prob_reputational := LEAST(100, GREATEST(0, ROUND(v_prob_reputational))); v_prob_compliance := LEAST(100, GREATEST(0, ROUND(v_prob_compliance)));
  v_impact_legal := LEAST(100, GREATEST(0, CASE WHEN v_clause_signals.has_broad_indemnity THEN 80 ELSE 0 END + CASE WHEN v_clause_signals.total_liability_cap > 10000000 THEN 40 WHEN v_clause_signals.total_liability_cap > 1000000 THEN 20 ELSE 0 END));
  v_impact_financial := LEAST(100, GREATEST(0, ROUND(100 * v_exposure_fraction) + CASE WHEN v_contract_row.value_aed > 100000000 THEN 20 ELSE 0 END));
  v_reasons_financial := v_reasons_financial || jsonb_build_array('exposure_fraction ' || v_exposure_fraction);
  v_impact_operational := LEAST(100, GREATEST(0, v_clause_signals.critical_path_clauses * 25 + CASE WHEN v_clause_signals.has_single_source THEN 10 ELSE 0 END));
  v_impact_reputational := CASE WHEN v_clause_signals.is_public THEN 80 ELSE 30 END;
  v_reasons_reputational := v_reasons_reputational || jsonb_build_array('public_visibility: ' || v_clause_signals.is_public);
  v_impact_compliance := LEAST(100, GREATEST(0, v_clause_signals.regulatory_clauses * 30));
  v_dim_legal        := LEAST(100, GREATEST(0, ROUND(v_prob_legal        * v_impact_legal        / 100.0)));
  v_dim_financial    := LEAST(100, GREATEST(0, ROUND(v_prob_financial    * v_impact_financial    / 100.0)));
  v_dim_operational  := LEAST(100, GREATEST(0, ROUND(v_prob_operational  * v_impact_operational  / 100.0)));
  v_dim_reputational := LEAST(100, GREATEST(0, ROUND(v_prob_reputational * v_impact_reputational / 100.0)));
  v_dim_compliance   := LEAST(100, GREATEST(0, ROUND(v_prob_compliance   * v_impact_compliance   / 100.0)));
  v_health_score := LEAST(100, GREATEST(0, ROUND(v_dim_legal * (v_weights->>'legal')::numeric + v_dim_financial * (v_weights->>'financial')::numeric + v_dim_operational * (v_weights->>'operational')::numeric + v_dim_reputational * (v_weights->>'reputational')::numeric + v_dim_compliance * (v_weights->>'compliance')::numeric)));
  IF v_contract_row.value_aed IS NOT NULL AND v_correlations IS NOT NULL THEN
    v_mar_total := 0;
    FOREACH v_corr IN ARRAY v_correlations LOOP
      v_confidence := (v_corr->>'confidence')::numeric; v_source_rel := (v_corr->>'sourceReliability')::numeric; v_rule_id := v_corr->>'ruleId'; v_impact_mult := 1.0;
      IF v_rule_id LIKE 'rule.counterparty.%' THEN v_impact_mult := v_impact_mult * COALESCE((v_impact_multipliers->>'single_source_dependency')::numeric, 1.0); END IF;
      IF v_clause_signals.regulatory_clauses > 0 THEN v_impact_mult := v_impact_mult * COALESCE((v_impact_multipliers->>'regulatory_linkage')::numeric, 1.0); END IF;
      IF v_clause_signals.critical_path_clauses > 0 THEN v_impact_mult := v_impact_mult * COALESCE((v_impact_multipliers->>'critical_path_impact')::numeric, 1.0); END IF;
      v_impact_mult := LEAST(3.0, v_impact_mult);
      v_corr_mar := v_contract_row.value_aed * v_exposure_fraction * (v_confidence * v_source_rel) * v_impact_mult;
      v_mar_total := v_mar_total + v_corr_mar;
      v_contributing_correlations := v_contributing_correlations || jsonb_build_array(jsonb_build_object('correlationId', (v_corr->>'correlationId')::bigint, 'ruleId', v_rule_id, 'signalId', (v_corr->>'signalId')::bigint, 'confidence', v_confidence, 'sourceReliability', v_source_rel, 'probability', ROUND(v_confidence * v_source_rel * 100, 2), 'impactMultiplier', v_impact_mult, 'marContribution', ROUND(v_corr_mar, 2), 'dimensionsAffected', CASE WHEN v_rule_id LIKE 'rule.sanctions.%' THEN '["legal","compliance"]'::jsonb WHEN v_rule_id LIKE 'rule.regulatory.%' THEN '["legal","compliance"]'::jsonb WHEN v_rule_id LIKE 'rule.market.%' THEN '["financial"]'::jsonb WHEN v_rule_id LIKE 'rule.geopolitical.%' THEN '["operational","reputational"]'::jsonb WHEN v_rule_id LIKE 'rule.cyber.%' THEN '["operational","reputational","compliance"]'::jsonb WHEN v_rule_id LIKE 'rule.disruption.%' THEN '["operational","financial"]'::jsonb WHEN v_rule_id LIKE 'rule.counterparty.%' THEN '["financial","legal","reputational"]'::jsonb ELSE '["legal","financial","operational","reputational","compliance"]'::jsonb END));
    END LOOP;
  ELSE
    IF v_contract_row.value_aed IS NOT NULL THEN v_mar_total := 0; END IF;
  END IF;
  SELECT COALESCE(jsonb_agg(cce.id ORDER BY cce.id), '[]'::jsonb) INTO v_clause_id_array FROM contract_clause_extracted cce WHERE cce.contract_id = p_contract_id AND cce.is_active = TRUE;
  v_explanation := jsonb_build_object('dimensions', jsonb_build_object('legal', jsonb_build_object('score', v_dim_legal, 'probability', v_prob_legal, 'impact', v_impact_legal, 'reasons', v_reasons_legal), 'financial', jsonb_build_object('score', v_dim_financial, 'probability', v_prob_financial, 'impact', v_impact_financial, 'reasons', v_reasons_financial), 'operational', jsonb_build_object('score', v_dim_operational, 'probability', v_prob_operational, 'impact', v_impact_operational, 'reasons', v_reasons_operational), 'reputational', jsonb_build_object('score', v_dim_reputational, 'probability', v_prob_reputational, 'impact', v_impact_reputational, 'reasons', v_reasons_reputational), 'compliance', jsonb_build_object('score', v_dim_compliance, 'probability', v_prob_compliance, 'impact', v_impact_compliance, 'reasons', v_reasons_compliance)), 'marFormula', jsonb_build_object('contractValue', v_contract_row.value_aed, 'exposureFraction', v_exposure_fraction, 'probability', NULL, 'impactMultiplier', NULL, 'marValue', v_mar_total), 'weightsAtCalculation', jsonb_build_object('legal', (v_weights->>'legal')::numeric, 'financial', (v_weights->>'financial')::numeric, 'operational', (v_weights->>'operational')::numeric, 'reputational', (v_weights->>'reputational')::numeric, 'compliance', (v_weights->>'compliance')::numeric), 'contributingClauses', v_clause_id_array);
  INSERT INTO risk_score (tenant_id, contract_id, health_score, dim_legal, dim_financial, dim_operational, dim_reputational, dim_compliance, mar_value, mar_currency, contributing_correlations, explanation, weights_version, calculated_at, triggered_by, data_classification, created_at, created_by)
  VALUES (v_tenant_id, p_contract_id, v_health_score, v_dim_legal, v_dim_financial, v_dim_operational, v_dim_reputational, v_dim_compliance, v_mar_total, 'AED', v_contributing_correlations, v_explanation, v_weights_version, fn_demo_now(), p_triggered_by, 'demo', NOW(), v_actor_id)
  RETURNING id INTO v_risk_score_id;
  REFRESH MATERIALIZED VIEW latest_risk_score;
  PERFORM fn_contract_activity_create(p_contract_id, 'ai_risk_score_updated', v_actor_id, 'Risk score recomputed (Health Score: ' || v_health_score || ')', 'تم إعادة احتساب درجة المخاطر (' || v_health_score || ')', jsonb_build_object('riskScoreId', v_risk_score_id, 'healthScore', v_health_score, 'triggeredBy', p_triggered_by, 'weightsVersion', v_weights_version));
  RETURN jsonb_build_object('riskScoreId', v_risk_score_id, 'contractId', p_contract_id, 'healthScore', v_health_score, 'dimensions', jsonb_build_object('legal', v_dim_legal, 'financial', v_dim_financial, 'operational', v_dim_operational, 'reputational', v_dim_reputational, 'compliance', v_dim_compliance), 'marValue', v_mar_total, 'marCurrency', 'AED', 'weightsVersion', v_weights_version, 'calculatedAt', fn_demo_now(), 'contributingCorrelationCount', COALESCE(array_length(v_correlations, 1), 0), 'deduplicated', FALSE);
EXCEPTION
  WHEN OTHERS THEN RAISE EXCEPTION 'fn_risk_score_compute: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_risk_score_compute FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_risk_score_compute TO neondb_owner;
COMMENT ON FUNCTION fn_risk_score_compute IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_risk_score_history(p_contract_id bigint, p_window_days integer, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_tenant_id UUID;
  v_snapshots JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;
  IF p_window_days NOT IN (30, 90, 180) THEN
    RAISE EXCEPTION 'windowDays must be 30, 90, or 180 (got %)', p_window_days USING ERRCODE = '22023';
  END IF;
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'contract with id % not found', p_contract_id USING ERRCODE = 'P0002';
  END IF;
  SELECT jsonb_agg(jsonb_build_object('riskScoreId', id::text, 'calculatedAt', calculated_at, 'healthScore', health_score, 'dimLegal', dim_legal, 'dimFinancial', dim_financial, 'dimOperational', dim_operational, 'dimReputational', dim_reputational, 'dimCompliance', dim_compliance, 'marValue', mar_value::text, 'marCurrency', mar_currency, 'triggeredBy', triggered_by, 'weightsVersion', weights_version) ORDER BY calculated_at ASC)
  INTO   v_snapshots
  FROM   risk_score
  WHERE  contract_id   = p_contract_id
    AND  tenant_id     = v_tenant_id
    AND  calculated_at >= fn_demo_now() - (p_window_days || ' days')::interval;
  RETURN jsonb_build_object('contractId', p_contract_id::text, 'windowDays', p_window_days, 'snapshots', COALESCE(v_snapshots, '[]'::jsonb), 'count', jsonb_array_length(COALESCE(v_snapshots, '[]'::jsonb)));
EXCEPTION
  WHEN OTHERS THEN RAISE EXCEPTION 'fn_risk_score_history: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_risk_score_history FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_risk_score_history TO neondb_owner;
COMMENT ON FUNCTION fn_risk_score_history IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_avar_aggregate(p_filters jsonb, p_window_days integer, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_group_by    TEXT;
  v_tenant_id   UUID;
  v_filter_bu   TEXT;
  v_filter_geo  TEXT;
  v_filter_cp   BIGINT;
  v_filter_kind TEXT;
  v_window_from TIMESTAMPTZ;
  v_result      JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('score.read') THEN
    RAISE EXCEPTION 'Permission denied: score.read required' USING ERRCODE = '42501';
  END IF;
  IF p_window_days < 1 OR p_window_days > 365 THEN
    RAISE EXCEPTION 'windowDays out of [1, 365] (got %)', p_window_days USING ERRCODE = '22023';
  END IF;
  v_group_by := COALESCE(p_filters->>'groupBy', 'business_unit');
  IF v_group_by NOT IN ('business_unit','counterparty_id','counterparty_chain','geography','risk_kind') THEN
    RAISE EXCEPTION 'groupBy out of allowed set (got %)', v_group_by USING ERRCODE = '22023';
  END IF;
  v_tenant_id   := current_setting('app.current_tenant_id', true)::uuid;
  v_filter_bu   := lower(p_filters->>'businessUnit');
  v_filter_geo  := lower(p_filters->>'geography');
  v_filter_cp   := (p_filters->>'counterpartyId')::bigint;
  v_filter_kind := lower(p_filters->>'riskKind');
  v_window_from := fn_demo_now() - (p_window_days || ' days')::interval;
  WITH filtered AS (
    SELECT lrs.contract_id, lrs.mar_value, lrs.health_score, lrs.contributing_correlations, lrs.calculated_at, c.contract_type, c.emirate, c.counterparty_id
    FROM   latest_risk_score lrs
    JOIN   contract c ON c.id = lrs.contract_id AND c.is_active = TRUE
    WHERE  lrs.tenant_id     = v_tenant_id
      AND  lrs.calculated_at >= v_window_from
      AND  (v_filter_bu   IS NULL OR lower(c.contract_type) = v_filter_bu)
      AND  (v_filter_geo  IS NULL OR lower(c.emirate)       = v_filter_geo)
      AND  (v_filter_cp   IS NULL OR c.counterparty_id      = v_filter_cp)
      AND  (v_filter_kind IS NULL OR EXISTS (SELECT 1 FROM jsonb_array_elements(lrs.contributing_correlations) AS cc(elem) WHERE cc.elem->>'ruleId' LIKE 'rule.' || v_filter_kind || '.%'))
  ),
  per_bucket AS (
    SELECT
      CASE v_group_by
        WHEN 'business_unit'      THEN COALESCE(contract_type,        '(none)')
        WHEN 'geography'          THEN COALESCE(emirate,               '(none)')
        WHEN 'counterparty_id'    THEN COALESCE(counterparty_id::text, '(unknown)')
        WHEN 'counterparty_chain' THEN COALESCE(counterparty_id::text, '(unknown)')
        WHEN 'risk_kind'          THEN '(all)'
        ELSE COALESCE(contract_type, '(none)')
      END AS bucket_label,
      SUM(mar_value) AS bucket_avar,
      COUNT(*) AS bucket_count,
      COUNT(*) FILTER (WHERE mar_value IS NULL) AS bucket_no_value_count
    FROM filtered
    GROUP BY bucket_label
  ),
  totals AS (
    SELECT SUM(bucket_avar) AS total_avar, SUM(bucket_count) AS total_contract_count, SUM(bucket_no_value_count) AS no_value_count
    FROM per_bucket
  )
  SELECT jsonb_build_object(
    'totalAvar', COALESCE((SELECT total_avar FROM totals), 0)::text,
    'currency', 'AED',
    'contractCount', COALESCE((SELECT total_contract_count FROM totals), 0),
    'windowDays', p_window_days,
    'groupBy', v_group_by,
    'noValueCount', COALESCE((SELECT no_value_count FROM totals), 0),
    'breakdown', COALESCE((SELECT jsonb_agg(jsonb_build_object('key', bucket_label, 'label', bucket_label, 'avar', bucket_avar::text, 'contractCount', bucket_count, 'pctOfTotal', ROUND(100.0 * bucket_avar / NULLIF((SELECT total_avar FROM totals), 0), 2)) ORDER BY bucket_avar DESC NULLS LAST) FROM per_bucket), '[]'::jsonb),
    'deltaVsPriorWindow', (SELECT jsonb_build_object('priorAvar', COALESCE(SUM(rs.mar_value), 0)::text, 'deltaAed', (COALESCE((SELECT total_avar FROM totals), 0) - COALESCE(SUM(rs.mar_value), 0))::text, 'deltaPct', ROUND(100.0 * (COALESCE((SELECT total_avar FROM totals), 0) - COALESCE(SUM(rs.mar_value), 0)) / NULLIF(SUM(rs.mar_value), 0), 2)) FROM (SELECT DISTINCT ON (contract_id) mar_value FROM risk_score WHERE tenant_id = v_tenant_id AND calculated_at >= fn_demo_now() - (2 * p_window_days || ' days')::interval AND calculated_at < fn_demo_now() - (p_window_days || ' days')::interval ORDER BY contract_id, calculated_at DESC) rs)
  ) INTO v_result;
  RETURN v_result;
EXCEPTION
  WHEN OTHERS THEN RAISE EXCEPTION 'fn_avar_aggregate: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_avar_aggregate FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_avar_aggregate TO neondb_owner;
COMMENT ON FUNCTION fn_avar_aggregate IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_notification_send(p_actor_id bigint, p_notification_template_id bigint, p_notification_kind text, p_channel text, p_priority text, p_recipient_user_id bigint, p_recipient_address text, p_context jsonb, p_advisory_draft_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_actor          BIGINT;
  v_tenant_id      UUID;
  v_id             BIGINT;
  v_status         TEXT;
  v_next_retry     TIMESTAMPTZ;
  v_enabled        BOOLEAN;
  v_pm             TEXT;
  v_priority_order INTEGER;
  v_pm_order       INTEGER;
  v_subject        TEXT;
  v_body           TEXT;
BEGIN
  v_actor := NULLIF(p_actor_id, 0);
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF p_recipient_user_id IS NULL AND p_recipient_address IS NULL THEN
    RAISE EXCEPTION 'fn_notification_send: missing_recipient' USING ERRCODE = '22023';
  END IF;
  IF p_channel NOT IN ('email','in_app','teams_capture','slack_capture') THEN
    RAISE EXCEPTION 'fn_notification_send: invalid_channel' USING ERRCODE = '22023';
  END IF;
  IF p_notification_kind NOT IN ('alert','advisory','approval_request','signature_request','system','risk_case','report') THEN
    RAISE EXCEPTION 'fn_notification_send: invalid_kind' USING ERRCODE = '22023';
  END IF;
  IF p_priority NOT IN ('low','medium','high','critical') THEN
    RAISE EXCEPTION 'fn_notification_send: invalid_priority' USING ERRCODE = '22023';
  END IF;
  IF p_notification_template_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM notification_template WHERE id = p_notification_template_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_notification_send: notification_template_not_found' USING ERRCODE = '23503';
  END IF;
  v_subject := p_context->>'subject';
  v_body    := p_context->>'bodyRendered';
  IF v_body IS NULL OR trim(v_body) = '' THEN v_body := p_context->>'body'; END IF;
  IF v_body IS NULL THEN v_body := ''; END IF;
  v_status := 'pending';
  IF p_recipient_user_id IS NOT NULL THEN
    SELECT ns.enabled, ns.priority_min INTO v_enabled, v_pm
    FROM notification_subscription ns
    WHERE ns.tenant_id = v_tenant_id AND ns.user_id = p_recipient_user_id
      AND ns.notification_kind = p_notification_kind AND ns.channel = p_channel AND ns.is_active = TRUE;
    IF NOT FOUND THEN v_enabled := TRUE; v_pm := 'high'; END IF;
    v_priority_order := CASE p_priority WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END;
    v_pm_order       := CASE v_pm WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END;
    IF (NOT v_enabled) OR (v_priority_order < v_pm_order) THEN v_status := 'suppressed_by_preference'; END IF;
  END IF;
  IF v_status = 'pending' THEN
    v_status := CASE p_channel
      WHEN 'teams_capture'  THEN 'captured_only'
      WHEN 'slack_capture'  THEN 'captured_only'
      WHEN 'in_app'         THEN 'sent'
      WHEN 'email'          THEN 'pending_retry'
    END;
    v_next_retry := CASE WHEN v_status = 'pending_retry' THEN fn_demo_now() + INTERVAL '0 seconds' ELSE NULL END;
  ELSE
    v_next_retry := NULL;
  END IF;
  INSERT INTO notification_dispatch_log (
    tenant_id, notification_template_id, notification_kind, priority, channel,
    recipient_user_id, recipient_address, subject, body_rendered, context_payload,
    status, delivery_attempted_at, retry_count, next_retry_at,
    advisory_draft_id, data_classification, created_at, created_by, is_active
  ) VALUES (
    v_tenant_id, p_notification_template_id, p_notification_kind, p_priority, p_channel,
    p_recipient_user_id, p_recipient_address, v_subject, COALESCE(v_body, ''),
    p_context - 'bodyRendered' - 'subject', v_status, NOW(), 0, v_next_retry,
    p_advisory_draft_id, 'sensitive', NOW(), v_actor, TRUE
  ) RETURNING id INTO v_id;
  PERFORM fn_audit_log_record_v2('notification_dispatch_log', v_id, 'INSERT', NULL,
    jsonb_build_object('notificationKind', p_notification_kind, 'channel', p_channel,
      'priority', p_priority, 'status', v_status,
      'recipientUserId', p_recipient_user_id, 'advisoryDraftId', p_advisory_draft_id,
      'actionCode', 'notification.dispatched'),
    COALESCE(NULLIF(p_actor_id, 0), NULL));
  RETURN jsonb_build_object(
    'notificationDispatchLogId', v_id, 'status', v_status,
    'renderedSubject', v_subject, 'channel', p_channel);
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_notification_send: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_notification_send FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_send TO neondb_owner;
COMMENT ON FUNCTION fn_notification_send IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';

CREATE OR REPLACE FUNCTION public.fn_notification_dispatch_retry_due(p_batch_size integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_data JSONB;
BEGIN
  WITH claimed AS (
    SELECT id, channel, recipient_address, subject, body_rendered,
           retry_count, delivery_attempted_at, tenant_id
    FROM notification_dispatch_log
    WHERE status = 'pending_retry' AND next_retry_at <= fn_demo_now()
    ORDER BY next_retry_at ASC
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', c.id,
    'channel', c.channel,
    'recipientAddress', c.recipient_address,
    'subject', c.subject,
    'bodyRendered', c.body_rendered,
    'retryCount', c.retry_count,
    'deliveryAttemptedAt', c.delivery_attempted_at,
    'tenantId', c.tenant_id
  )), '[]'::jsonb) INTO v_data
  FROM claimed c;

  RETURN jsonb_build_object('data', v_data);
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'fn_notification_dispatch_retry_due: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$
;

REVOKE ALL ON FUNCTION fn_notification_dispatch_retry_due FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_notification_dispatch_retry_due TO neondb_owner;
COMMENT ON FUNCTION fn_notification_dispatch_retry_due IS 'DEBT-CRIJ-1: time-sensitive NOW() replaced with fn_demo_now() for demo time-freeze support (migration 244).';
