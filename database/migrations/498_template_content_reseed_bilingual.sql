-- Migration: 498_template_content_reseed_bilingual.sql
-- Module: Contract templates — full bilingual content + {{token}} placeholders
-- Date: 2026-06-02
--
-- Replaces the existing 8 seeded contract_template rows with:
--   * full bilingual bodies (EN + AR) where language='bilingual'
--   * Mustache-style {{token}} placeholders inline
--   * placeholder catalog (key/labelEn/labelAr/kind/required)
--   * headline regulatory_reference where applicable
--
-- Only updates the 8 seed rows (id 9..16). Does not touch user-created
-- templates (which start at id >= 17 by convention).

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- #9 — MoHRE Fixed-Term Employment Contract (bilingual, 20 placeholders)
-- ────────────────────────────────────────────────────────────────────────────

UPDATE contract_template SET
  name_en              = 'MoHRE Fixed-Term Employment Contract',
  name_ar              = 'عقد عمل محدد المدة (وزارة الموارد البشرية والتوطين)',
  contract_type        = 'employment',
  language             = 'bilingual',
  description_en       = 'Standard UAE private-sector fixed-term contract (up to 3 years). Compliant with Federal Decree-Law 33/2021 and MoHRE 2022 executive regulations.',
  description_ar       = 'عقد عمل قياسي للقطاع الخاص في الإمارات لمدة محددة (حتى 3 سنوات)، متوافق مع المرسوم بقانون اتحادي 33/2021 ولوائحه التنفيذية لعام 2022.',
  regulatory_reference = 'Federal Decree-Law 33/2021',
  regulatory_tags      = ARRAY['MoHRE', 'Federal Decree-Law 33/2021', 'Wages Protection System'],
  placeholders         = $JSON$[
    {"key":"effective_date",        "labelEn":"Effective Date",        "labelAr":"تاريخ السريان",        "kind":"date",     "required":true},
    {"key":"employer_name",         "labelEn":"Employer Name",         "labelAr":"اسم صاحب العمل",       "kind":"party",    "required":true},
    {"key":"emirate",               "labelEn":"Emirate",               "labelAr":"الإمارة",              "kind":"text",     "required":true},
    {"key":"trade_license_number",  "labelEn":"Trade Licence Number",  "labelAr":"رقم الرخصة التجارية",   "kind":"text",     "required":true},
    {"key":"employee_name",         "labelEn":"Employee Name",         "labelAr":"اسم العامل",            "kind":"party",    "required":true},
    {"key":"emirates_id",           "labelEn":"Emirates ID Number",    "labelAr":"رقم الهوية الإماراتية", "kind":"text",     "required":true},
    {"key":"nationality",           "labelEn":"Nationality",           "labelAr":"الجنسية",              "kind":"text",     "required":true},
    {"key":"job_title",             "labelEn":"Job Title",             "labelAr":"المسمى الوظيفي",        "kind":"text",     "required":true},
    {"key":"work_location",         "labelEn":"Work Location",         "labelAr":"مكان العمل",            "kind":"text",     "required":true},
    {"key":"start_date",            "labelEn":"Start Date",            "labelAr":"تاريخ بدء العمل",       "kind":"date",     "required":true},
    {"key":"end_date",              "labelEn":"End Date",              "labelAr":"تاريخ انتهاء العقد",    "kind":"date",     "required":true},
    {"key":"probation_days",        "labelEn":"Probation Period (days)","labelAr":"فترة التجربة (أيام)",  "kind":"number",   "required":true},
    {"key":"basic_salary",          "labelEn":"Basic Salary (AED/mo)", "labelAr":"الراتب الأساسي (شهرياً)","kind":"currency","required":true},
    {"key":"allowances",            "labelEn":"Allowances (AED/mo)",   "labelAr":"البدلات (شهرياً)",       "kind":"currency","required":false},
    {"key":"monthly_salary",        "labelEn":"Total Monthly Salary",  "labelAr":"إجمالي الراتب الشهري",  "kind":"currency","required":true},
    {"key":"salary_day",            "labelEn":"Salary Payment Day",    "labelAr":"يوم صرف الراتب",        "kind":"number",   "required":true},
    {"key":"notice_period_days",    "labelEn":"Notice Period (days)",  "labelAr":"فترة الإشعار (أيام)",   "kind":"number",   "required":true},
    {"key":"non_compete_months",    "labelEn":"Non-Compete (months)",  "labelAr":"عدم المنافسة (أشهر)",   "kind":"number",   "required":false},
    {"key":"non_compete_scope",     "labelEn":"Non-Compete Scope",     "labelAr":"نطاق عدم المنافسة",     "kind":"text",     "required":false},
    {"key":"jurisdiction_court",    "labelEn":"Jurisdiction Court",    "labelAr":"المحكمة المختصة",       "kind":"text",     "required":true}
  ]$JSON$::jsonb,
  body_en              = $EN$# MoHRE Limited-Term Employment Contract

This Employment Contract ("Agreement") is entered into on {{effective_date}} between:

**Employer:** {{employer_name}}, a company duly licensed in the {{emirate}}, holding Trade Licence No. {{trade_license_number}} ("Employer"), and

**Employee:** {{employee_name}}, holder of Emirates ID No. {{emirates_id}} of {{nationality}} nationality ("Employee").

