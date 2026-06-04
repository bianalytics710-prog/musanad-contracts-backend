-- MIGRATION: 524_report_template_tailored_seeds.sql
-- Date: 2026-06-03
-- Description:
--   Per-role tailored report seeds + assigned_roles cleanup. Companion to
--   mig 523 (fns). Each of the 4 target roles (Executive / Drafter /
--   Approver / Legal Counsel) now sees a curated 5-7 report set grouped
--   into 2 sections.
--
--   For each target role:
--     1. UPDATE existing templates to set section_key + assigned_roles
--     2. INSERT 8 new templates (3 drafter, 3 approver, 2 executive)
--     3. UPDATE 3 broken Legal-Counsel templates to use the fn slugs
--        deployed in mig 523 (advisory_approval_sla, cure_notice_audit,
--        dispatched_notifications_log).
--   Other roles (compliance_esg, finance_treasury, operations,
--   procurement_supplier_risk) are not touched here.

BEGIN;

-- ============================================================
-- EXECUTIVE — section_key + reassign + 2 NEW
-- ============================================================
UPDATE report_template SET
  section_key = 'board_brief',
  assigned_roles = '["executive","platform_admin","Super Admin"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id IN ('executive_weekly_brief', 'executive_monthly_board');

UPDATE report_template SET
  section_key = 'risk_exposure',
  assigned_roles = '["executive","platform_admin","Super Admin","contract_approver"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id = 'executive_top10_exposures';

UPDATE report_template SET
  section_key = 'risk_exposure',
  assigned_roles = '["executive","platform_admin","Super Admin"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id = 'executive_avar_trend';

-- New executive templates
INSERT INTO report_template (
  tenant_id, template_id, display_name_en, display_name_ar, description,
  report_kind, data_source, parameter_schema, assigned_roles,
  is_scheduled, enabled, section_key, data_classification,
  created_by, updated_by
) VALUES
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'counterparty_concentration', 'Counterparty Concentration',
   'تركّز الأطراف المقابلة',
   'Top 20 counterparties by total committed value, with portfolio share and average risk score. Used by Executives to track concentration risk.',
   'excel', 'counterparty_concentration', '{}'::jsonb,
   '["executive","platform_admin","Super Admin"]'::jsonb,
   FALSE, TRUE, 'risk_exposure', 'internal', 1, 1),
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'recent_material_events', 'Recent Material Events (30d)',
   'الأحداث الجوهرية الأخيرة',
   'Last 30 days of correlation events that fired board-watch rules (FM, sanctions, ICV, weather, ESG). Counterparty, contract, rule, and severity per row.',
   'pdf', 'recent_material_events', '{}'::jsonb,
   '["executive","platform_admin","Super Admin"]'::jsonb,
   FALSE, TRUE, 'board_brief', 'internal', 1, 1)
ON CONFLICT (tenant_id, template_id) DO UPDATE SET
  display_name_en = EXCLUDED.display_name_en, display_name_ar = EXCLUDED.display_name_ar,
  description = EXCLUDED.description, report_kind = EXCLUDED.report_kind,
  data_source = EXCLUDED.data_source, assigned_roles = EXCLUDED.assigned_roles,
  section_key = EXCLUDED.section_key, enabled = TRUE, is_active = TRUE, updated_at = NOW();


-- ============================================================
-- DRAFTER — section_key + reassign + 3 NEW
-- ============================================================
UPDATE report_template SET
  section_key = 'my_work',
  assigned_roles = '["contract_drafter","platform_admin","Super Admin"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id = 'drafter_my_pipeline';

UPDATE report_template SET
  section_key = 'productivity',
  assigned_roles = '["contract_drafter","platform_admin","Super Admin"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id IN ('drafter_cycle_time', 'drafter_template_usage');

-- Remove drafter from legal_clause_review_backlog (it's a legal-counsel report)
UPDATE report_template SET
  assigned_roles = (
    SELECT jsonb_agg(value) FROM jsonb_array_elements_text(assigned_roles)
    WHERE value::text NOT IN ('"contract_drafter"','contract_drafter')
  ),
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id = 'legal_clause_review_backlog'
  AND assigned_roles ? 'contract_drafter';

INSERT INTO report_template (
  tenant_id, template_id, display_name_en, display_name_ar, description,
  report_kind, data_source, parameter_schema, assigned_roles,
  is_scheduled, enabled, section_key, data_classification,
  created_by, updated_by
) VALUES
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'drafter_drafts_awaiting_input', 'Drafts awaiting my input',
   'المسودات بانتظار ردي',
   'Contracts I drafted where an approver has requested information from me. Shows days open + requester role.',
   'excel', 'drafter_drafts_awaiting_input', '{}'::jsonb,
   '["contract_drafter","platform_admin","Super Admin"]'::jsonb,
   FALSE, TRUE, 'my_work', 'internal', 1, 1),
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'drafter_contracts_in_approval', 'My contracts in approval',
   'عقودي قيد الموافقة',
   'Contracts I drafted that are currently in the approval queue. Shows current stage, approver role, and days in queue.',
   'excel', 'drafter_contracts_in_approval', '{}'::jsonb,
   '["contract_drafter","platform_admin","Super Admin"]'::jsonb,
   FALSE, TRUE, 'my_work', 'internal', 1, 1),
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'drafter_recently_signed', 'Recently signed (30d)',
   'العقود الموقعة مؤخراً',
   'My contracts signed in the last 30 days with cycle time and value. Personal self-review surface.',
   'excel', 'drafter_recently_signed', '{}'::jsonb,
   '["contract_drafter","platform_admin","Super Admin"]'::jsonb,
   FALSE, TRUE, 'productivity', 'internal', 1, 1)
