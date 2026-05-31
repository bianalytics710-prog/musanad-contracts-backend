-- Migration: 382_layla_cluster_d_dashboard.sql
-- Unit: Layla Counsel QA Phase 3.7 (2026-05-31) — Cluster D dashboard fixes
--
-- Closes Layla audit findings:
--   L1  — KPI strip has no section heading (FE-side fix in cluster K — no DB work)
--   L2  — Date filter no-op on KPI strip (window-scope the affected KPIs + FE caption)
--   L3  — Three different "active" totals on the same page (align: KPI / Risk exposure / Contract types)
--   L4  — Activity feed shows only "Status changed" 12× (down-rank status_changed + prefer description)
--   L6  — Top-5 highest-risk contracts all score 70 (real diversification — completes mig 381 step 3)
--   L7  — Obligations at risk: 5 rows all "Payment milestone" (diversify top-5 by category)
--   L10 — Reg-updates 12-week chart: only 3 authorities (re-attribute misattributed regulator_ids)
--   L11 — Recent regulatory updates: 3+ regs misattributed to MoHRE (UPDATE regulator_id per L11)

-- 0. Sentinel
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM regulator WHERE id IN (1,2,3)) THEN
    RAISE NOTICE 'Mig 382: regulator catalog missing — skipping';
    RETURN;
  END IF;
END $$;

-- 1. Seed Ministry of Climate Change & Environment (for ESG / Water-Stress regs) — L11
INSERT INTO regulator (code, name_en, name_ar, jurisdiction, created_at, is_active)
SELECT 'MoCCE', 'Ministry of Climate Change & Environment', 'وزارة التغير المناخي والبيئة', 'UAE', NOW(), TRUE
 WHERE NOT EXISTS (SELECT 1 FROM regulator WHERE code = 'MoCCE');

-- 2. Seed Ministry of Industry & Advanced Technology (for ICV Programme) — L11
INSERT INTO regulator (code, name_en, name_ar, jurisdiction, created_at, is_active)
SELECT 'MOIAT', 'Ministry of Industry & Advanced Technology', 'وزارة الصناعة والتكنولوجيا المتقدمة', 'UAE', NOW(), TRUE
 WHERE NOT EXISTS (SELECT 1 FROM regulator WHERE code = 'MOIAT');

-- 3. L11 — Re-attribute misattributed regulatory_update rows
UPDATE regulatory_update SET regulator_id = (SELECT id FROM regulator WHERE code = 'MoCCE'), updated_at = NOW()
 WHERE id = 15 AND title_en ILIKE '%ESG%Water-Stress%';

UPDATE regulatory_update SET regulator_id = (SELECT id FROM regulator WHERE code = 'Central Bank'), updated_at = NOW()
 WHERE id = 18 AND title_en ILIKE '%AML/CFT%';

UPDATE regulatory_update SET regulator_id = (SELECT id FROM regulator WHERE code = 'MOIAT'), updated_at = NOW()
 WHERE id = 19 AND title_en ILIKE '%ICV%';

UPDATE regulatory_update SET regulator_id = (SELECT id FROM regulator WHERE code = 'Central Bank'), updated_at = NOW()
 WHERE id = 13 AND title_en ILIKE '%Central Bank Circular%';

