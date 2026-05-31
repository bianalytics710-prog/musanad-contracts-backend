-- Migration: 405_layla_dashboard_avg_review_key_rename.sql
-- Unit: Layla Counsel QA medium-pass — finish L8
-- BE returned `avgReviewTime12w` but FE reads `avgReview12w`. Rename to match.

CREATE OR REPLACE FUNCTION public.fn_dashboard_legal_counsel(p_window_days integer DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_inner JSONB;
BEGIN
  -- Reuse the rich body by calling an inline subquery to avoid duplicating 200 lines.
  -- We just wrap the existing function output and rename one key.
  -- NOTE: we cannot recursively call ourselves; instead inline the same logic via a CTE.
  -- For simplicity, build v_inner from the V392-aligned shape, then key-swap.
  PERFORM 1;
  SELECT jsonb_build_object(
    -- Build the same payload by re-invoking a temp materialised fn — for safety
    -- we copy the body inline (concise rebuild that calls underlying helper queries).
    -- Easier path: re-run the 392 fn via a different name. To stay self-contained,
    -- we just alias the existing key on the JSON output level.
    'placeholder', NULL
  ) INTO v_inner;
  -- This dummy body never runs because we replace it below with the real implementation.
  RETURN v_inner;
END;
$function$;

-- Replace with the real implementation (mig 392 body + key rename)
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
  v_active_total   INTEGER;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: unauthorized' USING ERRCODE = '42501';
  END IF;
  SELECT r.name INTO v_role FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;
  IF v_role IS NULL OR v_role NOT IN ('legal_counsel', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: forbidden' USING ERRCODE = '42501';
  END IF;
  v_has_audit_read := fn_current_user_has_permission('audit.read');

  SELECT COUNT(*) INTO v_active_total
    FROM contract
   WHERE status IN ('active', 'fully_signed') AND is_active = TRUE;

  SELECT jsonb_build_object(
    'regulatoryUpdatesThisWindow',
      (SELECT COUNT(*) FROM regulatory_update
        WHERE published_date >= CURRENT_DATE - v_window AND is_active = TRUE),
    'openRegulatoryImpacts',
      (SELECT COUNT(*) FROM regulatory_impact WHERE resolved = FALSE AND is_active = TRUE),
    'criticalSeverityCount',
      (SELECT COUNT(*) FROM regulatory_update ru
       JOIN regulatory_impact ri ON ri.regulatory_update_id = ru.id
       WHERE ru.severity = 'critical' AND ri.resolved = FALSE
         AND ru.is_active = TRUE AND ri.is_active = TRUE),
    'regulationCatalogSize', (SELECT COUNT(*) FROM regulation WHERE is_active = TRUE),
    'auditSummary',
      CASE WHEN v_has_audit_read THEN
        COALESCE((SELECT jsonb_object_agg(table_name, cnt)
                  FROM (SELECT table_name, COUNT(*) AS cnt FROM audit_log
                        WHERE changed_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
                        GROUP BY table_name) s), '{}'::jsonb)
      ELSE NULL END,
    'activeContracts', v_active_total,
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
       WHERE s.status = 'pending' AND s.approver_role = 'legal_counsel'
         AND ch.is_active = TRUE AND s.is_active = TRUE AND c.is_active = TRUE)
  ) INTO v_kpis;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractId',     c.id,
    'contractNumber', c.contract_number,
    'titleEn',        c.title_en,
    'titleAr',        c.title_ar,
    'contractType',   c.contract_type,
    'drafterName',    concat_ws(' ', du.first_name, du.last_name),
    'submittedAt',    s.created_at
  ) ORDER BY s.created_at ASC), '[]'::jsonb) INTO v_approval_queue
  FROM approval_step s
  JOIN approval_chain ch ON ch.id = s.approval_chain_id
  JOIN contract c ON c.id = ch.contract_id
  LEFT JOIN "user" du ON du.id = c.drafted_by
  WHERE s.status = 'pending' AND s.approver_role = 'legal_counsel'
    AND s.is_active = TRUE AND ch.is_active = TRUE AND c.is_active = TRUE;

  WITH scored AS (
    SELECT c.id AS contract_id, c.contract_number, c.title_en,
           COALESCE(lrs.health_score, 50) AS risk
      FROM contract c
      LEFT JOIN latest_risk_score lrs ON lrs.contract_id = c.id
     WHERE c.status IN ('active', 'fully_signed') AND c.is_active = TRUE
  )
  SELECT jsonb_build_object(
    'totalActive', v_active_total,
    'lowCount',    (SELECT COUNT(*) FROM scored WHERE risk BETWEEN 0 AND 30),
    'mediumCount', (SELECT COUNT(*) FROM scored WHERE risk BETWEEN 31 AND 60),
    'highCount',   (SELECT COUNT(*) FROM scored WHERE risk > 60),
    'top5HighRisk',        COALESCE((SELECT jsonb_agg(jsonb_build_object(
                     'contractId', s.contract_id, 'contractNumber', s.contract_number,
                     'titleEn', s.title_en, 'risk', s.risk)
                     ORDER BY s.risk DESC, s.contract_number)
                   FROM (SELECT * FROM scored ORDER BY risk DESC, contract_number LIMIT 5) s), '[]'::jsonb)
  ) INTO v_risk;

  WITH weeks AS (SELECT generate_series(0, 11) AS w), decisions AS (
    SELECT ((CURRENT_DATE - ad.decided_at::DATE) / 7)::INT AS weeks_ago,
           EXTRACT(EPOCH FROM (ad.decided_at - s.created_at)) / 3600.0 AS hours
      FROM approval_decision ad
      JOIN approval_step s ON s.id = ad.approval_step_id
     WHERE s.approver_role = 'legal_counsel'
       AND ad.decided_at >= CURRENT_DATE - INTERVAL '12 weeks'
       AND ad.is_active = TRUE AND s.is_active = TRUE
  ), agg AS (
    SELECT weeks_ago, AVG(hours) AS avg_hours FROM decisions
     WHERE weeks_ago >= 0 AND weeks_ago < 12 GROUP BY weeks_ago
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('weekIndex', weeks.w,
    'avgHours', COALESCE(ROUND(agg.avg_hours::NUMERIC, 1), 0)) ORDER BY weeks.w DESC), '[]'::jsonb) INTO v_avg_review
  FROM weeks LEFT JOIN agg ON agg.weeks_ago = weeks.w;

  WITH updates AS (
    SELECT ru.id, r.code AS authority,
           ((CURRENT_DATE - ru.published_date) / 7)::INT AS weeks_ago
      FROM regulatory_update ru
      LEFT JOIN regulator r ON r.id = ru.regulator_id
     WHERE ru.published_date >= CURRENT_DATE - INTERVAL '12 weeks' AND ru.is_active = TRUE
  )
  SELECT jsonb_build_object(
    'totalUpdates', (SELECT COUNT(*) FROM updates),
    'authoritiesActive', (SELECT COUNT(DISTINCT authority) FROM updates WHERE authority IS NOT NULL),
    'weeklyByAuthority', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('weekIndex', weeks_ago, 'authority', authority, 'count', cnt) ORDER BY weeks_ago DESC)
        FROM (SELECT weeks_ago, authority, COUNT(*) AS cnt FROM updates
               WHERE weeks_ago >= 0 AND weeks_ago < 12 GROUP BY 1, 2) g), '[]'::jsonb)
  ) INTO v_reg_updates_12w;

  WITH typed AS (
    SELECT contract_type, COUNT(*) AS cnt FROM contract
     WHERE status IN ('active', 'fully_signed') AND is_active = TRUE
     GROUP BY contract_type
  ), tot AS (SELECT COALESCE(SUM(cnt), 0) AS total FROM typed)
  SELECT jsonb_build_object(
    'total', (SELECT total FROM tot),
    'rows', COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'type', contract_type, 'count', cnt,
      'pct', CASE WHEN (SELECT total FROM tot) > 0
                  THEN ROUND(100.0 * cnt / (SELECT total FROM tot), 1) ELSE 0 END
    ) ORDER BY cnt DESC) FROM typed), '[]'::jsonb)
  ) INTO v_contract_types;

  WITH categorized AS (
    SELECT o.id, o.title_en, o.contract_id, o.due_date, o.status,
           CASE
             WHEN o.title_en ILIKE 'Payment milestone%'    THEN 'payment'
             WHEN o.title_en ILIKE 'Renewal notice%'       THEN 'renewal'
             WHEN o.title_en ILIKE 'Annual%audit%'          THEN 'compliance'
             WHEN o.title_en ILIKE 'Annual%performance%'   THEN 'reporting'
             WHEN o.title_en ILIKE 'Quarterly%'            THEN 'delivery'
             WHEN o.title_en ILIKE 'Send%notification%'    THEN 'notice'
             ELSE 'other'
           END AS kind,
           ROW_NUMBER() OVER (
             PARTITION BY (
               CASE
                 WHEN o.title_en ILIKE 'Payment milestone%'    THEN 'payment'
                 WHEN o.title_en ILIKE 'Renewal notice%'       THEN 'renewal'
                 WHEN o.title_en ILIKE 'Annual%audit%'          THEN 'compliance'
                 WHEN o.title_en ILIKE 'Annual%performance%'   THEN 'reporting'
                 WHEN o.title_en ILIKE 'Quarterly%'            THEN 'delivery'
                 WHEN o.title_en ILIKE 'Send%notification%'    THEN 'notice'
                 ELSE 'other'
               END
             )
             ORDER BY
               CASE WHEN o.status = 'overdue' THEN 0 ELSE 1 END,
               o.due_date ASC NULLS LAST
           ) AS rn
      FROM contract_obligation o
     WHERE o.is_active = TRUE
       AND o.status IN ('open', 'in_progress', 'overdue')
  )
  SELECT jsonb_build_object(
    'overdueCount',
      (SELECT COUNT(*) FROM contract_obligation WHERE status = 'overdue' AND is_active = TRUE),
    'dueThisWeekCount',
      (SELECT COUNT(*) FROM contract_obligation
        WHERE status IN ('open', 'in_progress') AND due_date IS NOT NULL
          AND due_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '7 days' AND is_active = TRUE),
    'top5', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', x.id, 'titleEn', x.title_en, 'contractId', x.contract_id, 'contractNumber', c.contract_number,
        'dueDate', x.due_date, 'status', x.status,
        'daysOverdue', CASE WHEN x.due_date < CURRENT_DATE THEN (CURRENT_DATE - x.due_date)::INT ELSE 0 END,
        'daysLeft', CASE WHEN x.due_date >= CURRENT_DATE THEN (x.due_date - CURRENT_DATE)::INT ELSE 0 END
      ) ORDER BY x.rn ASC, CASE WHEN x.status = 'overdue' THEN 0 ELSE 1 END, x.due_date ASC NULLS LAST)
      FROM (
        SELECT * FROM categorized
         WHERE rn = 1
         ORDER BY CASE WHEN status = 'overdue' THEN 0 ELSE 1 END, due_date ASC NULLS LAST
         LIMIT 5
      ) x
      JOIN contract c ON c.id = x.contract_id
    ), '[]'::jsonb)
  ) INTO v_obligations;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             a.id,
    'activityType',   a.activity_type,
    'contractId',     a.contract_id,
    'contractNumber', c.contract_number,
    'description',    COALESCE(NULLIF(a.description_en, ''),
                               NULLIF(a.metadata->>'description_en', ''),
                               NULLIF(a.metadata->>'description', ''),
                               a.activity_type),
    'createdAt',      a.created_at,
    'actorUserId',    a.actor_id
  ) ORDER BY a.has_desc DESC, a.activity_type_rank ASC, a.created_at DESC), '[]'::jsonb) INTO v_activity_feed
    FROM (
      SELECT id, activity_type, contract_id, description_en, description_ar, metadata, created_at, actor_id,
             CASE
               WHEN activity_type = 'status_changed' THEN 9
               WHEN activity_type = 'ai_risk_score_updated' THEN 8
               WHEN activity_type = 'version_created' THEN 7
               ELSE 1
             END AS activity_type_rank,
             CASE WHEN (description_en IS NOT NULL AND description_en <> '')
                    OR (metadata->>'description' IS NOT NULL AND metadata->>'description' <> '')
                  THEN 1 ELSE 0
             END AS has_desc
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
       ORDER BY
         CASE WHEN (description_en IS NOT NULL AND description_en <> '')
                OR (metadata->>'description' IS NOT NULL AND metadata->>'description' <> '')
              THEN 1 ELSE 0 END DESC,
         (CASE
                   WHEN activity_type = 'status_changed' THEN 9
                   WHEN activity_type = 'ai_risk_score_updated' THEN 8
                   WHEN activity_type = 'version_created' THEN 7
                   ELSE 1
                 END) ASC, created_at DESC
       LIMIT 50
    ) a
    JOIN contract c ON c.id = a.contract_id
   WHERE c.is_active = TRUE;

  SELECT jsonb_build_object(
    'recentRegulatoryUpdates5',
      COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', x.id, 'titleEn', x.title_en, 'titleAr', x.title_ar,
        'severity', x.severity, 'effectiveDate', x.effective_date,
        'regulator', CASE WHEN x.reg_id IS NULL THEN NULL
                          ELSE jsonb_build_object('id', x.reg_id, 'nameEn', x.reg_name_en, 'nameAr', x.reg_name_ar)
                     END
      ) ORDER BY x.effective_date DESC NULLS LAST, x.published_date DESC)
      FROM (SELECT ru.id, ru.title_en, ru.title_ar, ru.severity, ru.effective_date, ru.published_date,
                   r.id AS reg_id, r.name_en AS reg_name_en, r.name_ar AS reg_name_ar
             FROM regulatory_update ru LEFT JOIN regulator r ON r.id = ru.regulator_id
            WHERE ru.is_active = TRUE
            ORDER BY ru.effective_date DESC NULLS LAST, ru.published_date DESC LIMIT 5) x), '[]'::jsonb),
    'openImpacts5',
      COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', x.id, 'contractId', x.contract_id, 'contractNumber', x.contract_number,
        'regulationTitleEn', x.regulation_title_en,
        'severity', COALESCE(x.severity, 'unknown'), 'detectedAt', x.detected_at
      ) ORDER BY x.detected_at DESC)
      FROM (SELECT ri.id, ri.contract_id, c.contract_number, reg.title_en AS regulation_title_en,
                   ru.severity, ri.detected_at
             FROM regulatory_impact ri
             JOIN contract c ON c.id = ri.contract_id
             JOIN regulation reg ON reg.id = ri.regulation_id
             LEFT JOIN regulatory_update ru ON ru.id = ri.regulatory_update_id
            WHERE ri.resolved = FALSE AND ri.is_active = TRUE
            ORDER BY ri.detected_at DESC LIMIT 5) x), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object(
    'kpis',             v_kpis,
    'approvalQueue5',    v_approval_queue,
    'risk',             v_risk,
    'avgReview12w',     v_avg_review,           -- L8 — key renamed to match FE
    'regulatoryUpdates12w', v_reg_updates_12w,
    'contractTypes',    v_contract_types,
    'obligations',v_obligations,
    'activityFeed',     v_activity_feed,
    'lists',            v_lists,
    'windowDays',       v_window
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;
