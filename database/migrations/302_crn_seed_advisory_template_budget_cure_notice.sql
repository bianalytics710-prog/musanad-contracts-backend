-- Migration: 302_crn_seed_advisory_template_budget_cure_notice.sql
-- Module: CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half)
-- Description: INSERT budget_cure_notice_v1 advisory_template (EN+AR Mustache).
--              Modeled on cure_notice_v1 (mig 211). Same draft_type, assigned_approver_role,
--              dispatch_channels, version, data_classification.
--              Advisory template uses display_name_en / display_name_ar columns (verified from live schema).
--              Idempotency: ON CONFLICT (tenant_id, template_id) DO NOTHING.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

INSERT INTO advisory_template (
  tenant_id,
  template_id,
  display_name_en,
  display_name_ar,
  draft_type,
  body_template_en,
  body_template_ar,
  parameter_schema,
  assigned_approver_role,
  dispatch_channels,
  version,
  data_classification,
  is_active,
  created_at,
  updated_at
)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid,
  'budget_cure_notice_v1',
  'Budget Variance Cure Notice',
  'إشعار إصلاح انحراف الميزانية',
  'cure_notice',
  $body_en$BUDGET VARIANCE CURE NOTICE

Date: {{notice_date}}
Contract: {{contract_id}}
To: {{addressee}} — {{counterparty_name}}

Dear {{addressee}},

We refer to the above contract and write to formally notify you of a budget variance breach in the {{breach_period}} period for {{cost_category}}.

VARIANCE DETAILS:
  Budgeted amount ({{breach_period}}): AED {{budgeted_amount_aed}}
  Actual spend ({{breach_period}}):    AED {{actual_amount_aed}}
  Overrun:                             {{overrun_pct}}% above plan

This variance exceeds the contractual performance threshold. Pursuant to the contract's liquidated damages provision ({{ld_clause_ref}}), the Company reserves all rights in respect of this overrun.

CURE REQUIREMENT:
  You are required to remedy this variance within {{cure_period_days}} calendar days of this notice (cure deadline: {{cure_period_end_date}}). Please provide a written remediation plan within 7 calendar days.

Please direct any response or queries to: {{cure_address}}

Yours faithfully,
[Authorised Signatory]
ADNOC [Entity]$body_en$,
  $body_ar$إشعار إصلاح انحراف الميزانية

التاريخ: {{notice_date}}
العقد: {{contract_id}}
إلى: {{addressee}} — {{counterparty_name}}

عزيزي {{addressee}}،

نشير إلى العقد المذكور أعلاه ونكتب إليكم لإخطاركم رسمياً بانحراف في الميزانية خلال فترة {{breach_period}} فيما يخص {{cost_category}}.

تفاصيل الانحراف:
  المبلغ المُدرج في الميزانية ({{breach_period}}): {{budgeted_amount_aed}} درهم إماراتي
  الإنفاق الفعلي ({{breach_period}}):              {{actual_amount_aed}} درهم إماراتي
  الزيادة:                                         {{overrun_pct}}% فوق الخطة

يتجاوز هذا الانحراف حد الأداء التعاقدي. استناداً إلى بند الغرامات التعاقدية ({{ld_clause_ref}})، تحتفظ الشركة بجميع حقوقها فيما يتعلق بهذا الانحراف.

متطلبات الإصلاح:
  يُلزَم بإصلاح هذا الانحراف خلال {{cure_period_days}} يوماً تقويمياً من تاريخ هذا الإشعار (آخر موعد للإصلاح: {{cure_period_end_date}}). يُرجى تقديم خطة إصلاح مكتوبة خلال 7 أيام تقويمية.

يُرجى توجيه أي رد أو استفسار إلى: {{cure_address}}

مع التحية،
[المفوَّض بالتوقيع]
أدنوك [الكيان]$body_ar$,
  '{
    "notice_date":          {"type":"string","description":"Date of notice (DD Month YYYY)"},
    "contract_id":          {"type":"string","description":"Contract number (e.g. CRN-296-HERO-001)"},
    "addressee":            {"type":"string","description":"Name of counterparty contact / signatory"},
    "counterparty_name":    {"type":"string","description":"Legal name of counterparty (e.g. ADNOC Drilling)"},
    "breach_period":        {"type":"string","description":"Human label for breach period (e.g. April 2026 / 2026-Q2)"},
    "cost_category":        {"type":"string","description":"Cost category in breach (e.g. day-rate billing)"},
    "overrun_pct":          {"type":"string","description":"Overrun percentage (e.g. 8)"},
    "budgeted_amount_aed":  {"type":"string","description":"Budgeted amount for the period/category in AED"},
    "actual_amount_aed":    {"type":"string","description":"Actual spend for the period/category in AED"},
    "ld_clause_ref":        {"type":"string","description":"LD rate/cap reference text from the contract"},
    "cure_period_days":     {"type":"string","description":"Cure period in days (e.g. 30)"},
    "cure_period_end_date": {"type":"string","description":"Cure deadline date (DD Month YYYY)"},
    "cure_address":         {"type":"string","description":"Notice delivery address"}
  }'::jsonb,
  'legal_counsel',
  '["email","teams_capture","slack_capture"]'::jsonb,
  1,
  'sensitive',
  TRUE,
  NOW(),
  NOW()
)
ON CONFLICT (tenant_id, template_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (302, '302_crn_seed_advisory_template_budget_cure_notice', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM advisory_template
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
--     AND template_id = 'budget_cure_notice_v1';
-- DELETE FROM schema_migrations WHERE version = 302;
-- COMMIT;
-- ============================================================
