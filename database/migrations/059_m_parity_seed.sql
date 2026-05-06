-- ============================================================================
-- 059_m_parity_seed.sql
-- ============================================================================
-- Module:    M_parity (Lovable feature-depth parity polish)
-- Owner:     Direct work — no orchestrator pipeline
-- Depends:   058 (party + contract_template + contract_clause + contract_obligation)
-- ----------------------------------------------------------------------------
-- Seeds 12 UAE counterparties, 8 contract templates, 18 reusable clauses,
-- and 25+ obligations derived from existing payment_schedule rows.
-- Wires existing contracts to counterparties + templates so the executive
-- dashboard's top-counterparties stops being empty.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. Parties (12 UAE counterparties + 1 our_party)
-- ============================================================================
INSERT INTO party (party_type, name_en, name_ar, trade_license_number, trade_license_issuer, emirate, free_zone, country, contact_email, contact_phone, registered_address, is_seed, created_by, updated_by)
VALUES
  ('company', 'Musanad Technologies FZ-LLC', 'مُسنَد للتقنيات', 'DSO-12345', 'Dubai Silicon Oasis Authority', 'dubai', 'Dubai Silicon Oasis', 'United Arab Emirates', 'legal@musanad.ae', '+971-4-555-0001', 'DSO HQ Building, Dubai', TRUE, 1, 1),
  ('company', 'ADNOC Distribution PJSC', 'أدنوك للتوزيع', 'AD-100023', 'Abu Dhabi Department of Economic Development', 'abu_dhabi', NULL, 'United Arab Emirates', 'contracts@adnocdistribution.ae', '+971-2-606-0000', 'Corniche Road, Abu Dhabi', TRUE, 1, 1),
  ('company', 'Emirates NBD Bank PJSC', 'بنك الإمارات دبي الوطني', 'CN-100450', 'Dubai Department of Economic Development', 'dubai', NULL, 'United Arab Emirates', 'corporate@emiratesnbd.com', '+971-4-316-0316', 'Baniyas Road, Deira, Dubai', TRUE, 1, 1),
  ('company', 'Mubadala Investment Company', 'مبادلة', 'AD-200145', 'Abu Dhabi Global Market', 'abu_dhabi', 'ADGM', 'United Arab Emirates', 'partnerships@mubadala.ae', '+971-2-413-0000', 'Al Maryah Island, Abu Dhabi', TRUE, 1, 1),
  ('company', 'DEWA — Dubai Electricity & Water Authority', 'هيئة كهرباء ومياه دبي', 'DEWA-001', 'Dubai Government', 'dubai', NULL, 'United Arab Emirates', 'procurement@dewa.gov.ae', '+971-4-601-9999', 'Al Wasl Road, Dubai', TRUE, 1, 1),
  ('company', 'Etisalat Group (e&)', 'مجموعة اتصالات', 'AD-099812', 'Abu Dhabi Department of Economic Development', 'abu_dhabi', NULL, 'United Arab Emirates', 'enterprise@etisalat.ae', '+971-2-628-3333', 'Etisalat HQ, Abu Dhabi', TRUE, 1, 1),
  ('company', 'IBM Middle East FZ-LLC', 'IBM الشرق الأوسط', 'DIC-87231', 'Dubai Internet City', 'dubai', 'Dubai Internet City', 'United Arab Emirates', 'mea-contracts@ibm.com', '+971-4-441-7000', 'IBM Building, DIC', TRUE, 1, 1),
  ('company', 'Microsoft (Azure UAE) FZ-LLC', 'مايكروسوفت', 'DIC-67124', 'Dubai Internet City', 'dubai', 'Dubai Internet City', 'United Arab Emirates', 'azureuae@microsoft.com', '+971-4-446-1111', 'DIC, Dubai', TRUE, 1, 1),
  ('company', 'Galadari Brothers Group', 'مجموعة الجلاداري', 'CN-067890', 'Dubai Department of Economic Development', 'dubai', NULL, 'United Arab Emirates', 'legal@galadari.ae', '+971-4-235-0000', 'Garhoud, Dubai', TRUE, 1, 1),
  ('company', 'Crescent Petroleum Company', 'كريسنت بتروليوم', 'SH-432198', 'Sharjah Economic Development', 'sharjah', NULL, 'United Arab Emirates', 'admin@crescent-petroleum.com', '+971-6-528-1111', 'Crescent Tower, Sharjah', TRUE, 1, 1),
  ('individual', 'Dr. Khalid bin Saeed', 'د. خالد بن سعيد', NULL, NULL, 'dubai', NULL, 'United Arab Emirates', 'k.saeed@advisory.ae', '+971-50-555-0011', 'Downtown Dubai', TRUE, 1, 1),
  ('individual', 'Aisha Al Marri', 'عائشة المري', NULL, NULL, 'abu_dhabi', NULL, 'United Arab Emirates', 'aisha.almarri@consultant.ae', '+971-50-555-0022', 'Al Reem Island, Abu Dhabi', TRUE, 1, 1),
  ('company', 'Digital DEWA Innovation Centre', 'مركز ديوا الرقمي للابتكار', 'DEWA-DIG-001', 'Dubai Government', 'dubai', NULL, 'United Arab Emirates', 'innovation@dewa.gov.ae', '+971-4-601-2222', 'Al Wasl, Dubai', TRUE, 1, 1)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 2. Templates (8 reusable contract templates)