ON CONFLICT (tenant_id, template_id) DO UPDATE SET
  display_name_en = EXCLUDED.display_name_en, display_name_ar = EXCLUDED.display_name_ar,
  description = EXCLUDED.description, report_kind = EXCLUDED.report_kind,
  data_source = EXCLUDED.data_source, assigned_roles = EXCLUDED.assigned_roles,
  section_key = EXCLUDED.section_key, enabled = TRUE, is_active = TRUE, updated_at = NOW();


-- ============================================================
-- APPROVER — section_key + reassign + 3 NEW
-- ============================================================
UPDATE report_template SET
  section_key = 'my_queue',
  assigned_roles = '["contract_approver","contract_approver_2","platform_admin","Super Admin"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id = 'approver_sla_breach_summary';

UPDATE report_template SET
  section_key = 'decisions',
  assigned_roles = '["contract_approver","contract_approver_2","platform_admin","Super Admin"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id IN ('approver_my_decisions', 'approver_cycle_time_by_type');

-- Remove approver from legal_clause_review_backlog + executive_top10_exposures
UPDATE report_template SET
  assigned_roles = (
    SELECT COALESCE(jsonb_agg(value), '[]'::jsonb) FROM jsonb_array_elements_text(assigned_roles)
    WHERE value::text NOT IN ('"contract_approver"','contract_approver')
  ),
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id = 'legal_clause_review_backlog'
  AND assigned_roles ? 'contract_approver';

UPDATE report_template SET
  assigned_roles = (
    SELECT COALESCE(jsonb_agg(value), '[]'::jsonb) FROM jsonb_array_elements_text(assigned_roles)
    WHERE value::text NOT IN ('"contract_approver"','contract_approver')
  ),
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id = 'executive_top10_exposures'
  AND assigned_roles ? 'contract_approver';

INSERT INTO report_template (
  tenant_id, template_id, display_name_en, display_name_ar, description,
  report_kind, data_source, parameter_schema, assigned_roles,
  is_scheduled, enabled, section_key, data_classification,
  created_by, updated_by
) VALUES
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'approver_pending_approvals', 'My pending approvals',
   'الموافقات المعلقة لدي',
   'Approval steps currently awaiting my decision. Shows hours pending, contract value, and counterparty.',
   'excel', 'approver_pending_approvals', '{}'::jsonb,
   '["contract_approver","contract_approver_2","platform_admin","Super Admin"]'::jsonb,
   FALSE, TRUE, 'my_queue', 'internal', 1, 1),
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'approver_high_value_approvals', 'High-value approvals (≥ AED 1M)',
   'الموافقات ذات القيمة العالية',
   'Pending approvals in my queue where the contract value is at or above AED 1 million. Threshold configurable via parameters.thresholdAed.',
   'excel', 'approver_high_value_approvals', '{"properties":{"thresholdAed":{"type":"number","default":1000000}}}'::jsonb,
   '["contract_approver","contract_approver_2","platform_admin","Super Admin"]'::jsonb,
   FALSE, TRUE, 'my_queue', 'internal', 1, 1),
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'approver_weekly_activity', 'Weekly decision activity',
   'نشاط القرارات الأسبوعي',
   'PDF briefing of decisions I made in the last 7 days: counts by decision status, average cycle time, and a per-contract decision log.',
   'pdf', 'approver_weekly_activity', '{}'::jsonb,
   '["contract_approver","contract_approver_2","platform_admin","Super Admin"]'::jsonb,
   FALSE, TRUE, 'decisions', 'internal', 1, 1)
ON CONFLICT (tenant_id, template_id) DO UPDATE SET
  display_name_en = EXCLUDED.display_name_en, display_name_ar = EXCLUDED.display_name_ar,
  description = EXCLUDED.description, report_kind = EXCLUDED.report_kind,
  data_source = EXCLUDED.data_source, assigned_roles = EXCLUDED.assigned_roles,
  section_key = EXCLUDED.section_key, enabled = TRUE, is_active = TRUE, updated_at = NOW();


-- ============================================================
-- LEGAL COUNSEL — section_key + 3 FIXES (data_source)
-- ============================================================
UPDATE report_template SET
  section_key = 'advisory',
  assigned_roles = '["legal_counsel","platform_admin","Super Admin"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id = 'legal_advisory_queue';

-- Fix the 3 broken data_source pointers + set section + roles
UPDATE report_template SET
  data_source = 'advisory_approval_sla',
  section_key = 'advisory',
  assigned_roles = '["legal_counsel","platform_admin","Super Admin"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id = 'advisory_approval_sla';

UPDATE report_template SET
  data_source = 'cure_notice_audit',
  section_key = 'advisory',
  assigned_roles = '["legal_counsel","platform_admin","Super Admin"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id = 'cure_notice_audit';

UPDATE report_template SET
  data_source = 'dispatched_notifications_log',
  section_key = 'advisory',
  assigned_roles = '["legal_counsel","platform_admin","Super Admin"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id = 'dispatched_notifications_log';

UPDATE report_template SET
  section_key = 'regulatory_clause',
  assigned_roles = '["legal_counsel","platform_admin","Super Admin"]'::jsonb,
  updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND template_id IN ('legal_clause_review_backlog', 'legal_fm_eligibility', 'legal_regulatory_digest');

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (524, 'report_template_tailored_seeds', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
