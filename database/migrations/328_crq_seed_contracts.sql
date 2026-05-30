-- Migration: 328_crq_seed_contracts.sql
-- Module: CR-Q — ADNOC Data Scale-Up (v1.4 foundation)
-- Description: Seed +280 contracts across ADNOC subsidiaries + contract_version rows.
--              Distribution: Onshore ~70 · Offshore ~60 · Drilling ~50 · Gas ~30 ·
--              L&S ~25 · Distribution ~25 · Trading 6 · AGT 12.
--              3 gas_spa + 2 concession contracts; remainder services/epc/etc.
--              Emirate distribution: AbuDhabi 75% · Dubai 10% · Sharjah 7% · others 8%.
--              Value ranges: drilling 100M–1.5B AED · EPC 200M–4B · others 5M–500M.
--              Counterparties sampled from the 400-contractor pool.
--              Idempotency: ON CONFLICT (contract_number) DO NOTHING.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_seed_user  BIGINT;

  -- ADNOC subsidiary IDs
  v_onshore_id   BIGINT;
  v_offshore_id  BIGINT;
  v_drilling_id  BIGINT;
  v_gas_id       BIGINT;
  v_ls_id        BIGINT;
  v_dist_id      BIGINT;
  v_trading_id   BIGINT;
  v_agt_id       BIGINT;

  -- Sample contractor IDs (resolved from previously seeded parties)
  v_cp BIGINT[] := ARRAY[]::BIGINT[];
  v_cnt INTEGER := 0;

  -- Temp variables
  v_cid  BIGINT;
  v_cpid BIGINT;

