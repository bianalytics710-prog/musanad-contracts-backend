-- Migration: 291_crm_seed_advisory_template_labor_law.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: INSERT labor_law_amendment_v1 advisory_template for ADNOC tenant.
--              draft_type='custom' (closed CHECK has no labor/amendment value — per decision CR-M-Q5).
--              EN+AR Mustache bodies with 5 required placeholders.
--              ON CONFLICT (tenant_id, template_id) DO NOTHING — idempotent.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

INSERT INTO advisory_template
  (tenant_id, template_id, display_name_en, display_name_ar,
   draft_type, body_template_en, body_template_ar,
   parameter_schema, assigned_approver_role, dispatch_channels,
   version, data_classification,
   created_at, updated_at, created_by, updated_by, last_modified_by, is_active)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'labor_law_amendment_v1',
  'Labor-Law Amendment Notice',
  'إشعار تعديل قانون العمل',
  'custom',
  $$NOTICE OF REQUIRED CONTRACT AMENDMENT — LABOR LAW COMPLIANCE

Date: {{notice_date}}
Contract Reference: {{contract_id}}
To: {{addressee}}
Contractor: {{contractorName}}

Dear {{addressee}},

This notice is issued pursuant to {{decreeRef}} (effective 30 August 2024), which extends Emiratisation obligations to employers in the 20–49 headcount band and establishes fines in the range of AED 100,000 to AED 1,000,000 for non-compliance.

Clause Reference: {{clauseRef}}

Following a review of your existing contractual obligations under ADNOC Group procurement standards, we hereby notify {{contractorName}} of the requirement to amend the above-referenced contract clause to reflect the updated Emiratisation targets.

Required Action:
{{contractorName}} must achieve a minimum of {{emiratisationTarget}} Emirati national(s) in its UAE workforce employed under ADNOC contracts by {{complianceDeadline}}.

Failure to comply by the stated deadline may expose {{contractorName}} to regulatory penalties under {{decreeRef}} and may affect eligibility for future ADNOC procurement engagements.

Please confirm receipt and your proposed remediation plan within 14 calendar days of this notice.

Issued by ADNOC Legal & Compliance$$,
  $$إشعار بتعديل العقد المطلوب — الامتثال لقانون العمل

التاريخ: {{notice_date}}
مرجع العقد: {{contract_id}}
إلى: {{addressee}}
المقاول: {{contractorName}}

عزيزي {{addressee}}،

يُصدر هذا الإشعار وفقاً لأحكام {{decreeRef}} (النافذ بتاريخ 30 أغسطس 2024)، الذي يُوسّع نطاق التزامات التوطين ليشمل أصحاب العمل في فئة القوى العاملة بين 20 و49 موظفاً، ويُحدد غرامات تتراوح بين 100,000 و1,000,000 درهم إماراتي على المخالفين.

المرجع البندي: {{clauseRef}}

عقب مراجعة التزاماتكم التعاقدية القائمة في إطار معايير المشتريات لمجموعة أدنوك، نُخطر شركة {{contractorName}} بضرورة تعديل البند التعاقدي المشار إليه آنفاً ليعكس أهداف التوطين المستحدثة.

الإجراء المطلوب:
يتعين على {{contractorName}} توظيف ما لا يقل عن {{emiratisationTarget}} مواطن(ين) إماراتي(ين) في قوتها العاملة بدولة الإمارات العاملين في إطار عقود أدنوك، وذلك بحلول {{complianceDeadline}}.

قد يُعرِّض عدم الامتثال في الموعد المحدد شركةَ {{contractorName}} للعقوبات التنظيمية المنصوص عليها في {{decreeRef}}، وقد يؤثر على أهليتها للمشاركة في مناقصات أدنوك المستقبلية.

يُرجى تأكيد الاستلام وتقديم خطة العلاج المقترحة خلال 14 يوماً تقويمياً من تاريخ هذا الإشعار.

صادر عن إدارة الشؤون القانونية والامتثال — أدنوك$$,
  '{
    "required": ["contractorName","clauseRef","decreeRef","complianceDeadline","emiratisationTarget"],
    "optional": ["notice_date","contract_id","addressee"],
    "properties": {
      "contractorName":      {"type":"string","description":"Full legal name of the contractor party"},
      "clauseRef":           {"type":"string","description":"Contract clause reference (e.g. clause number/title)"},
      "decreeRef":           {"type":"string","description":"Regulatory decree reference (e.g. Federal Decree-Law No. 9 of 2024)"},
      "complianceDeadline":  {"type":"string","description":"Deadline for Emiratisation compliance (ISO date string)"},
      "emiratisationTarget": {"type":"number","description":"Required number of Emirati employees"},
      "notice_date":         {"type":"string","description":"Date of this notice (ISO date, defaults to today)"},
      "contract_id":         {"type":"string","description":"Contract number for reference"},
      "addressee":           {"type":"string","description":"Name of recipient / addressee"}
    }
  }'::jsonb,
  'legal_counsel',
  '["email","teams_capture","slack_capture"]'::jsonb,
  1,
  'sensitive',
  NOW(), NOW(), NULL, NULL, NULL, TRUE
)
ON CONFLICT (tenant_id, template_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (291, '291_crm_seed_advisory_template_labor_law', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 291;
-- DELETE FROM advisory_template
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--     AND template_id = 'labor_law_amendment_v1';
-- COMMIT;
-- ============================================================