## 1. Position and Place of Work
The Employer engages the Employee in the role of **{{job_title}}**. The principal place of work shall be {{work_location}}, {{emirate}}.

## 2. Term
This is a limited-term contract commencing on {{start_date}} and expiring on {{end_date}}, unless renewed by mutual written agreement or terminated earlier in accordance with Federal Decree-Law 33/2021.

## 3. Probation Period
The Employee shall serve a probation period of {{probation_days}} days from the start date. During probation, either party may terminate this Agreement by giving fourteen (14) days' written notice (Employer) or one (1) month's written notice if the Employee resigns to join another UAE employer (Article 9).

## 4. Working Hours
Normal working hours shall not exceed 8 hours per day or 48 hours per week, with weekly rest and public holidays as specified by the Federal Government.

## 5. Compensation
- **Basic Salary:** AED {{basic_salary}} per month
- **Allowances:** AED {{allowances}} per month
- **Total Monthly Salary:** AED {{monthly_salary}}

Salary shall be paid on or before the {{salary_day}}th of each calendar month via the UAE Wages Protection System (WPS).

## 6. Leave Entitlements
The Employee is entitled to (a) thirty (30) calendar days of annual paid leave after one year of service; (b) paid sick leave per Article 31; (c) maternity, paternity, bereavement and study leave per Articles 30-33; and (d) UAE public holidays.

## 7. End-of-Service Gratuity
On completion of one year or more of continuous service, the Employee is entitled to end-of-service gratuity calculated on the basic salary in accordance with Articles 51-52 of Federal Decree-Law 33/2021.

## 8. Confidentiality and Non-Compete
The Employee shall keep confidential all proprietary information of the Employer during and after employment. Where lawful, the Employee shall not, for a period of {{non_compete_months}} months following termination, engage in the following activities in competition with the Employer: {{non_compete_scope}}.

## 9. Termination
Either party may terminate this Agreement by giving {{notice_period_days}} days' written notice. The Employer may terminate without notice in the cases set out in Article 44 of Federal Decree-Law 33/2021.

## 10. Governing Law and Jurisdiction
This Agreement is governed by the laws of the United Arab Emirates, in particular Federal Decree-Law 33/2021 and its executive regulations. Any dispute shall be referred to the {{jurisdiction_court}}.

## 11. Entire Agreement
This Agreement, together with the MoHRE-registered offer letter and any annexes, constitutes the entire agreement between the parties and supersedes all prior understandings.

Signed:

For and on behalf of {{employer_name}}     For and on behalf of {{employee_name}}
__________________________________         __________________________________
$EN$,
  body_ar              = $AR$# عقد عمل محدد المدة (وزارة الموارد البشرية والتوطين)

أُبرم هذا العقد ("الاتفاقية") بتاريخ {{effective_date}} بين:

**صاحب العمل:** {{employer_name}}، شركة مرخّصة في إمارة {{emirate}}، تحمل الرخصة التجارية رقم {{trade_license_number}} ("صاحب العمل"), و

**العامل:** {{employee_name}}، حامل بطاقة الهوية الإماراتية رقم {{emirates_id}}، من جنسية {{nationality}} ("العامل").

## 1. الوظيفة ومكان العمل
يلتحق العامل لدى صاحب العمل بوظيفة **{{job_title}}**. ويكون مكان العمل الرئيسي {{work_location}}، إمارة {{emirate}}.

## 2. مدة العقد
هذا عقد محدد المدة يبدأ في {{start_date}} وينتهي في {{end_date}}، ما لم يتم تجديده باتفاق خطي متبادل أو إنهاؤه قبل ذلك وفقاً للمرسوم بقانون اتحادي رقم 33 لسنة 2021.

## 3. فترة التجربة
يخضع العامل لفترة تجربة مدتها {{probation_days}} يوماً تبدأ من تاريخ مباشرة العمل. ويحق لأي من الطرفين خلال فترة التجربة إنهاء هذا العقد بإشعار خطي مسبق مدته أربعة عشر (14) يوماً (صاحب العمل) أو شهر واحد (1) إذا استقال العامل للالتحاق بصاحب عمل آخر داخل الدولة (المادة 9).

## 4. ساعات العمل
لا يجوز أن تتجاوز ساعات العمل العادية 8 ساعات يومياً أو 48 ساعة أسبوعياً، مع منح العامل يوم راحة أسبوعي وعطلات رسمية وفقاً لما تحدده الحكومة الاتحادية.

## 5. الأجر والبدلات
- **الراتب الأساسي:** {{basic_salary}} درهم شهرياً
- **البدلات:** {{allowances}} درهم شهرياً
- **إجمالي الراتب الشهري:** {{monthly_salary}} درهم

يُصرف الراتب في موعد أقصاه اليوم {{salary_day}} من كل شهر ميلادي عبر نظام حماية الأجور.

## 6. الإجازات
يستحق العامل: (أ) ثلاثين (30) يوماً ميلادياً من الإجازة السنوية مدفوعة الأجر بعد سنة خدمة كاملة؛ (ب) الإجازة المرضية وفقاً للمادة 31؛ (ج) إجازات الأمومة والأبوة والحداد والدراسة وفق المواد 30-33؛ (د) العطلات الرسمية المعتمدة في الدولة.

