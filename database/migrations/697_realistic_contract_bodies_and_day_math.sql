-- ============================================================================
-- Migration 697 — Realistic contract bodies (77, 243) + fix milestone day math
-- ============================================================================
-- 1. The previous bodies were 4 thin markdown sections. Rewrite them as full,
--    realistic contracts mirroring the platform's contract format (cover block,
--    recitals/WHEREAS, numbered Articles, signature page) while keeping the
--    milestone (A1340, baseline 30 Apr 2026, LD 0.5%/wk cap 10%) and SLA
--    (P2 ≤ 8h + service credits) clauses that the internal risks reference.
-- 2. Day math fix: baseline finish 30 Apr 2026 and capture date 17 Jun 2026 is
--    48 days, not 21. Correct the milestone case + signal + snapshot to 48.
-- ============================================================================

BEGIN;

-- ── 1a. Contract 77 — EPC Crude Stabilization Unit (full body) ──────────────
UPDATE contract SET
  body_en =
    E'ADNOC Onshore Company\n'
 || E'Contract No. CRQ-ONS-023\n'
 || E'ENGINEERING, PROCUREMENT AND CONSTRUCTION (EPC) CONTRACT\n'
 || E'for the\nCrude Stabilization Unit — Ruwais\n'
 || E'between ADNOC Onshore Company ("Company") and Mubadala Petroleum Support Services ("Contractor")\n\n'
 || E'Effective Date: 1 July 2022 (2 Dhu al-Hijjah 1443 AH)\n'
 || E'Place of Execution: Abu Dhabi, United Arab Emirates\n'
 || E'Contract Value: AED 3,800,000,000 (USD 1,034,717,000)\n'
 || E'Term: 1 July 2022 to 30 June 2027\n\n'
 || E'CONFIDENTIAL — Property of ADNOC Onshore. Distribution restricted to authorised personnel.\n\n'
 || E'## Recitals\n'
 || E'This Engineering, Procurement and Construction Contract (this "Contract") is entered into on 1 July 2022 at Abu Dhabi, United Arab Emirates, by and between ADNOC Onshore Company, a company existing under the laws of the Emirate of Abu Dhabi ("Company"), and Mubadala Petroleum Support Services, a company incorporated in the United Arab Emirates ("Contractor"). The Company and the Contractor are referred to individually as a "Party" and collectively as the "Parties".\n'
 || E'WHEREAS the Company requires the engineering, procurement and construction of a Crude Stabilization Unit at the Ruwais Onshore complex; and WHEREAS the Contractor represents that it possesses the expertise, qualified personnel and resources necessary to perform the Works, the Parties agree as follows.\n\n'
 || E'## Article 1 — Definitions\n'
 || E'"Works" means all engineering, procurement, construction, pre-commissioning and commissioning activities required to deliver the Crude Stabilization Unit. "Mechanical Completion" means the stage at which the Works have been completed in accordance with the Specifications and are ready for commissioning. "Baseline Schedule" means the schedule maintained in Oracle Primavera P6. "Contract Value" has the meaning given on the cover page.\n\n'
 || E'## Article 2 — Scope of Work\n'
 || E'The Contractor shall, on a lump-sum turnkey basis, engineer, procure, construct, pre-commission and commission the Crude Stabilization Unit, including all mechanical, electrical, instrumentation and civil works, in accordance with the Specifications, applicable ADNOC engineering standards and the laws of the United Arab Emirates.\n\n'
 || E'## Article 3 — Contract Price and Payment\n'
 || E'In consideration of the performance of the Works, the Company shall pay the Contractor the Contract Value of AED 3,800,000,000, payable against certified progress milestones in accordance with Annex B. All payments are subject to retention of five percent (5%), released upon Final Acceptance.\n\n'
 || E'## Article 4 — Project Schedule and Milestones\n'
 || E'The Contractor shall perform the Works in accordance with the Baseline Schedule maintained in Oracle Primavera P6 and reviewed monthly by the Parties. The Contractor shall achieve Mechanical Completion of the Crude Stabilization Unit (critical-path activity A1340) no later than 30 April 2026. Each activity on the critical path constitutes a key contractual milestone, and the Contractor shall promptly report any actual or anticipated slippage.\n\n'
 || E'## Article 5 — Liquidated Damages\n'
 || E'If the Contractor fails to achieve a critical-path milestone by its baseline date, the Contractor shall pay the Company liquidated damages equal to zero point five percent (0.5%) of the Contract Value for each week of delay (or pro-rata part thereof), capped in aggregate at ten percent (10%) of the Contract Value. The Parties agree that such liquidated damages are a genuine pre-estimate of loss and constitute the Company sole monetary remedy for delay.\n\n'
 || E'## Article 6 — Performance Standards and Warranties\n'
 || E'The Contractor warrants that the Works shall be free from defects in design, materials and workmanship and shall conform to the Specifications for a period of twelve (12) months from Mechanical Completion (the "Defects Liability Period").\n\n'
 || E'## Article 7 — Health, Safety and Environment\n'
 || E'The Contractor shall comply with all HSE requirements of the Company and applicable UAE federal law, and shall maintain a documented HSE management system throughout the Works.\n\n'
 || E'## Article 8 — In-Country Value and Emiratisation\n'
 || E'The Contractor shall achieve the In-Country Value (ICV) commitment stated in its certified ICV certificate and shall comply with applicable Emiratisation requirements.\n\n'
 || E'## Article 9 — Indemnification and Insurance\n'
 || E'Each Party shall indemnify the other against third-party claims arising from its negligence or breach. The Contractor shall maintain Contractor All-Risks, third-party liability and workmen compensation insurance with reputable insurers throughout the Works.\n\n'
 || E'## Article 10 — Confidentiality and Intellectual Property\n'
 || E'Each Party shall keep confidential all information disclosed under this Contract. All intellectual property developed specifically for the Company under the Works shall vest in the Company upon payment.\n\n'
 || E'## Article 11 — Force Majeure and Termination\n'
 || E'Neither Party shall be liable for failure to perform caused by an event of Force Majeure. The Company may terminate this Contract for convenience upon thirty (30) days written notice, or for cause upon an uncured material breach.\n\n'
 || E'## Article 12 — Governing Law and Dispute Resolution\n'
 || E'This Contract is governed by the federal laws of the United Arab Emirates as applied in the Emirate of Abu Dhabi. Any dispute shall be finally resolved by arbitration under the Rules of the Abu Dhabi International Arbitration Centre (arbitrateAD), seated in Abu Dhabi, conducted in the English language.\n\n'
 || E'## Article 13 — Notices and General Provisions\n'
 || E'All notices shall be in writing and delivered to the addresses on the cover page. This Contract, together with its Annexes, constitutes the entire agreement between the Parties and supersedes all prior understandings.\n\n'
 || E'## Signature Page\n'
 || E'SIGNED for and on behalf of ADNOC Onshore Company:  ______________________   Name: __________________   Title: __________________   Date: __________\n\n'
 || E'SIGNED for and on behalf of Mubadala Petroleum Support Services:  ______________________   Name: __________________   Title: __________________   Date: __________',
  body_ar =
    E'شركة أدنوك البرية\n'
 || E'العقد رقم CRQ-ONS-023\n'
 || E'عقد الهندسة والتوريد والإنشاء (EPC)\n'
 || E'الخاص بوحدة تثبيت الخام — الرويس\n'
 || E'بين شركة أدنوك البرية ("الشركة") وشركة مبادلة لخدمات دعم البترول ("المقاول")\n\n'
 || E'تاريخ النفاذ: 1 يوليو 2022 (2 ذو الحجة 1443 هـ)\n'
 || E'مكان الإبرام: أبوظبي، الإمارات العربية المتحدة\n'
 || E'قيمة العقد: 3,800,000,000 درهم إماراتي\n'
 || E'المدة: من 1 يوليو 2022 إلى 30 يونيو 2027\n\n'
 || E'سري — ملك لشركة أدنوك البرية. التوزيع مقصور على الأشخاص المخوّلين.\n\n'
 || E'## التمهيد\n'
 || E'أُبرم هذا العقد في 1 يوليو 2022 بأبوظبي بين شركة أدنوك البرية ("الشركة") وشركة مبادلة لخدمات دعم البترول ("المقاول"). يُشار إلى كل منهما بـ"الطرف" ومجتمعَين بـ"الطرفين". وحيث ترغب الشركة في هندسة وتوريد وإنشاء وحدة تثبيت الخام في مجمع الرويس البري، وحيث يقرّ المقاول بامتلاكه الخبرة والكوادر والموارد اللازمة، اتفق الطرفان على ما يلي.\n\n'
 || E'## المادة 1 — التعريفات\n'
 || E'تعني "الأعمال" جميع أنشطة الهندسة والتوريد والإنشاء والتشغيل اللازمة لتسليم وحدة تثبيت الخام. ويعني "الإنجاز الميكانيكي" اكتمال الأعمال وفق المواصفات وجاهزيتها للتشغيل. وتعني "الخطة الأساسية" الجدول المُدار في Oracle Primavera P6.\n\n'
 || E'## المادة 2 — نطاق العمل\n'
 || E'يتولى المقاول على أساس تسليم المفتاح بمبلغ إجمالي هندسة وتوريد وإنشاء وتشغيل وحدة تثبيت الخام، بما في ذلك جميع الأعمال الميكانيكية والكهربائية وأعمال التحكم والمدنية، وفقاً للمواصفات ومعايير أدنوك الهندسية وقوانين الدولة.\n\n'
 || E'## المادة 3 — قيمة العقد والدفع\n'
 || E'مقابل تنفيذ الأعمال، تدفع الشركة للمقاول قيمة العقد البالغة 3,800,000,000 درهم، تُسدَّد مقابل معالم إنجاز مُعتمدة وفق الملحق ب، مع احتجاز خمسة بالمئة (5%) تُفرَج عند القبول النهائي.\n\n'
 || E'## المادة 4 — الجدول الزمني والمعالم\n'
 || E'ينفّذ المقاول الأعمال وفق الخطة الأساسية المُدارة في Oracle Primavera P6 والمُراجَعة شهرياً. ويلتزم بتحقيق الإنجاز الميكانيكي لوحدة تثبيت الخام (النشاط الحرج A1340) في موعد أقصاه 30 أبريل 2026. ويُعدّ كل نشاط على المسار الحرج معلَماً تعاقدياً جوهرياً، ويبلّغ المقاول فوراً عن أي تأخّر فعلي أو متوقَّع.\n\n'
 || E'## المادة 5 — التعويضات المقطوعة\n'
 || E'في حال إخفاق المقاول في تحقيق معلَم على المسار الحرج بحلول تاريخه الأساسي، يدفع للشركة تعويضات مقطوعة بنسبة 0.5% من قيمة العقد عن كل أسبوع تأخير، بحد أقصى 10% من قيمة العقد، وتُعدّ تقديراً منصفاً للضرر وعلاجاً مالياً وحيداً للتأخير.\n\n'
 || E'## المادة 6 — معايير الأداء والضمانات\n'
 || E'يضمن المقاول خلوّ الأعمال من العيوب في التصميم والمواد والصنعة ومطابقتها للمواصفات لمدة اثني عشر (12) شهراً من الإنجاز الميكانيكي ("فترة ضمان العيوب").\n\n'
 || E'## المادة 7 — الصحة والسلامة والبيئة\n'
 || E'يلتزم المقاول بجميع متطلبات الصحة والسلامة والبيئة لدى الشركة والقوانين الاتحادية، ويحافظ على نظام موثّق لإدارة الصحة والسلامة والبيئة طوال الأعمال.\n\n'
 || E'## المادة 8 — القيمة المحلية المضافة والتوطين\n'
 || E'يحقّق المقاول التزام القيمة المحلية المضافة (ICV) المذكور في شهادته المعتمدة ويلتزم بمتطلبات التوطين السارية.\n\n'
 || E'## المادة 9 — التعويض والتأمين\n'
 || E'يعوّض كل طرف الآخر عن مطالبات الغير الناشئة عن إهماله أو إخلاله. ويحتفظ المقاول بتأمين جميع أخطار المقاولين والمسؤولية تجاه الغير وتعويض العمال طوال الأعمال.\n\n'
 || E'## المادة 10 — السرية والملكية الفكرية\n'
 || E'يحافظ كل طرف على سرية المعلومات المُفصح عنها. وتؤول للشركة الملكية الفكرية المطوَّرة خصيصاً لها ضمن الأعمال عند السداد.\n\n'
 || E'## المادة 11 — القوة القاهرة والإنهاء\n'
 || E'لا يُسأل أي طرف عن إخفاق ناتج عن قوة قاهرة. ويجوز للشركة إنهاء العقد لمصلحتها بإشعار خطّي مدته ثلاثون (30) يوماً، أو لسبب عند إخلال جوهري غير مُعالَج.\n\n'
 || E'## المادة 12 — القانون الحاكم وتسوية المنازعات\n'
 || E'يخضع هذا العقد للقوانين الاتحادية لدولة الإمارات كما تُطبَّق في إمارة أبوظبي، وتُحسم المنازعات نهائياً بالتحكيم وفق قواعد مركز أبوظبي للتحكيم الدولي ومقره أبوظبي وباللغة الإنجليزية.\n\n'
 || E'## المادة 13 — الإشعارات وأحكام عامة\n'
 || E'تكون الإشعارات خطّية وتُسلَّم إلى العناوين المبيّنة في الغلاف. ويمثّل هذا العقد وملاحقه الاتفاق الكامل بين الطرفين ويَجبّ كل ما سبقه.\n\n'
 || E'## صفحة التوقيع\n'
 || E'مُوقَّع عن شركة أدنوك البرية: ______________   الاسم: __________   المنصب: __________   التاريخ: ______\n\n'
 || E'مُوقَّع عن شركة مبادلة لخدمات دعم البترول: ______________   الاسم: __________   المنصب: __________   التاريخ: ______',
  updated_at = now()
