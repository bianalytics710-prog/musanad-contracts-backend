/**
 * One-shot seed script — populates body_en + body_ar on the M_parity-seeded
 * contracts (id 5..39, drafted_by=5) with realistic 8-12 KB per-language
 * bilingual contract text per contract type.
 *
 * Run: `npx tsx scripts/seed-realistic-contract-bodies.ts`
 *
 * Idempotent — re-running overwrites the bodies. Touches only contract
 * rows whose body_en is currently NULL or shorter than 1000 chars (so it
 * doesn't clobber any contract you've manually edited).
 */
import 'dotenv/config';
import { Pool } from 'pg';

interface ContractRow {
  id: number;
  contract_number: string;
  contract_type: string;
  status: string;
  value_aed: string | null;
  start_date: string | null;
  end_date: string | null;
  counterparty_name: string;
  counterparty_name_ar: string | null;
}

interface BodyArgs {
  contract_number: string;
  counterparty_en: string;
  counterparty_ar: string;
  value_aed: string;
  start_date: string;
  end_date: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-contract-type body templates
// Each returns { en, ar } at ~10 KB per language.
// ─────────────────────────────────────────────────────────────────────────────

function masterServices(args: BodyArgs): { en: string; ar: string } {
  const { contract_number, counterparty_en, counterparty_ar, value_aed, start_date, end_date } = args;
  return {
    en: `## Recitals

THIS MASTER SERVICES AGREEMENT (the "Agreement"), reference number ${contract_number}, is entered into and effective as of ${start_date} (the "Effective Date") by and between **Musanad Technologies FZ-LLC**, a Free Zone limited liability company duly licensed by the Dubai Multi Commodities Centre Authority, holding Trade Licence No. DMCC-181452 (hereinafter "Musanad" or the "Service Provider"), and **${counterparty_en}** (hereinafter the "Client" or "Counterparty"), each a "Party" and collectively the "Parties".

WHEREAS, the Service Provider is engaged in the business of providing professional information technology, advisory, and managed services across the United Arab Emirates and the wider Gulf Cooperation Council region;

WHEREAS, the Client wishes to engage the Service Provider to perform certain services under the framework set forth in this Agreement, with specific deliverables, timelines, and commercial terms to be set out in one or more Statements of Work executed pursuant hereto;

WHEREAS, the Parties acknowledge that this Agreement is governed by the laws of the United Arab Emirates and is to be construed in good faith and with reasonable commercial intent;

NOW, THEREFORE, in consideration of the mutual covenants and obligations herein contained, the Parties agree as follows:

## 1. Definitions

1.1 **"Agreement"** means this Master Services Agreement, including all schedules, exhibits, and Statements of Work executed under it.

1.2 **"Statement of Work"** or **"SOW"** means a written work order substantially in the form of Schedule A, executed by an authorised signatory of each Party, that describes specific Services, Deliverables, Fees, milestones, and acceptance criteria.

1.3 **"Services"** means the professional services described in any executed SOW, including but not limited to consulting, software development, systems integration, managed operations, support, training, and advisory services.

1.4 **"Deliverables"** means the work product, reports, code, documentation, and other tangible items expressly identified as Deliverables in an SOW.

1.5 **"Confidential Information"** has the meaning given in Clause 9.

1.6 **"Personal Data"** has the meaning given to it in Federal Decree-Law No. 45 of 2021 on Personal Data Protection (the "PDPL").

1.7 **"Effective Date"** means the date set out at the head of this Agreement.

## 2. Term

2.1 This Agreement shall commence on the Effective Date and shall continue in full force and effect until ${end_date} (the "Initial Term"), unless earlier terminated in accordance with Clause 11.

2.2 The Parties may extend the Initial Term by mutual written agreement for one or more renewal terms of twelve (12) months each (each a "Renewal Term"), provided that notice of intention to renew is given by either Party not less than ninety (90) days before the expiry of the then-current term.

2.3 Termination or expiry of this Agreement shall not affect any SOW that remains in force, unless the SOW expressly provides otherwise. Each SOW shall continue subject to the terms of this Agreement until completion or earlier termination of the SOW.

## 3. Statements of Work

3.1 Each engagement under this Agreement shall be documented in a separately-executed SOW. In the event of any conflict between this Agreement and an SOW, the terms of this Agreement shall prevail save where the SOW expressly states an intention to vary this Agreement, in which case the SOW shall prevail solely for that engagement.

3.2 Each SOW shall set out, at minimum: (a) a description of the Services and Deliverables; (b) the Fees, payment milestones, and any expense reimbursement terms; (c) the project timeline and key dates; (d) the acceptance criteria for each Deliverable; and (e) the names and contact details of the Project Managers appointed by each Party.

3.3 No SOW shall create any obligation on either Party until it has been signed by an authorised signatory of each Party.

## 4. Fees and Payment

4.1 The total estimated value under this Agreement, as of the Effective Date, is **AED ${value_aed}**, allocated across SOWs to be executed during the Term.

4.2 Unless otherwise specified in an SOW, the Service Provider shall invoice the Client monthly in arrears for Services performed and Deliverables accepted during the preceding calendar month. Each invoice shall be accompanied by a reasonably-detailed timesheet or milestone report.

4.3 The Client shall pay each undisputed invoice within thirty (30) days of the invoice date by electronic funds transfer to the bank account nominated by the Service Provider.

4.4 All Fees are exclusive of value-added tax (VAT). VAT, where applicable under Federal Decree-Law No. 8 of 2017 on Value Added Tax, shall be charged at the rate prevailing on the date of supply and shall be the responsibility of the Client.

4.5 Late payment shall accrue interest at the rate of twelve per cent (12%) per annum from the due date until paid in full, calculated daily on the outstanding balance.

4.6 The Client may dispute any invoice in good faith provided that written notice of the dispute, with reasonable particulars, is given to the Service Provider within fifteen (15) days of receipt of the invoice. The undisputed portion shall be paid in accordance with Clause 4.3.

## 5. Service Standards and Acceptance

5.1 The Service Provider shall perform the Services with reasonable skill, care, and diligence, in accordance with generally accepted industry practice and the standards set out in each SOW.

5.2 Deliverables shall be subject to acceptance testing in accordance with the criteria set out in the relevant SOW. The Client shall have ten (10) Business Days from delivery to review each Deliverable and to either accept it or provide written notice of any non-conformity.

5.3 If the Client provides timely notice of non-conformity, the Service Provider shall, at its cost, correct the non-conformity within fifteen (15) Business Days and re-submit the Deliverable for acceptance. If the Deliverable remains non-conforming after two re-submissions, the Client may, at its option, accept the Deliverable with an equitable reduction in Fees, or terminate the relevant SOW with refund of Fees paid for that Deliverable.

5.4 If the Client fails to provide timely notice of non-conformity, the Deliverable shall be deemed accepted on the eleventh (11th) Business Day after delivery.

## 6. Project Governance

6.1 Each Party shall appoint a Project Manager for each SOW, who shall be the primary point of contact for the day-to-day administration of the engagement.

6.2 The Project Managers shall meet at least monthly (or as otherwise agreed in the SOW) to review progress, risks, and issues, and to approve any necessary scope changes pursuant to the change-control process described in Clause 7.

6.3 Material disputes that cannot be resolved at the Project Manager level shall be escalated to a Steering Committee comprising senior executives of each Party, who shall use reasonable endeavours to resolve such disputes within ten (10) Business Days.

## 7. Change Control

7.1 Either Party may request a change to the scope of any SOW by submitting a written change request describing the proposed change and its rationale.

7.2 The Service Provider shall, within five (5) Business Days, respond with a written impact assessment setting out any changes to the Fees, timeline, Deliverables, or other commercial terms.

7.3 No change shall take effect until both Parties have signed a written change order incorporating the impact assessment.

## 8. Intellectual Property

8.1 Each Party shall retain ownership of all intellectual property rights it owned before the Effective Date or develops independently of this Agreement ("Background IP").

8.2 Subject to Clause 8.3 and unless an SOW expressly provides otherwise, the Service Provider shall, upon full payment for the relevant Deliverable, assign to the Client all intellectual property rights in any work product specifically created for the Client under that SOW ("Foreground IP").

8.3 The Service Provider shall retain ownership of, and the Client shall have a perpetual, non-exclusive, royalty-free licence to use, any tools, methodologies, frameworks, libraries, or pre-existing components incorporated into the Deliverables, solely as part of the Deliverables and not on a stand-alone basis.

8.4 The Client grants the Service Provider a non-exclusive, royalty-free licence to use the Client's name and a high-level description of the engagement for reference and marketing purposes, subject to the Client's prior written approval of the specific text and form of any such reference.

## 9. Confidentiality and Data Protection

9.1 Each Party (the "Receiving Party") shall hold in strict confidence all non-public information disclosed to it by the other Party (the "Disclosing Party"), whether oral, written, or in any other form, that is marked as confidential or that a reasonable person would understand to be confidential ("Confidential Information").

9.2 The Receiving Party shall: (a) use the Confidential Information solely for the purpose of performing its obligations under this Agreement; (b) protect the Confidential Information using at least the same standard of care that it uses to protect its own confidential information of like importance, and in any event not less than a reasonable standard of care; and (c) restrict disclosure to those of its employees, agents, and subcontractors who have a legitimate need to know and who are bound by written confidentiality obligations no less protective than those set out in this Clause 9.

9.3 The obligations of confidentiality shall survive termination or expiry of this Agreement for a period of five (5) years.

9.4 Where either Party processes Personal Data on behalf of the other in connection with the Services, the Parties shall comply with the PDPL and any sector-specific regulations issued by the UAE Data Office, including by entering into a written data processing addendum that addresses the matters required by Article 26 of the PDPL.

## 10. Warranties and Liability

10.1 Each Party warrants to the other that it has full corporate power and authority to enter into and perform this Agreement.

10.2 The Service Provider warrants that the Services shall be performed in a professional and workmanlike manner consistent with industry standards. The Service Provider does not warrant that the Services or Deliverables will be uninterrupted, error-free, or fit for any particular purpose not expressly identified in the relevant SOW.

10.3 Subject to Clause 10.4, the total aggregate liability of either Party arising out of or in connection with this Agreement, whether in contract, tort (including negligence), or otherwise, shall not exceed the Fees paid or payable by the Client to the Service Provider under the SOW giving rise to the claim during the twelve (12) months preceding the claim.

10.4 Nothing in this Agreement shall exclude or limit either Party's liability for: (a) death or personal injury caused by its negligence; (b) fraud or fraudulent misrepresentation; (c) any breach of confidentiality obligations under Clause 9; or (d) any other liability that cannot be excluded or limited by applicable law.

10.5 Neither Party shall be liable to the other for any indirect, incidental, special, or consequential losses, including loss of profit, loss of revenue, loss of business, loss of goodwill, or loss of anticipated savings, arising out of or in connection with this Agreement.

## 11. Termination

11.1 Either Party may terminate this Agreement or any SOW by giving the other Party not less than ninety (90) days' prior written notice.

11.2 Either Party may terminate this Agreement or any SOW immediately by written notice to the other if: (a) the other Party commits a material breach of this Agreement that is incapable of remedy, or that is capable of remedy but is not remedied within thirty (30) days of written notice requiring its remedy; (b) the other Party becomes insolvent, enters into liquidation, or has a receiver or administrator appointed over any of its assets; or (c) the other Party ceases or threatens to cease to carry on business.

11.3 On termination or expiry of this Agreement: (a) the Service Provider shall promptly deliver to the Client all Deliverables completed and accepted up to the date of termination, together with any work-in-progress for which the Client has paid; (b) the Client shall pay the Service Provider all undisputed Fees and reimbursable expenses incurred up to the date of termination; and (c) each Party shall return or destroy all Confidential Information of the other Party in its possession.

11.4 The provisions of Clauses 8 (Intellectual Property), 9 (Confidentiality and Data Protection), 10 (Warranties and Liability), 11 (Termination), 12 (Governing Law), and 13 (Notices) shall survive termination or expiry of this Agreement.

## 12. Governing Law and Dispute Resolution

12.1 This Agreement and any dispute or claim arising out of or in connection with it (including non-contractual disputes or claims) shall be governed by and construed in accordance with the laws of the United Arab Emirates as applied in the Emirate of Dubai.

12.2 The Parties shall use reasonable endeavours to resolve any dispute amicably through direct negotiation between senior representatives. If a dispute is not resolved within thirty (30) days of being raised, either Party may refer the dispute to mediation administered by the DIFC-LCIA Arbitration Centre under its Mediation Rules.

12.3 If the dispute is not resolved by mediation within sixty (60) days of the referral, the dispute shall be finally resolved by arbitration administered by the DIFC-LCIA Arbitration Centre under its Arbitration Rules. The seat of arbitration shall be the Dubai International Financial Centre. The language of the arbitration shall be English. The number of arbitrators shall be one (1) for disputes of value not exceeding AED 5,000,000 and three (3) for disputes of higher value.

## 13. Notices

13.1 Any notice or other communication required or permitted to be given under this Agreement shall be in writing and shall be delivered by hand, by registered post with acknowledgement of receipt, or by email with confirmed receipt, to the addresses notified by the Parties for this purpose.

13.2 Notices shall be deemed received: (a) if delivered by hand, on the date of delivery; (b) if sent by registered post, on the third Business Day after posting; or (c) if sent by email, at the time of confirmed receipt by the recipient's mail server, provided that no automated bounce-back is generated.

## 14. General

14.1 **Entire Agreement.** This Agreement, together with all SOWs executed under it, constitutes the entire agreement between the Parties in respect of its subject matter and supersedes all prior agreements, understandings, and representations.

14.2 **Variation.** No variation of this Agreement shall be effective unless made in writing and signed by an authorised representative of each Party.

14.3 **Assignment.** Neither Party may assign or transfer this Agreement or any of its rights or obligations under it without the prior written consent of the other Party, such consent not to be unreasonably withheld; provided that either Party may assign this Agreement to an affiliate or to a successor in connection with a merger, acquisition, or sale of substantially all of its assets, on prior written notice.

14.4 **Force Majeure.** Neither Party shall be liable for any delay or failure to perform its obligations under this Agreement to the extent that such delay or failure is caused by an event beyond its reasonable control, including acts of God, war, terrorism, civil commotion, governmental action, pandemic, or natural disaster, provided that the affected Party promptly notifies the other Party and uses reasonable endeavours to mitigate the effect of the event.

14.5 **No Partnership.** Nothing in this Agreement shall be construed as creating a partnership, joint venture, agency, or employment relationship between the Parties.

14.6 **Counterparts.** This Agreement may be executed in any number of counterparts, each of which when executed shall constitute an original, and all of which together shall constitute one and the same instrument. Counterparts may be exchanged by electronic means.

14.7 **Language.** This Agreement is executed in both English and Arabic. In the event of any inconsistency between the two language versions, the **Arabic** version shall prevail in accordance with Article 5 of the UAE Civil Transactions Law.

---

**SIGNED FOR AND ON BEHALF OF:**

**Musanad Technologies FZ-LLC**
Name: ____________________________
Title: ____________________________
Date:  ____________________________
Signature: ________________________

**${counterparty_en}**
Name: ____________________________
Title: ____________________________
Date:  ____________________________
Signature: ________________________`,
    ar: `## التمهيد

أُبرمت هذه الاتفاقية الرئيسية للخدمات (يُشار إليها فيما بعد بـ"الاتفاقية")، رقم المرجع ${contract_number}، وأصبحت سارية المفعول اعتبارًا من ${start_date} (يُشار إلى ذلك التاريخ بـ"تاريخ النفاذ")، بين **شركة مُسنَد للتكنولوجيا ذ.م.م المنطقة الحرة**، وهي شركة محدودة المسؤولية مرخصة من سلطة مركز دبي للسلع المتعددة، تحمل الرخصة التجارية رقم DMCC-181452 (يُشار إليها فيما بعد بـ"مُسنَد" أو "مزوّد الخدمة")، وبين **${counterparty_ar}** (يُشار إليها فيما بعد بـ"العميل" أو "الطرف المقابل")، ويُشار إلى كل منهما بـ"الطرف" ومجتمعَين بـ"الطرفان".

حيث إن مزوّد الخدمة يعمل في مجال تقديم الخدمات الاحترافية في مجال تكنولوجيا المعلومات والاستشارات والخدمات المُدارة في دولة الإمارات العربية المتحدة ومنطقة دول مجلس التعاون الخليجي الأوسع؛

وحيث إن العميل يرغب في تكليف مزوّد الخدمة بأداء خدمات معينة وفقًا للإطار المنصوص عليه في هذه الاتفاقية، مع تحديد المخرجات والجداول الزمنية والشروط التجارية المحددة في بيانات عمل واحدة أو أكثر تُبرَم بموجب هذه الاتفاقية؛

وحيث يُقرّ الطرفان بأن هذه الاتفاقية تخضع لقوانين دولة الإمارات العربية المتحدة وتُفسَّر بحسن نية وبقصد تجاري معقول؛

عليه، ونظير الالتزامات المتبادلة الواردة في هذه الاتفاقية، اتفق الطرفان على ما يلي:

## 1. التعريفات

1.1 **"الاتفاقية"** تعني هذه الاتفاقية الرئيسية للخدمات بما في ذلك جميع الجداول والمرفقات وبيانات العمل المُنفّذة بموجبها.

1.2 **"بيان العمل"** يعني أمرًا كتابيًا يكون في الأساس بالشكل المُبيَّن في الجدول (أ)، يوقّعه ممثل مفوض من كل طرف، ويصف الخدمات والمخرجات والأتعاب والمعالم الزمنية ومعايير القبول.

1.3 **"الخدمات"** تعني الخدمات الاحترافية الموصوفة في أي بيان عمل مُنفّذ، بما في ذلك على سبيل المثال لا الحصر الاستشارات وتطوير البرمجيات وتكامل الأنظمة والعمليات المُدارة والدعم والتدريب والخدمات الاستشارية.

1.4 **"المخرجات"** تعني نتاج العمل والتقارير والكود والوثائق وغيرها من البنود الملموسة المُحددة صراحة كمخرجات في بيان عمل.

1.5 **"المعلومات السرية"** لها المعنى المعطى لها في البند 9.

1.6 **"البيانات الشخصية"** لها المعنى المعطى لها في المرسوم بقانون اتحادي رقم 45 لسنة 2021 بشأن حماية البيانات الشخصية ("قانون حماية البيانات الشخصية").

1.7 **"تاريخ النفاذ"** يعني التاريخ المُبيَّن في صدر هذه الاتفاقية.

## 2. مدة الاتفاقية

2.1 تبدأ هذه الاتفاقية من تاريخ النفاذ وتظل سارية المفعول حتى ${end_date} ("المدة الأولية")، ما لم يتم إنهاؤها مبكرًا وفقًا للبند 11.

2.2 يجوز للطرفين تمديد المدة الأولية باتفاق مكتوب متبادل لمدة أو أكثر من فترات التجديد لمدة اثني عشر (12) شهرًا لكل منها (يُشار إلى كل منها بـ"مدة التجديد")، شريطة أن يقدم أي طرف إخطارًا بنية التجديد قبل تسعين (90) يومًا على الأقل من انتهاء المدة الجارية.

2.3 لا يؤثر إنهاء أو انتهاء هذه الاتفاقية على أي بيان عمل لا يزال ساريًا، ما لم يَنُص بيان العمل صراحة على خلاف ذلك. ويستمر كل بيان عمل خاضعًا لشروط هذه الاتفاقية حتى إكماله أو إنهائه المبكر.

## 3. بيانات العمل

3.1 يجب توثيق كل ارتباط بموجب هذه الاتفاقية في بيان عمل مُبرَم على حِدة. وفي حالة وجود أي تعارض بين هذه الاتفاقية وبيان العمل، تسود شروط هذه الاتفاقية ما لم يَنُص بيان العمل صراحة على نية تعديل هذه الاتفاقية، وفي هذه الحالة يسود بيان العمل لذلك الارتباط فقط.

3.2 يجب أن يتضمن كل بيان عمل، كحد أدنى: (أ) وصفًا للخدمات والمخرجات؛ (ب) الأتعاب ومعالم الدفع وأي شروط لتعويض المصاريف؛ (ج) الجدول الزمني للمشروع والتواريخ الرئيسية؛ (د) معايير قبول كل مخرج؛ (هـ) أسماء وبيانات الاتصال لمديري المشروع المعينين من كل طرف.

3.3 لا ينشئ أي بيان عمل أي التزام على أي طرف حتى يتم توقيعه من ممثل مفوض من كل طرف.

## 4. الأتعاب والدفع

4.1 إجمالي القيمة المقدّرة بموجب هذه الاتفاقية، اعتبارًا من تاريخ النفاذ، هو **${value_aed} درهم إماراتي**، تُوزَّع على بيانات العمل المُبرَمة خلال المدة.

4.2 ما لم يُنص على خلاف ذلك في بيان عمل، يُصدر مزوّد الخدمة فاتورة شهرية بأثر رجعي للخدمات المُؤَدَّاة والمخرجات المقبولة خلال الشهر التقويمي السابق. ويُرفَق بكل فاتورة جدول زمني تفصيلي معقول أو تقرير إنجاز معالم.

4.3 يدفع العميل كل فاتورة غير محل خلاف خلال ثلاثين (30) يومًا من تاريخ الفاتورة عبر التحويل المصرفي الإلكتروني إلى الحساب البنكي المُحدد من مزوّد الخدمة.

4.4 جميع الأتعاب لا تشمل ضريبة القيمة المضافة. وتُفرَض ضريبة القيمة المضافة، حيثما تنطبق وفقًا للمرسوم بقانون اتحادي رقم 8 لسنة 2017 بشأن ضريبة القيمة المضافة، بالسعر السائد في تاريخ التوريد، وتكون مسؤولية العميل.

4.5 يستحق التأخير في الدفع فائدة بنسبة اثني عشر بالمئة (12%) سنويًا من تاريخ الاستحقاق حتى السداد الكامل، تُحسَب يوميًا على الرصيد المستحق.

4.6 يجوز للعميل الاعتراض على أي فاتورة بحسن نية شريطة تقديم إخطار مكتوب بالاعتراض، مع تفاصيل معقولة، إلى مزوّد الخدمة خلال خمسة عشر (15) يومًا من استلام الفاتورة. ويُدفَع الجزء غير المعترض عليه وفقًا للبند 4.3.

## 5. معايير الخدمة والقبول

5.1 يؤدي مزوّد الخدمة الخدمات بمهارة ورعاية وعناية معقولة، وفقًا للممارسة الصناعية المقبولة عمومًا والمعايير المنصوص عليها في كل بيان عمل.

5.2 تخضع المخرجات لاختبار القبول وفقًا للمعايير المنصوص عليها في بيان العمل ذي الصلة. ويكون للعميل عشرة (10) أيام عمل من التسليم لمراجعة كل مخرج إما لقبوله أو تقديم إخطار مكتوب بأي عدم مطابقة.

5.3 إذا قدّم العميل إخطارًا في الوقت المحدد بعدم المطابقة، يقوم مزوّد الخدمة، على نفقته، بتصحيح عدم المطابقة خلال خمسة عشر (15) يوم عمل وإعادة تقديم المخرج للقبول. وإذا ظل المخرج غير مطابق بعد إعادتَي تقديم، يجوز للعميل، حسب اختياره، قبول المخرج مع تخفيض عادل للأتعاب، أو إنهاء بيان العمل ذي الصلة مع استرداد الأتعاب المدفوعة عن ذلك المخرج.

5.4 إذا فشل العميل في تقديم إخطار في الوقت المحدد بعدم المطابقة، يُعتبَر المخرج مقبولًا في يوم العمل الحادي عشر (11) بعد التسليم.

## 6. حوكمة المشروع

6.1 يعيّن كل طرف مدير مشروع لكل بيان عمل، ويكون نقطة الاتصال الأساسية للإدارة اليومية للارتباط.

6.2 يجتمع مديرو المشروع مرة واحدة على الأقل شهريًا (أو وفقًا لما هو متفق عليه في بيان العمل) لمراجعة التقدم والمخاطر والقضايا، ولاعتماد أي تغييرات نطاق ضرورية وفقًا لعملية مراقبة التغييرات الموضحة في البند 7.

6.3 تُحال النزاعات الجوهرية التي لا يمكن حلها على مستوى مدير المشروع إلى لجنة توجيهية تتألف من كبار المسؤولين التنفيذيين من كل طرف، الذين يبذلون مساعي معقولة لحل تلك النزاعات خلال عشرة (10) أيام عمل.

## 7. مراقبة التغييرات

7.1 يجوز لأي طرف طلب تغيير في نطاق أي بيان عمل بتقديم طلب تغيير مكتوب يصف التغيير المقترح ومبرراته.

7.2 يستجيب مزوّد الخدمة، خلال خمسة (5) أيام عمل، بتقييم أثر مكتوب يحدد أي تغييرات في الأتعاب أو الجدول الزمني أو المخرجات أو الشروط التجارية الأخرى.

7.3 لا يدخل أي تغيير حيز النفاذ حتى يوقّع كلا الطرفين أمر تغيير مكتوب يضم تقييم الأثر.

## 8. الملكية الفكرية

8.1 يحتفظ كل طرف بملكية جميع حقوق الملكية الفكرية التي يمتلكها قبل تاريخ النفاذ أو يطورها بشكل مستقل عن هذه الاتفاقية ("الملكية الفكرية الخلفية").

8.2 مع مراعاة البند 8.3 وما لم يَنُص بيان العمل صراحة على خلاف ذلك، يقوم مزوّد الخدمة، عند السداد الكامل للمخرج ذي الصلة، بنقل جميع حقوق الملكية الفكرية في أي نتاج عمل مُنشأ خصيصًا للعميل بموجب ذلك بيان العمل ("الملكية الفكرية الأمامية").

8.3 يحتفظ مزوّد الخدمة بملكية، ويمنح العميل ترخيصًا دائمًا غير حصري وخاليًا من الإتاوات لاستخدام، أي أدوات أو منهجيات أو أُطُر أو مكتبات أو مكونات سابقة الوجود تُدمَج في المخرجات، فقط كجزء من المخرجات وليس على أساس مستقل.

8.4 يمنح العميل مزوّد الخدمة ترخيصًا غير حصري خاليًا من الإتاوات لاستخدام اسم العميل ووصف عالي المستوى للارتباط لأغراض المرجعية والتسويق، رهنًا بالموافقة المكتوبة المسبقة من العميل على النص والشكل المحددين لأي مرجع كهذا.

## 9. السرية وحماية البيانات

9.1 يحتفظ كل طرف ("الطرف المُتلَقي") بسرية صارمة لجميع المعلومات غير العامة المُفصَح عنها له من الطرف الآخر ("الطرف المُفصِح")، سواء كانت شفهية أو مكتوبة أو في أي شكل آخر، تكون مُحدَّدة بأنها سرية أو يفهم الشخص المعقول أنها سرية ("المعلومات السرية").

9.2 يجب على الطرف المُتلَقي: (أ) استخدام المعلومات السرية فقط لغرض أداء التزاماته بموجب هذه الاتفاقية؛ (ب) حماية المعلومات السرية باستخدام نفس معيار الرعاية على الأقل الذي يستخدمه لحماية معلوماته السرية الخاصة ذات الأهمية المماثلة، وفي جميع الأحوال ليس أقل من معيار رعاية معقول؛ (ج) تقييد الإفصاح للموظفين والوكلاء والمقاولين من الباطن الذين لديهم حاجة مشروعة للمعرفة والمُلتزمين بالتزامات سرية مكتوبة لا تقل حماية عن تلك المنصوص عليها في هذا البند 9.

9.3 تستمر التزامات السرية بعد إنهاء أو انتهاء هذه الاتفاقية لمدة خمس (5) سنوات.

9.4 حيث يعالج أي طرف بيانات شخصية نيابة عن الطرف الآخر فيما يتعلق بالخدمات، يلتزم الطرفان بقانون حماية البيانات الشخصية وأي لوائح خاصة بالقطاع تصدرها مكتب البيانات الإماراتي، بما في ذلك بإبرام ملحق معالجة بيانات مكتوب يعالج المسائل المطلوبة بموجب المادة 26 من قانون حماية البيانات الشخصية.

## 10. الضمانات والمسؤولية

10.1 يضمن كل طرف للآخر أن لديه السلطة والصلاحية الكاملة للدخول في وأداء هذه الاتفاقية.

10.2 يضمن مزوّد الخدمة أن الخدمات ستُؤدَّى بطريقة احترافية ومتقنة بما يتوافق مع معايير الصناعة. لا يضمن مزوّد الخدمة أن الخدمات أو المخرجات ستكون دون انقطاع أو خالية من الأخطاء أو مناسبة لأي غرض معين غير مُحدَّد صراحة في بيان العمل ذي الصلة.

10.3 مع مراعاة البند 10.4، لا تتجاوز إجمالي المسؤولية الكلية لأي طرف الناشئة عن أو فيما يتعلق بهذه الاتفاقية، سواء في العقد أو الضرر (بما في ذلك الإهمال) أو غير ذلك، الأتعاب المدفوعة أو المستحقة من العميل لمزوّد الخدمة بموجب بيان العمل المُسبِّب للمطالبة خلال الاثني عشر (12) شهرًا السابقة للمطالبة.

10.4 لا يستثني أو يحد أي شيء في هذه الاتفاقية من مسؤولية أي طرف عن: (أ) الوفاة أو الإصابة الشخصية الناجمة عن إهماله؛ (ب) الاحتيال أو التحريف الاحتيالي؛ (ج) أي إخلال بالتزامات السرية بموجب البند 9؛ (د) أي مسؤولية أخرى لا يمكن استثناؤها أو تحديدها بموجب القانون المعمول به.

10.5 لا يتحمّل أي طرف مسؤولية تجاه الآخر عن أي خسائر غير مباشرة أو عرضية أو خاصة أو تبعية، بما في ذلك خسارة الربح أو خسارة الإيرادات أو خسارة الأعمال أو خسارة السمعة التجارية أو خسارة الوفورات المتوقعة، الناشئة عن أو فيما يتعلق بهذه الاتفاقية.

## 11. الإنهاء

11.1 يجوز لأي طرف إنهاء هذه الاتفاقية أو أي بيان عمل بإعطاء الطرف الآخر إخطارًا مكتوبًا مسبقًا لا يقل عن تسعين (90) يومًا.

11.2 يجوز لأي طرف إنهاء هذه الاتفاقية أو أي بيان عمل فورًا بإخطار مكتوب للطرف الآخر إذا: (أ) ارتكب الطرف الآخر إخلالًا جوهريًا بهذه الاتفاقية لا يمكن علاجه، أو يمكن علاجه ولكن لم يُعالَج خلال ثلاثين (30) يومًا من الإخطار المكتوب الذي يطلب علاجه؛ (ب) أصبح الطرف الآخر معسرًا أو دخل في تصفية أو تم تعيين حارس قضائي أو مسؤول إدارة على أي من أصوله؛ (ج) توقف الطرف الآخر أو هدد بالتوقف عن مزاولة الأعمال.

11.3 عند إنهاء أو انتهاء هذه الاتفاقية: (أ) يقوم مزوّد الخدمة فورًا بتسليم العميل جميع المخرجات المنجزة والمقبولة حتى تاريخ الإنهاء، بالإضافة إلى أي عمل قيد التنفيذ دفع العميل ثمنه؛ (ب) يدفع العميل لمزوّد الخدمة جميع الأتعاب غير المتنازع عليها والمصاريف القابلة للسداد المتكبدة حتى تاريخ الإنهاء؛ (ج) يقوم كل طرف بإعادة أو إتلاف جميع المعلومات السرية للطرف الآخر التي بحوزته.

11.4 تستمر أحكام البند 8 (الملكية الفكرية)، 9 (السرية وحماية البيانات)، 10 (الضمانات والمسؤولية)، 11 (الإنهاء)، 12 (القانون الحاكم)، 13 (الإخطارات) بعد إنهاء أو انتهاء هذه الاتفاقية.

## 12. القانون الحاكم وحل النزاعات

12.1 تخضع هذه الاتفاقية وأي نزاع أو مطالبة ناشئة عن أو فيما يتعلق بها (بما في ذلك النزاعات أو المطالبات غير التعاقدية) لقوانين دولة الإمارات العربية المتحدة كما هي مُطبَّقة في إمارة دبي وتُفسَّر وفقًا لها.

12.2 يبذل الطرفان مساعي معقولة لحل أي نزاع وديًا من خلال التفاوض المباشر بين كبار الممثلين. وإذا لم يتم حل النزاع خلال ثلاثين (30) يومًا من رفعه، يجوز لأي طرف إحالة النزاع إلى الوساطة التي يديرها مركز التحكيم DIFC-LCIA بموجب قواعد الوساطة الخاصة به.

12.3 إذا لم يتم حل النزاع بالوساطة خلال ستين (60) يومًا من الإحالة، يُحَل النزاع نهائيًا بالتحكيم الذي يديره مركز التحكيم DIFC-LCIA بموجب قواعد التحكيم الخاصة به. ويكون مقر التحكيم مركز دبي المالي العالمي. ولغة التحكيم هي الإنجليزية. ويكون عدد المحكمين واحدًا (1) للنزاعات التي لا تتجاوز قيمتها 5,000,000 درهم إماراتي وثلاثة (3) للنزاعات ذات القيمة الأعلى.

## 13. الإخطارات

13.1 يجب أن يكون أي إخطار أو اتصال آخر مطلوب أو مسموح به بموجب هذه الاتفاقية مكتوبًا ويُسلَّم باليد أو بالبريد المسجَّل مع علم الوصول أو بالبريد الإلكتروني مع تأكيد الاستلام، إلى العناوين التي يُخطِر بها الطرفان لهذا الغرض.

13.2 تُعتبَر الإخطارات مُستلَمة: (أ) إذا سُلِّمت باليد، في تاريخ التسليم؛ (ب) إذا أُرسِلت بالبريد المسجَّل، في يوم العمل الثالث بعد الإرسال؛ (ج) إذا أُرسِلت بالبريد الإلكتروني، في وقت التأكيد المُستلَم من خادم بريد المستلِم، شريطة عدم توليد أي ارتداد آلي.

## 14. أحكام عامة

14.1 **الاتفاقية الكاملة.** تُشكّل هذه الاتفاقية، مع جميع بيانات العمل المُنفَّذة بموجبها، الاتفاقية الكاملة بين الطرفين فيما يتعلق بموضوعها وتحل محل جميع الاتفاقيات والتفاهمات والتمثيلات السابقة.

14.2 **التعديل.** لا يكون أي تعديل لهذه الاتفاقية ساريًا ما لم يكن مكتوبًا وموقَّعًا من ممثل مفوض من كل طرف.

14.3 **التنازل.** لا يجوز لأي طرف التنازل عن أو نقل هذه الاتفاقية أو أي من حقوقه أو التزاماته بموجبها دون الموافقة المكتوبة المسبقة من الطرف الآخر، على ألا تُحجَب هذه الموافقة بشكل غير معقول؛ شريطة أنه يجوز لأي طرف التنازل عن هذه الاتفاقية لشركة تابعة أو لخلف فيما يتعلق بدمج أو استحواذ أو بيع جميع أصوله تقريبًا، بإخطار مكتوب مسبق.

14.4 **القوة القاهرة.** لا يتحمّل أي طرف مسؤولية أي تأخير أو فشل في أداء التزاماته بموجب هذه الاتفاقية إلى الحد الذي يكون فيه هذا التأخير أو الفشل ناجمًا عن حدث خارج عن سيطرته المعقولة، بما في ذلك القضاء والقدر والحرب والإرهاب والاضطرابات المدنية والإجراءات الحكومية والوباء أو الكوارث الطبيعية، شريطة أن يُخطِر الطرف المتضرر فورًا الطرف الآخر ويبذل مساعي معقولة لتخفيف أثر الحدث.

14.5 **عدم الشراكة.** لا يُفسَّر أي شيء في هذه الاتفاقية على أنه يُنشئ شراكة أو مشروعًا مشتركًا أو وكالة أو علاقة عمل بين الطرفين.

14.6 **النسخ.** يجوز تنفيذ هذه الاتفاقية في أي عدد من النسخ، تكون كل منها عند تنفيذها أصلية، وكل النسخ معًا تشكل صكًا واحدًا. ويجوز تبادل النسخ بالوسائل الإلكترونية.

14.7 **اللغة.** هذه الاتفاقية مُنفَّذة باللغتين الإنجليزية والعربية. وفي حالة أي تعارض بين النسختين، تسود **النسخة العربية** وفقًا للمادة 5 من قانون المعاملات المدنية الإماراتي.

---

**وُقِّع نيابةً عن:**

**شركة مُسنَد للتكنولوجيا ذ.م.م المنطقة الحرة**
الاسم: ____________________________
المنصب: __________________________
التاريخ: __________________________
التوقيع: __________________________

**${counterparty_ar}**
الاسم: ____________________________
المنصب: __________________________
التاريخ: __________________________
التوقيع: __________________________`,
  };
}

// For brevity in the file, the other 6 contract types use a shared
// generator with type-specific section overrides.
function genericLegalContract(typeLabelEn: string, typeLabelAr: string, args: BodyArgs): { en: string; ar: string } {
  const { contract_number, counterparty_en, counterparty_ar, value_aed, start_date, end_date } = args;
  return {
    en: `## Recitals

THIS ${typeLabelEn.toUpperCase()} (the "Agreement"), reference number ${contract_number}, is entered into and effective as of ${start_date} (the "Effective Date") between **Musanad Technologies FZ-LLC** (hereinafter "Musanad" or the "Company"), a Free Zone limited liability company licensed by the Dubai Multi Commodities Centre Authority under Trade Licence No. DMCC-181452, and **${counterparty_en}** (hereinafter the "Counterparty"), each a "Party" and together the "Parties".

WHEREAS, the Parties wish to enter into this Agreement on the terms and conditions set forth below;

WHEREAS, this Agreement is to be construed in accordance with the laws of the United Arab Emirates and applicable sector-specific regulations;

NOW, THEREFORE, in consideration of the mutual covenants contained herein, the Parties agree as follows:

## 1. Definitions and Interpretation

1.1 In this Agreement, unless the context otherwise requires:

  - **"Agreement"** means this ${typeLabelEn} and all schedules and exhibits attached hereto;
  - **"Business Day"** means any day other than a Friday, Saturday, or a public holiday in the United Arab Emirates;
  - **"Confidential Information"** has the meaning given in Clause 7;
  - **"Effective Date"** means the date set out at the head of this Agreement;
  - **"Force Majeure Event"** has the meaning given in Clause 12;
  - **"Personal Data"** has the meaning given in Federal Decree-Law No. 45 of 2021 on Personal Data Protection;
  - **"Term"** means the period from the Effective Date until ${end_date}, subject to earlier termination in accordance with this Agreement.

1.2 Words importing the singular shall include the plural and vice versa. References to a clause are references to a clause of this Agreement. Headings are for convenience only and shall not affect interpretation.

1.3 References to legislation include any subordinate legislation made under it and any amendment, re-enactment, or replacement of it.

## 2. Subject Matter and Scope

2.1 The Counterparty hereby engages the Company, and the Company accepts the engagement, to perform the obligations described in Schedule A ("Scope") in accordance with the terms of this Agreement.

2.2 The Scope may be amended only by written agreement of the Parties, executed by duly authorised signatories of each Party. Any unilateral attempt to vary the Scope shall be of no effect.

2.3 The Company shall perform its obligations under this Agreement with reasonable skill, care, and diligence, in accordance with generally accepted professional standards in the relevant industry, and in compliance with all applicable laws and regulations of the United Arab Emirates.

## 3. Term and Renewal

3.1 This Agreement shall commence on the Effective Date and shall continue in full force and effect until ${end_date} (the "Initial Term"), unless terminated earlier in accordance with Clause 11.

3.2 Upon expiry of the Initial Term, this Agreement may be renewed for one or more additional periods of twelve (12) months each by mutual written agreement, provided that notice of intention to renew is given by either Party not less than sixty (60) days before expiry of the then-current term.

3.3 Continued performance by either Party after expiry of the term shall not constitute a renewal in the absence of written agreement.

## 4. Consideration and Payment Terms

4.1 In consideration of the performance of the Company's obligations under this Agreement, the Counterparty shall pay the Company a total amount of **AED ${value_aed}**, plus value-added tax (VAT) as applicable.

4.2 Payment shall be made in accordance with the milestone schedule set out in Schedule B, or, where no milestone schedule is provided, monthly in arrears within thirty (30) days of receipt of a valid invoice.

4.3 All amounts payable under this Agreement are exclusive of VAT, which shall be charged where applicable in accordance with Federal Decree-Law No. 8 of 2017 on Value Added Tax and shall be the responsibility of the Counterparty.

4.4 Late payment shall accrue interest at twelve per cent (12%) per annum, calculated daily on the outstanding balance from the due date until the date of payment.

4.5 The Counterparty shall not be entitled to set off, deduct, withhold, or otherwise reduce any amount payable under this Agreement except to the extent expressly permitted by this Agreement or required by law.

## 5. Performance Standards and Reporting

5.1 The Company shall perform its obligations in a professional and workmanlike manner consistent with industry best practice and shall use reasonable endeavours to meet any milestones or deadlines set out in this Agreement or any related schedule.

5.2 The Company shall provide the Counterparty with monthly progress reports describing: (a) work performed during the reporting period; (b) work planned for the next period; (c) any risks, issues, or dependencies that may affect performance; and (d) any requested decisions or approvals from the Counterparty.

5.3 The Counterparty shall provide the Company with timely access to all information, premises, personnel, and resources reasonably required for the performance of the Company's obligations.

5.4 If the Counterparty fails to provide such access or to take any action reasonably required of it on a timely basis, the Company shall not be in breach of this Agreement to the extent that its performance is delayed or prevented by such failure.

## 6. Intellectual Property

6.1 Each Party shall retain ownership of all intellectual property rights it owned prior to the Effective Date or that it develops independently of this Agreement ("Background IP").

6.2 All intellectual property rights in any work product specifically created by the Company for the Counterparty under this Agreement ("Foreground IP") shall, upon full payment, vest in the Counterparty.

6.3 The Company shall retain ownership of, and the Counterparty shall have a perpetual, non-exclusive, royalty-free, world-wide licence to use, any methodologies, frameworks, or pre-existing tools incorporated into the Foreground IP, solely as part of the Foreground IP.

6.4 Each Party warrants that the materials it provides to the other Party do not infringe the intellectual property rights of any third party.

## 7. Confidentiality

7.1 Each Party (the "Receiving Party") shall hold in strict confidence all non-public information disclosed to it by the other Party (the "Disclosing Party") that is marked as confidential or that a reasonable person would understand to be confidential ("Confidential Information").

7.2 The Receiving Party shall: (a) use the Confidential Information only for the purpose of performing its obligations under this Agreement; (b) restrict disclosure to its employees, agents, and subcontractors who have a legitimate need to know and who are bound by confidentiality obligations no less protective than those in this Clause 7; and (c) protect the Confidential Information using at least a reasonable standard of care.

7.3 The obligations of confidentiality shall not apply to information that: (a) is or becomes publicly available through no fault of the Receiving Party; (b) was rightfully known to the Receiving Party prior to disclosure; (c) is independently developed by the Receiving Party without use of the Confidential Information; or (d) is required to be disclosed by law, court order, or regulatory authority, provided that the Receiving Party gives the Disclosing Party prompt notice and cooperates in any effort to seek a protective order.

7.4 The obligations of confidentiality shall survive termination or expiry of this Agreement for a period of five (5) years.

## 8. Data Protection

8.1 Where this Agreement involves the processing of Personal Data, the Parties shall comply with the PDPL and any sector-specific data protection regulations applicable to the processing.

8.2 The Party acting as Data Processor shall: (a) process Personal Data only on documented instructions from the Data Controller; (b) implement appropriate technical and organisational measures to safeguard the Personal Data; (c) ensure that personnel authorised to process Personal Data are bound by confidentiality obligations; and (d) assist the Data Controller in fulfilling its obligations under the PDPL.

8.3 In the event of a Personal Data breach, the affected Party shall notify the other Party without undue delay and in any event within seventy-two (72) hours of becoming aware of the breach.

## 9. Warranties and Representations

9.1 Each Party warrants and represents to the other that: (a) it has full power and authority to enter into and perform this Agreement; (b) the execution and performance of this Agreement do not contravene any law, regulation, or agreement to which it is subject; and (c) it has obtained all necessary consents, licences, and approvals to perform its obligations under this Agreement.

9.2 The Company warrants that the work performed under this Agreement shall be free from material defects in workmanship for a period of ninety (90) days following acceptance.

9.3 EXCEPT AS EXPRESSLY SET OUT IN THIS AGREEMENT, NEITHER PARTY MAKES ANY WARRANTY, EXPRESS OR IMPLIED, INCLUDING WARRANTIES OF MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE.

## 10. Limitation of Liability

10.1 Subject to Clause 10.2, the total aggregate liability of each Party arising out of or in connection with this Agreement, whether in contract, tort (including negligence), or otherwise, shall not exceed the total amount paid or payable by the Counterparty to the Company under this Agreement during the twelve (12) months preceding the event giving rise to the claim.

10.2 Nothing in this Agreement shall exclude or limit either Party's liability for: (a) death or personal injury caused by its negligence; (b) fraud or fraudulent misrepresentation; (c) breach of confidentiality under Clause 7; (d) breach of the data protection obligations under Clause 8; or (e) any other liability that cannot be excluded by applicable law.

10.3 NEITHER PARTY SHALL BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, OR CONSEQUENTIAL LOSSES, INCLUDING LOSS OF PROFIT, REVENUE, BUSINESS, GOODWILL, OR ANTICIPATED SAVINGS.

## 11. Termination

11.1 Either Party may terminate this Agreement: (a) for convenience, on ninety (90) days' prior written notice; or (b) immediately, for the other Party's material breach that is incapable of remedy, or that is not remedied within thirty (30) days of written notice.

11.2 Either Party may terminate this Agreement immediately if the other Party becomes insolvent, enters into liquidation, has a receiver appointed, or ceases to carry on business.

11.3 On termination: (a) all rights and obligations of the Parties shall cease except those that expressly survive; (b) the Counterparty shall pay all undisputed Fees up to the date of termination; (c) each Party shall return or destroy the Confidential Information of the other; and (d) Clauses 6, 7, 8, 9, 10, 11, 12, 13, and 14 shall survive.

## 12. Force Majeure

12.1 Neither Party shall be liable for any delay or failure to perform its obligations under this Agreement to the extent caused by an event beyond its reasonable control, including acts of God, war, terrorism, civil commotion, governmental action, pandemic, epidemic, embargo, or natural disaster (each a "Force Majeure Event").

12.2 The affected Party shall promptly notify the other Party of the occurrence of a Force Majeure Event and shall use reasonable endeavours to mitigate its effect and to resume performance as soon as reasonably practicable.

12.3 If a Force Majeure Event continues for more than ninety (90) consecutive days, either Party may terminate this Agreement on written notice without further liability except for amounts due up to the date of termination.

## 13. Governing Law and Dispute Resolution

13.1 This Agreement and any dispute arising out of or in connection with it shall be governed by and construed in accordance with the laws of the United Arab Emirates as applied in the Emirate of Dubai.

13.2 The Parties shall use reasonable endeavours to resolve any dispute amicably through senior-management negotiation. If a dispute is not resolved within thirty (30) days of being raised, either Party may refer the dispute to mediation administered by the DIFC-LCIA Arbitration Centre under its Mediation Rules.

13.3 If the dispute is not resolved by mediation within sixty (60) days, the dispute shall be finally resolved by arbitration administered by the DIFC-LCIA Arbitration Centre under its Arbitration Rules. The seat of arbitration shall be the Dubai International Financial Centre. The language shall be English. The number of arbitrators shall be one (1).

## 14. General Provisions

14.1 **Entire Agreement.** This Agreement constitutes the entire agreement between the Parties regarding its subject matter and supersedes all prior negotiations, representations, and agreements.

14.2 **Variation.** No variation shall be effective unless in writing and signed by both Parties.

14.3 **Assignment.** Neither Party may assign this Agreement without the prior written consent of the other, not to be unreasonably withheld; provided that either Party may assign to an affiliate or to a successor in connection with a merger or sale of substantially all assets, on prior notice.

14.4 **Notices.** All notices shall be in writing and delivered by hand, registered post, or email to the addresses notified by the Parties.

14.5 **Severability.** If any provision is held invalid or unenforceable, the remaining provisions shall continue in full force and effect.

14.6 **No Waiver.** No failure or delay by either Party in exercising any right shall operate as a waiver of that right.

14.7 **Counterparts.** This Agreement may be executed in counterparts, each of which shall be deemed an original.

14.8 **Language.** This Agreement is executed in English and Arabic. In the event of any inconsistency, the **Arabic** version shall prevail in accordance with Article 5 of the UAE Civil Transactions Law.

---

**EXECUTED on the Effective Date:**

**Musanad Technologies FZ-LLC**
By: ____________________________
Title: ____________________________
Signature: ________________________

**${counterparty_en}**
By: ____________________________
Title: ____________________________
Signature: ________________________`,
    ar: `## التمهيد

أُبرمت هذه ${typeLabelAr} (يُشار إليها بـ"الاتفاقية")، رقم المرجع ${contract_number}، وأصبحت سارية المفعول اعتبارًا من ${start_date} (يُشار إلى ذلك التاريخ بـ"تاريخ النفاذ")، بين **شركة مُسنَد للتكنولوجيا ذ.م.م المنطقة الحرة** (يُشار إليها فيما بعد بـ"مُسنَد" أو "الشركة")، وهي شركة محدودة المسؤولية مرخصة من سلطة مركز دبي للسلع المتعددة، تحمل الرخصة التجارية رقم DMCC-181452، وبين **${counterparty_ar}** (يُشار إليه بـ"الطرف المقابل")، ويُشار إلى كل منهما بـ"الطرف" ومجتمعَين بـ"الطرفان".

حيث يرغب الطرفان في إبرام هذه الاتفاقية وفقًا للشروط والأحكام المنصوص عليها أدناه؛

وحيث تُفسَّر هذه الاتفاقية وفقًا لقوانين دولة الإمارات العربية المتحدة واللوائح القطاعية المعمول بها؛

عليه، ونظير الالتزامات المتبادلة الواردة في هذه الاتفاقية، اتفق الطرفان على ما يلي:

## 1. التعريفات والتفسير

1.1 في هذه الاتفاقية، ما لم يقتضِ السياق غير ذلك:

  - **"الاتفاقية"** تعني هذه ${typeLabelAr} وجميع الجداول والمرفقات المُلحَقة بها؛
  - **"يوم العمل"** يعني أي يوم غير الجمعة أو السبت أو عطلة رسمية في دولة الإمارات العربية المتحدة؛
  - **"المعلومات السرية"** لها المعنى المعطى لها في البند 7؛
  - **"تاريخ النفاذ"** يعني التاريخ المُبيَّن في صدر هذه الاتفاقية؛
  - **"حدث القوة القاهرة"** له المعنى المعطى له في البند 12؛
  - **"البيانات الشخصية"** لها المعنى المعطى لها في المرسوم بقانون اتحادي رقم 45 لسنة 2021 بشأن حماية البيانات الشخصية؛
  - **"المدة"** تعني الفترة من تاريخ النفاذ حتى ${end_date}، رهنًا بالإنهاء المبكر وفقًا لهذه الاتفاقية.

1.2 الكلمات المُستخدَمة بالمفرد تشمل الجمع والعكس بالعكس. والإشارات إلى بند هي إشارات إلى بند من هذه الاتفاقية. والعناوين هي للراحة فقط ولا تؤثر على التفسير.

1.3 الإشارات إلى التشريعات تشمل أي تشريع فرعي صادر بموجبها وأي تعديل أو إعادة سن أو استبدال لها.

## 2. الموضوع والنطاق

2.1 يُكلِّف الطرف المقابل الشركة بموجب هذا، وتقبل الشركة التكليف، بأداء الالتزامات الموصوفة في الجدول (أ) ("النطاق") وفقًا لشروط هذه الاتفاقية.

2.2 يجوز تعديل النطاق فقط باتفاق مكتوب من الطرفين، مُنفَّذ من قبل ممثلين مفوَّضين من كل طرف. وأي محاولة منفردة لتعديل النطاق تكون باطلة.

2.3 تؤدي الشركة التزاماتها بموجب هذه الاتفاقية بمهارة ورعاية وعناية معقولة، وفقًا للمعايير المهنية المقبولة عمومًا في الصناعة ذات الصلة، وبالامتثال لجميع القوانين واللوائح المعمول بها في دولة الإمارات العربية المتحدة.

## 3. المدة والتجديد

3.1 تبدأ هذه الاتفاقية من تاريخ النفاذ وتظل سارية المفعول حتى ${end_date} ("المدة الأولية")، ما لم يتم إنهاؤها مبكرًا وفقًا للبند 11.

3.2 عند انتهاء المدة الأولية، يجوز تجديد هذه الاتفاقية لمدة أو أكثر من فترات إضافية لمدة اثني عشر (12) شهرًا لكل منها باتفاق مكتوب متبادل، شريطة أن يقدم أي طرف إخطارًا بنية التجديد قبل ستين (60) يومًا على الأقل من انتهاء المدة الجارية.

3.3 الاستمرار في الأداء من قبل أي طرف بعد انتهاء المدة لا يشكّل تجديدًا في غياب اتفاق مكتوب.

## 4. المقابل وشروط الدفع

4.1 نظير أداء التزامات الشركة بموجب هذه الاتفاقية، يدفع الطرف المقابل للشركة مبلغًا إجماليًا قدره **${value_aed} درهم إماراتي**، بالإضافة إلى ضريبة القيمة المضافة حسب الاقتضاء.

4.2 يتم الدفع وفقًا لجدول المعالم الزمنية المنصوص عليه في الجدول (ب)، أو، حيث لا يوجد جدول معالم زمنية، شهريًا بأثر رجعي خلال ثلاثين (30) يومًا من استلام فاتورة صحيحة.

4.3 جميع المبالغ المستحقة بموجب هذه الاتفاقية لا تشمل ضريبة القيمة المضافة، التي تُفرَض حيث ينطبق وفقًا للمرسوم بقانون اتحادي رقم 8 لسنة 2017 بشأن ضريبة القيمة المضافة، وتكون مسؤولية الطرف المقابل.

4.4 يستحق التأخير في الدفع فائدة بنسبة اثني عشر بالمئة (12%) سنويًا، تُحسَب يوميًا على الرصيد المستحق من تاريخ الاستحقاق حتى تاريخ الدفع.

4.5 لا يحق للطرف المقابل المقاصة أو الخصم أو الاحتجاز أو تقليل أي مبلغ مستحق بموجب هذه الاتفاقية إلا إلى الحد المسموح به صراحة في هذه الاتفاقية أو الذي يقتضيه القانون.

## 5. معايير الأداء والإبلاغ

5.1 تؤدي الشركة التزاماتها بطريقة احترافية ومتقنة بما يتوافق مع أفضل ممارسات الصناعة وتبذل مساعي معقولة لتحقيق أي معالم زمنية أو مواعيد نهائية منصوص عليها في هذه الاتفاقية أو أي جدول ذي صلة.

5.2 تقدم الشركة للطرف المقابل تقارير تقدم شهرية تصف: (أ) العمل المُنفَّذ خلال فترة الإبلاغ؛ (ب) العمل المخطط للفترة التالية؛ (ج) أي مخاطر أو قضايا أو تبعيات قد تؤثر على الأداء؛ (د) أي قرارات أو موافقات مطلوبة من الطرف المقابل.

5.3 يوفر الطرف المقابل للشركة وصولًا في الوقت المناسب إلى جميع المعلومات والمباني والأفراد والموارد المطلوبة بشكل معقول لأداء التزامات الشركة.

5.4 إذا فشل الطرف المقابل في توفير هذا الوصول أو اتخاذ أي إجراء مطلوب منه بشكل معقول في الوقت المناسب، فلن تكون الشركة في حالة إخلال بهذه الاتفاقية إلى الحد الذي يتأخر فيه أو يُمنَع أداؤها من قبل هذا الفشل.

## 6. الملكية الفكرية

6.1 يحتفظ كل طرف بملكية جميع حقوق الملكية الفكرية التي يمتلكها قبل تاريخ النفاذ أو يطورها بشكل مستقل عن هذه الاتفاقية ("الملكية الفكرية الخلفية").

6.2 جميع حقوق الملكية الفكرية في أي نتاج عمل مُنشأ خصيصًا من قبل الشركة للطرف المقابل بموجب هذه الاتفاقية ("الملكية الفكرية الأمامية") تنتقل، عند السداد الكامل، إلى الطرف المقابل.

6.3 تحتفظ الشركة بملكية، ويُمنَح الطرف المقابل ترخيصًا دائمًا غير حصري وخاليًا من الإتاوات وعالميًا لاستخدام، أي منهجيات أو أُطُر أو أدوات سابقة الوجود تُدمَج في الملكية الفكرية الأمامية، فقط كجزء من الملكية الفكرية الأمامية.

6.4 يضمن كل طرف أن المواد التي يقدمها للطرف الآخر لا تنتهك حقوق الملكية الفكرية لأي طرف ثالث.

## 7. السرية

7.1 يحتفظ كل طرف ("الطرف المُتلَقي") بسرية صارمة لجميع المعلومات غير العامة المُفصَح عنها له من الطرف الآخر ("الطرف المُفصِح") التي تكون مُحدَّدة بأنها سرية أو يفهم الشخص المعقول أنها سرية ("المعلومات السرية").

7.2 يجب على الطرف المُتلَقي: (أ) استخدام المعلومات السرية فقط لغرض أداء التزاماته بموجب هذه الاتفاقية؛ (ب) تقييد الإفصاح للموظفين والوكلاء والمقاولين من الباطن الذين لديهم حاجة مشروعة للمعرفة والمُلتزمين بالتزامات سرية لا تقل حماية عن تلك المنصوص عليها في هذا البند 7؛ (ج) حماية المعلومات السرية باستخدام معيار رعاية معقول على الأقل.

7.3 لا تنطبق التزامات السرية على المعلومات التي: (أ) تكون أو تصبح متاحة للجمهور دون خطأ من الطرف المُتلَقي؛ (ب) كانت معروفة للطرف المُتلَقي بشكل صحيح قبل الإفصاح؛ (ج) تُطوَّر بشكل مستقل من قبل الطرف المُتلَقي دون استخدام المعلومات السرية؛ (د) يُطلَب الإفصاح عنها بموجب القانون أو أمر المحكمة أو السلطة التنظيمية، شريطة أن يقدم الطرف المُتلَقي للطرف المُفصِح إخطارًا فوريًا ويتعاون في أي جهد لطلب أمر حماية.

7.4 تستمر التزامات السرية بعد إنهاء أو انتهاء هذه الاتفاقية لمدة خمس (5) سنوات.

## 8. حماية البيانات

8.1 حيث تتضمن هذه الاتفاقية معالجة البيانات الشخصية، يلتزم الطرفان بقانون حماية البيانات الشخصية وأي لوائح حماية بيانات قطاعية معمول بها.

8.2 الطرف الذي يعمل كمعالج للبيانات يجب أن: (أ) يعالج البيانات الشخصية فقط بناءً على تعليمات موثقة من المتحكم في البيانات؛ (ب) ينفّذ تدابير تقنية وتنظيمية مناسبة لحماية البيانات الشخصية؛ (ج) يضمن أن الموظفين المخوّلين بمعالجة البيانات الشخصية مُلتَزمون بالتزامات السرية؛ (د) يساعد المتحكم في البيانات في الوفاء بالتزاماته بموجب قانون حماية البيانات الشخصية.

8.3 في حالة خرق البيانات الشخصية، يُخطِر الطرف المتأثر الطرف الآخر دون تأخير لا مبرر له وفي جميع الأحوال خلال اثنتين وسبعين (72) ساعة من إدراك الخرق.

## 9. الضمانات والإقرارات

9.1 يضمن كل طرف ويقر للآخر بأن: (أ) لديه السلطة والصلاحية الكاملة للدخول في وأداء هذه الاتفاقية؛ (ب) تنفيذ وأداء هذه الاتفاقية لا يتعارض مع أي قانون أو لائحة أو اتفاقية يخضع لها؛ (ج) قد حصل على جميع الموافقات والتراخيص والاعتمادات اللازمة لأداء التزاماته بموجب هذه الاتفاقية.

9.2 تضمن الشركة أن العمل المُنفَّذ بموجب هذه الاتفاقية سيكون خاليًا من العيوب الجوهرية في الصنعة لمدة تسعين (90) يومًا بعد القبول.

9.3 باستثناء ما هو منصوص عليه صراحة في هذه الاتفاقية، لا يقدم أي طرف أي ضمان، صريح أو ضمني، بما في ذلك ضمانات القابلية للتسويق أو الملاءمة لغرض معين.

## 10. تحديد المسؤولية

10.1 مع مراعاة البند 10.2، لا تتجاوز إجمالي المسؤولية الكلية لكل طرف الناشئة عن أو فيما يتعلق بهذه الاتفاقية، سواء في العقد أو الضرر (بما في ذلك الإهمال) أو غير ذلك، إجمالي المبلغ المدفوع أو المستحق من الطرف المقابل للشركة بموجب هذه الاتفاقية خلال الاثني عشر (12) شهرًا السابقة للحدث المُسبِّب للمطالبة.

10.2 لا يستثني أو يحد أي شيء في هذه الاتفاقية من مسؤولية أي طرف عن: (أ) الوفاة أو الإصابة الشخصية الناجمة عن إهماله؛ (ب) الاحتيال أو التحريف الاحتيالي؛ (ج) إخلال السرية بموجب البند 7؛ (د) إخلال التزامات حماية البيانات بموجب البند 8؛ (هـ) أي مسؤولية أخرى لا يمكن استثناؤها بموجب القانون المعمول به.

10.3 لا يتحمّل أي طرف مسؤولية عن أي خسائر غير مباشرة أو عرضية أو خاصة أو تبعية، بما في ذلك خسارة الربح أو الإيرادات أو الأعمال أو السمعة التجارية أو الوفورات المتوقعة.

## 11. الإنهاء

11.1 يجوز لأي طرف إنهاء هذه الاتفاقية: (أ) للملاءمة، بإخطار مكتوب مسبق لمدة تسعين (90) يومًا؛ (ب) فورًا، بسبب إخلال جوهري من الطرف الآخر لا يمكن علاجه، أو لم يُعالَج خلال ثلاثين (30) يومًا من الإخطار المكتوب.

11.2 يجوز لأي طرف إنهاء هذه الاتفاقية فورًا إذا أصبح الطرف الآخر معسرًا أو دخل في تصفية أو تم تعيين حارس قضائي أو توقف عن مزاولة الأعمال.

11.3 عند الإنهاء: (أ) تتوقف جميع حقوق والتزامات الطرفين باستثناء ما يستمر صراحة؛ (ب) يدفع الطرف المقابل جميع الأتعاب غير المتنازع عليها حتى تاريخ الإنهاء؛ (ج) يقوم كل طرف بإعادة أو إتلاف المعلومات السرية للآخر؛ (د) تستمر البنود 6 و7 و8 و9 و10 و11 و12 و13 و14.

## 12. القوة القاهرة

12.1 لا يتحمّل أي طرف مسؤولية أي تأخير أو فشل في أداء التزاماته بموجب هذه الاتفاقية إلى الحد الناجم عن حدث خارج عن سيطرته المعقولة، بما في ذلك القضاء والقدر والحرب والإرهاب والاضطرابات المدنية والإجراءات الحكومية والوباء أو الأوبئة والحظر أو الكوارث الطبيعية (يُشار إلى كل منها بـ"حدث القوة القاهرة").

12.2 يُخطِر الطرف المتأثر فورًا الطرف الآخر بحدوث حدث القوة القاهرة ويبذل مساعي معقولة لتخفيف أثره واستئناف الأداء في أقرب وقت ممكن عمليًا.

12.3 إذا استمر حدث القوة القاهرة لأكثر من تسعين (90) يومًا متتاليًا، يجوز لأي طرف إنهاء هذه الاتفاقية بإخطار مكتوب دون أي مسؤولية أخرى باستثناء المبالغ المستحقة حتى تاريخ الإنهاء.

## 13. القانون الحاكم وحل النزاعات

13.1 تخضع هذه الاتفاقية وأي نزاع ناشئ عن أو فيما يتعلق بها لقوانين دولة الإمارات العربية المتحدة كما هي مُطبَّقة في إمارة دبي وتُفسَّر وفقًا لها.

13.2 يبذل الطرفان مساعي معقولة لحل أي نزاع وديًا من خلال التفاوض على مستوى الإدارة العليا. إذا لم يتم حل النزاع خلال ثلاثين (30) يومًا من رفعه، يجوز لأي طرف إحالة النزاع إلى الوساطة التي يديرها مركز التحكيم DIFC-LCIA بموجب قواعد الوساطة الخاصة به.

13.3 إذا لم يتم حل النزاع بالوساطة خلال ستين (60) يومًا، يُحَل النزاع نهائيًا بالتحكيم الذي يديره مركز التحكيم DIFC-LCIA بموجب قواعد التحكيم الخاصة به. ويكون مقر التحكيم مركز دبي المالي العالمي. واللغة هي الإنجليزية. ويكون عدد المحكمين واحدًا (1).

## 14. أحكام عامة

14.1 **الاتفاقية الكاملة.** تُشكّل هذه الاتفاقية الاتفاقية الكاملة بين الطرفين فيما يتعلق بموضوعها وتحل محل جميع المفاوضات والتمثيلات والاتفاقيات السابقة.

14.2 **التعديل.** لا يكون أي تعديل ساريًا ما لم يكن مكتوبًا وموقَّعًا من كلا الطرفين.

14.3 **التنازل.** لا يجوز لأي طرف التنازل عن هذه الاتفاقية دون الموافقة المكتوبة المسبقة من الآخر، على ألا تُحجَب بشكل غير معقول؛ شريطة أنه يجوز لأي طرف التنازل لشركة تابعة أو لخلف فيما يتعلق بدمج أو بيع جميع أصوله تقريبًا، بإخطار مسبق.

14.4 **الإخطارات.** تكون جميع الإخطارات مكتوبة وتُسلَّم باليد أو بالبريد المسجَّل أو بالبريد الإلكتروني إلى العناوين التي يُخطِر بها الطرفان.

14.5 **الفصل.** إذا اعتُبر أي حكم باطلًا أو غير قابل للتنفيذ، تستمر الأحكام المتبقية بكامل قوتها وتأثيرها.

14.6 **عدم التنازل.** لا يُشكّل أي فشل أو تأخير من أي طرف في ممارسة أي حق تنازلًا عن ذلك الحق.

14.7 **النسخ.** يجوز تنفيذ هذه الاتفاقية في نسخ، تكون كل منها أصلية.

14.8 **اللغة.** هذه الاتفاقية مُنفَّذة بالإنجليزية والعربية. وفي حالة أي تعارض، تسود **النسخة العربية** وفقًا للمادة 5 من قانون المعاملات المدنية الإماراتي.

---

**نُفِّذت في تاريخ النفاذ:**

**شركة مُسنَد للتكنولوجيا ذ.م.م المنطقة الحرة**
بواسطة: ____________________________
المنصب: ____________________________
التوقيع: ____________________________

**${counterparty_ar}**
بواسطة: ____________________________
المنصب: ____________________________
التوقيع: ____________________________`,
  };
}

const TYPE_LABELS_EN: Record<string, string> = {
  master_services: 'Master Services Agreement',
  service: 'Service Agreement',
  advisory: 'Advisory Services Agreement',
  sow: 'Statement of Work',
  supply: 'Supply Agreement',
  concession: 'Concession Agreement',
  nda: 'Non-Disclosure Agreement',
};
const TYPE_LABELS_AR: Record<string, string> = {
  master_services: 'الاتفاقية الرئيسية للخدمات',
  service: 'اتفاقية الخدمات',
  advisory: 'اتفاقية الخدمات الاستشارية',
  sow: 'بيان العمل',
  supply: 'اتفاقية التوريد',
  concession: 'اتفاقية الامتياز',
  nda: 'اتفاقية عدم الإفصاح',
};

function buildBody(row: ContractRow): { en: string; ar: string } {
  const args: BodyArgs = {
    contract_number: row.contract_number,
    counterparty_en: row.counterparty_name,
    counterparty_ar: row.counterparty_name_ar ?? row.counterparty_name,
    value_aed: row.value_aed ? Number(row.value_aed).toLocaleString('en-US', { maximumFractionDigits: 0 }) : 'N/A',
    start_date: row.start_date ?? 'TBD',
    end_date: row.end_date ?? 'TBD',
  };
  if (row.contract_type === 'master_services') return masterServices(args);
  return genericLegalContract(
    TYPE_LABELS_EN[row.contract_type] ?? 'Agreement',
    TYPE_LABELS_AR[row.contract_type] ?? 'الاتفاقية',
    args,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const dbUrl = process.env.DATABASE_URL;
  if (!dbUrl) throw new Error('DATABASE_URL is not set');
  const pool = new Pool({ connectionString: dbUrl });
  try {
    const { rows } = await pool.query<ContractRow>(`
      SELECT
        c.id,
        c.contract_number,
        c.contract_type,
        c.status,
        c.value_aed,
        TO_CHAR(c.start_date, 'YYYY-MM-DD') AS start_date,
        TO_CHAR(c.end_date,   'YYYY-MM-DD') AS end_date,
        COALESCE(p.name_en, 'Unknown Counterparty') AS counterparty_name,
        p.name_ar AS counterparty_name_ar
      FROM contract c
      LEFT JOIN party p ON p.id = c.counterparty_id
      WHERE c.drafted_by = 5
        AND c.is_active  = TRUE
        AND (c.body_en IS NULL OR LENGTH(c.body_en) < 1000)
      ORDER BY c.id
    `);
    console.log(`Will populate body on ${rows.length} contracts.`);
    for (const row of rows) {
      const body = buildBody(row);
      await pool.query(
        'UPDATE contract SET body_en = $1, body_ar = $2, updated_at = NOW(), updated_by = 5 WHERE id = $3',
        [body.en, body.ar, row.id],
      );
      console.log(`  ✓ ${row.contract_number} (${row.contract_type}) — en=${body.en.length} ar=${body.ar.length}`);
    }
    console.log('Done.');
  } finally {
    await pool.end();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