## 7. مكافأة نهاية الخدمة
عند إتمام سنة أو أكثر من الخدمة المتصلة، يستحق العامل مكافأة نهاية الخدمة محسوبة على الراتب الأساسي وفق المادتين 51 و52 من المرسوم بقانون اتحادي رقم 33 لسنة 2021.

## 8. السرية وعدم المنافسة
يلتزم العامل بالحفاظ على سرية جميع المعلومات الخاصة بصاحب العمل أثناء وبعد انتهاء الخدمة. وحيثما يكون ذلك مشروعاً، يلتزم العامل بألا يمارس الأنشطة التالية المنافِسة لصاحب العمل لمدة {{non_compete_months}} شهراً بعد إنهاء العقد: {{non_compete_scope}}.

## 9. إنهاء العقد
لأي من الطرفين إنهاء هذه الاتفاقية بإشعار خطي مدته {{notice_period_days}} يوماً. ولصاحب العمل إنهاء العقد دون إشعار في الحالات المنصوص عليها في المادة 44 من المرسوم بقانون اتحادي رقم 33 لسنة 2021.

## 10. القانون الواجب التطبيق والاختصاص القضائي
تخضع هذه الاتفاقية لقوانين دولة الإمارات العربية المتحدة، ولا سيما المرسوم بقانون اتحادي رقم 33 لسنة 2021 ولوائحه التنفيذية، ويختص بأي نزاع ينشأ عنها {{jurisdiction_court}}.

## 11. الاتفاقية الكاملة
تشكّل هذه الاتفاقية مع خطاب العرض المسجّل لدى الوزارة وأي ملاحق مرفقة الاتفاقية الكاملة بين الطرفين، وتلغي ما سبقها من اتفاقيات.

التوقيعات:

عن {{employer_name}}                       عن {{employee_name}}
__________________________________          __________________________________
$AR$,
  updated_by = 1,
  updated_at = NOW()
WHERE id = 9;

-- ────────────────────────────────────────────────────────────────────────────
-- #10 — Mutual NDA (Bilingual) — 7 placeholders
-- ────────────────────────────────────────────────────────────────────────────

UPDATE contract_template SET
  name_en              = 'Mutual Non-Disclosure Agreement (Bilingual)',
  name_ar              = 'اتفاقية عدم إفصاح متبادل (ثنائية اللغة)',
  contract_type        = 'nda',
  language             = 'bilingual',
  description_en       = 'Bilateral NDA suitable for exploratory commercial discussions in the UAE. Mirrors the structure used in cross-border energy / LNG / IT collaboration deals.',
  description_ar       = 'اتفاقية سرية متبادلة مناسبة للمحادثات التجارية الاستكشافية في الإمارات، تعكس الهيكل المستخدم في صفقات الطاقة والغاز المسال وتعاون تقنية المعلومات العابرة للحدود.',
  regulatory_reference = 'UAE Federal Law',
  regulatory_tags      = ARRAY['Confidentiality', 'arbitrateAD', 'UAE Federal Law'],
  placeholders         = $JSON$[
    {"key":"effective_date",   "labelEn":"Effective Date",      "labelAr":"تاريخ السريان",        "kind":"date",  "required":true},
    {"key":"discloser_name",   "labelEn":"Discloser Name",      "labelAr":"اسم المُفصح",          "kind":"party", "required":true},
    {"key":"recipient_name",   "labelEn":"Recipient Name",      "labelAr":"اسم المتلقّي",          "kind":"party", "required":true},
    {"key":"purpose",          "labelEn":"Purpose of Disclosure","labelAr":"غرض الإفصاح",         "kind":"text",  "required":true},
    {"key":"term_years",       "labelEn":"Confidentiality Term (years)","labelAr":"مدة السرية (سنوات)","kind":"number","required":true},
    {"key":"governing_emirate","labelEn":"Governing Emirate",   "labelAr":"الإمارة المختصة",      "kind":"text",  "required":true},
    {"key":"arbitration_seat", "labelEn":"Arbitration Seat",    "labelAr":"مقر التحكيم",           "kind":"text",  "required":true}
  ]$JSON$::jsonb,
  body_en              = $EN$# Mutual Non-Disclosure Agreement

This Mutual Non-Disclosure Agreement (this "Agreement") is entered into on {{effective_date}} by and between **{{discloser_name}}** (the "Discloser"), and **{{recipient_name}}** (the "Recipient"), in connection with {{purpose}} (the "Purpose"). Each party may act as both Discloser and Recipient hereunder.

## 1. Definition of Confidential Information
"Confidential Information" means any information disclosed by one party to the other in connection with the Purpose, whether in written, oral, electronic, graphical, prototype or any other form, that (i) is marked as confidential, restricted, proprietary or with a similar designation; or (ii) by its nature would reasonably be understood by a person of ordinary skill and intelligence to be confidential. Confidential Information does NOT include information that is publicly known through no breach of this Agreement, was lawfully in the Recipient's possession prior to disclosure, is independently developed without use of or reference to the Discloser's Confidential Information, or is rightfully received from a third party without restriction.

## 2. Obligations of the Recipient
The Recipient shall (a) hold the Confidential Information in strict confidence; (b) use it solely for the Purpose; (c) not disclose it to any third party except as expressly permitted; (d) limit disclosure within its organisation to directors, officers, employees, advisers and consultants who have a strict need-to-know and who are bound by no less stringent confidentiality obligations; (e) be responsible for any breach by such persons; and (f) not reverse-engineer or use the Discloser's name, logo or trade marks in any publicity without prior written consent.