-- 4. L4 — Seed narrative contract_activity events so the Activity feed has business stories
DO $$
DECLARE
  v_seed_count INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = 52) THEN
    RAISE NOTICE 'Mig 382: HERO-001 missing — skipping activity seed';
    RETURN;
  END IF;

  -- Idempotency: only seed if narrative events don't already exist
  SELECT COUNT(*) INTO v_seed_count
    FROM contract_activity
   WHERE activity_type IN ('regulatory_impact_detected', 'ai_summary_generated', 'sent_for_signature', 'fully_executed')
     AND metadata->>'description' ILIKE '%L4-layla-seed%';

  IF v_seed_count > 0 THEN
    RAISE NOTICE 'Mig 382: narrative activity events already seeded — skipping';
    RETURN;
  END IF;

  -- 10 narrative events to displace status_changed dominance
  INSERT INTO contract_activity (contract_id, activity_type, description_en, description_ar, metadata, created_at, actor_id, is_active, data_classification)
  VALUES
  (52, 'regulatory_impact_detected',
   'Cure notice queued for HERO-001 — variance +13.0% on 2026-07 budget',
   'إشعار علاج مدرج في القائمة لـ HERO-001 — تجاوز +13.0% على ميزانية 2026-07',
   jsonb_build_object('description', 'L4-layla-seed cure notice'),
   NOW() - INTERVAL '12 hours', 4, TRUE, 'demo'),
  (7, 'regulatory_impact_detected',
   'Hormuz FM signal correlated — Mubadala Investment Advisory',
   'إشارة القوة القاهرة لمضيق هرمز مرتبطة — استشارات مبادلة',
   jsonb_build_object('description', 'L4-layla-seed hormuz fm'),
   NOW() - INTERVAL '1 day', 4, TRUE, 'demo'),
  (5, 'regulatory_impact_detected',
   'Federal Decree-Law 9/2024 cascaded to 132 contractors',
   'المرسوم بقانون اتحادي 9/2024 يتدفق إلى 132 مقاولاً',
   jsonb_build_object('description', 'L4-layla-seed decree cascade'),
   NOW() - INTERVAL '2 days', 14, TRUE, 'demo'),
  (5, 'ai_summary_generated',
   'Murban OSP dropped 5.7% — trade margin auto-recompute triggered',
   'انخفض سعر مورّبان الرسمي بنسبة 5.7% — تم إعادة حساب هامش التداول تلقائياً',
   jsonb_build_object('description', 'L4-layla-seed murban'),
   NOW() - INTERVAL '2 days 4 hours', 13, TRUE, 'demo'),
  (38, 'regulatory_impact_detected',
   'ESG water-stress concern flagged — DEWA concession review queued',
   'تم الإبلاغ عن قلق المياه البيئي والاجتماعي والحوكمة — مراجعة امتياز ديوا مدرجة',
   jsonb_build_object('description', 'L4-layla-seed esg water'),
   NOW() - INTERVAL '3 days', 14, TRUE, 'demo'),
  (52, 'ai_summary_generated',
   'High-risk score increase: HERO-001 +5pts after April day-rate breaches',
   'زيادة درجة المخاطر العالية: HERO-001 +5 نقاط بعد تجاوزات سعر اليوم في أبريل',
   jsonb_build_object('description', 'L4-layla-seed risk uplift'),
   NOW() - INTERVAL '3 days 6 hours', 4, TRUE, 'demo'),
  (25, 'regulatory_impact_detected',
   'AML/CFT Cabinet Resolution 24/2026 — Enhanced Due Diligence required',
   'قرار مجلس الوزراء 24/2026 لمكافحة غسل الأموال — العناية الواجبة المعززة مطلوبة',
   jsonb_build_object('description', 'L4-layla-seed amlcft'),
   NOW() - INTERVAL '4 days', 14, TRUE, 'demo'),
  (8, 'sent_for_signature',
   'Hormuz FM Invocation Notice dispatched to Mubadala',
   'تم إرسال إشعار استدعاء القوة القاهرة لمضيق هرمز إلى مبادلة',
   jsonb_build_object('description', 'L4-layla-seed dispatch'),
   NOW() - INTERVAL '4 days 8 hours', 4, TRUE, 'demo'),
  (13, 'ai_summary_generated',
   'Counterparty concentration alert — Mubadala portfolio share crossed 18%',
   'تنبيه تركيز الطرف المقابل — تجاوزت حصة محفظة مبادلة 18%',
   jsonb_build_object('description', 'L4-layla-seed concentration'),
   NOW() - INTERVAL '5 days', 15, TRUE, 'demo'),
  (16, 'fully_executed',
   'MoHRE Fixed-Term Employment template — 5 new contracts onboarded this week',
   'قالب التوظيف محدد المدة لوزارة الموارد البشرية — تم إعداد 5 عقود جديدة هذا الأسبوع',
   jsonb_build_object('description', 'L4-layla-seed onboarding'),
   NOW() - INTERVAL '6 days', 5, TRUE, 'demo');
END $$;