WHERE id = 77;

-- ── 1b. Contract 243 — 20-Year Gas SPA (full body) ──────────────────────────
UPDATE contract SET
  body_en =
    E'ADNOC Gas PLC\n'
 || E'Contract No. CRQ-GAS-009\n'
 || E'GAS SALES AND PURCHASE AGREEMENT (20-YEAR TERM)\n'
 || E'for the supply of natural gas to Ruwais Fertilizers (FERTIL)\n'
 || E'between ADNOC Gas PLC ("Seller") and North Star Shipping Services ("Buyer")\n\n'
 || E'Effective Date: 1 July 2025 (5 Muharram 1447 AH)\n'
 || E'Place of Execution: Abu Dhabi, United Arab Emirates\n'
 || E'Contract Value: AED 14,000,000,000 (USD 3,812,117,000)\n'
 || E'Term: 1 July 2025 to 30 June 2045 (20 years)\n\n'
 || E'CONFIDENTIAL — Property of ADNOC Gas. Distribution restricted to authorised personnel.\n\n'
 || E'## Recitals\n'
 || E'This Gas Sales and Purchase Agreement (this "Agreement") is entered into on 1 July 2025 at Abu Dhabi, United Arab Emirates, by and between ADNOC Gas PLC, a company existing under the laws of the Emirate of Abu Dhabi ("Seller"), and North Star Shipping Services, a company incorporated in the United Arab Emirates ("Buyer"). The Seller and the Buyer are referred to individually as a "Party" and collectively as the "Parties".\n'
 || E'WHEREAS the Seller produces and supplies natural gas; and WHEREAS the Buyer requires a long-term, reliable supply of natural gas for its Ruwais operations, the Parties agree as follows.\n\n'
 || E'## Article 1 — Definitions\n'
 || E'"Gas" means natural gas meeting the quality specification in Annex A. "Delivery Point" means the custody-transfer flange at the Ruwais receiving facility. "Dispatch Scheduling Service" means the operational interface, recorded in ServiceNow ITSM, through which delivery nominations and incidents are managed. "Service Level" has the meaning given in Article 5.\n\n'
 || E'## Article 2 — Sale and Purchase of Gas\n'
 || E'The Seller shall sell and deliver, and the Buyer shall purchase and take or pay for, the contracted daily quantities of Gas at the Delivery Point in accordance with this Agreement throughout the Term.\n\n'
 || E'## Article 3 — Delivery, Nominations and Scheduling\n'
 || E'Delivery nominations and operational changes shall be managed through the Dispatch Scheduling Service. Incidents affecting that service shall be logged and tracked in ServiceNow ITSM and classified by priority in accordance with Article 5.\n\n'
 || E'## Article 4 — Price and Payment\n'
 || E'The price of Gas shall be determined under the pricing formula in Annex B and invoiced monthly. The Buyer shall pay each undisputed invoice within thirty (30) days of receipt.\n\n'
 || E'## Article 5 — Service Levels\n'
 || E'Incidents affecting the Dispatch Scheduling Service are classified by priority. Priority-2 (P2) incidents shall be resolved within eight (8) hours of being logged. Service performance is recorded in ServiceNow ITSM and reviewed monthly by the Parties.\n\n'
 || E'## Article 6 — Service Credits\n'
 || E'Where the Seller fails to meet a Service Level target, the Buyer shall be entitled to service credits calculated by reference to the duration of the breach, applied against the following monthly invoice. Service credits are the Buyer sole monetary remedy for a Service Level breach.\n\n'
 || E'## Article 7 — Measurement and Quality\n'
 || E'Gas shall be measured at the Delivery Point using metering compliant with applicable standards. Gas not meeting the quality specification may be rejected by the Buyer.\n\n'
 || E'## Article 8 — Term and Renewal\n'
 || E'This Agreement shall remain in force for twenty (20) years from the Effective Date and may be renewed by mutual written agreement of the Parties.\n\n'
 || E'## Article 9 — In-Country Value\n'
 || E'Each Party shall support the In-Country Value programme of the United Arab Emirates in the performance of this Agreement.\n\n'
 || E'## Article 10 — Confidentiality\n'
 || E'Each Party shall keep confidential all commercial and operational information disclosed under this Agreement.\n\n'
 || E'## Article 11 — Force Majeure and Termination\n'
 || E'Neither Party shall be liable for failure to perform caused by an event of Force Majeure. Either Party may terminate for cause upon an uncured material breach by the other.\n\n'
 || E'## Article 12 — Governing Law and Dispute Resolution\n'
 || E'This Agreement is governed by the federal laws of the United Arab Emirates as applied in the Emirate of Abu Dhabi. Any dispute shall be finally resolved by arbitration under the Rules of the Abu Dhabi International Arbitration Centre (arbitrateAD), seated in Abu Dhabi, conducted in the English language.\n\n'
 || E'## Article 13 — Notices and General Provisions\n'
 || E'All notices shall be in writing and delivered to the addresses on the cover page. This Agreement, together with its Annexes, constitutes the entire agreement between the Parties and supersedes all prior understandings.\n\n'
 || E'## Signature Page\n'
 || E'SIGNED for and on behalf of ADNOC Gas PLC:  ______________________   Name: __________________   Title: __________________   Date: __________\n\n'
 || E'SIGNED for and on behalf of North Star Shipping Services:  ______________________   Name: __________________   Title: __________________   Date: __________',
  body_ar =
    E'شركة أدنوك للغاز\n'
 || E'العقد رقم CRQ-GAS-009\n'
 || E'اتفاقية بيع وشراء الغاز (مدة 20 عاماً)\n'
 || E'لتوريد الغاز الطبيعي إلى أسمدة الرويس (فيرتيل)\n'
 || E'بين شركة أدنوك للغاز ("البائع") وشركة نورث ستار للخدمات الملاحية ("المشتري")\n\n'
 || E'تاريخ النفاذ: 1 يوليو 2025 (5 محرم 1447 هـ)\n'
 || E'مكان الإبرام: أبوظبي، الإمارات العربية المتحدة\n'
 || E'قيمة العقد: 14,000,000,000 درهم إماراتي\n'
 || E'المدة: من 1 يوليو 2025 إلى 30 يونيو 2045 (20 عاماً)\n\n'
 || E'سري — ملك لشركة أدنوك للغاز. التوزيع مقصور على الأشخاص المخوّلين.\n\n'
 || E'## التمهيد\n'
 || E'أُبرمت هذه الاتفاقية في 1 يوليو 2025 بأبوظبي بين شركة أدنوك للغاز ("البائع") وشركة نورث ستار للخدمات الملاحية ("المشتري"). وحيث ينتج البائع الغاز الطبيعي ويورّده، وحيث يحتاج المشتري إمداداً موثوقاً طويل الأجل لعملياته في الرويس، اتفق الطرفان على ما يلي.\n\n'
 || E'## المادة 1 — التعريفات\n'
 || E'يعني "الغاز" الغاز الطبيعي المطابق لمواصفة الجودة في الملحق أ. ويعني "نقطة التسليم" وصلة نقل العهدة في منشأة الاستقبال بالرويس. وتعني "خدمة جدولة التوزيع" الواجهة التشغيلية المسجّلة في ServiceNow التي تُدار عبرها إخطارات التسليم والحوادث.\n\n'
 || E'## المادة 2 — بيع وشراء الغاز\n'
 || E'يبيع البائع ويسلّم، ويشتري المشتري ويستلم أو يدفع مقابل، الكميات اليومية المتعاقَد عليها من الغاز عند نقطة التسليم طوال المدة.\n\n'
 || E'## المادة 3 — التسليم والإخطارات والجدولة\n'
 || E'تُدار إخطارات التسليم والتغييرات التشغيلية عبر خدمة جدولة التوزيع، وتُسجَّل الحوادث المؤثرة عليها وتُتابَع في ServiceNow وتُصنَّف حسب الأولوية وفق المادة 5.\n\n'
 || E'## المادة 4 — السعر والدفع\n'
 || E'يُحدَّد سعر الغاز وفق معادلة التسعير في الملحق ب ويُفوتر شهرياً، ويسدّد المشتري كل فاتورة غير متنازَع عليها خلال ثلاثين (30) يوماً من استلامها.\n\n'
 || E'## المادة 5 — مستويات الخدمة\n'
 || E'تُصنَّف الحوادث المؤثرة على خدمة جدولة التوزيع حسب الأولوية. ويجب حل حوادث الأولوية الثانية (P2) خلال ثماني (8) ساعات من تسجيلها. ويُسجَّل أداء الخدمة في ServiceNow ويُراجَع شهرياً.\n\n'
 || E'## المادة 6 — ائتمانات الخدمة\n'
 || E'عند إخفاق البائع في تحقيق مستوى الخدمة المستهدف، يحق للمشتري ائتمانات خدمة تُحتسب بحسب مدة الإخلال وتُطبَّق على الفاتورة الشهرية التالية، وتُعدّ العلاج المالي الوحيد للإخلال بمستوى الخدمة.\n\n'
 || E'## المادة 7 — القياس والجودة\n'
 || E'يُقاس الغاز عند نقطة التسليم بأجهزة مطابقة للمعايير، ويجوز للمشتري رفض الغاز غير المطابق لمواصفة الجودة.\n\n'
 || E'## المادة 8 — المدة والتجديد\n'
 || E'تظل هذه الاتفاقية سارية لمدة عشرين (20) عاماً من تاريخ النفاذ، ويجوز تجديدها باتفاق خطّي متبادل.\n\n'
 || E'## المادة 9 — القيمة المحلية المضافة\n'
 || E'يدعم كل طرف برنامج القيمة المحلية المضافة لدولة الإمارات عند تنفيذ هذه الاتفاقية.\n\n'
 || E'## المادة 10 — السرية\n'
 || E'يحافظ كل طرف على سرية المعلومات التجارية والتشغيلية المُفصح عنها بموجب هذه الاتفاقية.\n\n'
 || E'## المادة 11 — القوة القاهرة والإنهاء\n'
 || E'لا يُسأل أي طرف عن إخفاق ناتج عن قوة قاهرة، ويجوز لأي طرف الإنهاء لسبب عند إخلال جوهري غير مُعالَج من الطرف الآخر.\n\n'
 || E'## المادة 12 — القانون الحاكم وتسوية المنازعات\n'
 || E'تخضع هذه الاتفاقية للقوانين الاتحادية لدولة الإمارات كما تُطبَّق في إمارة أبوظبي، وتُحسم المنازعات نهائياً بالتحكيم وفق قواعد مركز أبوظبي للتحكيم الدولي ومقره أبوظبي.\n\n'
 || E'## المادة 13 — الإشعارات وأحكام عامة\n'
 || E'تكون الإشعارات خطّية وتُسلَّم إلى العناوين المبيّنة في الغلاف، وتمثّل هذه الاتفاقية وملاحقها الاتفاق الكامل بين الطرفين.\n\n'
 || E'## صفحة التوقيع\n'
 || E'مُوقَّع عن شركة أدنوك للغاز: ______________   الاسم: __________   المنصب: __________   التاريخ: ______\n\n'
 || E'مُوقَّع عن شركة نورث ستار للخدمات الملاحية: ______________   الاسم: __________   المنصب: __________   التاريخ: ______',
  updated_at = now()