## 3. Permitted Disclosures
The Recipient may disclose Confidential Information to the extent required by applicable law, court order or any governmental authority of competent jurisdiction, provided that (where lawful and practicable) the Recipient gives prior notice to the Discloser.

## 4. Term
The Recipient's obligations under this Agreement shall continue from the Effective Date for a period of {{term_years}} years from the date of last disclosure, or, in the case of trade secrets, for so long as the relevant information retains its trade-secret character.

## 5. Return or Destruction
On expiry or termination of this Agreement, or on written request by the Discloser at any time, the Recipient shall promptly (i) return all Confidential Information in tangible form, (ii) destroy or delete all Confidential Information in electronic or other intangible form, and (iii) provide a written certificate signed by an authorised officer confirming such return or destruction.

## 6. No Licence and No Representations
Nothing in this Agreement shall be construed as granting any licence or other right in any Confidential Information, or in any intellectual property right of the Discloser, beyond the right to use the Confidential Information for the Purpose. The Discloser makes no representations or warranties, express or implied, regarding the accuracy or completeness of the Confidential Information.

## 7. Injunctive Relief
The parties acknowledge that monetary damages may be inadequate to remedy a breach of this Agreement, and that the non-breaching party shall be entitled to seek injunctive relief or specific performance, without the requirement to post a bond, in any court of competent jurisdiction.

## 8. Governing Law and Dispute Resolution
This Agreement shall be governed by and construed in accordance with the federal laws of the United Arab Emirates as applied in the Emirate of {{governing_emirate}}. Any dispute arising hereunder shall be referred to arbitration administered by the Abu Dhabi International Arbitration Centre (arbitrateAD) under its Arbitration Rules, seated in {{arbitration_seat}}, with a sole arbitrator, in the English language.

## 9. Entire Agreement, Assignment and Counterparts
This Agreement constitutes the entire agreement between the parties in respect of its subject matter and supersedes all prior agreements, understandings and proposals. Neither party may assign this Agreement without the prior written consent of the other party. This Agreement may be executed in counterparts, including by exchange of signed PDF copies.

Signed for and on behalf of {{discloser_name}}        Signed for and on behalf of {{recipient_name}}
__________________________________                     __________________________________
$EN$,
  body_ar              = $AR$# اتفاقية عدم إفصاح متبادل

أُبرمت اتفاقية عدم الإفصاح المتبادل هذه ("الاتفاقية") بتاريخ {{effective_date}} بين **{{discloser_name}}** ("المُفصح") و**{{recipient_name}}** ("المتلقّي")، فيما يتعلق بـ {{purpose}} ("الغرض"). ولكلٍّ من الطرفين أن يكون مُفصحاً ومتلقّياً بموجب هذه الاتفاقية.

## 1. تعريف المعلومات السرية
يُقصد بـ "المعلومات السرية" أي معلومات يفصح عنها أحد الطرفين للآخر بشأن الغرض، سواء كانت كتابية أو شفهية أو إلكترونية أو رسومية أو أولية أو بأي شكل آخر، التي (1) تُوسم بأنها سرية أو مقيّدة أو محمية الملكية أو بأي وصف مماثل؛ أو (2) تكون بطبيعتها مما يفهم أي شخص ذي معرفة وذكاء عاديين أنها سرية. ولا تشمل المعلومات السرية ما هو متاح للعموم دون إخلال بهذه الاتفاقية، أو ما كان بحوزة المتلقّي بصورة مشروعة قبل الإفصاح، أو ما طوّره بشكل مستقل دون الرجوع إلى المعلومات السرية للمُفصح، أو ما تلقاه بصورة مشروعة من طرف ثالث دون قيد.

## 2. التزامات المتلقّي
يلتزم المتلقّي بأن (أ) يحافظ على سرية المعلومات السرية بشكل صارم؛ (ب) يستخدمها فقط لتحقيق الغرض؛ (ج) لا يُفصح عنها لأي طرف ثالث إلا بما هو مسموح صراحة؛ (د) يقصر الإفصاح داخل منظمته على المديرين والمسؤولين والموظفين والمستشارين والمتعاقدين الذين تربطهم حاجة فعلية للاطلاع وملزمين بسرية لا تقل صرامة عن الواردة هنا؛ (هـ) يكون مسؤولاً عن أي إخلال يصدر عن هؤلاء؛ (و) لا يُفكِّك أو يُهندس عكسياً المعلومات السرية، ولا يستخدم اسم المُفصح أو شعاره أو علاماته التجارية في أي إعلان دون موافقة خطية مسبقة.

## 3. الإفصاحات المسموح بها
يجوز للمتلقّي الإفصاح عن المعلومات السرية بالقدر الذي يقتضيه القانون أو أمر محكمة أو سلطة حكومية مختصة، شريطة إخطار المُفصح مسبقاً متى أمكن ذلك قانوناً وعملياً.

## 4. المدة
تستمر التزامات المتلقّي بموجب هذه الاتفاقية اعتباراً من تاريخ السريان لمدة {{term_years}} سنوات من تاريخ آخر إفصاح، وفي حالة الأسرار التجارية، طوال احتفاظ تلك المعلومات بطابع السر التجاري.