-- ============================================================================
INSERT INTO contract_template (name_en, name_ar, contract_type, description_en, description_ar, body_en, body_ar, language, regulatory_tags, usage_count, is_seed, created_by, updated_by)
VALUES
  ('MoHRE Fixed-Term Employment Contract', 'عقد عمل محدد المدة - وزارة الموارد البشرية', 'employment', 'Standard MoHRE-aligned fixed-term employment contract for UAE private sector employers. Bilingual (AR/EN). Compliant with Federal Decree-Law 33 of 2021.', 'عقد عمل محدد المدة متوافق مع وزارة الموارد البشرية', 'EMPLOYMENT CONTRACT (Fixed Term)\n\nThis Employment Contract ("Contract") is entered into on [Date] between [Employer Name] (the "Employer") and [Employee Name] (the "Employee").\n\n1. POSITION AND DUTIES\nThe Employee shall serve as [Job Title] reporting to [Manager Name].\n\n2. TERM\nThis Contract shall commence on [Start Date] and remain in effect for [Duration] years, unless terminated earlier in accordance with applicable law.\n\n3. COMPENSATION\nBasic salary: AED [Amount] per month. Allowances: housing, transport, and other benefits as per Schedule A.\n\n4. PROBATION\nEmployee shall serve a probation period of six (6) months from the Start Date.\n\n5. WORKING HOURS\nForty-eight (48) hours per week, Sunday through Thursday.\n\n6. ANNUAL LEAVE\nThirty (30) calendar days per year accrued from the Start Date.\n\n7. END OF SERVICE\nIn accordance with Federal Decree-Law 33 of 2021.\n\n8. JURISDICTION\nUAE Federal Law shall govern this Contract.', NULL, 'bilingual', ARRAY['mohre','federal_decree_law_33_2021','employment'], 18, TRUE, 1, 1),
  ('Mutual Non-Disclosure Agreement (Bilingual)', 'اتفاقية عدم إفصاح متبادلة', 'nda', 'Bilingual mutual NDA suitable for evaluating business opportunities, partnerships, and information exchange.', 'اتفاقية عدم إفصاح متبادلة باللغتين العربية والإنجليزية', 'MUTUAL NON-DISCLOSURE AGREEMENT\n\nThis Mutual Non-Disclosure Agreement ("Agreement") is entered into on [Date] between [Party A] and [Party B] (collectively the "Parties").\n\n1. CONFIDENTIAL INFORMATION\nAny non-public information disclosed by one Party ("Disclosing Party") to the other ("Receiving Party"), in writing, orally, or otherwise, that is marked or reasonably understood to be confidential.\n\n2. OBLIGATIONS\nThe Receiving Party shall: (a) maintain the Confidential Information in strict confidence; (b) use it solely to evaluate the Purpose; (c) not disclose to any third party without prior written consent.\n\n3. EXCLUSIONS\nNothing herein restricts information that: (i) is publicly available; (ii) was rightfully known prior to disclosure; (iii) is independently developed.\n\n4. TERM\nObligations survive for three (3) years after termination.\n\n5. GOVERNING LAW\nUAE Federal Law and the courts of [Emirate].', NULL, 'bilingual', ARRAY['nda','confidentiality'], 24, TRUE, 1, 1),
  ('Vendor Services Agreement', 'اتفاقية خدمات المورّد', 'vendor_services', 'General-purpose vendor / supplier services agreement with deliverables, milestones, and SLAs.', 'اتفاقية خدمات شاملة للموردين', 'VENDOR SERVICES AGREEMENT\n\n1. SERVICES\nThe Vendor shall provide the services described in Schedule A ("Services").\n\n2. DELIVERABLES\nDeliverables shall be completed per the milestone schedule in Schedule B.\n\n3. SLAs\nVendor commits to the service levels in Schedule C, including response and resolution times.\n\n4. FEES AND PAYMENT\nPayment per Schedule D milestones, net 30 days from invoice.\n\n5. INTELLECTUAL PROPERTY\nAll deliverables produced under this Agreement vest in the Customer upon final payment.\n\n6. TERMINATION\nEither party may terminate for material breach with 30 days written notice.\n\n7. GOVERNING LAW\nUAE Federal Law.', NULL, 'en', ARRAY['vendor','sla','procurement'], 19, TRUE, 1, 1),
  ('Master Services Agreement (MSA)', 'اتفاقية الخدمات الرئيسية', 'msa', 'Umbrella MSA enabling future Statements of Work (SOWs) without re-negotiating terms.', 'اتفاقية رئيسية تتيح إصدار بيانات عمل لاحقة', 'MASTER SERVICES AGREEMENT\n\nThis MSA governs all Statements of Work ("SOWs") issued under it. SOWs incorporate by reference these terms.\n\n1. SCOPE\nServices to be defined in individual SOWs.\n\n2. PRICING\nPer SOW; SOWs may add to or modify rates.\n\n3. WARRANTIES\nServices performed in workmanlike manner; deliverables conform to specifications.\n\n4. INDEMNITY\nEach party indemnifies the other against third-party IP claims arising from its own materials.\n\n5. LIMITATION OF LIABILITY\nLiability cap = greater of fees paid in the 12 months preceding the claim or AED 500,000.\n\n6. TERM\nThis MSA renews annually unless terminated with 60 days notice.', NULL, 'en', ARRAY['msa','sow','umbrella'], 11, TRUE, 1, 1),
  ('Consultancy Services Agreement', 'اتفاقية خدمات استشارية', 'consultancy', 'Independent consultant engagement covering scope, deliverables, fees, and IP.', 'اتفاقية تعاقد مع مستشار مستقل', 'CONSULTANCY SERVICES AGREEMENT\n\n1. SCOPE OF WORK\nConsultant shall deliver the advisory services in Schedule A.\n\n2. INDEPENDENCE\nConsultant is an independent contractor; no employer-employee relationship is created.\n\n3. FEES\nFee: AED [Amount] payable in [installments] tranches as per Schedule B.\n\n4. CONFIDENTIALITY\nMutual confidentiality survives for two (2) years post-termination.\n\n5. WORK PRODUCT\nAll deliverables and materials prepared in connection with this engagement vest in the Client.\n\n6. TERM AND TERMINATION\nDuration: [N months]. Either party may terminate with 14 days notice.\n\n7. GOVERNING LAW\nLaws of the United Arab Emirates.', NULL, 'en', ARRAY['consulting','independent_contractor'], 9, TRUE, 1, 1),
  ('LLC Incorporation Agreement', 'اتفاقية تأسيس شركة ذات مسؤولية محدودة', 'llc_incorporation', 'Multi-shareholder LLC incorporation agreement compliant with Federal Decree-Law 32 of 2021 (Commercial Companies Law).', 'اتفاقية تأسيس متوافقة مع قانون الشركات التجارية', 'LIMITED LIABILITY COMPANY INCORPORATION AGREEMENT\n\n1. NAME\nThe Company shall be incorporated as [Company Name] LLC.\n\n2. SHAREHOLDERS\n[Shareholder list with capital contributions]\n\n3. CAPITAL\nTotal authorized capital: AED [Amount], divided into [N] equity shares.\n\n4. MANAGEMENT\nThe Company shall be managed by a Manager appointed by majority shareholder vote.\n\n5. PROFIT DISTRIBUTION\nProfits distributed pro-rata to capital contributions, after retention of mandatory legal reserve (10%).\n\n6. TRANSFER OF SHARES\nSubject to right of first refusal among existing shareholders.\n\n7. DISSOLUTION\nPer Federal Decree-Law 32 of 2021 articles 287-301.', NULL, 'en', ARRAY['llc','federal_decree_law_32_2021','incorporation'], 6, TRUE, 1, 1),
  ('Distribution Agreement', 'اتفاقية توزيع', 'distribution', 'Exclusive or non-exclusive distribution agreement aligned with UAE Commercial Agencies Law.', 'اتفاقية توزيع متوافقة مع قانون الوكالات التجارية', 'DISTRIBUTION AGREEMENT\n\n1. APPOINTMENT\nPrincipal appoints Distributor as [exclusive/non-exclusive] distributor for the Territory.\n\n2. TERRITORY\n[Defined territory].\n\n3. PRODUCTS\n[Defined product range].\n\n4. ORDERING AND PAYMENT\nDistributor places orders against Principals price list. Payment terms: [30/60] days.\n\n5. MARKETING\nDistributor commits to minimum marketing spend of [%] of net sales.\n\n6. PERFORMANCE TARGETS\nMinimum annual purchase quotas as set out in Schedule A.\n\n7. TERMINATION\nUAE Federal Law 13 of 2006 (Commercial Agencies Law) compensation rules apply.', NULL, 'en', ARRAY['distribution','commercial_agencies'], 5, TRUE, 1, 1),
  ('Real Estate Lease Agreement (Tenancy Contract)', 'عقد إيجار', 'lease', 'Standard tenancy contract aligned with Dubai Law 26 of 2007 and Abu Dhabi Tawtheeq.', 'عقد إيجار متوافق مع قوانين الإمارات', 'TENANCY CONTRACT\n\n1. PARTIES\nLandlord: [Name]. Tenant: [Name].\n\n2. PREMISES\n[Address, area, type].\n\n3. TERM\nFrom [Start] to [End]. Renewable by mutual agreement.\n\n4. RENT\nAED [Amount] payable in [N] cheques annually.\n\n5. SECURITY DEPOSIT\nEquivalent to one (1) month rent, refundable upon end of tenancy minus deductions for damage.\n\n6. MAINTENANCE\nLandlord responsible for major maintenance; Tenant for minor repairs and AC servicing.\n\n7. EJARI / TAWTHEEQ\nLandlord shall register this contract with [Ejari (Dubai) / Tawtheeq (Abu Dhabi)] within 30 days.', NULL, 'en', ARRAY['lease','tenancy','ejari','tawtheeq'], 7, TRUE, 1, 1)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 3. Clauses (18 reusable clauses)