WHERE id = 243;

-- ── 2. Fix milestone day math: 30 Apr 2026 → 17 Jun 2026 capture = 48 days ──
DO $$
DECLARE v_sig BIGINT;
BEGIN
  PERFORM set_config('app.current_tenant_id', '00000000-0000-0000-0000-000000000001', true);
  PERFORM set_config('app.current_user_id', '1', true);

  UPDATE risk_case
     SET title = 'Milestone slippage — critical-path activity 48 days past baseline (still open) on EPC Crude Stabilization',
         body  = 'Oracle Primavera P6 shows critical-path activity A1340 (Mechanical Completion) is 48 days past its baseline finish date of 30 April 2026 and has not been marked complete — an active milestone slip that exposes the contract to liquidated damages. Confirm as an operations risk or dismiss as noise.',
         metadata = COALESCE(metadata,'{}'::jsonb) || jsonb_build_object(
             'breachedClauseSnippet','Mechanical Completion of the Crude Stabilization Unit (critical-path activity A1340) shall be achieved no later than 30 April 2026; delay on a critical-path milestone attracts liquidated damages of 0.5% of Contract Value per week, capped at 10%.'),
         updated_at = now()
   WHERE id = 44;

  SELECT os.id INTO v_sig
    FROM osint_signal os JOIN correlation co ON co.signal_id = os.id JOIN risk_case rc ON rc.correlation_id = co.id
   WHERE rc.id = 44;
  IF v_sig IS NOT NULL THEN
    UPDATE osint_signal
       SET title = 'Milestone Slippage — EPC Crude Stabilization critical activity 48d past baseline',
           source_record_snapshot = jsonb_build_object(
             'systemName','Oracle Primavera P6','systemCode','primavera_p6','systemKind','scm',
             'recordType','Schedule activity','recordId','A1340 — Mechanical Completion',
             'recordUrl','https://p6.adnoc.ae/record/A1340',
             'capturedAt', now(),
             'fields', jsonb_build_array(
               jsonb_build_object('label','Activity ID','value','A1340 — Mechanical Completion'),
               jsonb_build_object('label','Baseline finish','value','2026-04-30'),
               jsonb_build_object('label','Status','value','In progress — not completed'),
               jsonb_build_object('label','Days past baseline','value','48 days'),
               jsonb_build_object('label','On critical path','value','Yes')
             ))
     WHERE id = v_sig;
  END IF;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (697, 'realistic full contract bodies for 77/243 + milestone day-math fix (48 days)', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
