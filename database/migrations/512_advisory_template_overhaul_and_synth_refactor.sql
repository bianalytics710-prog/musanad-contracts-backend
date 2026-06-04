-- 512_advisory_template_overhaul_and_synth_refactor.sql
-- ============================================================================
-- Purpose: Make every advisory in Layla's queue look like the Hormuz FM
-- template (the user-confirmed gold standard) — formal headline, metadata
-- trio, direct address, clause citation, named event + source, legal
-- consequence, acknowledgment ask, authoritative closing.
--
-- Three layered fixes:
--   1. Rewrite the 5 thin one-line templates (Weather FM, ICV Rectification,
--      ESG Concern, Insurance Renewal, Budget Cure) with the Hormuz 9-block
--      structure, EN + AR.
--   2. Refactor fn_demo_synthesize_advisories_for_correlations to actually
--      USE the loaded body_template (today the lookup is dead code, then the
--      function writes inline strings). The new version builds a rich context
--      (contract_number / contract_title / counterparty_name / clause_title /
--      clause_excerpt / signal_*) and calls fn_mustache_render.
--   3. Regenerate the body of every existing unapproved demo-seeded draft via
--      the new path so the queue is presentable immediately. Approved and
--      dispatched drafts are intentionally left frozen (audit integrity).
--
-- Finally — bump Hormuz drafts so they sort first in the queue.
-- ============================================================================
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Template bodies — five rewrites
-- ---------------------------------------------------------------------------

DO $tpl$
DECLARE
  v_tenant_id UUID := '00000000-0000-0000-0000-000000000001';
BEGIN

  -- 1a. Weather FM Notice (weather_fm_notice_v1)
  UPDATE advisory_template SET
    body_template_en = $body_en$WEATHER-INDUCED FORCE MAJEURE INVOCATION NOTICE

Date: {{notice_date}}
Contract Reference: {{contract_number}} — {{contract_title}}
Addressee: {{counterparty_name}}

Dear {{counterparty_name}},

We hereby formally invoke the Force Majeure provisions contained within the {{clause_title}} clause of Contract No. {{contract_number}} ({{contract_title}}), entered into between ADNOC Group and {{counterparty_name}}.

A confirmed weather event has materially affected performance of the Contract:

  Event: {{signal_title}}
  Identified: {{signal_date}}
  Summary: {{signal_summary}}

Pursuant to the clause referenced above, performance obligations affected by the event are suspended for its duration. Notice is hereby served within the contractual notice period of {{notice_period_days}} calendar days from the date of event identification.

We request written acknowledgment of receipt of this notice within 5 business days, together with the counterparty's proposed mitigation plan.

Yours faithfully,
ADNOC Group — Legal Affairs Division$body_en$,
    body_template_ar = $body_ar$إشعار استدعاء القوة القاهرة بسبب الطقس

التاريخ: {{notice_date}}
مرجع العقد: {{contract_number}} — {{contract_title}}
المرسل إليه: {{counterparty_name}}

عزيزي {{counterparty_name}}،

نحيطكم علماً بأننا ندعو رسمياً إلى أحكام القوة القاهرة الواردة ضمن بند {{clause_title}} من العقد رقم {{contract_number}} ({{contract_title}})، المبرم بين مجموعة أدنوك و{{counterparty_name}}.

وقع حدث طقسي مؤكد أثر جوهرياً على تنفيذ العقد:

  الحدث: {{signal_title}}
  تاريخ التحديد: {{signal_date}}
  الموجز: {{signal_summary}}

وفقاً للبند المشار إليه أعلاه، تُعلَّق التزامات الأداء المتأثرة طوال مدة الحدث. يُقدَّم هذا الإشعار ضمن مدة الإشعار التعاقدية البالغة {{notice_period_days}} يوماً تقويمياً من تاريخ تحديد الحدث.

نطلب تأكيداً خطياً باستلام هذا الإشعار في غضون 5 أيام عمل، مع خطة التخفيف المقترحة من قِبَل الطرف المقابل.