-- ============================================================================
INSERT INTO contract_clause (category, title_en, title_ar, body_en, body_ar, variant, regulatory_refs, usage_count, is_seed, created_by, updated_by)
VALUES
  ('confidentiality', 'Mutual Confidentiality (Standard)', 'السرية المتبادلة', 'Each Party shall hold in confidence all non-public information of the other Party and shall not use it except for the purposes contemplated by this Agreement. The obligation survives termination for three (3) years.', NULL, 'standard', ARRAY['nda','data_protection'], 31, TRUE, 1, 1),
  ('confidentiality', 'One-Way Confidentiality (Disclosing Party)', 'سرية أحادية الاتجاه', 'The Receiving Party shall hold in confidence all Confidential Information disclosed by the Disclosing Party and shall not use such information for any purpose other than the Permitted Use without the prior written consent of the Disclosing Party.', NULL, 'alternative', ARRAY['nda'], 8, TRUE, 1, 1),
  ('payment', 'Net 30 Payment Terms', 'شروط الدفع 30 يومًا', 'All invoices shall be paid within thirty (30) days of receipt. Late payments accrue interest at 1.5% per month or the maximum rate permitted by UAE law, whichever is lower.', NULL, 'standard', ARRAY['payment'], 27, TRUE, 1, 1),
  ('payment', 'Milestone-Based Payment', 'الدفع على أساس المعالم', 'Payment shall be made against achievement of milestones set forth in Schedule B. Each milestone shall be invoiced upon completion and acceptance.', NULL, 'alternative', ARRAY['payment','milestone'], 14, TRUE, 1, 1),
  ('termination', 'Termination for Convenience (30 Days)', 'الإنهاء للراحة', 'Either Party may terminate this Agreement for convenience upon thirty (30) days prior written notice to the other Party. Pro-rata fees for completed work shall be paid up to the effective termination date.', NULL, 'standard', ARRAY['termination'], 22, TRUE, 1, 1),
  ('termination', 'Termination for Material Breach (Cure Period)', 'الإنهاء بسبب إخلال جوهري', 'Either Party may terminate this Agreement immediately upon written notice if the other Party materially breaches a provision and fails to cure such breach within fifteen (15) business days of receipt of written notice.', NULL, 'standard', ARRAY['termination','breach'], 19, TRUE, 1, 1),
  ('liability', 'Limitation of Liability (Cap = Annual Fees)', 'تحديد المسؤولية', 'Except for liability arising from fraud, willful misconduct, or breach of confidentiality, the aggregate liability of either Party shall not exceed the total fees paid or payable under this Agreement in the twelve (12) months preceding the claim.', NULL, 'standard', ARRAY['liability'], 25, TRUE, 1, 1),
  ('liability', 'Mutual Indemnity (IP)', 'تعويض متبادل عن الملكية الفكرية', 'Each Party shall indemnify, defend, and hold harmless the other Party from any third-party claim alleging that the indemnifying Partys materials infringe any intellectual property right.', NULL, 'standard', ARRAY['ip','indemnity'], 16, TRUE, 1, 1),
  ('governing_law', 'UAE Federal Law (Standard)', 'القانون الفيدرالي للإمارات', 'This Agreement shall be governed by and construed in accordance with the laws of the United Arab Emirates. The courts of [Emirate] shall have exclusive jurisdiction over any dispute arising out of or in connection with this Agreement.', NULL, 'standard', ARRAY['governing_law'], 38, TRUE, 1, 1),
  ('governing_law', 'DIFC Courts and Law', 'محاكم وقوانين مركز دبي المالي', 'This Agreement shall be governed by DIFC law and the parties submit to the exclusive jurisdiction of the DIFC Courts.', NULL, 'alternative', ARRAY['governing_law','difc'], 6, TRUE, 1, 1),
  ('governing_law', 'ADGM Arbitration', 'تحكيم سوق أبوظبي العالمي', 'Any dispute arising out of or in connection with this Agreement shall be referred to and finally resolved by arbitration under the ADGM Arbitration Rules. The seat of arbitration shall be Abu Dhabi Global Market.', NULL, 'alternative', ARRAY['governing_law','adgm','arbitration'], 4, TRUE, 1, 1),
  ('data_protection', 'UAE PDPL Compliance', 'الامتثال لقانون حماية البيانات', 'Each Party shall comply with Federal Decree-Law 45 of 2021 on the Protection of Personal Data (UAE PDPL) when processing personal data under this Agreement, including lawful basis, security measures, breach notification, and data subject rights.', NULL, 'standard', ARRAY['pdpl','data_protection','federal_decree_law_45_2021'], 20, TRUE, 1, 1),
  ('intellectual_property', 'Background IP and Foreground IP', 'الملكية الفكرية الأساسية والمستحدثة', 'Each Party retains ownership of its Background IP. Foreground IP created in the course of this Agreement vests in the Client upon payment in full of the applicable fees.', NULL, 'standard', ARRAY['ip'], 17, TRUE, 1, 1),
  ('warranties', 'Workmanlike Performance', 'الأداء المهني', 'The Vendor warrants that the Services shall be performed in a professional and workmanlike manner consistent with industry standards.', NULL, 'standard', ARRAY['warranties'], 21, TRUE, 1, 1),
  ('warranties', 'Disclaimer of Implied Warranties', 'تنصل من الضمانات الضمنية', 'EXCEPT AS EXPRESSLY SET FORTH HEREIN, ALL WARRANTIES, INCLUDING IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, ARE DISCLAIMED.', NULL, 'fallback', ARRAY['warranties'], 9, TRUE, 1, 1),
  ('force_majeure', 'Force Majeure (Standard)', 'القوة القاهرة', 'Neither Party shall be liable for delay or failure to perform any obligation under this Agreement caused by events beyond its reasonable control, including acts of God, war, terrorism, pandemic, government action, or natural disaster.', NULL, 'standard', ARRAY['force_majeure'], 18, TRUE, 1, 1),
  ('assignment', 'No Assignment Without Consent', 'عدم التنازل بدون موافقة', 'Neither Party may assign this Agreement without the prior written consent of the other Party, except to an affiliate or successor in connection with a merger or sale of all or substantially all of its assets.', NULL, 'standard', ARRAY['assignment'], 14, TRUE, 1, 1),
  ('notice', 'Notice — Electronic Permitted', 'الإشعار', 'All notices shall be in writing and delivered by hand, courier, or email to the addresses set out below. Email notices are deemed received the next business day.', NULL, 'standard', ARRAY['notice'], 12, TRUE, 1, 1)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 4. Wire counterparties to existing contracts
