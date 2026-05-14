-- MIGRATION: 211_crh_seed_advisory_templates.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: INSERT 3 advisory_template seed rows for ADNOC tenant — Hormuz FM Invocation, Sanctions Hold Notice, Cure Notice.
--              ON CONFLICT (tenant_id, template_id) DO NOTHING — idempotent.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_adnoc_tenant UUID := '00000000-0000-0000-0000-000000000001';
BEGIN

INSERT INTO advisory_template
  (tenant_id, template_id, display_name_en, display_name_ar, description,
   draft_type, body_template_en, body_template_ar,
   parameter_schema, assigned_approver_role, dispatch_channels, version, data_classification,
   created_at, updated_at, created_by, updated_by, last_modified_by, is_active)
VALUES
-- 1. Hormuz Force Majeure Invocation Notice
(v_adnoc_tenant, 'hormuz_fm_invocation_v1',
 'Hormuz Strait — Force Majeure Invocation Notice',
 'مضيق هرمز — إشعار استدعاء القوة القاهرة',
 'Formal force majeure invocation notice for contracts with Gulf shipping clauses, triggered by Hormuz Strait closure or navigability event.',
 'fm_invocation',
 $$FORCE MAJEURE INVOCATION NOTICE

Date: {{notice_date}}
Contract Reference: {{contract_id}}
Addressee: {{addressee}}

Dear {{addressee}},

We hereby formally invoke the Force Majeure provisions contained within Section {{fm_clause_text}} of Contract No. {{contract_id}} entered into between ADNOC Group and {{counterparty_name}}.

A confirmed force majeure event has arisen arising from disruption to navigability of the Hormuz Strait. The event was identified on {{signal_date}} via the following credible source: {{signal_summary}}.

Pursuant to the force majeure clause referenced above, performance obligations under the Contract are suspended for the duration of the event. Notice is hereby served within the contractual notice period of {{notice_period_days}} calendar days from the date of event identification.

We request acknowledgment of receipt of this notice within 5 business days.

Yours faithfully,
ADNOC Group — Legal Affairs Division$$,
 $$إشعار استدعاء القوة القاهرة

التاريخ: {{notice_date}}
مرجع العقد: {{contract_id}}
المرسل إليه: {{addressee}}

عزيزي {{addressee}}،

نحيطكم علماً بأننا ندعو رسمياً إلى أحكام القوة القاهرة الواردة في القسم {{fm_clause_text}} من العقد رقم {{contract_id}} المبرم بين مجموعة أدنوك و{{counterparty_name}}.

نشأ حدث قوة قاهرة مؤكد نتيجة اضطراب في إمكانية الملاحة في مضيق هرمز. تم تحديد الحدث في {{signal_date}} عبر المصدر الموثوق التالي: {{signal_summary}}.

وفقاً لبند القوة القاهرة المشار إليه أعلاه، تُعلَّق التزامات الأداء بموجب العقد طوال مدة الحدث. يُقدَّم هذا الإشعار ضمن مدة الإشعار التعاقدية البالغة {{notice_period_days}} يوماً تقويمياً من تاريخ تحديد الحدث.

نطلب تأكيد استلام هذا الإشعار في غضون 5 أيام عمل.

مع خالص التحية،
مجموعة أدنوك — إدارة الشؤون القانونية$$,
 jsonb_build_object(
   'notice_date',        jsonb_build_object('type','string','description','ISO date of notice issuance','required',true),
   'contract_id',        jsonb_build_object('type','string','description','Contract reference number','required',true),
   'addressee',          jsonb_build_object('type','string','description','Recipient name or designation','required',true),
   'counterparty_name',  jsonb_build_object('type','string','description','Counterparty legal entity name','required',true),
   'fm_clause_text',     jsonb_build_object('type','string','description','Force majeure clause section reference','required',true),
   'notice_period_days', jsonb_build_object('type','number','description','Contractual notice period in calendar days','required',true),
   'signal_date',        jsonb_build_object('type','string','description','Date force majeure event was identified','required',true),
   'signal_summary',     jsonb_build_object('type','string','description','Brief summary of the Hormuz navigability signal','required',true,'maxLength',500)
 ),
 'legal_counsel', '["email","teams_capture","slack_capture"]'::jsonb, 1, 'sensitive',
 NOW(), NOW(), NULL, NULL, NULL, TRUE),