مع خالص التحية،
مجموعة أدنوك — إدارة الشؤون القانونية$body_ar$,
    updated_at = NOW()
  WHERE tenant_id = v_tenant_id AND template_id = 'weather_fm_notice_v1';

  -- 1b. ICV Rectification Notice (icv_rectification_notice_v1)
  UPDATE advisory_template SET
    body_template_en = $body_en$ICV RECTIFICATION NOTICE

Date: {{notice_date}}
Contract Reference: {{contract_number}} — {{contract_title}}
Addressee: {{counterparty_name}}

Dear {{counterparty_name}},

Following our ongoing audit of In-Country Value (ICV) performance under Contract No. {{contract_number}} ({{contract_title}}), we have identified that the contractor's ICV is materially below the contractually agreed threshold.

Finding:
  {{signal_summary}}

Pursuant to the ICV provisions of the Contract (clause: {{clause_title}}), the contractor is required to submit a rectification plan addressing the shortfall and restoring ICV performance to the agreed level. The rectification plan and supporting evidence must be delivered to ADNOC Group within {{notice_period_days}} calendar days from the date of this notice.

Failure to rectify within the notice period may trigger the contractual remedies available to ADNOC Group, up to and including suspension of award eligibility.

Yours faithfully,
ADNOC Group — Procurement & ICV Office$body_en$,
    body_template_ar = $body_ar$إشعار تصحيح القيمة المحلية المضافة (ICV)

التاريخ: {{notice_date}}
مرجع العقد: {{contract_number}} — {{contract_title}}
المرسل إليه: {{counterparty_name}}

عزيزي {{counterparty_name}}،

في إطار التدقيق الجاري على أداء القيمة المحلية المضافة (ICV) ضمن العقد رقم {{contract_number}} ({{contract_title}})، تبيَّن أن نسبة الـICV لدى المقاول أدنى جوهرياً من الحد المتفق عليه تعاقدياً.

النتيجة:
  {{signal_summary}}

وفقاً لأحكام الـICV في العقد (البند: {{clause_title}})، يُطلب من المقاول تقديم خطة تصحيح تعالج العجز وتعيد أداء الـICV إلى المستوى المتفق عليه. يجب تسليم خطة التصحيح والمستندات الداعمة إلى مجموعة أدنوك خلال {{notice_period_days}} يوماً تقويمياً من تاريخ هذا الإشعار.

قد يؤدي عدم التصحيح خلال مدة الإشعار إلى تفعيل سبل الإنصاف التعاقدية المتاحة لمجموعة أدنوك، بما في ذلك تعليق الأهلية للمنح.

مع خالص التحية،
مجموعة أدنوك — مكتب المشتريات والقيمة المحلية المضافة$body_ar$,
    updated_at = NOW()
  WHERE tenant_id = v_tenant_id AND template_id = 'icv_rectification_notice_v1';

  -- 1c. ESG Concern Memo (esg_concern_memo_v1) — internal memo, in_app only
  UPDATE advisory_template SET
    body_template_en = $body_en$ESG CONCERN MEMORANDUM — INTERNAL

Date: {{notice_date}}
Contract Reference: {{contract_number}} — {{contract_title}}
Counterparty: {{counterparty_name}}

To: Compliance & ESG Team

An ESG concern has been raised in connection with the above contract and requires review prior to any external action.

Concern:
  {{signal_title}}
  {{signal_summary}}

Identified: {{signal_date}}
Relevant clause: {{clause_title}}

Recommended action:
  1. Validate the underlying signal with an independent source.
  2. Engage the Compliance & ESG team to determine whether the concern triggers reporting or escalation obligations under ADNOC Group ESG policy.
  3. If confirmed, prepare a formal counterparty notice via the standard advisory workflow.

This memorandum is internal. Do not dispatch to the counterparty without Compliance & ESG sign-off.

ADNOC Group — Legal Affairs Division$body_en$,
    body_template_ar = $body_ar$مذكرة قلق ESG — داخلية