## 5. الإعادة أو الإتلاف
عند انتهاء أو إنهاء هذه الاتفاقية، أو بناءً على طلب خطي من المُفصح في أي وقت، يلتزم المتلقّي بالقيام فوراً بـ (1) إعادة جميع المعلومات السرية المادية، (2) إتلاف أو حذف جميع المعلومات السرية الإلكترونية أو غير الملموسة، (3) تقديم شهادة خطية موقعة من مسؤول مفوّض تؤكد ذلك.

## 6. عدم وجود ترخيص أو تعهدات
لا يُعتبر أي مما ورد في هذه الاتفاقية منحاً لأي ترخيص أو حق آخر في المعلومات السرية أو في أي حقوق ملكية فكرية للمُفصح، فيما عدا الحق في استخدام المعلومات السرية لتحقيق الغرض. ولا يقدم المُفصح أي تعهدات أو ضمانات صريحة أو ضمنية بشأن دقة أو اكتمال المعلومات السرية.

## 7. الإنصاف القضائي
يقرّ الطرفان بأن التعويض المالي قد لا يكون كافياً لمعالجة أي إخلال بهذه الاتفاقية، وأن للطرف غير المخل الحق في طلب أوامر زجرية أو تنفيذ عيني دون اشتراط تقديم كفالة، أمام أي محكمة مختصة.

## 8. القانون الواجب التطبيق وتسوية النزاعات
تخضع هذه الاتفاقية للقوانين الاتحادية لدولة الإمارات العربية المتحدة كما تُطبَّق في إمارة {{governing_emirate}}، ويُحال أي نزاع ينشأ بموجبها إلى التحكيم لدى مركز أبوظبي للتحكيم الدولي (arbitrateAD) وفقاً لقواعده، ومقره {{arbitration_seat}}، أمام محكّم منفرد، وباللغة الإنجليزية.

## 9. الاتفاقية الكاملة والتنازل والنسخ
تُمثل هذه الاتفاقية الاتفاقية الكاملة بين الطرفين بشأن موضوعها، وتلغي ما سبقها من اتفاقيات أو تفاهمات أو مقترحات. ولا يجوز لأي طرف التنازل عن هذه الاتفاقية دون موافقة خطية مسبقة من الطرف الآخر. ويجوز توقيع الاتفاقية في عدة نسخ متطابقة، بما في ذلك بتبادل نسخ PDF موقعة.

موقع عن {{discloser_name}}                            موقع عن {{recipient_name}}
__________________________________                     __________________________________
$AR$,
  updated_by = 1,
  updated_at = NOW()
WHERE id = 10;

-- ────────────────────────────────────────────────────────────────────────────
-- #11 — Vendor Services Agreement (EN only, 8 placeholders)
-- ────────────────────────────────────────────────────────────────────────────

UPDATE contract_template SET
  name_en              = 'Vendor Services Agreement',
  contract_type        = 'vendor_services',
  language             = 'en',
  description_en       = 'General-purpose vendor services contract for one-off or recurring work. Pair with a Statement of Work (SOW) for scope and milestones.',
  regulatory_reference = NULL,
  regulatory_tags      = ARRAY['VAT', 'Procurement'],
  placeholders         = $JSON$[
    {"key":"vendor_name",          "labelEn":"Vendor Name",          "labelAr":"اسم المورّد",            "kind":"party",    "required":true},
    {"key":"vendor_address",       "labelEn":"Vendor Address",       "labelAr":"عنوان المورّد",          "kind":"text",     "required":true},
    {"key":"principal_name",       "labelEn":"Principal (Client) Name","labelAr":"اسم الجهة المتعاقدة","kind":"party",    "required":true},
    {"key":"services_description", "labelEn":"Services Description", "labelAr":"وصف الخدمات",            "kind":"text",     "required":true},
    {"key":"effective_date",       "labelEn":"Effective Date",       "labelAr":"تاريخ السريان",          "kind":"date",     "required":true},
    {"key":"end_date",             "labelEn":"End Date",             "labelAr":"تاريخ الانتهاء",         "kind":"date",     "required":true},
    {"key":"fee_amount",           "labelEn":"Fee Amount (AED)",     "labelAr":"قيمة الأتعاب",           "kind":"currency", "required":true},
    {"key":"payment_terms_days",   "labelEn":"Payment Terms (days)", "labelAr":"شروط الدفع (أيام)",       "kind":"number",   "required":true}
  ]$JSON$::jsonb,
  body_en              = $EN$# Vendor Services Agreement

This Vendor Services Agreement ("Agreement") is entered into on {{effective_date}} between **{{principal_name}}** (the "Principal") and **{{vendor_name}}**, of {{vendor_address}} (the "Vendor").

## 1. Services
The Vendor shall provide the following services to the Principal: {{services_description}} (the "Services"). The Services shall be performed in accordance with the Statement of Work attached as Schedule A.

## 2. Deliverables
Deliverables shall be completed per the milestone schedule set out in Schedule A. The Vendor shall notify the Principal in writing upon completion of each milestone.

## 3. Fees and Payment
- **Total Fee:** AED {{fee_amount}} (excluding VAT where applicable).
- **Payment Terms:** {{payment_terms_days}} days from the date of a valid VAT invoice.
- The Vendor shall be responsible for any tax (including VAT and withholding tax) on its income.