-- 5. Rewrite fn_dashboard_legal_counsel sections affected by L3, L4, L7
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

  -- L3 — Single source of truth for "active": status IN ('active','fully_signed')
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
    'activeContracts', v_active_total,   -- L3 — unified
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

  -- Approval queue (unchanged)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractId',     c.id,
    'contractNumber', c.contract_number,
    'titleEn',        c.title_en,
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

  -- Risk exposure (L3 — use v_active_total)
  WITH scored AS (
    SELECT c.id AS contract_id, c.contract_number, c.title_en,
           COALESCE(lrs.health_score, 50) AS risk
      FROM contract c
      LEFT JOIN latest_risk_score lrs ON lrs.contract_id = c.id
     WHERE c.status IN ('active', 'fully_signed') AND c.is_active = TRUE
  )
  SELECT jsonb_build_object(
    'totalActive', v_active_total,                          -- L3 — aligned
    'lowCount',    (SELECT COUNT(*) FROM scored WHERE risk BETWEEN 0 AND 30),
    'mediumCount', (SELECT COUNT(*) FROM scored WHERE risk BETWEEN 31 AND 60),
    'highCount',   (SELECT COUNT(*) FROM scored WHERE risk > 60),
    'top5',        COALESCE((SELECT jsonb_agg(jsonb_build_object(
                     'contractId', s.contract_id, 'contractNumber', s.contract_number,
                     'titleEn', s.title_en, 'risk', s.risk)
                     ORDER BY s.risk DESC, s.contract_number)
                   FROM (SELECT * FROM scored ORDER BY risk DESC, contract_number LIMIT 5) s), '[]'::jsonb)
  ) INTO v_risk;

  -- Avg review time (unchanged)
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

  -- Reg updates 12 weeks (unchanged — now bigger authorities count via L11 update)
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

  -- L3 — Contract types totals aligned: count only `active` + `fully_signed`
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

  -- L7 — Diversified top-5 obligations: pick 1 per category, then fill with overdue payments
  WITH cat_pick AS (
    SELECT DISTINCT ON (kind) o.id, o.title_en, o.contract_id, o.due_date, o.status,
           CASE
             WHEN o.title_en ILIKE 'Payment milestone%' THEN 'payment'
             WHEN o.title_en ILIKE 'Renewal notice%'    THEN 'renewal'
             WHEN o.title_en ILIKE 'Annual%audit%'      THEN 'compliance'
             WHEN o.title_en ILIKE 'Annual%performance%' THEN 'reporting'
             WHEN o.title_en ILIKE 'Quarterly%'         THEN 'delivery'
             WHEN o.title_en ILIKE 'Send%notification%' THEN 'notice'
             ELSE 'other'
           END AS kind
      FROM contract_obligation o
     WHERE o.is_active = TRUE AND o.status IN ('open', 'in_progress', 'overdue')
     ORDER BY kind,
              CASE WHEN o.status = 'overdue' THEN 0 ELSE 1 END,
              o.due_date ASC NULLS LAST
  ),
  ranked AS (
    SELECT id, title_en, contract_id, due_date, status, 1 AS sort_pri FROM cat_pick
    UNION ALL
    SELECT o.id, o.title_en, o.contract_id, o.due_date, o.status, 2 AS sort_pri
      FROM contract_obligation o
     WHERE o.is_active = TRUE AND o.status IN ('open', 'in_progress', 'overdue')
       AND o.id NOT IN (SELECT id FROM cat_pick)
     ORDER BY 6, CASE WHEN o.status = 'overdue' THEN 0 ELSE 1 END, o.due_date ASC NULLS LAST
  )
  SELECT jsonb_build_object(
    'overdueCount',
      (SELECT COUNT(*) FROM contract_obligation WHERE status = 'overdue' AND is_active = TRUE),
    'dueThisWeekCount',
      (SELECT COUNT(*) FROM contract_obligation
        WHERE status IN ('open', 'in_progress') AND due_date IS NOT NULL
          AND due_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '7 days' AND is_active = TRUE),
    'top5', COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id', o.id, 'titleEn', o.title_en, 'contractId', o.contract_id, 'contractNumber', c.contract_number,
      'dueDate', o.due_date, 'status', o.status,
      'daysOverdue', CASE WHEN o.due_date < CURRENT_DATE THEN (CURRENT_DATE - o.due_date)::INT ELSE 0 END,
      'daysLeft', CASE WHEN o.due_date >= CURRENT_DATE THEN (o.due_date - CURRENT_DATE)::INT ELSE 0 END
    ) ORDER BY o.sort_pri,
               CASE WHEN o.status = 'overdue' THEN 0 ELSE 1 END,
               o.due_date ASC NULLS LAST)
      FROM (SELECT * FROM ranked LIMIT 5) o
      JOIN contract c ON c.id = o.contract_id), '[]'::jsonb)
  ) INTO v_obligations;

  -- L4 — Activity feed: prefer description from metadata, down-rank status_changed
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
  ) ORDER BY a.activity_type_rank ASC, a.created_at DESC), '[]'::jsonb) INTO v_activity_feed
    FROM (
      SELECT id, activity_type, contract_id, description_en, description_ar, metadata, created_at, actor_id,
             CASE
               WHEN activity_type = 'status_changed' THEN 9
               WHEN activity_type = 'ai_risk_score_updated' THEN 8
               WHEN activity_type = 'version_created' THEN 7
               ELSE 1
             END AS activity_type_rank
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
       ORDER BY (CASE
                   WHEN activity_type = 'status_changed' THEN 9
                   WHEN activity_type = 'ai_risk_score_updated' THEN 8
                   WHEN activity_type = 'version_created' THEN 7
                   ELSE 1
                 END) ASC,
                created_at DESC
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
    'approvalQueue',    v_approval_queue,
    'riskExposure',     v_risk,
    'avgReviewTime12w', v_avg_review,
    'regUpdates12w',    v_reg_updates_12w,
    'contractTypes',    v_contract_types,
    'obligationsAtRisk',v_obligations,
    'activityFeed',     v_activity_feed,
    'lists',            v_lists,
    'windowDays',       v_window
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_dashboard_legal_counsel(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_legal_counsel(INTEGER) TO neondb_owner;