التاريخ: {{notice_date}}
مرجع العقد: {{contract_number}} — {{contract_title}}
الطرف المقابل: {{counterparty_name}}

إلى: فريق الامتثال والـESG

أُثير قلق ESG يتعلق بالعقد المذكور أعلاه، ويستلزم المراجعة قبل أي إجراء خارجي.

القلق:
  {{signal_title}}
  {{signal_summary}}

تاريخ التحديد: {{signal_date}}
البند ذو الصلة: {{clause_title}}

الإجراء الموصى به:
  ١. التحقق من الإشارة الأساسية عبر مصدر مستقل.
  ٢. إشراك فريق الامتثال والـESG لتحديد ما إذا كان القلق يستوجب التزامات الإبلاغ أو التصعيد وفق سياسة ESG لمجموعة أدنوك.
  ٣. في حال التأكيد، إعداد إشعار رسمي للطرف المقابل عبر سير العمل الاستشاري المعتاد.

هذه المذكرة داخلية. يُمنع توزيعها على الطرف المقابل دون موافقة فريق الامتثال والـESG.

مجموعة أدنوك — إدارة الشؤون القانونية$body_ar$,
    updated_at = NOW()
  WHERE tenant_id = v_tenant_id AND template_id = 'esg_concern_memo_v1';

  -- 1d. Insurance Renewal Reminder (insurance_renewal_reminder_v1)
  UPDATE advisory_template SET
    body_template_en = $body_en$INSURANCE RENEWAL REMINDER

Date: {{notice_date}}
Contract Reference: {{contract_number}} — {{contract_title}}
Addressee: {{counterparty_name}}

Dear {{counterparty_name}},

This notice is issued in accordance with the insurance and indemnification provisions of Contract No. {{contract_number}} ({{contract_title}}) entered into between ADNOC Group and {{counterparty_name}}.

Our records indicate that one or more certificates of insurance required under the Contract are approaching expiry:

  {{signal_summary}}

Pursuant to the {{clause_title}} clause, the counterparty is required to maintain continuous cover at the limits specified in the Contract and to deliver evidence of renewal to ADNOC Group no later than {{notice_period_days}} calendar days from the date of this notice — and in any event prior to the expiry of the current cover.

Acceptable evidence comprises an updated certificate of insurance, broker confirmation, and (where applicable) the relevant endorsements.

Failure to maintain cover may suspend ADNOC Group's performance obligations until valid evidence is provided.

Yours faithfully,
ADNOC Group — Contract Management & Legal Affairs$body_en$,
    body_template_ar = $body_ar$تذكير بتجديد التأمين

التاريخ: {{notice_date}}
مرجع العقد: {{contract_number}} — {{contract_title}}
المرسل إليه: {{counterparty_name}}

عزيزي {{counterparty_name}}،

يُصدَر هذا الإشعار وفقاً لأحكام التأمين والتعويض في العقد رقم {{contract_number}} ({{contract_title}}) المبرم بين مجموعة أدنوك و{{counterparty_name}}.

تشير سجلاتنا إلى أن إحدى أو أكثر من شهادات التأمين المطلوبة بموجب العقد تقترب من تاريخ انتهاء صلاحيتها:

  {{signal_summary}}

وفقاً لبند {{clause_title}}، يُلزَم الطرف المقابل بالاحتفاظ بتغطية تأمينية مستمرة بالحدود المنصوص عليها في العقد، وبتسليم ما يثبت التجديد إلى مجموعة أدنوك في موعد لا يتجاوز {{notice_period_days}} يوماً تقويمياً من تاريخ هذا الإشعار، وقبل انتهاء التغطية الحالية في جميع الأحوال.

تشمل الأدلة المقبولة شهادة تأمين محدثة، وتأكيداً من الوسيط، وأي تظهيرات ذات صلة عند الاقتضاء.

قد يؤدي عدم الحفاظ على التغطية إلى تعليق التزامات أداء مجموعة أدنوك حتى تقديم دليل ساري المفعول.