-- 2. Sanctions Hold Notice
(v_adnoc_tenant, 'sanctions_hold_v1',
 'Sanctions Hold Notice',
 'إشعار وقف العقوبات',
 'Formal sanctions hold notice issued when a counterparty or vessel is placed on OFAC / EU / UN designation list. Suspends performance pending legal review.',
 'sanctions_hold',
 $$SANCTIONS HOLD NOTICE — CONTRACT PERFORMANCE SUSPENSION

Date: {{notice_date}}
Contract Reference: {{contract_id}}
Addressee: {{addressee}}

Dear {{addressee}},

ADNOC Group has been notified that {{counterparty_name}} (or an affiliated entity) has been designated on the {{sanctioning_authority}} sanctions list effective {{designation_date}}.

As a result of the foregoing designation, and in compliance with ADNOC Group's obligations under applicable sanctions law and its internal compliance policy, performance under Contract No. {{contract_id}} is hereby suspended with immediate effect.

The basis for this hold is as follows: {{hold_basis}}.

No payments, deliveries, or other performance obligations shall be executed under the Contract pending completion of ADNOC Group's legal review.

This notice is confidential and intended solely for the named addressee.

Yours faithfully,
ADNOC Group — Compliance & Legal Affairs$$,
 $$إشعار وقف تنفيذ العقد بسبب العقوبات

التاريخ: {{notice_date}}
مرجع العقد: {{contract_id}}
المرسل إليه: {{addressee}}

عزيزي {{addressee}}،

أُبلغت مجموعة أدنوك بأن {{counterparty_name}} (أو كياناً تابعاً لها) قد أُدرج في قائمة عقوبات {{sanctioning_authority}} اعتباراً من {{designation_date}}.

نتيجةً للإدراج المذكور أعلاه، وانسجاماً مع التزامات مجموعة أدنوك بموجب قانون العقوبات المعمول به وسياستها الداخلية للامتثال، يُوقَّف تنفيذ العقد رقم {{contract_id}} بأثر فوري.

أساس هذا الإيقاف هو: {{hold_basis}}.

لا يجوز تنفيذ أي مدفوعات أو تسليمات أو أي التزامات أداء أخرى بموجب العقد ريثما يُستكمل المراجعة القانونية لمجموعة أدنوك.

هذا الإشعار سري ومخصص للمرسل إليه المحدد فحسب.

مع خالص التحية،
مجموعة أدنوك — الامتثال والشؤون القانونية$$,
 jsonb_build_object(
   'notice_date',          jsonb_build_object('type','string','description','ISO date of notice','required',true),
   'contract_id',          jsonb_build_object('type','string','description','Contract reference number','required',true),
   'addressee',            jsonb_build_object('type','string','description','Recipient name','required',true),
   'counterparty_name',    jsonb_build_object('type','string','description','Designated entity legal name','required',true),
   'sanctioning_authority',jsonb_build_object('type','string','description','Sanctioning body (e.g. OFAC, EU, UN)','required',true),
   'designation_date',     jsonb_build_object('type','string','description','Effective date of sanctions designation','required',true),
   'hold_basis',           jsonb_build_object('type','string','description','Specific rule or clause basis for hold','required',true,'maxLength',1000)
 ),
 'legal_counsel', '["email","teams_capture","slack_capture"]'::jsonb, 1, 'sensitive',
 NOW(), NOW(), NULL, NULL, NULL, TRUE),