-- ============================================================================
-- Cycle ADNOC, Mubadala, IBM, Microsoft, Etisalat, DEWA, Crescent, Galadari,
-- Emirates NBD across the 35 active contracts so the Executive dashboard
-- top-counterparties surfaces real names.
DO $$
DECLARE
  v_party_ids BIGINT[] := ARRAY(
    SELECT id FROM party WHERE party_type = 'company' AND is_seed = TRUE AND name_en NOT LIKE 'Musanad%' ORDER BY id
  );
  v_our_party_id BIGINT := (SELECT id FROM party WHERE name_en = 'Musanad Technologies FZ-LLC');
  v_contract_ids BIGINT[] := ARRAY(SELECT id FROM contract WHERE is_active = TRUE ORDER BY id);
  v_i INTEGER;
  v_party_count INTEGER := array_length(v_party_ids, 1);
BEGIN
  FOR v_i IN 1 .. array_length(v_contract_ids, 1) LOOP
    UPDATE contract
    SET counterparty_id = v_party_ids[((v_i - 1) % v_party_count) + 1],
        our_party_id = v_our_party_id,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = 1
    WHERE id = v_contract_ids[v_i] AND counterparty_id IS NULL;
  END LOOP;
END $$;

-- ============================================================================
-- 5. Wire templates to a representative subset of contracts
-- ============================================================================
DO $$
DECLARE
  v_employment_id BIGINT := (SELECT id FROM contract_template WHERE name_en LIKE '%MoHRE Fixed-Term%');
  v_nda_id        BIGINT := (SELECT id FROM contract_template WHERE name_en LIKE '%Mutual Non-Disclosure%');
  v_vendor_id     BIGINT := (SELECT id FROM contract_template WHERE name_en = 'Vendor Services Agreement');
  v_msa_id        BIGINT := (SELECT id FROM contract_template WHERE name_en = 'Master Services Agreement (MSA)');
  v_consultancy_id BIGINT := (SELECT id FROM contract_template WHERE name_en = 'Consultancy Services Agreement');