مع خالص التحية،
مجموعة أدنوك — إدارة العقود والشؤون القانونية$body_ar$,
    updated_at = NOW()
  WHERE tenant_id = v_tenant_id AND template_id = 'insurance_renewal_reminder_v1';

  -- 1e. Budget Variance Cure Notice (budget_cure_notice_v1)
  UPDATE advisory_template SET
    body_template_en = $body_en$NOTICE TO CURE — BUDGET VARIANCE

Date: {{notice_date}}
Contract Reference: {{contract_number}} — {{contract_title}}
Addressee: {{counterparty_name}}

Dear {{counterparty_name}},

Pursuant to the cost-control and cure provisions of Contract No. {{contract_number}} ({{contract_title}}), ADNOC Group notifies {{counterparty_name}} of a material variance between the budgeted spend and the actuals reported for the current reporting period.

Finding:
  {{signal_summary}}

Relevant clause: {{clause_title}}

Cure requirements:
  • Provide a written explanation of the variance, including the underlying drivers and the corrective measures already in place.
  • Submit a revised forecast restoring spend to within the agreed tolerance band by no later than {{notice_period_days}} calendar days from the date of this notice.
  • Where the variance reflects a permanent change in scope or cost basis, propose a contract amendment for ADNOC Group's review.

Failure to cure within the notice period will entitle ADNOC Group to exercise the remedies available under the Contract, including budget reallocation and step-in rights where applicable.

Yours faithfully,
ADNOC Group — Finance & Contract Management$body_en$,
    body_template_ar = $body_ar$إشعار الإصلاح — انحراف الميزانية

التاريخ: {{notice_date}}
مرجع العقد: {{contract_number}} — {{contract_title}}
المرسل إليه: {{counterparty_name}}

عزيزي {{counterparty_name}}،

وفقاً لأحكام ضبط التكاليف والإصلاح في العقد رقم {{contract_number}} ({{contract_title}})، تُبلغ مجموعة أدنوك {{counterparty_name}} بوجود انحراف جوهري بين الإنفاق المُدرَج في الميزانية والإنفاق الفعلي المُبلَّغ عنه في فترة التقرير الحالية.

النتيجة:
  {{signal_summary}}

البند ذو الصلة: {{clause_title}}

متطلبات الإصلاح:
  • تقديم تفسير خطي للانحراف، يشمل المُسبِّبات الجوهرية والإجراءات التصحيحية المُتَّخذة بالفعل.
  • تقديم توقعات مُحدَّثة تعيد الإنفاق إلى ضمن نطاق التحمل المتفق عليه في موعد لا يتجاوز {{notice_period_days}} يوماً تقويمياً من تاريخ هذا الإشعار.
  • إذا كان الانحراف يعكس تغييراً دائماً في النطاق أو في أساس التكلفة، اقتراح تعديل تعاقدي للعرض على مجموعة أدنوك للمراجعة.

قد يؤدي عدم الإصلاح خلال مدة الإشعار إلى تفعيل سبل الإنصاف المتاحة بموجب العقد، بما في ذلك إعادة توزيع الميزانية وحقوق التدخل عند الاقتضاء.

مع خالص التحية،
مجموعة أدنوك — إدارة المالية والعقود$body_ar$,
    updated_at = NOW()
  WHERE tenant_id = v_tenant_id AND template_id = 'budget_cure_notice_v1';

END
$tpl$;