## 4. Term
This Agreement commences on {{effective_date}} and continues until {{end_date}} unless terminated earlier in accordance with Clause 8.

## 5. Vendor Obligations
The Vendor shall (a) perform the Services with reasonable skill and care, (b) comply with all applicable laws of the United Arab Emirates including data-protection and anti-bribery laws, (c) maintain valid trade licences, insurance and permits required to perform the Services, and (d) cooperate with the Principal's auditors and procurement governance.

## 6. Intellectual Property
All foreground intellectual property created by the Vendor in performing the Services and paid for under this Agreement shall vest in the Principal upon payment. The Vendor retains rights to its pre-existing background IP and grants the Principal a perpetual, non-exclusive licence to use it as necessary to enjoy the deliverables.

## 7. Confidentiality
Each party shall keep confidential all non-public information of the other party received in connection with this Agreement, and shall not disclose such information to any third party except to its personnel on a need-to-know basis.

## 8. Termination
Either party may terminate this Agreement (a) for material breach by the other party that is not remedied within thirty (30) days of written notice; or (b) for convenience on sixty (60) days' written notice. On termination, the Principal shall pay the Vendor for Services properly performed up to the date of termination.

## 9. Liability
The Vendor's total aggregate liability under this Agreement shall not exceed the total fees paid in the twelve (12) months preceding the event giving rise to the claim. Neither party shall be liable for indirect or consequential losses.

## 10. Governing Law
This Agreement shall be governed by the laws of the United Arab Emirates and the courts of the Emirate of Abu Dhabi shall have exclusive jurisdiction.

Signed for and on behalf of {{principal_name}}      Signed for and on behalf of {{vendor_name}}
__________________________________                    __________________________________
$EN$,
  body_ar              = NULL,
  updated_by = 1,
  updated_at = NOW()
WHERE id = 11;

-- ────────────────────────────────────────────────────────────────────────────
-- #12 — Master Services Agreement (EN, 7 placeholders)
-- ────────────────────────────────────────────────────────────────────────────

UPDATE contract_template SET
  name_en              = 'Master Services Agreement (MSA)',
  contract_type        = 'master_services',
  language             = 'en',
  description_en       = 'Framework master agreement under which one or more Statements of Work (SOWs) may be issued. Caps fees in each SOW; this MSA governs cross-cutting terms.',
  regulatory_reference = NULL,
  regulatory_tags      = ARRAY['Procurement', 'Multi-SOW'],
  placeholders         = $JSON$[
    {"key":"effective_date",   "labelEn":"Effective Date",   "labelAr":"تاريخ السريان",   "kind":"date",  "required":true},
    {"key":"client_name",      "labelEn":"Client Name",      "labelAr":"اسم العميل",      "kind":"party", "required":true},
    {"key":"client_address",   "labelEn":"Client Address",   "labelAr":"عنوان العميل",    "kind":"text",  "required":true},
    {"key":"vendor_name",      "labelEn":"Vendor Name",      "labelAr":"اسم المورّد",     "kind":"party", "required":true},
    {"key":"vendor_address",   "labelEn":"Vendor Address",   "labelAr":"عنوان المورّد",   "kind":"text",  "required":true},
    {"key":"term_years",       "labelEn":"Term (years)",     "labelAr":"المدة (سنوات)",   "kind":"number","required":true},
    {"key":"governing_law",    "labelEn":"Governing Law",    "labelAr":"القانون الواجب",  "kind":"text",  "required":true}
  ]$JSON$::jsonb,
  body_en              = $EN$# Master Services Agreement

This Master Services Agreement (this "MSA") is entered into on {{effective_date}} between **{{client_name}}**, of {{client_address}} (the "Client"), and **{{vendor_name}}**, of {{vendor_address}} (the "Vendor").

## 1. Scope
This MSA governs all Statements of Work ("SOWs") issued under it. Each SOW shall reference this MSA and incorporate by reference these terms. In the event of conflict between an SOW and this MSA, this MSA prevails except where the SOW expressly states otherwise and is signed by both parties.

## 2. Term
This MSA commences on {{effective_date}} and continues for {{term_years}} years, automatically renewing for successive one-year terms unless either party gives ninety (90) days' written notice of non-renewal.

## 3. SOWs and Pricing
Each SOW shall set out (a) the scope of services, (b) the deliverables and acceptance criteria, (c) the fee structure (fixed-price, time-and-materials, or capped time-and-materials), (d) the milestone schedule, and (e) the project sponsors on each side. Fees are exclusive of VAT.

## 4. Acceptance
Deliverables shall be deemed accepted upon (a) written acceptance by the Client's project sponsor, or (b) failure of the Client to provide reasoned written objections within fifteen (15) business days of delivery.

## 5. Change Control
Any change to an SOW scope, fee or timeline shall be documented in a Change Order signed by both parties. No work outside an approved SOW or Change Order shall be billable.

## 6. Confidentiality and Data Protection
Each party shall protect the other's confidential information and personal data in accordance with applicable UAE law, including Federal Decree-Law 45/2021 (Personal Data Protection Law) where relevant.

## 7. Intellectual Property
Subject to payment, all foreground IP developed under an SOW vests in the Client. The Vendor retains rights in its pre-existing background IP and grants the Client a perpetual licence as necessary to use the deliverables.