BEGIN
  UPDATE contract SET template_id = v_employment_id   WHERE id IN (SELECT id FROM contract WHERE template_id IS NULL ORDER BY id LIMIT 6);
  UPDATE contract SET template_id = v_nda_id          WHERE id IN (SELECT id FROM contract WHERE template_id IS NULL ORDER BY id LIMIT 5);
  UPDATE contract SET template_id = v_vendor_id       WHERE id IN (SELECT id FROM contract WHERE template_id IS NULL ORDER BY id LIMIT 5);
  UPDATE contract SET template_id = v_msa_id          WHERE id IN (SELECT id FROM contract WHERE template_id IS NULL ORDER BY id LIMIT 4);
  UPDATE contract SET template_id = v_consultancy_id  WHERE id IN (SELECT id FROM contract WHERE template_id IS NULL ORDER BY id LIMIT 3);
END $$;

-- ============================================================================
-- 6. Obligations — derive from existing payment_schedule (1 obligation per row)
--    plus a few non-payment obligations for variety
-- ============================================================================
INSERT INTO contract_obligation (
  contract_id, title_en, title_ar, description_en,
  obligation_type, due_date, recurrence, responsible_party,
  status, is_seed, created_by, updated_by
)
SELECT
  ps.contract_id,
  'Payment milestone — ' || COALESCE(ps.milestone_label_en, ps.milestone_name_en, ('Milestone ' || ps.id::text)),
  ps.milestone_label_ar,
  'Scheduled payment of ' || ps.amount_aed::text || ' AED',
  'payment',
  ps.due_date,
  'once',
  'counterparty',
  CASE
    WHEN ps.paid_at IS NOT NULL THEN 'completed'
    WHEN ps.due_date < CURRENT_DATE THEN 'overdue'
    WHEN ps.due_date < CURRENT_DATE + INTERVAL '30 days' THEN 'in_progress'
    ELSE 'open'
  END,
  TRUE,
  1, 1