-- 3. Cure Notice
(v_adnoc_tenant, 'cure_notice_v1',
 'Cure Notice',
 'إشعار الإصلاح',
 'Formal cure notice served on counterparty for identified contract breach, specifying cure period and required remediation actions.',
 'cure_notice',
 $$NOTICE TO CURE

Date: {{notice_date}}
Contract Reference: {{contract_id}}
Addressee: {{addressee}}

Dear {{addressee}},

Pursuant to the cure provisions of Contract No. {{contract_id}}, ADNOC Group hereby notifies {{counterparty_name}} of the following material breach and demands cure within the contractual cure period.

BREACH DESCRIPTION

{{breach_description}}

CURE REQUIREMENTS

You are required to fully remedy the above-described breach and provide written confirmation of remediation to ADNOC Group no later than {{cure_period_end_date}}, being {{cure_period_days}} calendar days from the date of this notice.

All cure communications and documentation should be addressed to:
{{cure_address}}

Failure to cure the identified breach within the specified period will entitle ADNOC Group to exercise all available remedies under the Contract.

Yours faithfully,
ADNOC Group — Contract Management & Legal Affairs$$,
 $$إشعار الإصلاح

التاريخ: {{notice_date}}
مرجع العقد: {{contract_id}}
المرسل إليه: {{addressee}}

عزيزي {{addressee}}،

وفقاً لأحكام الإصلاح الواردة في العقد رقم {{contract_id}}، تُبلغ مجموعة أدنوك بموجب هذا {{counterparty_name}} بالمخالفة الجوهرية التالية وتطالبها بالإصلاح خلال مدة الإصلاح التعاقدية.

وصف المخالفة

{{breach_description}}

متطلبات الإصلاح

يُطلب منكم معالجة المخالفة الموصوفة أعلاه بشكل كامل وتقديم تأكيد خطي للمعالجة إلى مجموعة أدنوك في موعد لا يتجاوز {{cure_period_end_date}}، وهو {{cure_period_days}} يوماً تقويمياً من تاريخ هذا الإشعار.

يجب توجيه جميع مراسلات الإصلاح والوثائق إلى:
{{cure_address}}

يُخوِّل عدم معالجة المخالفة المحددة خلال الفترة المحددة مجموعة أدنوك ممارسة جميع سبل الإنصاف المتاحة بموجب العقد.

مع خالص التحية،
مجموعة أدنوك — إدارة العقود والشؤون القانونية$$,
 jsonb_build_object(
   'notice_date',         jsonb_build_object('type','string','description','ISO date of notice','required',true),
   'contract_id',         jsonb_build_object('type','string','description','Contract reference number','required',true),
   'addressee',           jsonb_build_object('type','string','description','Recipient name','required',true),
   'counterparty_name',   jsonb_build_object('type','string','description','Counterparty legal entity name','required',true),
   'breach_description',  jsonb_build_object('type','string','description','Description of breach','required',true,'maxLength',2000),
   'cure_period_days',    jsonb_build_object('type','number','description','Contractual cure period in calendar days','required',true),
   'cure_period_end_date',jsonb_build_object('type','string','description','ISO date: NOW + cure_period_days','required',true),
   'cure_address',        jsonb_build_object('type','string','description','Counterparty cure notice address','required',true,'maxLength',500)
 ),
 'legal_counsel', '["email","teams_capture","slack_capture"]'::jsonb, 1, 'sensitive',
 NOW(), NOW(), NULL, NULL, NULL, TRUE)

ON CONFLICT (tenant_id, template_id) DO NOTHING;

END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (211, '211_crh_seed_advisory_templates', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM advisory_template
-- WHERE template_id IN ('hormuz_fm_invocation_v1','sanctions_hold_v1','cure_notice_v1')
--   AND tenant_id = '00000000-0000-0000-0000-000000000001';
-- DELETE FROM schema_migrations WHERE version = 211;
-- ============================================================