## 8. Warranties and Liability
The Vendor warrants that Services will be performed with reasonable skill and care and that deliverables will materially conform to the agreed acceptance criteria for ninety (90) days post-acceptance. Each party's total aggregate liability under this MSA shall not exceed the fees paid under the relevant SOW in the twelve (12) months preceding the claim.

## 9. Termination
Either party may terminate (a) any SOW for material breach not cured within thirty (30) days of written notice, or (b) this MSA for convenience on ninety (90) days' written notice, provided that termination of the MSA does not terminate any then-active SOW unless the parties so agree in writing.

## 10. Governing Law and Disputes
This MSA shall be governed by {{governing_law}} and the courts of the seat of the governing law shall have exclusive jurisdiction. The parties shall attempt to resolve any dispute through good-faith negotiation before escalating to litigation.

Signed for and on behalf of {{client_name}}        Signed for and on behalf of {{vendor_name}}
__________________________________                  __________________________________
$EN$,
  body_ar              = NULL,
  updated_by = 1,
  updated_at = NOW()
WHERE id = 12;

-- ────────────────────────────────────────────────────────────────────────────
-- #13 — Consultancy Services Agreement (light touch — convert brackets +
--       add placeholder catalog; preserve concise body shape)
-- ────────────────────────────────────────────────────────────────────────────

UPDATE contract_template SET
  language             = 'en',
  placeholders         = $JSON$[
    {"key":"consultant_name","labelEn":"Consultant Name","labelAr":"اسم المستشار","kind":"party","required":true},
    {"key":"client_name",   "labelEn":"Client Name",   "labelAr":"اسم العميل",   "kind":"party","required":true},
    {"key":"effective_date","labelEn":"Effective Date","labelAr":"تاريخ السريان","kind":"date", "required":true},
    {"key":"daily_rate",    "labelEn":"Daily Rate (AED)","labelAr":"السعر اليومي","kind":"currency","required":true},
    {"key":"engagement_days","labelEn":"Engagement Days","labelAr":"عدد الأيام", "kind":"number","required":true}
  ]$JSON$::jsonb,
  body_en              = $EN$# Consultancy Services Agreement

This Consultancy Services Agreement is entered into on {{effective_date}} between **{{client_name}}** ("Client") and **{{consultant_name}}** ("Consultant").

## 1. Scope of Work
Consultant shall deliver the advisory services in Schedule A.

## 2. Independence
Consultant is an independent contractor; no employer-employee relationship is created.

## 3. Compensation
Daily rate of AED {{daily_rate}} for up to {{engagement_days}} engagement days, plus pre-approved expenses.

## 4. Deliverables and Acceptance
Deliverables are accepted upon Client's written sign-off, or after fifteen (15) business days without written objection.

## 5. Confidentiality
Consultant shall keep all Client information confidential for two (2) years after termination.

## 6. Intellectual Property
Foreground IP developed under this engagement vests in the Client upon payment; Consultant retains background IP.

## 7. Termination
Either party may terminate on thirty (30) days' written notice or immediately for material breach.

## 8. Governing Law
UAE law, courts of Abu Dhabi.
$EN$,
  updated_by = 1,
  updated_at = NOW()
WHERE id = 13;

-- ────────────────────────────────────────────────────────────────────────────
-- #14 — LLC Incorporation Agreement (light touch)
-- ────────────────────────────────────────────────────────────────────────────

UPDATE contract_template SET
  language             = 'en',
  placeholders         = $JSON$[
    {"key":"company_name",      "labelEn":"Company Name",          "labelAr":"اسم الشركة","kind":"party","required":true},
    {"key":"shareholder_list",  "labelEn":"Shareholder List",      "labelAr":"قائمة الشركاء","kind":"text","required":true},
    {"key":"share_capital_aed", "labelEn":"Share Capital (AED)",   "labelAr":"رأس المال (درهم)","kind":"currency","required":true},
    {"key":"effective_date",    "labelEn":"Effective Date",        "labelAr":"تاريخ السريان","kind":"date","required":true},
    {"key":"registered_office", "labelEn":"Registered Office",     "labelAr":"المقر المسجل","kind":"text","required":true}
  ]$JSON$::jsonb,
  body_en              = $EN$# Limited Liability Company Incorporation Agreement

Effective {{effective_date}}.

## 1. Name
The Company shall be incorporated as **{{company_name}}** LLC.

## 2. Shareholders
{{shareholder_list}}.

## 3. Share Capital
AED {{share_capital_aed}}, divided into shares per the cap table at Schedule A.

## 4. Registered Office
{{registered_office}}.

## 5. Management
Management shall be appointed by ordinary resolution of the shareholders, in accordance with Federal Law 32/2021 (Commercial Companies Law).

## 6. Distribution of Profits
Profits and losses shall be allocated in proportion to shareholdings, subject to any reserves required by law.

## 7. Transfer of Shares
No share may be transferred without first being offered to existing shareholders on the same terms (right of first refusal).

## 8. Dissolution
The Company may be dissolved by unanimous shareholder resolution or by operation of law.

## 9. Governing Law
UAE Federal Law 32/2021 and the laws of the Emirate in which the Company is registered.
$EN$,
  updated_by = 1,
  updated_at = NOW()
WHERE id = 14;

-- ────────────────────────────────────────────────────────────────────────────
-- #15 — Distribution Agreement (light touch)
-- ────────────────────────────────────────────────────────────────────────────

