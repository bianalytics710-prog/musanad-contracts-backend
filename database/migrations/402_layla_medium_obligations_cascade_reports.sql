-- Migration: 402_layla_medium_obligations_cascade_reports.sql
-- Unit: Layla Counsel QA medium-pass — L67, L69, L81, L82, L83, L84
--
-- L67 — "COMPLETED = 0" on 50 obligations is implausible → mark 12 obligations completed
-- L69 — CT-2026 prefix on isolated contracts breaks the contract-number convention → rename
-- L81 — Cascade triggered_by always Khalid → diversify on 1 cascade run
-- L82 — Reports show "Never generated" on every template → seed last_run_at
-- L83 — Report description has slug "weather.fm_eligible rule" → rewrite
-- L84 — Only 4 reports for legal_counsel → seed 3 more legal-relevant templates

-- 1. L67 — Mark 12 obligations completed (open/in_progress with due_date in past 60 days)
UPDATE contract_obligation
   SET status = 'completed',
       completed_at = (due_date + INTERVAL '2 days')::timestamptz,
       updated_at = NOW()
 WHERE id IN (
   SELECT id FROM contract_obligation
    WHERE is_active = TRUE
      AND status IN ('open', 'in_progress')
      AND due_date BETWEEN CURRENT_DATE - INTERVAL '60 days' AND CURRENT_DATE - INTERVAL '7 days'
    ORDER BY due_date
    LIMIT 12
 );

-- 2. L69 — Rename CT-2026-000002 → MUSANAD-2026-100 (consistent prefix)
UPDATE contract
   SET contract_number = 'MUSANAD-2026-100',
       updated_at = NOW()
 WHERE contract_number = 'CT-2026-000002';

-- 3. L81 — Diversify cascade triggered_by: split between Khalid/Layla/platform_admin
DO $$
DECLARE
  v_layla BIGINT;
  v_khalid BIGINT;
  v_admin BIGINT;
  v_runs BIGINT[];
BEGIN
  SELECT id INTO v_layla FROM "user" WHERE email = 'legal@musanad.local' LIMIT 1;
  SELECT id INTO v_khalid FROM "user" WHERE email = 'compliance@musanad.local' LIMIT 1;
  SELECT id INTO v_admin FROM "user" WHERE email = 'platform@musanad.local' LIMIT 1;

  SELECT array_agg(id ORDER BY id) INTO v_runs
    FROM regulatory_cascade_run WHERE is_active = TRUE;

  IF v_runs IS NULL OR array_length(v_runs, 1) = 0 THEN RETURN; END IF;

  -- Assign distinct created_by across runs
  IF array_length(v_runs, 1) >= 1 AND v_khalid IS NOT NULL THEN
    UPDATE regulatory_cascade_run SET created_by = v_khalid WHERE id = v_runs[1];
  END IF;
  IF array_length(v_runs, 1) >= 2 AND v_layla IS NOT NULL THEN
    UPDATE regulatory_cascade_run SET created_by = v_layla WHERE id = v_runs[2];
  END IF;
  IF array_length(v_runs, 1) >= 3 AND v_admin IS NOT NULL THEN
    UPDATE regulatory_cascade_run SET created_by = v_admin WHERE id = v_runs[3];
  END IF;
END $$;

-- 4. L82 — Backdate last_run_at on existing report templates so the FE shows
--    a "Last generated" timestamp instead of "Never generated"
UPDATE report_template
   SET last_run_at = NOW() - (random() * INTERVAL '5 days'),
       updated_at = NOW()
 WHERE last_run_at IS NULL AND is_active = TRUE;

-- 4b. Also seed one report_run row per visible template so the FE log surfaces real history
INSERT INTO report_run (
  tenant_id, report_template_id, triggered_by, triggered_by_user_id,
  parameters, format, status,
  started_at, completed_at, created_at
)
SELECT
  '00000000-0000-0000-0000-000000000001',
  rt.id,
  'manual',
  COALESCE((SELECT id FROM "user" WHERE email = 'legal@musanad.local' LIMIT 1), 1),
  '{}'::jsonb,
  CASE WHEN LOWER(rt.report_kind) = 'pdf' THEN 'pdf' ELSE 'excel' END,
  'complete',
  NOW() - INTERVAL '2 days',
  NOW() - INTERVAL '2 days' + INTERVAL '37 seconds',
  NOW() - INTERVAL '2 days'
FROM report_template rt
WHERE rt.is_active = TRUE
  AND NOT EXISTS (SELECT 1 FROM report_run rr WHERE rr.report_template_id = rt.id);

-- 5. L83 — Rewrite slug-laden description on FM eligibility report template
UPDATE report_template
   SET description = 'Contracts flagged by weather-driven Force Majeure eligibility (Hormuz Strait + Persian Gulf wind/wave events) with full match evidence and impacted-clause traceability.',
       updated_at = NOW()
 WHERE template_id = 'force_majeure_eligibility'
    OR display_name_en ILIKE '%Force Majeure Eligibility%';

-- 6. L84 — Seed 3 more legal-relevant report templates so Layla's library
--    isn't anemic. Templates are tenant-scoped, marked enabled, assigned_roles
--    targets legal_counsel.
INSERT INTO report_template (
  tenant_id, template_id, display_name_en, display_name_ar, description,
  report_kind, data_source, parameter_schema, assigned_roles, is_scheduled,
  enabled, data_classification, created_at, updated_at, is_active
)
SELECT '00000000-0000-0000-0000-000000000001', t.template_id, t.display_name_en, t.display_name_ar,
       t.description, t.report_kind, t.data_source, '{}'::jsonb, t.assigned_roles, FALSE,
       TRUE, 'internal', NOW(), NOW(), TRUE
  FROM (VALUES
    (
      'cure_notice_audit',
      'Cure Notice Audit',
      'تدقيق إشعارات الإصلاح',
      'All cure notices dispatched in the last 12 months with disposition + remediation outcomes per contract.',
      'pdf',
      'advisory_draft',
      '["legal_counsel","platform_admin","Super Admin"]'::jsonb
    ),
    (
      'advisory_approval_sla',
      'Advisory Approval SLA',
      'مستوى خدمة اعتماد الاستشارات',
      'Advisory queue throughput by template + average review hours, broken down per legal counsel actor.',
      'excel',
      'advisory_draft',
      '["legal_counsel","platform_admin","Super Admin"]'::jsonb
    ),
    (
      'dispatched_notifications_log',
      'Dispatched Notifications Log',
      'سجل الإشعارات المُرسلة',
      'All advisory dispatches (email + Teams + Slack) with delivery status + recipient acknowledgement.',
      'excel',
      'advisory_dispatch_log',
      '["legal_counsel","platform_admin","Super Admin"]'::jsonb
    )
  ) AS t(template_id, display_name_en, display_name_ar, description, report_kind, data_source, assigned_roles)
WHERE NOT EXISTS (
  SELECT 1 FROM report_template WHERE template_id = t.template_id
);
