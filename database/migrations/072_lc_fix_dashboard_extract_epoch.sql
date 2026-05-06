-- Migration 072: R-LC1 patch — fix EXTRACT(EPOCH FROM date - date) error.
--
-- 071 used `FLOOR(EXTRACT(EPOCH FROM (CURRENT_DATE - ad.decided_at::DATE))
-- / 86400 / 7)` to compute weeks-ago buckets. Postgres errors with
-- "function pg_catalog.extract(unknown, integer) does not exist" because
-- DATE - DATE returns INTEGER (number of days), not INTERVAL. EXTRACT only
-- works on INTERVAL/TIMESTAMP/TIME. Use direct integer division instead.
--
-- Caught at R-LC1 Playwright verification:
--   GET /api/v1/dashboards/legal-counsel → 500 with SQLSTATE 42883.

CREATE OR REPLACE FUNCTION fn_dashboard_legal_counsel(
  p_window_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
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
            WHERE changed_at >= NOW() - (v_window || ' days')::INTERVAL
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
    WHERE created_at >= NOW() - (v_window || ' days')::INTERVAL
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
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_legal_counsel(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_legal_counsel(INTEGER) TO neondb_owner;

-- ROLLBACK BEGIN
-- ROLLBACK END