FROM payment_schedule ps
WHERE ps.is_active = TRUE
ON CONFLICT DO NOTHING;

-- Non-payment obligations: VAT filing reminder, contract renewal review, regulatory compliance review
INSERT INTO contract_obligation (
  contract_id, title_en, title_ar, description_en,
  obligation_type, due_date, recurrence, responsible_party,
  status, is_seed, created_by, updated_by
)
SELECT
  c.id,
  'Annual contract performance review',
  'مراجعة الأداء السنوي للعقد',
  'Internal review of vendor performance, SLA compliance, and renewal recommendation.',
  'reporting',
  c.start_date + INTERVAL '11 months',
  'annually',
  'our_party',
  CASE WHEN (c.start_date + INTERVAL '11 months') < CURRENT_DATE THEN 'completed' ELSE 'open' END,
  TRUE,
  1, 1
FROM contract c
WHERE c.status = 'active' AND c.is_active = TRUE
LIMIT 6
ON CONFLICT DO NOTHING;

INSERT INTO contract_obligation (
  contract_id, title_en, title_ar, description_en,
  obligation_type, due_date, recurrence, responsible_party,
  status, is_seed, created_by, updated_by
)
SELECT
  c.id,
  'Renewal notice — 90 days before expiry',
  'إشعار التجديد - 90 يوم',
  'Trigger renewal-decision workflow with line-of-business owner and counterparty.',
  'renewal',
  c.end_date - INTERVAL '90 days',
  'once',
  'our_party',
  CASE
    WHEN c.end_date IS NULL THEN 'open'
    WHEN (c.end_date - INTERVAL '90 days') < CURRENT_DATE - INTERVAL '7 days' THEN 'completed'
    WHEN (c.end_date - INTERVAL '90 days') < CURRENT_DATE THEN 'overdue'
    WHEN (c.end_date - INTERVAL '90 days') < CURRENT_DATE + INTERVAL '30 days' THEN 'in_progress'
    ELSE 'open'
  END,
  TRUE,
  1, 1
FROM contract c
WHERE c.status IN ('active', 'fully_signed') AND c.end_date IS NOT NULL AND c.is_active = TRUE
LIMIT 8
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 7. Schema migration tracker
-- ============================================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (59, 'M_parity seed: 12 parties + 8 templates + 18 clauses + obligations from payment_schedule + counterparty/template wiring on existing contracts', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