UPDATE contract_template SET
  language             = 'en',
  placeholders         = $JSON$[
    {"key":"principal_name",  "labelEn":"Principal Name",     "labelAr":"اسم الموكّل","kind":"party","required":true},
    {"key":"distributor_name","labelEn":"Distributor Name",   "labelAr":"اسم الموزّع","kind":"party","required":true},
    {"key":"exclusivity",     "labelEn":"Exclusive or Non-exclusive","labelAr":"حصري أو غير حصري","kind":"text","required":true},
    {"key":"territory",       "labelEn":"Territory",          "labelAr":"الإقليم","kind":"text","required":true},
    {"key":"product_range",   "labelEn":"Product Range",      "labelAr":"نطاق المنتجات","kind":"text","required":true},
    {"key":"term_years",      "labelEn":"Term (years)",       "labelAr":"المدة (سنوات)","kind":"number","required":true},
    {"key":"effective_date",  "labelEn":"Effective Date",     "labelAr":"تاريخ السريان","kind":"date","required":true}
  ]$JSON$::jsonb,
  body_en              = $EN$# Distribution Agreement

Effective {{effective_date}} between **{{principal_name}}** ("Principal") and **{{distributor_name}}** ("Distributor").

## 1. Appointment
Principal appoints Distributor as the **{{exclusivity}}** distributor for the Territory.

## 2. Territory
{{territory}}.

## 3. Products
{{product_range}}.

## 4. Term
This Agreement runs for {{term_years}} years from the Effective Date and may be renewed by mutual written agreement.

## 5. Pricing and Payment
Prices per Schedule A; payment terms net 30 days from invoice.

## 6. Marketing Obligations
Distributor shall use commercially reasonable efforts to promote and sell the Products in the Territory.

## 7. Reporting
Distributor shall report sales quarterly with sufficient detail for the Principal to monitor performance.

## 8. Termination
Either party may terminate for material breach on thirty (30) days' written notice. Principal may terminate for convenience on six (6) months' notice, with arms-length compensation for the Distributor's stock-in-hand.

## 9. Compliance
Distributor shall comply with all applicable laws including UAE Commercial Agencies Law (where registered), anti-bribery and sanctions regulations.

## 10. Governing Law
UAE law, courts of Abu Dhabi.
$EN$,
  updated_by = 1,
  updated_at = NOW()
WHERE id = 15;

-- ────────────────────────────────────────────────────────────────────────────
-- #16 — Real Estate Lease (Tenancy Contract) — light touch
-- ────────────────────────────────────────────────────────────────────────────

UPDATE contract_template SET
  language             = 'en',
  regulatory_reference = 'Ejari',
  regulatory_tags      = ARRAY['Ejari', 'Tenancy'],
  placeholders         = $JSON$[
    {"key":"landlord_name",  "labelEn":"Landlord Name",   "labelAr":"اسم المؤجّر","kind":"party","required":true},
    {"key":"tenant_name",    "labelEn":"Tenant Name",     "labelAr":"اسم المستأجر","kind":"party","required":true},
    {"key":"premises_address","labelEn":"Premises Address","labelAr":"عنوان العقار","kind":"text","required":true},
    {"key":"premises_area",  "labelEn":"Premises Area (sqft)","labelAr":"المساحة (قدم مربع)","kind":"number","required":true},
    {"key":"start_date",     "labelEn":"Start Date",      "labelAr":"تاريخ البدء","kind":"date","required":true},
    {"key":"end_date",       "labelEn":"End Date",        "labelAr":"تاريخ الانتهاء","kind":"date","required":true},
    {"key":"rent_amount",    "labelEn":"Annual Rent (AED)","labelAr":"الإيجار السنوي","kind":"currency","required":true},
    {"key":"cheque_count",   "labelEn":"Number of Cheques","labelAr":"عدد الشيكات","kind":"number","required":true}
  ]$JSON$::jsonb,
  body_en              = $EN$# Tenancy Contract

## 1. Parties
Landlord: **{{landlord_name}}**. Tenant: **{{tenant_name}}**.

## 2. Premises
{{premises_address}}, area {{premises_area}} sqft.

## 3. Term
From {{start_date}} to {{end_date}}. Renewable by mutual agreement subject to applicable rent-cap regulations.

## 4. Rent
AED {{rent_amount}} payable in {{cheque_count}} cheques.

## 5. Security Deposit
Equivalent to five (5) per cent of the annual rent, refundable upon expiry less any deductions for damage or unpaid utilities.

## 6. Utilities
Tenant shall be responsible for DEWA / SEWA / FEWA / ADDC and Etisalat / du connections in its own name.

## 7. Maintenance
Landlord is responsible for major structural repairs; Tenant is responsible for routine maintenance and any damage beyond fair wear and tear.

## 8. Use
Premises shall be used solely for residential or commercial purposes as registered with Ejari.

## 9. Termination
Either party may terminate on ninety (90) days' written notice prior to expiry; early termination by the Tenant attracts a penalty equivalent to two (2) months' rent unless otherwise agreed.

## 10. Governing Law
UAE law; the Rental Disputes Centre of the Emirate has exclusive jurisdiction.
$EN$,
  updated_by = 1,
  updated_at = NOW()
WHERE id = 16;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (498, '498_template_content_reseed_bilingual', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