BEGIN
  SELECT MIN(id) INTO v_seed_user FROM "user" WHERE is_active = TRUE;

  SELECT id INTO v_onshore_id  FROM party WHERE name_en = 'ADNOC Onshore'              AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_offshore_id FROM party WHERE name_en = 'ADNOC Offshore'             AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_drilling_id FROM party WHERE name_en = 'ADNOC Drilling'             AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_gas_id      FROM party WHERE name_en = 'ADNOC Gas'                  AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_ls_id       FROM party WHERE name_en = 'ADNOC Logistics & Services' AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_dist_id     FROM party WHERE name_en = 'ADNOC Distribution'         AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_trading_id  FROM party WHERE name_en = 'ADNOC Trading'              AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_agt_id      FROM party WHERE name_en = 'ADNOC Global Trading'       AND is_active = TRUE LIMIT 1;

  IF v_onshore_id IS NULL THEN
    RAISE EXCEPTION '328: ADNOC Onshore not found — run mig 285 first' USING ERRCODE = 'P0002';
  END IF;

  -- Build a reusable array of contractor party IDs (the full ~400 pool)
  SELECT ARRAY(
    SELECT p.id FROM party p
    WHERE p.is_active = TRUE
      AND p.party_type = 'company'
      AND p.metadata ? 'contractorCategory'
    ORDER BY p.id
  ) INTO v_cp;

  v_cnt := array_length(v_cp, 1);
  IF v_cnt = 0 THEN
    RAISE EXCEPTION '328: No contractor parties found — run mig 286+327 first' USING ERRCODE = 'P0002';
  END IF;

  -- ── Helper: pick contractor by modulo index ───────────────────────────────
  -- v_cp[((seq - 1) % v_cnt) + 1]  gives deterministic spread across all contractors

  -- ══════════════════════════════════════════════════════════════════════════
  -- ADNOC ONSHORE CONTRACTS (~70) — Seq 1..70
  -- ══════════════════════════════════════════════════════════════════════════

  INSERT INTO contract (contract_number, title_en, title_ar, contract_type, status,
    our_party_id, counterparty_id, value_aed, currency, start_date, end_date,
    emirate, governing_law, language, created_at, updated_at, created_by, updated_by, is_active)
  SELECT c.contract_number, c.title_en, c.title_ar, c.contract_type, 'active',
    v_onshore_id,
    v_cp[((c.seq - 1) % v_cnt) + 1],
    c.value_aed, 'AED', c.start_date::date, c.end_date::date,
    c.emirate, 'uae_federal', 'en',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  FROM (VALUES
    (1, 'CRQ-ONS-001','ADNOC Onshore — Onshore Field Development Services Package A','أدنوك للبر — حزمة خدمات تطوير الحقول البرية أ','services',350000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (2, 'CRQ-ONS-002','ADNOC Onshore — Manpower Supply & Camp Services — Bab Field','أدنوك للبر — إمداد القوى العاملة وخدمات المعسكرات حقل باب','services',45000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (3, 'CRQ-ONS-003','ADNOC Onshore — EPC Crude Oil Gathering Network — Phase 3','أدنوك للبر — شبكة تجميع النفط الخام EPC — المرحلة 3','epc',1200000000.00,'2023-06-01','2027-05-31','abu_dhabi'),
    (4, 'CRQ-ONS-004','ADNOC Onshore — Well Workover Rig Services','أدنوك للبر — خدمات حفارات إعادة تأهيل الآبار','services',280000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (5, 'CRQ-ONS-005','ADNOC Onshore — Pipeline Integrity Management Services','أدنوك للبر — خدمات إدارة سلامة خطوط الأنابيب','services',92000000.00,'2023-09-01','2026-08-31','abu_dhabi'),
    (6, 'CRQ-ONS-006','ADNOC Onshore — Instrument & Electrical Maintenance Contract','أدنوك للبر — عقد صيانة الأجهزة والكهرباء','services',68000000.00,'2024-02-01','2027-01-31','abu_dhabi'),
    (7, 'CRQ-ONS-007','ADNOC Onshore — Bu Hasa Field Water Injection EPC','أدنوك للبر — مشروع حقن المياه EPC حقل بو حسة','epc',2200000000.00,'2023-01-01','2027-12-31','abu_dhabi'),
    (8, 'CRQ-ONS-008','ADNOC Onshore — Corrosion Inspection & Treatment Services','أدنوك للبر — خدمات فحص ومعالجة التآكل','services',31000000.00,'2024-04-01','2026-03-31','abu_dhabi'),
    (9, 'CRQ-ONS-009','ADNOC Onshore — Scaffold & Insulation Services — South','أدنوك للبر — خدمات السقالات والعزل الجنوب','services',24000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (10,'CRQ-ONS-010','ADNOC Onshore — Rotating Equipment Overhauling — Asab','أدنوك للبر — إعادة تأهيل المعدات الدوارة أصب','services',55000000.00,'2023-10-01','2026-09-30','abu_dhabi'),
    (11,'CRQ-ONS-011','ADNOC Onshore — Chemical Injection & Production Enhancement','أدنوك للبر — حقن الكيماويات وتعزيز الإنتاج','services',40000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (12,'CRQ-ONS-012','ADNOC Onshore — Wellhead Completion & Testing Services','أدنوك للبر — خدمات إتمام رأس الآبار والاختبار','services',75000000.00,'2023-07-01','2026-06-30','abu_dhabi'),
    (13,'CRQ-ONS-013','ADNOC Onshore — Habshan Gas Plant Maintenance Services','أدنوك للبر — خدمات صيانة مصنع غاز الحبشان','services',120000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (14,'CRQ-ONS-014','ADNOC Onshore — Field Access Roads & Civil Infrastructure','أدنوك للبر — طرق الوصول الميداني والبنية المدنية','epc',450000000.00,'2023-04-01','2026-03-31','abu_dhabi'),
    (15,'CRQ-ONS-015','ADNOC Onshore — Cathodic Protection Services — Network A','أدنوك للبر — خدمات الحماية الكاثودية الشبكة أ','services',18000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (16,'CRQ-ONS-016','ADNOC Onshore — SCADA & Telecom Systems Maintenance','أدنوك للبر — صيانة أنظمة SCADA والاتصالات','services',32000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (17,'CRQ-ONS-017','ADNOC Onshore — Fire & Safety Equipment Services','أدنوك للبر — خدمات معدات الحريق والسلامة','services',14000000.00,'2023-11-01','2025-10-31','abu_dhabi'),
    (18,'CRQ-ONS-018','ADNOC Onshore — Onshore Logistics & Materials Handling','أدنوك للبر — اللوجستيات البرية ومناولة المواد','services',60000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (19,'CRQ-ONS-019','ADNOC Onshore — Production Chemicals Supply Contract','أدنوك للبر — عقد توريد كيماويات الإنتاج','services',28000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (20,'CRQ-ONS-020','ADNOC Onshore — Well Stimulation & Hydraulic Fracturing','أدنوك للبر — تنشيط الآبار والتكسير الهيدروليكي','services',195000000.00,'2023-09-01','2027-08-31','abu_dhabi'),
    (21,'CRQ-ONS-021','ADNOC Onshore — Training Academy Managed Services','أدنوك للبر — خدمات أكاديمية التدريب المُدارة','services',8000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (22,'CRQ-ONS-022','ADNOC Onshore — Medical Services & Ambulance Contract','أدنوك للبر — خدمات طبية وعقد سيارات الإسعاف','services',6000000.00,'2023-10-01','2025-09-30','abu_dhabi'),
    (23,'CRQ-ONS-023','ADNOC Onshore — EPC Crude Stabilization Unit — Ruwais','أدنوك للبر — EPC وحدة تثبيت النفط الخام الرويس','epc',3800000000.00,'2022-07-01','2027-06-30','abu_dhabi'),
    (24,'CRQ-ONS-024','ADNOC Onshore — Ali Field Artificial Lift Optimization','أدنوك للبر — تحسين الرفع الاصطناعي حقل علي','services',48000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (25,'CRQ-ONS-025','ADNOC Onshore — Waste Management & Environmental Services','أدنوك للبر — إدارة النفايات والخدمات البيئية','services',11000000.00,'2024-04-01','2026-03-31','abu_dhabi'),
    (26,'CRQ-ONS-026','ADNOC Onshore — Electrical Substation Maintenance — BAB','أدنوك للبر — صيانة المحطة الكهربائية الفرعية بات','services',22000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (27,'CRQ-ONS-027','ADNOC Onshore — Shah Field Compression Services','أدنوك للبر — خدمات الضغط في حقل شاه','services',140000000.00,'2023-06-01','2027-05-31','abu_dhabi'),
    (28,'CRQ-ONS-028','ADNOC Onshore — Tank Farm Maintenance — Jebel Dhanna','أدنوك للبر — صيانة مزرعة الخزانات جبل الظنة','services',35000000.00,'2023-12-01','2026-11-30','abu_dhabi'),
    (29,'CRQ-ONS-029','ADNOC Onshore — Onshore Security & Surveillance','أدنوك للبر — الأمن والمراقبة البرية','services',9000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (30,'CRQ-ONS-030','ADNOC Onshore — Catering & Accommodation Services — NE','أدنوك للبر — التموين والإقامة الشمال الشرقي','services',16000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (31,'CRQ-ONS-031','ADNOC Onshore — GIS & Mapping Technical Services','أدنوك للبر — خدمات GIS وتقنيات الرسم','services',7000000.00,'2024-03-01','2026-02-28','sharjah'),
    (32,'CRQ-ONS-032','ADNOC Onshore — Well Logging & Perforating Services','أدنوك للبر — خدمات تسجيل وتثقيب الآبار','services',55000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (33,'CRQ-ONS-033','ADNOC Onshore — LV/MV Electrical Infrastructure Upgrade','أدنوك للبر — ترقية البنية الكهربائية LV/MV','epc',280000000.00,'2023-08-01','2026-07-31','abu_dhabi'),
    (34,'CRQ-ONS-034','ADNOC Onshore — Hot-Work & Cold-Cut Services','أدنوك للبر — خدمات اللحام الحار والقطع البارد','services',19000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (35,'CRQ-ONS-035','ADNOC Onshore — Painting & Coating Services — South Fields','أدنوك للبر — خدمات الطلاء والطلاء الحقول الجنوبية','services',12000000.00,'2024-04-01','2026-03-31','abu_dhabi'),
    (36,'CRQ-ONS-036','ADNOC Onshore — Onshore Survey & Geophysical Services','أدنوك للبر — المسح والخدمات الجيوفيزيائية البرية','services',38000000.00,'2023-10-01','2026-09-30','abu_dhabi'),
    (37,'CRQ-ONS-037','ADNOC Onshore — Valve Maintenance & Testing Services','أدنوك للبر — خدمات صيانة واختبار الصمامات','services',14000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (38,'CRQ-ONS-038','ADNOC Onshore — Environmental Monitoring & Reporting','أدنوك للبر — الرصد البيئي والتقارير','services',6000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (39,'CRQ-ONS-039','ADNOC Onshore — Onshore Pipeline Right-of-Way Management','أدنوك للبر — إدارة حق الطريق للخطوط البرية','services',25000000.00,'2023-11-01','2026-10-31','abu_dhabi'),
    (40,'CRQ-ONS-040','ADNOC Onshore — Instrumentation & Automation Systems','أدنوك للبر — أنظمة الأجهزة والتشغيل الآلي','services',44000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (41,'CRQ-ONS-041','ADNOC Onshore — Camp Construction & Temporary Facilities','أدنوك للبر — إنشاء المعسكرات والمرافق المؤقتة','epc',85000000.00,'2023-07-01','2025-06-30','abu_dhabi'),
    (42,'CRQ-ONS-042','ADNOC Onshore — IT Infrastructure & Network Services','أدنوك للبر — خدمات البنية التحتية لتكنولوجيا المعلومات','services',15000000.00,'2024-01-01','2025-12-31','dubai'),
    (43,'CRQ-ONS-043','ADNOC Onshore — Materials & Consumables Supply Chain','أدنوك للبر — سلسلة إمداد المواد والمستهلكات','services',33000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (44,'CRQ-ONS-044','ADNOC Onshore — Crane & Heavy Lift Services','أدنوك للبر — خدمات الرافعات والرفع الثقيل','services',20000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (45,'CRQ-ONS-045','ADNOC Onshore — Concession Renewal — Block 1 (Bu Hasa Area)','أدنوك للبر — تجديد الامتياز الكتلة 1 منطقة بو حسة','concession',1500000000.00,'2026-01-01','2056-12-31','abu_dhabi'),
    (46,'CRQ-ONS-046','ADNOC Onshore — Flow Assurance Technical Services','أدنوك للبر — خدمات التدفق التقنية','services',28000000.00,'2024-04-01','2027-03-31','abu_dhabi'),
    (47,'CRQ-ONS-047','ADNOC Onshore — Hazardous Materials Handling & Disposal','أدنوك للبر — مناولة والتخلص من المواد الخطرة','services',8500000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (48,'CRQ-ONS-048','ADNOC Onshore — Pumping Station O&M Services','أدنوك للبر — خدمات تشغيل وصيانة محطة الضخ','services',52000000.00,'2023-09-01','2027-08-31','abu_dhabi'),
    (49,'CRQ-ONS-049','ADNOC Onshore — Onshore Tank Cleaning Services','أدنوك للبر — خدمات تنظيف الخزانات البرية','services',7200000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (50,'CRQ-ONS-050','ADNOC Onshore — Non-Destructive Testing Services','أدنوك للبر — خدمات الاختبار غير التدميري','services',16000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (51,'CRQ-ONS-051','ADNOC Onshore — Seismic Data Acquisition Services','أدنوك للبر — خدمات جمع البيانات الزلزالية','services',95000000.00,'2023-12-01','2026-11-30','abu_dhabi'),
    (52,'CRQ-ONS-052','ADNOC Onshore — Oil Spill Response & Environmental Emergency','أدنوك للبر — الاستجابة للتسرب النفطي والطوارئ البيئية','services',5500000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (53,'CRQ-ONS-053','ADNOC Onshore — Renewable Energy Integration Study EPC','أدنوك للبر — EPC دراسة تكامل الطاقة المتجددة','epc',620000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (54,'CRQ-ONS-054','ADNOC Onshore — Power Generation O&M — Bab Central','أدنوك للبر — تشغيل وصيانة توليد الطاقة باب المركزي','services',76000000.00,'2023-08-01','2027-07-31','abu_dhabi'),
    (55,'CRQ-ONS-055','ADNOC Onshore — Demineralized Water Plant Services','أدنوك للبر — خدمات محطة المياه المنزوعة المعادن','services',21000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (56,'CRQ-ONS-056','ADNOC Onshore — Master Service Agreement — Engineering Consulting','أدنوك للبر — اتفاقية خدمة رئيسية استشارات هندسية','services',48000000.00,'2024-01-01','2026-12-31','dubai'),
    (57,'CRQ-ONS-057','ADNOC Onshore — Construction QA/QC Inspection Services','أدنوك للبر — خدمات فحص ضبط جودة الإنشاء','services',11000000.00,'2024-04-01','2026-03-31','abu_dhabi'),
    (58,'CRQ-ONS-058','ADNOC Onshore — Flare Systems Maintenance & Upgrade','أدنوك للبر — صيانة وتطوير أنظمة الشعلة','services',33000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (59,'CRQ-ONS-059','ADNOC Onshore — Abu Dhabi EPC Carbon Capture Pilot Unit','أدنوك للبر — EPC وحدة تجريبية لالتقاط الكربون','epc',890000000.00,'2024-03-01','2028-02-28','abu_dhabi'),
    (60,'CRQ-ONS-060','ADNOC Onshore — Drilling Site Preparation Civil Works','أدنوك للبر — أعمال مدنية لإعداد مواقع الحفر','epc',175000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (61,'CRQ-ONS-061','ADNOC Onshore — Completion Fluids & Chemicals Supply','أدنوك للبر — إمداد سوائل الإتمام والكيماويات','services',18500000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (62,'CRQ-ONS-062','ADNOC Onshore — Remote Sensing & Drone Survey Services','أدنوك للبر — خدمات الاستشعار عن بعد والمسح بالطائرات','services',9000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (63,'CRQ-ONS-063','ADNOC Onshore — Field Communications & Radio Services','أدنوك للبر — خدمات الاتصالات الميدانية واللاسلكية','services',13000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (64,'CRQ-ONS-064','ADNOC Onshore — Third-Party Lab & Inspection Services','أدنوك للبر — خدمات المختبرات والفحص الخارجية','services',7500000.00,'2024-01-01','2025-12-31','dubai'),
    (65,'CRQ-ONS-065','ADNOC Onshore — Sand Management & Control Services','أدنوك للبر — خدمات إدارة والتحكم في الرمال','services',29000000.00,'2023-11-01','2026-10-31','abu_dhabi'),
    (66,'CRQ-ONS-066','ADNOC Onshore — Workover Fluid Services & Chemicals','أدنوك للبر — سوائل وكيماويات خدمات إعادة التأهيل','services',22000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (67,'CRQ-ONS-067','ADNOC Onshore — Production Data Management System','أدنوك للبر — نظام إدارة بيانات الإنتاج','services',15000000.00,'2024-04-01','2026-03-31','abu_dhabi'),
    (68,'CRQ-ONS-068','ADNOC Onshore — Well Testing & Extended Well Test Services','أدنوك للبر — خدمات اختبار الآبار والاختبار الممتد','services',42000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (69,'CRQ-ONS-069','ADNOC Onshore — Onshore Pipeline Cathodic Protection EPC','أدنوك للبر — EPC الحماية الكاثودية للخطوط البرية','epc',320000000.00,'2023-10-01','2026-09-30','abu_dhabi'),
    (70,'CRQ-ONS-070','ADNOC Onshore — EPC Smart Metering & Flow Measurement','أدنوك للبر — EPC القياس الذكي وقياس التدفق','epc',500000000.00,'2024-01-01','2027-12-31','abu_dhabi')
  ) AS c(seq, contract_number, title_en, title_ar, contract_type, value_aed, start_date, end_date, emirate)
  ON CONFLICT (contract_number) DO NOTHING;

  -- ══════════════════════════════════════════════════════════════════════════
  -- ADNOC OFFSHORE CONTRACTS (~60) — Seq 71..130
  -- ══════════════════════════════════════════════════════════════════════════

  INSERT INTO contract (contract_number, title_en, title_ar, contract_type, status,
    our_party_id, counterparty_id, value_aed, currency, start_date, end_date,
    emirate, governing_law, language, created_at, updated_at, created_by, updated_by, is_active)
  SELECT c.contract_number, c.title_en, c.title_ar, c.contract_type, 'active',
    v_offshore_id,
    v_cp[((c.seq - 1) % v_cnt) + 1],
    c.value_aed, 'AED', c.start_date::date, c.end_date::date,
    c.emirate, 'uae_federal', 'en',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  FROM (VALUES
    (71, 'CRQ-OFF-001','ADNOC Offshore — Offshore Platform Maintenance & Inspection','أدنوك للبترول البحري — صيانة وفحص المنصة البحرية','services',180000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (72, 'CRQ-OFF-002','ADNOC Offshore — Subsea Pipeline Inspection & Repair Services','أدنوك للبترول البحري — فحص وإصلاح خطوط الأنابيب تحت البحر','services',95000000.00,'2023-08-01','2026-07-31','abu_dhabi'),
    (73, 'CRQ-OFF-003','ADNOC Offshore — EPC Offshore Processing Platform — Umm Shaif','أدنوك للبترول البحري — EPC منصة معالجة بحرية أم الشيف','epc',3200000000.00,'2022-06-01','2027-05-31','abu_dhabi'),
    (74, 'CRQ-OFF-004','ADNOC Offshore — Diving & Underwater Services Contract','أدنوك للبترول البحري — عقد الغوص والخدمات تحت الماء','services',62000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (75, 'CRQ-OFF-005','ADNOC Offshore — ROV Operations & Survey Services','أدنوك للبترول البحري — عمليات ROV والمسح','services',38000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (76, 'CRQ-OFF-006','ADNOC Offshore — Marine Spread Charter — DSV Vessel','أدنوك للبترول البحري — استئجار مجموعة بحرية — سفينة DSV','services',125000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (77, 'CRQ-OFF-007','ADNOC Offshore — Offshore Crane Maintenance Services','أدنوك للبترول البحري — خدمات صيانة رافعات بحرية','services',18000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (78, 'CRQ-OFF-008','ADNOC Offshore — Offshore Structural Integrity — NDA Field','أدنوك للبترول البحري — سلامة الهياكل البحرية حقل NDA','services',55000000.00,'2023-11-01','2026-10-31','abu_dhabi'),
    (79, 'CRQ-OFF-009','ADNOC Offshore — Offshore Electrical Systems Maintenance','أدنوك للبترول البحري — صيانة الأنظمة الكهربائية البحرية','services',44000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (80, 'CRQ-OFF-010','ADNOC Offshore — Marine Transport & Crew Boat Services','أدنوك للبترول البحري — خدمات النقل البحري وزوارق الطاقم','services',32000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (81, 'CRQ-OFF-011','ADNOC Offshore — Topside Modifications — Zirku Platform','أدنوك للبترول البحري — تعديلات الجزء العلوي منصة زركو','epc',750000000.00,'2023-05-01','2026-04-30','abu_dhabi'),
    (82, 'CRQ-OFF-012','ADNOC Offshore — Production Chemical Injection Offshore','أدنوك للبترول البحري — حقن كيماويات الإنتاج البحري','services',24000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (83, 'CRQ-OFF-013','ADNOC Offshore — Offshore Platform Catering & Housekeeping','أدنوك للبترول البحري — تموين المنصة البحرية والتنظيف','services',16000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (84, 'CRQ-OFF-014','ADNOC Offshore — Subsea Completion & Tie-Back Services','أدنوك للبترول البحري — خدمات الإتمام تحت البحر والربط','services',210000000.00,'2023-09-01','2027-08-31','abu_dhabi'),
    (85, 'CRQ-OFF-015','ADNOC Offshore — EPC Riser Replacement — Nasr Field','أدنوك للبترول البحري — EPC استبدال الروازن حقل النصر','epc',420000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (86, 'CRQ-OFF-016','ADNOC Offshore — Offshore NDT & Corrosion Services','أدنوك للبترول البحري — خدمات NDT والتآكل البحرية','services',28000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (87, 'CRQ-OFF-017','ADNOC Offshore — Helicopter Aviation Services','أدنوك للبترول البحري — خدمات الطيران بالطائرات المروحية','services',88000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (88, 'CRQ-OFF-018','ADNOC Offshore — Offshore Safety & Emergency Response','أدنوك للبترول البحري — السلامة والاستجابة للطوارئ البحرية','services',22000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (89, 'CRQ-OFF-019','ADNOC Offshore — Process Control Systems Upgrade Offshore','أدنوك للبترول البحري — ترقية أنظمة التحكم في العمليات البحرية','services',66000000.00,'2024-03-01','2027-02-28','abu_dhabi'),
    (90, 'CRQ-OFF-020','ADNOC Offshore — Offshore Pipeline Coating & Insulation','أدنوك للبترول البحري — طلاء وعزل خطوط الأنابيب البحرية','services',35000000.00,'2023-12-01','2026-11-30','abu_dhabi'),
    (91, 'CRQ-OFF-021','ADNOC Offshore — Offshore Instrumentation Calibration','أدنوك للبترول البحري — معايرة الأجهزة البحرية','services',12000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (92, 'CRQ-OFF-022','ADNOC Offshore — EPC Gas Compression — Al Bunduq Field','أدنوك للبترول البحري — EPC ضغط الغاز حقل البندق','epc',1800000000.00,'2023-07-01','2027-06-30','abu_dhabi'),
    (93, 'CRQ-OFF-023','ADNOC Offshore — Offshore Water Injection Enhancement','أدنوك للبترول البحري — تحسين حقن المياه البحري','epc',960000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (94, 'CRQ-OFF-024','ADNOC Offshore — Environmental Compliance & Monitoring','أدنوك للبترول البحري — الامتثال البيئي والرصد','services',9500000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (95, 'CRQ-OFF-025','ADNOC Offshore — Flare Stack Inspection & Maintenance','أدنوك للبترول البحري — فحص وصيانة برج الشعلة','services',19000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (96, 'CRQ-OFF-026','ADNOC Offshore — Offshore Laboratory Testing Services','أدنوك للبترول البحري — خدمات الاختبار المعملي البحري','services',8000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (97, 'CRQ-OFF-027','ADNOC Offshore — Marine Spread — AHT & Supply Vessels','أدنوك للبترول البحري — مجموعة بحرية سفن AHT وإمداد','services',150000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (98, 'CRQ-OFF-028','ADNOC Offshore — Brownfield Revamp — Platform Al Jurf','أدنوك للبترول البحري — تجديد الحقل القائم منصة الجرف','epc',600000000.00,'2023-04-01','2027-03-31','abu_dhabi'),
    (99, 'CRQ-OFF-029','ADNOC Offshore — Gas Flaring Reduction EPC','أدنوك للبترول البحري — EPC تقليل حرق الغاز','epc',850000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (100,'CRQ-OFF-030','ADNOC Offshore — Offshore Scaffold & Insulation Services','أدنوك للبترول البحري — خدمات السقالات والعزل البحري','services',31000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (101,'CRQ-OFF-031','ADNOC Offshore — Offshore Telecom & Radio Systems','أدنوك للبترول البحري — أنظمة الاتصالات واللاسلكي البحري','services',14000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (102,'CRQ-OFF-032','ADNOC Offshore — Topsides Hook-up & Commissioning','أدنوك للبترول البحري — توصيل وتشغيل الأجزاء العلوية','services',280000000.00,'2023-06-01','2026-05-31','abu_dhabi'),
    (103,'CRQ-OFF-033','ADNOC Offshore — Flow Line Pigging & Inspection Services','أدنوك للبترول البحري — خدمات تنظيف وفحص خطوط التدفق','services',18000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (104,'CRQ-OFF-034','ADNOC Offshore — Offshore Construction Vessels Charter','أدنوك للبترول البحري — استئجار سفن إنشاء بحرية','services',220000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (105,'CRQ-OFF-035','ADNOC Offshore — Gas Lift Optimization Services','أدنوك للبترول البحري — خدمات تحسين رفع الغاز','services',42000000.00,'2024-02-01','2027-01-31','abu_dhabi'),
    (106,'CRQ-OFF-036','ADNOC Offshore — Pipeline Repair & Emergency Response','أدنوك للبترول البحري — إصلاح خطوط الأنابيب والاستجابة الطارئة','services',28000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (107,'CRQ-OFF-037','ADNOC Offshore — EPC FPSO Mooring System Upgrade','أدنوك للبترول البحري — EPC ترقية نظام رسو FPSO','epc',1100000000.00,'2023-09-01','2027-08-31','abu_dhabi'),
    (108,'CRQ-OFF-038','ADNOC Offshore — Chemical Treatment & Scale Inhibition','أدنوك للبترول البحري — المعالجة الكيميائية ومنع الترسبات','services',22000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (109,'CRQ-OFF-039','ADNOC Offshore — Compressor Maintenance — Zakum Field','أدنوك للبترول البحري — صيانة الضاغط حقل ظاقم','services',95000000.00,'2023-10-01','2027-09-30','abu_dhabi'),
    (110,'CRQ-OFF-040','ADNOC Offshore — Subsea Tree Services & Intervention','أدنوك للبترول البحري — خدمات أشجار تحت البحر والتدخل','services',74000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (111,'CRQ-OFF-041','ADNOC Offshore — Offshore Waste Management Services','أدنوك للبترول البحري — خدمات إدارة النفايات البحرية','services',11000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (112,'CRQ-OFF-042','ADNOC Offshore — Offshore EPC — Central Metering Station','أدنوك للبترول البحري — EPC بحري محطة قياس مركزية','epc',680000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (113,'CRQ-OFF-043','ADNOC Offshore — Platform Coating & Anti-Corrosion Works','أدنوك للبترول البحري — طلاء المنصة وأعمال مكافحة التآكل','services',26000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (114,'CRQ-OFF-044','ADNOC Offshore — Production Logging & Well Interventions','أدنوك للبترول البحري — تسجيل الإنتاج وتدخلات الآبار','services',65000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (115,'CRQ-OFF-045','ADNOC Offshore — Offshore Camp Facilities Management','أدنوك للبترول البحري — إدارة مرافق المعسكر البحري','services',14000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (116,'CRQ-OFF-046','ADNOC Offshore — Marine Warranty Survey Services','أدنوك للبترول البحري — خدمات مسح ضمان البحري','services',6500000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (117,'CRQ-OFF-047','ADNOC Offshore — Pressure Control & Well Intervention','أدنوك للبترول البحري — التحكم في الضغط وتدخل الآبار','services',88000000.00,'2023-11-01','2027-10-31','abu_dhabi'),
    (118,'CRQ-OFF-048','ADNOC Offshore — EPC New Wellhead Platform — Block 3','أدنوك للبترول البحري — EPC منصة رأس آبار جديدة الكتلة 3','epc',2600000000.00,'2023-01-01','2028-12-31','abu_dhabi'),
    (119,'CRQ-OFF-049','ADNOC Offshore — Offshore Remote Sensing & Survey','أدنوك للبترول البحري — الاستشعار عن بعد والمسح البحري','services',18000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (120,'CRQ-OFF-050','ADNOC Offshore — Oil Storage Tank Maintenance Offshore','أدنوك للبترول البحري — صيانة خزانات التخزين البحرية','services',42000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (121,'CRQ-OFF-051','ADNOC Offshore — Offshore Medical Services & Medevac','أدنوك للبترول البحري — الخدمات الطبية والإخلاء الطبي','services',7000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (122,'CRQ-OFF-052','ADNOC Offshore — EPC Power Export Cable — Platform Grid','أدنوك للبترول البحري — EPC كابل تصدير الطاقة شبكة المنصة','epc',380000000.00,'2024-03-01','2027-02-28','abu_dhabi'),
    (123,'CRQ-OFF-053','ADNOC Offshore — Anchor Handling & Towing Services','أدنوك للبترول البحري — خدمات مناولة المرساة والقطر','services',55000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (124,'CRQ-OFF-054','ADNOC Offshore — Wellsite Cementing Services','أدنوك للبترول البحري — خدمات التسمنت لموقع الآبار','services',34000000.00,'2024-02-01','2027-01-31','abu_dhabi'),
    (125,'CRQ-OFF-055','ADNOC Offshore — Offshore Metering & Fiscal Measurement','أدنوك للبترول البحري — القياس المالي البحري','services',28000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (126,'CRQ-OFF-056','ADNOC Offshore — Offshore Security Vessel Services','أدنوك للبترول البحري — سفن الأمن البحري','services',24000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (127,'CRQ-OFF-057','ADNOC Offshore — Offshore IT & Connectivity Services','أدنوك للبترول البحري — خدمات تكنولوجيا المعلومات والاتصال البحري','services',9000000.00,'2024-01-01','2025-12-31','dubai'),
    (128,'CRQ-OFF-058','ADNOC Offshore — Topsides EPC — Platform B Expansion','أدنوك للبترول البحري — EPC الأجزاء العلوية توسيع منصة B','epc',1450000000.00,'2023-06-01','2027-05-31','abu_dhabi'),
    (129,'CRQ-OFF-059','ADNOC Offshore — Wellbore Cleanup & Debris Removal','أدنوك للبترول البحري — تنظيف آبار وإزالة الحطام','services',16000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (130,'CRQ-OFF-060','ADNOC Offshore — Offshore Structural Repair & Refurb','أدنوك للبترول البحري — إصلاح وتجديد الهياكل البحرية','services',38000000.00,'2024-02-01','2027-01-31','abu_dhabi')
  ) AS c(seq, contract_number, title_en, title_ar, contract_type, value_aed, start_date, end_date, emirate)
  ON CONFLICT (contract_number) DO NOTHING;

  -- ══════════════════════════════════════════════════════════════════════════
  -- ADNOC DRILLING CONTRACTS (~50) — Seq 131..180
  -- ══════════════════════════════════════════════════════════════════════════

  INSERT INTO contract (contract_number, title_en, title_ar, contract_type, status,
    our_party_id, counterparty_id, value_aed, currency, start_date, end_date,
    emirate, governing_law, language, created_at, updated_at, created_by, updated_by, is_active)
  SELECT c.contract_number, c.title_en, c.title_ar, c.contract_type, 'active',
    v_drilling_id,
    v_cp[((c.seq - 1) % v_cnt) + 1],
    c.value_aed, 'AED', c.start_date::date, c.end_date::date,
    c.emirate, 'uae_federal', 'en',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  FROM (VALUES
    (131,'CRQ-DRL-001','ADNOC Drilling — Directional Drilling Services — Onshore A','أدنوك للحفر — خدمات الحفر الاتجاهي البري A','services',380000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (132,'CRQ-DRL-002','ADNOC Drilling — Rig Maintenance & Spare Parts Supply','أدنوك للحفر — صيانة الحفارات وإمداد قطع الغيار','services',220000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (133,'CRQ-DRL-003','ADNOC Drilling — Mud Engineering & Drilling Fluids','أدنوك للحفر — هندسة الطين وسوائل الحفر','services',95000000.00,'2024-02-01','2027-01-31','abu_dhabi'),
    (134,'CRQ-DRL-004','ADNOC Drilling — Drill Bit Supply & Management Services','أدنوك للحفر — إمداد وإدارة لقم الحفر','services',42000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (135,'CRQ-DRL-005','ADNOC Drilling — Casing & Tubing Supply Contract','أدنوك للحفر — عقد إمداد غلاف الأنبوب','services',320000000.00,'2023-10-01','2027-09-30','abu_dhabi'),
    (136,'CRQ-DRL-006','ADNOC Drilling — Drilling Waste Management Services','أدنوك للحفر — خدمات إدارة نفايات الحفر','services',28000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (137,'CRQ-DRL-007','ADNOC Drilling — Real-Time Drilling Monitoring & LWD','أدنوك للحفر — مراقبة الحفر الآني و LWD','services',88000000.00,'2024-03-01','2027-02-28','abu_dhabi'),
    (138,'CRQ-DRL-008','ADNOC Drilling — Well Cementing Services','أدنوك للحفر — خدمات تسمنت الآبار','services',65000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (139,'CRQ-DRL-009','ADNOC Drilling — Coiled Tubing & Wireline Services','أدنوك للحفر — خدمات الأنابيب الملفوفة والأسلاك','services',110000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (140,'CRQ-DRL-010','ADNOC Drilling — Oilfield Chemical Services — Drilling Phase','أدنوك للحفر — خدمات كيماويات حقول النفط مرحلة الحفر','services',35000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (141,'CRQ-DRL-011','ADNOC Drilling — Rig Acceptance Testing & Certification','أدنوك للحفر — اختبار قبول وتصديق الحفارات','services',12000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (142,'CRQ-DRL-012','ADNOC Drilling — Blowout Preventer Rental & Maintenance','أدنوك للحفر — استئجار وصيانة مانعة الانفجار','services',55000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (143,'CRQ-DRL-013','ADNOC Drilling — Derrick & Substructure Supply EPC','أدنوك للحفر — EPC توريد الصارية والهيكل الفرعي','epc',460000000.00,'2023-07-01','2026-06-30','abu_dhabi'),
    (144,'CRQ-DRL-014','ADNOC Drilling — Rock Bit & PDC Technology Services','أدنوك للحفر — خدمات تقنية الحفر الصخري و PDC','services',78000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (145,'CRQ-DRL-015','ADNOC Drilling — Wellbore Surveying & Mapping Services','أدنوك للحفر — خدمات مسح ورسم الآبار','services',48000000.00,'2024-02-01','2027-01-31','abu_dhabi'),
    (146,'CRQ-DRL-016','ADNOC Drilling — Offshore Jack-Up Rig — Zubara Contract','أدنوك للحفر — حفارة رافعة بحرية عقد زبارة','services',820000000.00,'2023-09-01','2027-08-31','abu_dhabi'),
    (147,'CRQ-DRL-017','ADNOC Drilling — Land Rig Services — Package B','أدنوك للحفر — خدمات الحفارات البرية حزمة B','services',1450000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (148,'CRQ-DRL-018','ADNOC Drilling — EPC Rig Upgrade & Refurbishment','أدنوك للحفر — EPC ترقية وتجديد الحفارات','epc',230000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (149,'CRQ-DRL-019','ADNOC Drilling — Perforating & Completion Services','أدنوك للحفر — خدمات التثقيب والإتمام','services',95000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (150,'CRQ-DRL-020','ADNOC Drilling — Horizontal & ERD Drilling Services','أدنوك للحفر — خدمات الحفر الأفقي وبعيد المدى','services',650000000.00,'2023-06-01','2027-05-31','abu_dhabi'),
    (151,'CRQ-DRL-021','ADNOC Drilling — Drilling IT & Data Management Systems','أدنوك للحفر — أنظمة معلومات وإدارة بيانات الحفر','services',22000000.00,'2024-01-01','2026-12-31','dubai'),
    (152,'CRQ-DRL-022','ADNOC Drilling — Rig Logistics & Heavy Transport','أدنوك للحفر — اللوجستيات والنقل الثقيل للحفارات','services',68000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (153,'CRQ-DRL-023','ADNOC Drilling — EPC Automated Drill Floor Technology','أدنوك للحفر — EPC تقنية طابق الحفر الآلي','epc',185000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (154,'CRQ-DRL-024','ADNOC Drilling — Wellbore Cleaning & Deviation Services','أدنوك للحفر — خدمات تنظيف وانحراف الآبار','services',35000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (155,'CRQ-DRL-025','ADNOC Drilling — Cementing Technical Services — Offshore','أدنوك للحفر — خدمات التسمنت التقنية البحرية','services',42000000.00,'2024-02-01','2027-01-31','abu_dhabi'),
    (156,'CRQ-DRL-026','ADNOC Drilling — Wellbore Stability & Geomechanics Consulting','أدنوك للحفر — استشارات استقرار الآبار والميكانيكا الجيولوجية','services',16000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (157,'CRQ-DRL-027','ADNOC Drilling — Drill Pipe Inspection & Repair Services','أدنوك للحفر — خدمات فحص وإصلاح أنابيب الحفر','services',24000000.00,'2024-03-01','2026-02-28','sharjah'),
    (158,'CRQ-DRL-028','ADNOC Drilling — Rig Catering & Accommodation Services','أدنوك للحفر — خدمات تموين وإقامة الحفارات','services',19000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (159,'CRQ-DRL-029','ADNOC Drilling — EPC Drilling Instrumentation Upgrade','أدنوك للحفر — EPC ترقية أجهزة الحفر','epc',110000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (160,'CRQ-DRL-030','ADNOC Drilling — Plug & Abandonment Services','أدنوك للحفر — خدمات السد والإغلاق','services',75000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (161,'CRQ-DRL-031','ADNOC Drilling — Fishing & Retrieval Tool Rental','أدنوك للحفر — استئجار أدوات استرداد الأجسام الغريبة','services',14000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (162,'CRQ-DRL-032','ADNOC Drilling — Production Testing Services','أدنوك للحفر — خدمات اختبار الإنتاج','services',58000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (163,'CRQ-DRL-033','ADNOC Drilling — Stuck Pipe & Jarring Services','أدنوك للحفر — خدمات إزالة العوالق والصدم','services',22000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (164,'CRQ-DRL-034','ADNOC Drilling — Well Abandonment & Decommissioning','أدنوك للحفر — التخلي عن الآبار وإلغاء التشغيل','services',115000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (165,'CRQ-DRL-035','ADNOC Drilling — Drilling Engineering Consulting','أدنوك للحفر — الاستشارات الهندسية للحفر','services',28000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (166,'CRQ-DRL-036','ADNOC Drilling — Well Integrity Diagnostic Services','أدنوك للحفر — خدمات تشخيص سلامة الآبار','services',44000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (167,'CRQ-DRL-037','ADNOC Drilling — Formation Evaluation & Core Analysis','أدنوك للحفر — تقييم التكوين وتحليل النوى','services',32000000.00,'2024-03-01','2027-02-28','abu_dhabi'),
    (168,'CRQ-DRL-038','ADNOC Drilling — Offshore Semi-Sub Drilling Contract','أدنوك للحفر — عقد الحفر شبه الغاطس البحري','services',1200000000.00,'2023-07-01','2027-06-30','abu_dhabi'),
    (169,'CRQ-DRL-039','ADNOC Drilling — Drilling Campaign Planning & Optimization','أدنوك للحفر — تخطيط وتحسين حملة الحفر','services',18000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (170,'CRQ-DRL-040','ADNOC Drilling — Rig Safety Management System Upgrade','أدنوك للحفر — ترقية نظام إدارة سلامة الحفارات','services',9500000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (171,'CRQ-DRL-041','ADNOC Drilling — Mud Logging Services — Onshore Fields','أدنوك للحفر — خدمات تسجيل الطين الحقول البرية','services',36000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (172,'CRQ-DRL-042','ADNOC Drilling — Drilling Waste Pit Closure Services','أدنوك للحفر — خدمات إغلاق حفر نفايات الحفر','services',12000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (173,'CRQ-DRL-043','ADNOC Drilling — Temporary Production & Test Separator','أدنوك للحفر — فاصل إنتاج واختبار مؤقت','services',25000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (174,'CRQ-DRL-044','ADNOC Drilling — Deepwater Well Technology Study','أدنوك للحفر — دراسة تكنولوجيا آبار المياه العميقة','services',8000000.00,'2024-02-01','2026-01-31','abu_dhabi'),
    (175,'CRQ-DRL-045','ADNOC Drilling — High-Pressure High-Temperature Drilling','أدنوك للحفر — حفر الضغط العالي ودرجة الحرارة العالية','services',480000000.00,'2023-11-01','2027-10-31','abu_dhabi'),
    (176,'CRQ-DRL-046','ADNOC Drilling — EPC Portable Drilling Unit Fabrication','أدنوك للحفر — EPC تصنيع وحدة حفر محمولة','epc',350000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (177,'CRQ-DRL-047','ADNOC Drilling — Completion Equipment Supply','أدنوك للحفر — إمداد معدات الإتمام','services',88000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (178,'CRQ-DRL-048','ADNOC Drilling — Rig Fleet Utilization Optimization','أدنوك للحفر — تحسين استخدام أسطول الحفارات','services',14000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (179,'CRQ-DRL-049','ADNOC Drilling — Drilling Project Management Services','أدنوك للحفر — خدمات إدارة مشروع الحفر','services',22000000.00,'2024-01-01','2026-12-31','dubai'),
    (180,'CRQ-DRL-050','ADNOC Drilling — EPC Automated Drilling Controls Platform','أدنوك للحفر — EPC منصة تحكم حفر آلي','epc',280000000.00,'2024-01-01','2027-12-31','abu_dhabi')
  ) AS c(seq, contract_number, title_en, title_ar, contract_type, value_aed, start_date, end_date, emirate)
  ON CONFLICT (contract_number) DO NOTHING;

  -- ══════════════════════════════════════════════════════════════════════════
  -- ADNOC GAS CONTRACTS (~30 incl. gas_spa stubs) — Seq 181..210
  -- ══════════════════════════════════════════════════════════════════════════

  INSERT INTO contract (contract_number, title_en, title_ar, contract_type, status,
    our_party_id, counterparty_id, value_aed, currency, start_date, end_date,
    emirate, governing_law, language, created_at, updated_at, created_by, updated_by, is_active)
  SELECT c.contract_number, c.title_en, c.title_ar, c.contract_type, 'active',
    v_gas_id,
    v_cp[((c.seq - 1) % v_cnt) + 1],
    c.value_aed, 'AED', c.start_date::date, c.end_date::date,
    c.emirate, 'uae_federal', 'en',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  FROM (VALUES
    (181,'CRQ-GAS-001','ADNOC Gas — EPC LNG Precooling Train Expansion','أدنوك للغاز — EPC توسيع قطار التبريد المسبق للغاز الطبيعي المسال','epc',3500000000.00,'2022-07-01','2027-06-30','abu_dhabi'),
    (182,'CRQ-GAS-002','ADNOC Gas — Gas Processing Maintenance Services','أدنوك للغاز — خدمات صيانة معالجة الغاز','services',135000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (183,'CRQ-GAS-003','ADNOC Gas — Gas Transmission Pipeline Integrity','أدنوك للغاز — سلامة خطوط نقل الغاز','services',48000000.00,'2024-02-01','2027-01-31','abu_dhabi'),
    (184,'CRQ-GAS-004','ADNOC Gas — NGL Fractionation Plant O&M Services','أدنوك للغاز — خدمات تشغيل وصيانة مصنع تكسير NGL','services',88000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (185,'CRQ-GAS-005','ADNOC Gas — 25-Year Gas SPA — Shah Gas Field (Abu Dhabi Power)','أدنوك للغاز — اتفاقية بيع غاز 25 سنة حقل شاه لكهرباء أبوظبي','gas_spa',22000000000.00,'2026-01-01','2050-12-31','abu_dhabi'),
    (186,'CRQ-GAS-006','ADNOC Gas — Compressor Station EPC — Habshan','أدنوك للغاز — EPC محطة ضاغطة حبشان','epc',820000000.00,'2023-05-01','2026-04-30','abu_dhabi'),
    (187,'CRQ-GAS-007','ADNOC Gas — Sulfur Recovery Unit Maintenance','أدنوك للغاز — صيانة وحدة استرداد الكبريت','services',42000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (188,'CRQ-GAS-008','ADNOC Gas — Gas Dehydration System Services','أدنوك للغاز — خدمات نظام تجفيف الغاز','services',28000000.00,'2024-03-01','2027-02-28','abu_dhabi'),
    (189,'CRQ-GAS-009','ADNOC Gas — 20-Year Gas SPA — Ruwais Fertilizers (FERTIL)','أدنوك للغاز — اتفاقية بيع غاز 20 سنة لمصنع أسمدة الرويس','gas_spa',14000000000.00,'2025-07-01','2045-06-30','abu_dhabi'),
    (190,'CRQ-GAS-010','ADNOC Gas — Gas Metering & Custody Transfer Services','أدنوك للغاز — خدمات قياس وتسليم الغاز','services',22000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (191,'CRQ-GAS-011','ADNOC Gas — Sour Gas Treatment Plant Services','أدنوك للغاز — خدمات محطة معالجة الغاز الحامض','services',65000000.00,'2024-02-01','2027-01-31','abu_dhabi'),
    (192,'CRQ-GAS-012','ADNOC Gas — EPC Helium Recovery Plant','أدنوك للغاز — EPC مصنع استرداد الهيليوم','epc',1200000000.00,'2024-01-01','2027-12-31','abu_dhabi'),
    (193,'CRQ-GAS-013','ADNOC Gas — Gas Transmission Network Inspection','أدنوك للغاز — فحص شبكة نقل الغاز','services',34000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (194,'CRQ-GAS-014','ADNOC Gas — 15-Year Gas SPA — Emirates Steel Industries','أدنوك للغاز — اتفاقية بيع غاز 15 سنة لإمارات ستيل','gas_spa',8500000000.00,'2026-01-01','2040-12-31','abu_dhabi'),
    (195,'CRQ-GAS-015','ADNOC Gas — LNG Tanker Loading Arm Services','أدنوك للغاز — خدمات أذرع تحميل ناقلات الغاز','services',18000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (196,'CRQ-GAS-016','ADNOC Gas — Carbon Capture & Sequestration EPC','أدنوك للغاز — EPC التقاط وتخزين الكربون','epc',1800000000.00,'2024-01-01','2028-12-31','abu_dhabi'),
    (197,'CRQ-GAS-017','ADNOC Gas — Pipeline Right-of-Way Maintenance','أدنوك للغاز — صيانة حق الطريق للأنابيب','services',15000000.00,'2024-02-01','2026-01-31','sharjah'),
    (198,'CRQ-GAS-018','ADNOC Gas — Gas Flare Monitoring & Reporting','أدنوك للغاز — رصد وتقارير حرق الغاز','services',8000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (199,'CRQ-GAS-019','ADNOC Gas — EPC Condensate Stabilization Train','أدنوك للغاز — EPC قطار تثبيت الكثيفة','epc',640000000.00,'2023-08-01','2026-07-31','abu_dhabi'),
    (200,'CRQ-GAS-020','ADNOC Gas — Pipeline Cathodic Protection Services','أدنوك للغاز — خدمات الحماية الكاثودية للأنابيب','services',12000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (201,'CRQ-GAS-021','ADNOC Gas — Gas Chromatography Lab Services','أدنوك للغاز — خدمات مختبر الكروماتوغرافيا الغازية','services',6500000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (202,'CRQ-GAS-022','ADNOC Gas — Plant Turnaround Management Services','أدنوك للغاز — خدمات إدارة إيقاف المصنع للصيانة','services',75000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (203,'CRQ-GAS-023','ADNOC Gas — NGL Export Terminal Services','أدنوك للغاز — خدمات محطة تصدير NGL','services',32000000.00,'2024-02-01','2027-01-31','abu_dhabi'),
    (204,'CRQ-GAS-024','ADNOC Gas — Cryogenic Pump Maintenance Services','أدنوك للغاز — خدمات صيانة مضخة التبريد العميق','services',22000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (205,'CRQ-GAS-025','ADNOC Gas — LNG Jetty Marine Services','أدنوك للغاز — خدمات رصيف الغاز الطبيعي المسال البحري','services',28000000.00,'2024-01-01','2026-12-31','abu_dhabi'),
    (206,'CRQ-GAS-026','ADNOC Gas — Gas Storage Cavern Technical Services','أدنوك للغاز — خدمات الكهف التقنية لتخزين الغاز','services',38000000.00,'2024-02-01','2027-01-31','abu_dhabi'),
    (207,'CRQ-GAS-027','ADNOC Gas — EPC Additional Train — Ruwais Gas Complex','أدنوك للغاز — EPC قطار إضافي مجمع الرويس للغاز','epc',2800000000.00,'2023-01-01','2028-12-31','abu_dhabi'),
    (208,'CRQ-GAS-028','ADNOC Gas — Gas Quality & Sampling Services','أدنوك للغاز — خدمات جودة وأخذ عينات الغاز','services',9000000.00,'2024-01-01','2025-12-31','abu_dhabi'),
    (209,'CRQ-GAS-029','ADNOC Gas — Plant Emergency Response & Fire Services','أدنوك للغاز — خدمات الاستجابة الطارئة وإطفاء الحرائق','services',14000000.00,'2024-03-01','2026-02-28','abu_dhabi'),
    (210,'CRQ-GAS-030','ADNOC Gas — Digital Operations Center (DOC) Services','أدنوك للغاز — خدمات مركز العمليات الرقمي','services',18000000.00,'2024-01-01','2026-12-31','dubai')
  ) AS c(seq, contract_number, title_en, title_ar, contract_type, value_aed, start_date, end_date, emirate)
  ON CONFLICT (contract_number) DO NOTHING;

  -- ══════════════════════════════════════════════════════════════════════════
  -- L&S (~25) + Distribution (~25) + Trading (6) + AGT (12) — Seq 211..278
  -- ══════════════════════════════════════════════════════════════════════════

  INSERT INTO contract (contract_number, title_en, title_ar, contract_type, status,
    our_party_id, counterparty_id, value_aed, currency, start_date, end_date,
    emirate, governing_law, language, created_at, updated_at, created_by, updated_by, is_active)
  SELECT c.contract_number, c.title_en, c.title_ar, c.contract_type, 'active',
    CASE c.subsidiary
      WHEN 'ls'       THEN v_ls_id
      WHEN 'dist'     THEN v_dist_id
      WHEN 'trading'  THEN v_trading_id
      WHEN 'agt'      THEN v_agt_id
      ELSE v_ls_id
    END,
    v_cp[((c.seq - 1) % v_cnt) + 1],
    c.value_aed, 'AED', c.start_date::date, c.end_date::date,
    c.emirate, 'uae_federal', 'en',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  FROM (VALUES
    -- L&S (~25)
    (211,'CRQ-LS-001','ADNOC L&S — Tanker Fleet Management Services','أدنوك للخدمات اللوجستية — خدمات إدارة أسطول الناقلات','services',180000000.00,'2024-01-01','2027-12-31','abu_dhabi','ls'),
    (212,'CRQ-LS-002','ADNOC L&S — Offshore Supply Vessel Operations','أدنوك للخدمات اللوجستية — عمليات سفن الإمداد البحري','services',95000000.00,'2024-01-01','2026-12-31','abu_dhabi','ls'),
    (213,'CRQ-LS-003','ADNOC L&S — Marine Terminal Maintenance','أدنوك للخدمات اللوجستية — صيانة المحطة البحرية','services',42000000.00,'2024-02-01','2027-01-31','abu_dhabi','ls'),
    (214,'CRQ-LS-004','ADNOC L&S — Port Logistics & Stevedoring Services','أدنوك للخدمات اللوجستية — خدمات لوجستيات الميناء والتحميل','services',55000000.00,'2024-01-01','2026-12-31','abu_dhabi','ls'),
    (215,'CRQ-LS-005','ADNOC L&S — EPC Crude Export Terminal Upgrade','أدنوك للخدمات اللوجستية — EPC ترقية محطة تصدير النفط','epc',960000000.00,'2023-07-01','2027-06-30','abu_dhabi','ls'),
    (216,'CRQ-LS-006','ADNOC L&S — Aviation Fueling Services — ADNOC Fields','أدنوك للخدمات اللوجستية — خدمات وقود الطيران حقول أدنوك','services',28000000.00,'2024-01-01','2026-12-31','abu_dhabi','ls'),
    (217,'CRQ-LS-007','ADNOC L&S — Hazmat Storage & Transport Services','أدنوك للخدمات اللوجستية — خدمات تخزين ونقل المواد الخطرة','services',18000000.00,'2024-03-01','2026-02-28','sharjah','ls'),
    (218,'CRQ-LS-008','ADNOC L&S — VLCC Charter — Jebel Dhanna Route','أدنوك للخدمات اللوجستية — استئجار ناقلة VLCC مسار جبل الظنة','services',210000000.00,'2024-01-01','2025-12-31','abu_dhabi','ls'),
    (219,'CRQ-LS-009','ADNOC L&S — Buoy Maintenance & Navigation Aids','أدنوك للخدمات اللوجستية — صيانة العوامات ومساعدات الملاحة','services',12000000.00,'2024-01-01','2025-12-31','abu_dhabi','ls'),
    (220,'CRQ-LS-010','ADNOC L&S — Freight & Cargo Consolidation Services','أدنوك للخدمات اللوجستية — خدمات تجميع الشحن والبضائع','services',35000000.00,'2024-02-01','2026-01-31','dubai','ls'),
    (221,'CRQ-LS-011','ADNOC L&S — Container Terminal Handling Services','أدنوك للخدمات اللوجستية — خدمات مناولة محطة الحاويات','services',62000000.00,'2024-01-01','2026-12-31','abu_dhabi','ls'),
    (222,'CRQ-LS-012','ADNOC L&S — Oil Terminal Operations — Ruwais','أدنوك للخدمات اللوجستية — عمليات محطة النفط الرويس','services',88000000.00,'2024-01-01','2027-12-31','abu_dhabi','ls'),
    (223,'CRQ-LS-013','ADNOC L&S — Vessel Inspection & Classification Assistance','أدنوك للخدمات اللوجستية — فحص السفن ومساعدة التصنيف','services',16000000.00,'2024-03-01','2026-02-28','abu_dhabi','ls'),
    (224,'CRQ-LS-014','ADNOC L&S — EPC New Tank Farm — Das Island','أدنوك للخدمات اللوجستية — EPC مزرعة خزانات جديدة جزيرة داس','epc',1400000000.00,'2023-04-01','2027-03-31','abu_dhabi','ls'),
    (225,'CRQ-LS-015','ADNOC L&S — Tugboat Services — Abu Dhabi Terminals','أدنوك للخدمات اللوجستية — خدمات قاطرات محطات أبوظبي','services',45000000.00,'2024-01-01','2026-12-31','abu_dhabi','ls'),
    (226,'CRQ-LS-016','ADNOC L&S — Marine Pilotage Services — Mussafah','أدنوك للخدمات اللوجستية — خدمات الإرشاد البحري مصفح','services',22000000.00,'2024-01-01','2026-12-31','abu_dhabi','ls'),
    (227,'CRQ-LS-017','ADNOC L&S — Subsea Umbilical Cable Laying Services','أدنوك للخدمات اللوجستية — خدمات مد كابل السرة تحت البحر','services',145000000.00,'2024-02-01','2027-01-31','abu_dhabi','ls'),
    (228,'CRQ-LS-018','ADNOC L&S — Helicopter Deck Maintenance Services','أدنوك للخدمات اللوجستية — خدمات صيانة طابق المروحيات','services',8000000.00,'2024-01-01','2025-12-31','abu_dhabi','ls'),
    (229,'CRQ-LS-019','ADNOC L&S — Dry Dock Repair Services','أدنوك للخدمات اللوجستية — خدمات إصلاح الحوض الجاف','services',38000000.00,'2024-01-01','2026-12-31','dubai','ls'),
    (230,'CRQ-LS-020','ADNOC L&S — Marine Casualty & Emergency Response','أدنوك للخدمات اللوجستية — الحوادث البحرية والاستجابة الطارئة','services',14000000.00,'2024-03-01','2026-02-28','abu_dhabi','ls'),
    (231,'CRQ-LS-021','ADNOC L&S — Oil Spill Response Equipment & Services','أدنوك للخدمات اللوجستية — معدات وخدمات الاستجابة للتسرب','services',9500000.00,'2024-01-01','2025-12-31','abu_dhabi','ls'),
    (232,'CRQ-LS-022','ADNOC L&S — EPC Multipurpose Terminal — Mussafah','أدنوك للخدمات اللوجستية — EPC محطة متعددة الأغراض مصفح','epc',780000000.00,'2024-01-01','2027-12-31','abu_dhabi','ls'),
    (233,'CRQ-LS-023','ADNOC L&S — LNG Carrier Charter — Asia Route','أدنوك للخدمات اللوجستية — استئجار ناقلة LNG مسار آسيا','services',380000000.00,'2024-01-01','2025-12-31','abu_dhabi','ls'),
    (234,'CRQ-LS-024','ADNOC L&S — Marine Warranty & P&I Services','أدنوك للخدمات اللوجستية — ضمان بحري وخدمات P&I','services',11000000.00,'2024-02-01','2026-01-31','dubai','ls'),
    (235,'CRQ-LS-025','ADNOC L&S — Concession — Khalifa Port Marine Services Zone','أدنوك للخدمات اللوجستية — امتياز منطقة خدمات ميناء خليفة البحري','concession',850000000.00,'2026-01-01','2046-12-31','abu_dhabi','ls'),
    -- Distribution (~25)
    (236,'CRQ-DIS-001','ADNOC Distribution — Fuel Station O&M Services Package','أدنوك للتوزيع — خدمات تشغيل وصيانة محطات الوقود','services',120000000.00,'2024-01-01','2026-12-31','abu_dhabi','dist'),
    (237,'CRQ-DIS-002','ADNOC Distribution — EPC Automated Fuel Terminals','أدنوك للتوزيع — EPC محطات وقود آلية','epc',450000000.00,'2024-01-01','2027-12-31','abu_dhabi','dist'),
    (238,'CRQ-DIS-003','ADNOC Distribution — Lubricant Blending Plant Services','أدنوك للتوزيع — خدمات مصنع خلط المزلقات','services',38000000.00,'2024-02-01','2026-01-31','dubai','dist'),
    (239,'CRQ-DIS-004','ADNOC Distribution — Fuel Card & Fleet Management System','أدنوك للتوزيع — بطاقة وقود ونظام إدارة الأسطول','services',22000000.00,'2024-01-01','2026-12-31','dubai','dist'),
    (240,'CRQ-DIS-005','ADNOC Distribution — Retail Network Branding & Signage','أدنوك للتوزيع — العلامة التجارية وإشارات الشبكة التجزئة','services',15000000.00,'2024-03-01','2026-02-28','dubai','dist'),
    (241,'CRQ-DIS-006','ADNOC Distribution — Aviation Fueling Infrastructure EPC','أدنوك للتوزيع — EPC بنية تحتية للوقود في الطيران','epc',280000000.00,'2024-01-01','2027-12-31','abu_dhabi','dist'),
    (242,'CRQ-DIS-007','ADNOC Distribution — Fuel Transport & Delivery Services','أدنوك للتوزيع — خدمات نقل وتسليم الوقود','services',65000000.00,'2024-01-01','2026-12-31','sharjah','dist'),
    (243,'CRQ-DIS-008','ADNOC Distribution — Convenience Store Fit-Out Services','أدنوك للتوزيع — خدمات تجهيز متاجر التسهيلات','services',32000000.00,'2024-02-01','2026-01-31','dubai','dist'),
    (244,'CRQ-DIS-009','ADNOC Distribution — EV Charging Infrastructure — Phase 1','أدنوك للتوزيع — EPC بنية تحتية للشحن الكهربائي المرحلة 1','epc',180000000.00,'2024-01-01','2026-12-31','abu_dhabi','dist'),
    (245,'CRQ-DIS-010','ADNOC Distribution — Fuel Quality Testing Lab Services','أدنوك للتوزيع — خدمات مختبر اختبار جودة الوقود','services',8500000.00,'2024-01-01','2025-12-31','abu_dhabi','dist'),
    (246,'CRQ-DIS-011','ADNOC Distribution — CCTV & Security Systems Services','أدنوك للتوزيع — خدمات أنظمة CCTV والأمان','services',18000000.00,'2024-03-01','2026-02-28','dubai','dist'),
    (247,'CRQ-DIS-012','ADNOC Distribution — Retail Waste Management Services','أدنوك للتوزيع — خدمات إدارة النفايات التجزئة','services',5000000.00,'2024-01-01','2025-12-31','abu_dhabi','dist'),
    (248,'CRQ-DIS-013','ADNOC Distribution — Forecourt Equipment Maintenance','أدنوك للتوزيع — صيانة معدات ساحة محطة الوقود','services',24000000.00,'2024-02-01','2026-01-31','abu_dhabi','dist'),
    (249,'CRQ-DIS-014','ADNOC Distribution — LPG Distribution Network Services','أدنوك للتوزيع — خدمات شبكة توزيع غاز البترول المسال','services',45000000.00,'2024-01-01','2027-12-31','abu_dhabi','dist'),
    (250,'CRQ-DIS-015','ADNOC Distribution — Depot & Bulk Fuel Storage O&M','أدنوك للتوزيع — تشغيل وصيانة مستودع وتخزين الوقود الكبير','services',58000000.00,'2024-01-01','2027-12-31','sharjah','dist'),
    (251,'CRQ-DIS-016','ADNOC Distribution — Point of Sale IT Systems Integration','أدنوك للتوزيع — تكامل أنظمة IT لنقطة البيع','services',14000000.00,'2024-03-01','2026-02-28','dubai','dist'),
    (252,'CRQ-DIS-017','ADNOC Distribution — Training & Competency Development','أدنوك للتوزيع — خدمات التدريب وتطوير الكفاءات','services',6500000.00,'2024-01-01','2025-12-31','abu_dhabi','dist'),
    (253,'CRQ-DIS-018','ADNOC Distribution — New Station Construction — Emirate A','أدنوك للتوزيع — بناء محطة جديدة إمارة أبوظبي','epc',120000000.00,'2024-01-01','2026-12-31','abu_dhabi','dist'),
    (254,'CRQ-DIS-019','ADNOC Distribution — Fuel Hedging Advisory Services','أدنوك للتوزيع — خدمات استشارات تحوط الوقود','services',4000000.00,'2024-02-01','2026-01-31','dubai','dist'),
    (255,'CRQ-DIS-020','ADNOC Distribution — Bitumen Supply & Laying Services','أدنوك للتوزيع — خدمات توريد ووضع الزفت','services',28000000.00,'2024-01-01','2026-12-31','abu_dhabi','dist'),
    (256,'CRQ-DIS-021','ADNOC Distribution — Customer Portal & Mobile App Dev.','أدنوك للتوزيع — تطوير بوابة العملاء وتطبيق الهاتف','services',9000000.00,'2024-03-01','2026-02-28','dubai','dist'),
    (257,'CRQ-DIS-022','ADNOC Distribution — Environmental Compliance Services','أدنوك للتوزيع — خدمات الامتثال البيئي','services',5500000.00,'2024-01-01','2025-12-31','abu_dhabi','dist'),
    (258,'CRQ-DIS-023','ADNOC Distribution — Tank Calibration & Inspection Services','أدنوك للتوزيع — خدمات معايرة وفحص الخزانات','services',7200000.00,'2024-02-01','2026-01-31','sharjah','dist'),
    (259,'CRQ-DIS-024','ADNOC Distribution — Retail Expansion — Saudi Border Stn','أدنوك للتوزيع — توسعة التجزئة محطة الحدود السعودية','epc',95000000.00,'2024-01-01','2026-12-31','abu_dhabi','dist'),
    (260,'CRQ-DIS-025','ADNOC Distribution — Metering & Compliance Systems Upg.','أدنوك للتوزيع — ترقية أنظمة القياس والامتثال','services',12000000.00,'2024-01-01','2026-12-31','abu_dhabi','dist'),
    -- Trading (6)
    (261,'CRQ-TRD-001','ADNOC Trading — Crude Scheduling & Nomination IT System','أدنوك للتجارة — نظام IT لجدولة وترشيح النفط الخام','services',18000000.00,'2024-01-01','2026-12-31','dubai','trading'),
    (262,'CRQ-TRD-002','ADNOC Trading — Back-Office Operations Services','أدنوك للتجارة — خدمات عمليات المكتب الخلفي','services',12000000.00,'2024-02-01','2026-01-31','dubai','trading'),
    (263,'CRQ-TRD-003','ADNOC Trading — 5-Year Naphtha Term SPA — East Asia','أدنوك للتجارة — اتفاقية بيع نافتا لمدة 5 سنوات شرق آسيا','gas_spa',5500000000.00,'2025-01-01','2030-12-31','abu_dhabi','trading'),
    (264,'CRQ-TRD-004','ADNOC Trading — Commodity Risk Management Advisory','أدنوك للتجارة — استشارات إدارة مخاطر السلع','services',8000000.00,'2024-01-01','2025-12-31','dubai','trading'),
    (265,'CRQ-TRD-005','ADNOC Trading — Crude Quality Inspection & Sampling','أدنوك للتجارة — فحص جودة النفط الخام وأخذ العينات','services',6500000.00,'2024-02-01','2026-01-31','fujairah','trading'),
    (266,'CRQ-TRD-006','ADNOC Trading — Port Agency & Customs Brokerage','أدنوك للتجارة — وكالة المنفذ والسمسرة الجمركية','services',9500000.00,'2024-01-01','2025-12-31','dubai','trading'),
    -- AGT (~12)
    (267,'CRQ-AGT-001','ADNOC Global Trading — Trading Technology Platform Dev.','أدنوك للتجارة الدولية — تطوير منصة التكنولوجيا التجارية','services',35000000.00,'2024-01-01','2026-12-31','dubai','agt'),
    (268,'CRQ-AGT-002','ADNOC Global Trading — Singapore Trading Hub Services','أدنوك للتجارة الدولية — خدمات مركز التداول سنغافورة','services',22000000.00,'2024-02-01','2026-01-31','dubai','agt'),
    (269,'CRQ-AGT-003','ADNOC Global Trading — London Analytics & Research','أدنوك للتجارة الدولية — خدمات التحليل والبحث لندن','services',14000000.00,'2024-01-01','2025-12-31','dubai','agt'),
    (270,'CRQ-AGT-004','ADNOC Global Trading — Derivative Clearing Advisory','أدنوك للتجارة الدولية — استشارات تسوية المشتقات','services',9500000.00,'2024-03-01','2026-02-28','dubai','agt'),
    (271,'CRQ-AGT-005','ADNOC Global Trading — Freight Derivatives & FFA Services','أدنوك للتجارة الدولية — مشتقات الشحن وخدمات FFA','services',8000000.00,'2024-01-01','2025-12-31','dubai','agt'),
    (272,'CRQ-AGT-006','ADNOC Global Trading — Cargo Operations & Loading Masters','أدنوك للتجارة الدولية — عمليات الشحن وخبراء التحميل','services',12000000.00,'2024-02-01','2026-01-31','abu_dhabi','agt'),
    (273,'CRQ-AGT-007','ADNOC Global Trading — Physical Oil Market Analytics','أدنوك للتجارة الدولية — تحليلات سوق النفط الفعلي','services',11000000.00,'2024-01-01','2026-12-31','dubai','agt'),
    (274,'CRQ-AGT-008','ADNOC Global Trading — Trade Finance Banking Services','أدنوك للتجارة الدولية — خدمات تمويل التجارة البنكية','services',18000000.00,'2024-01-01','2025-12-31','dubai','agt'),
    (275,'CRQ-AGT-009','ADNOC Global Trading — Geopolitical Risk Advisory Services','أدنوك للتجارة الدولية — خدمات استشارات المخاطر الجيوسياسية','services',7500000.00,'2024-03-01','2026-02-28','dubai','agt'),
    (276,'CRQ-AGT-010','ADNOC Global Trading — 3-Year Residue Fuel SPA (HSFO)','أدنوك للتجارة الدولية — اتفاقية بيع وقود ثقيل HSFO 3 سنوات','gas_spa',3200000000.00,'2025-01-01','2028-12-31','abu_dhabi','agt'),
    (277,'CRQ-AGT-011','ADNOC Global Trading — Technology & Data Infra Upgrade','أدنوك للتجارة الدولية — ترقية التكنولوجيا والبنية البيانية','services',28000000.00,'2024-01-01','2026-12-31','dubai','agt'),
    (278,'CRQ-AGT-012','ADNOC Global Trading — Trading Compliance & Reporting','أدنوك للتجارة الدولية — الامتثال التجاري والتقارير','services',9000000.00,'2024-02-01','2026-01-31','dubai','agt')
  ) AS c(seq, contract_number, title_en, title_ar, contract_type, value_aed, start_date, end_date, emirate, subsidiary)
  ON CONFLICT (contract_number) DO NOTHING;

  -- ══════════════════════════════════════════════════════════════════════════
  -- CONTRACT_VERSION: one row per newly seeded contract (v1, current)
  -- ══════════════════════════════════════════════════════════════════════════

  INSERT INTO contract_version (
    contract_id, version_number, body_en,
    data_classification, ingestion_status,
    created_at, created_by, is_active
  )
  SELECT c.id, 1,
    'Demo seed contract — version 1, pending full document ingestion.',
    'demo', 'pending',
    NOW(), v_seed_user, TRUE
  FROM contract c
  WHERE c.contract_number LIKE 'CRQ-%'
    AND c.is_active = TRUE
    AND NOT EXISTS (
      SELECT 1 FROM contract_version cv
      WHERE cv.contract_id = c.id AND cv.version_number = 1
    );

  RAISE NOTICE '328: Contracts + contract_version rows seeded (ON CONFLICT DO NOTHING).';

END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (328, '328_crq_seed_contracts', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 328;
-- DELETE FROM contract_version WHERE contract_id IN (SELECT id FROM contract WHERE contract_number LIKE 'CRQ-%');
-- DELETE FROM contract WHERE contract_number LIKE 'CRQ-%';
-- COMMIT;
-- ============================================================