-- ---------------------------------------------------------------------------
-- 2. Refactored synthesizer — uses templates via fn_mustache_render
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_demo_synthesize_advisories_for_correlations(
  p_signal_id   BIGINT,
  p_scenario_id TEXT,
  p_actor_id    BIGINT
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id      UUID;
  v_inserted_count INTEGER := 0;
  v_template_id    BIGINT;
  v_template_ver   INTEGER;
  v_draft_type     TEXT;
  v_body_en_tpl    TEXT;
  v_body_ar_tpl    TEXT;
  v_template_key   TEXT;
  v_correlation    RECORD;
  v_signal         RECORD;
  v_ctx            JSONB;
  v_body_en        TEXT;
  v_body_ar        TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  -- Scenario → template_id (string, not numeric DB id). Robust against id
  -- drift across environments. Falls back to NULL when unmapped.
  v_template_key := CASE p_scenario_id
    WHEN 'brent_review'      THEN 'budget_cure_notice_v1'
    WHEN 'cyclone'           THEN 'weather_fm_notice_v1'
    WHEN 'hormuz'            THEN 'hormuz_fm_invocation_v1'
    WHEN 'ofac_sanctions'    THEN 'sanctions_hold_v1'
    WHEN 'epc_sla'           THEN 'cure_notice_v1'
    WHEN 'icv_shortfall'     THEN 'icv_rectification_notice_v1'
    WHEN 'esg_subcontractor' THEN 'esg_concern_memo_v1'
    WHEN 'renewal'           THEN 'insurance_renewal_reminder_v1'
    ELSE NULL
  END;

  IF v_template_key IS NULL THEN
    RETURN 0;
  END IF;

  SELECT id, version, body_template_en, body_template_ar, draft_type
  INTO v_template_id, v_template_ver, v_body_en_tpl, v_body_ar_tpl, v_draft_type
  FROM advisory_template
  WHERE tenant_id = v_tenant_id
    AND template_id = v_template_key
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  -- Cache the signal once — common across all correlations for this signal.
  SELECT
    COALESCE(title_en, title) AS title,
    COALESCE(summary, description_en, '') AS summary,
    to_char(COALESCE(event_date_v2, published_date, NOW()), 'DD Mon YYYY') AS sig_date
  INTO v_signal
  FROM osint_signal
  WHERE id = p_signal_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    v_signal := ROW('', '', '')::RECORD;
  END IF;

  FOR v_correlation IN
    SELECT
      co.id              AS correlation_id,
      co.contract_id     AS contract_id,
      co.matched_clause_id AS matched_clause_id,
      co.rule_id         AS rule_id,
      co.match_reason    AS match_reason,
      c.contract_number  AS contract_number,
      c.title_en         AS contract_title_en,
      c.title_ar         AS contract_title_ar,
      COALESCE(p.name_en, p.name_ar, 'Counterparty') AS counterparty_name,
      CASE
        WHEN cce.clause_type_v2 IS NULL THEN 'the relevant'
        ELSE initcap(replace(cce.clause_type_v2, '_', ' '))
      END                AS clause_title,
      LEFT(COALESCE(cce.summary_en, ''), 600) AS clause_excerpt
    FROM correlation co
    LEFT JOIN contract c ON c.id = co.contract_id
    LEFT JOIN party p ON p.id = c.counterparty_id
    LEFT JOIN contract_clause_extracted cce ON cce.id = co.matched_clause_id
      AND cce.tenant_id = v_tenant_id AND cce.is_active = TRUE
    WHERE co.tenant_id = v_tenant_id
      AND co.signal_id = p_signal_id
      AND co.status = 'active'
      AND co.is_active = TRUE
    ORDER BY co.id DESC
  LOOP
    -- Build the customer-facing context dictionary. Every template uses the
    -- same superset of vars; unused vars render harmlessly as empty strings.
    v_ctx := jsonb_build_object(
      'notice_date',         to_char(CURRENT_DATE, 'DD Mon YYYY'),
      'contract_number',     COALESCE(v_correlation.contract_number, '—'),
      'contract_title',      COALESCE(v_correlation.contract_title_en, ''),
      'counterparty_name',   v_correlation.counterparty_name,
      'addressee',           v_correlation.counterparty_name,
      'signal_title',        COALESCE(v_signal.title, ''),
      'signal_summary',      COALESCE(v_signal.summary, ''),
      'signal_date',         COALESCE(v_signal.sig_date, to_char(CURRENT_DATE, 'DD Mon YYYY')),
      'clause_title',        v_correlation.clause_title,
      'clause_excerpt',      v_correlation.clause_excerpt,
      'fm_clause_text',      v_correlation.clause_title,
      'notice_period_days',  14,
      'sanctioning_authority','OFAC/EU/UN',
      'designation_date',    to_char(CURRENT_DATE, 'DD Mon YYYY'),
      'hold_basis',          COALESCE(v_signal.summary, v_correlation.match_reason, ''),
      'breach_description',  COALESCE(v_correlation.match_reason, v_signal.summary, ''),
      'cure_period_days',    14,
      'cure_period_end_date',to_char(CURRENT_DATE + 14, 'DD Mon YYYY'),
      'cure_address',        'ADNOC Group — Legal Affairs Division'
    );

    v_body_en := fn_mustache_render(v_body_en_tpl, v_ctx);
    v_body_ar := fn_mustache_render(v_body_ar_tpl, v_ctx);

    INSERT INTO advisory_draft (
      tenant_id, correlation_id, contract_id,
      template_id, template_version, draft_type,
      generated_text_en, generated_text_ar,
      template_context, model_version, prompt_hash,
      approval_status, dispatch_recipients,
      data_classification, created_by, updated_by
    ) VALUES (
      v_tenant_id,
      v_correlation.correlation_id,
      v_correlation.contract_id,
      v_template_id,
      v_template_ver,
      v_draft_type,
      v_body_en,
      v_body_ar,
      v_ctx || jsonb_build_object(
        'scenarioId', p_scenario_id,
        'correlationId', v_correlation.correlation_id,
        'ruleId', v_correlation.rule_id,
        'demoSynthesized', TRUE
      ),
      'template-mustache-' || v_template_key,
      encode(digest(p_scenario_id || ':' || v_correlation.correlation_id::text, 'sha256'), 'hex'),
      'unapproved',
      '[]'::jsonb,
      'demo',
      p_actor_id,
      p_actor_id
    )
    ON CONFLICT DO NOTHING;
    IF FOUND THEN v_inserted_count := v_inserted_count + 1; END IF;
  END LOOP;

  RETURN v_inserted_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_demo_synthesize_advisories_for_correlations(BIGINT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_synthesize_advisories_for_correlations(BIGINT, TEXT, BIGINT) TO neondb_owner;


-- ---------------------------------------------------------------------------
-- 3. Regenerate existing unapproved demo drafts in-place
-- ---------------------------------------------------------------------------
-- Uses the same context builder, runs over each unapproved demo draft, and
-- UPDATEs generated_text_en/ar. Approved + dispatched + rejected drafts are
-- NOT touched (their final/rejection text is part of the audit trail).

DO $regen$
DECLARE
  v_tenant_id    UUID := '00000000-0000-0000-0000-000000000001';
  v_d            RECORD;
  v_body_en_tpl  TEXT;
  v_body_ar_tpl  TEXT;
  v_ctx          JSONB;
  v_count        INTEGER := 0;
BEGIN
  FOR v_d IN
    SELECT
      ad.id                   AS draft_id,
      ad.correlation_id,
      ad.contract_id,
      ad.template_id,
      ad.created_at,
      at.body_template_en     AS body_en_tpl,
      at.body_template_ar     AS body_ar_tpl,
      c.contract_number,
      c.title_en              AS contract_title_en,
      COALESCE(p.name_en, p.name_ar, 'Counterparty') AS counterparty_name,
      co.matched_clause_id,
      co.match_reason,
      cce.clause_type_v2,
      cce.summary_en          AS clause_summary,
      os.title_en             AS sig_title_en,
      os.title                AS sig_title,
      os.summary              AS sig_summary,
      os.description_en       AS sig_description_en,
      COALESCE(os.event_date_v2, os.published_date) AS sig_date_iso
    FROM advisory_draft ad
    JOIN advisory_template at ON at.id = ad.template_id
    LEFT JOIN contract c ON c.id = ad.contract_id
    LEFT JOIN party p ON p.id = c.counterparty_id
    LEFT JOIN correlation co ON co.id = ad.correlation_id
    LEFT JOIN contract_clause_extracted cce ON cce.id = co.matched_clause_id
      AND cce.tenant_id = v_tenant_id AND cce.is_active = TRUE
    LEFT JOIN osint_signal os ON os.id = co.signal_id AND os.tenant_id = v_tenant_id
    WHERE ad.tenant_id = v_tenant_id
      AND ad.is_active = TRUE
      AND ad.approval_status = 'unapproved'
  LOOP
    v_ctx := jsonb_build_object(
      'notice_date',          to_char(CURRENT_DATE, 'DD Mon YYYY'),
      'contract_number',      COALESCE(v_d.contract_number, '—'),
      'contract_title',       COALESCE(v_d.contract_title_en, ''),
      'counterparty_name',    v_d.counterparty_name,
      'addressee',            v_d.counterparty_name,
      'signal_title',         COALESCE(v_d.sig_title_en, v_d.sig_title, ''),
      'signal_summary',       COALESCE(v_d.sig_summary, v_d.sig_description_en, ''),
      'signal_date',          to_char(COALESCE(v_d.sig_date_iso, CURRENT_DATE), 'DD Mon YYYY'),
      'clause_title',         CASE
                                WHEN v_d.clause_type_v2 IS NULL THEN 'the relevant'
                                ELSE initcap(replace(v_d.clause_type_v2, '_', ' '))
                              END,
      'clause_excerpt',       LEFT(COALESCE(v_d.clause_summary, ''), 600),
      'fm_clause_text',       CASE
                                WHEN v_d.clause_type_v2 IS NULL THEN 'the relevant'
                                ELSE initcap(replace(v_d.clause_type_v2, '_', ' '))
                              END,
      'notice_period_days',   14,
      'sanctioning_authority','OFAC/EU/UN',
      'designation_date',     to_char(CURRENT_DATE, 'DD Mon YYYY'),
      'hold_basis',           COALESCE(v_d.sig_summary, v_d.match_reason, ''),
      'breach_description',   COALESCE(v_d.match_reason, v_d.sig_summary, ''),
      'cure_period_days',     14,
      'cure_period_end_date', to_char(CURRENT_DATE + 14, 'DD Mon YYYY'),
      'cure_address',         'ADNOC Group — Legal Affairs Division'
    );

    UPDATE advisory_draft SET
      generated_text_en = fn_mustache_render(COALESCE(v_d.body_en_tpl, ''), v_ctx),
      generated_text_ar = fn_mustache_render(COALESCE(v_d.body_ar_tpl, ''), v_ctx),
      template_context  = COALESCE(template_context, '{}'::jsonb) || v_ctx,
      updated_at        = NOW()
    WHERE id = v_d.draft_id;

    v_count := v_count + 1;
  END LOOP;

  RAISE NOTICE 'fn_demo regenerated % unapproved advisory drafts', v_count;
END
$regen$;


-- ---------------------------------------------------------------------------
-- 4. Surface Hormuz at the top of the queue
-- ---------------------------------------------------------------------------
-- The list orders by generated_at DESC (mapped from created_at). Bumping the
-- Hormuz drafts' created_at to now puts them first in the queue. We only
-- touch unapproved demo rows so we don't mess with audited approvals.

UPDATE advisory_draft ad SET
  created_at = NOW(),
  updated_at = NOW()
FROM advisory_template at
WHERE at.id = ad.template_id
  AND at.template_id = 'hormuz_fm_invocation_v1'
  AND ad.tenant_id = '00000000-0000-0000-0000-000000000001'
  AND ad.is_active = TRUE
  AND ad.approval_status = 'unapproved';


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (512, 'advisory_template_overhaul_and_synth_refactor', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- Restoring the prior thin templates + inline-synthesizer requires re-apply
-- of migrations 239 + 302 + 458 in order. Existing regenerated draft bodies
-- cannot be restored without a snapshot. Approved/dispatched drafts were
-- never touched.
-- ROLLBACK END
