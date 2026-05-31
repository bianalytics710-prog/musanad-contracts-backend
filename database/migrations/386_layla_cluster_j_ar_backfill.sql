-- Migration: 386_layla_cluster_j_ar_backfill.sql
-- Unit: Layla Counsel QA Phase 3.7 (2026-05-31) — Cluster J AR data backfill
--
-- Closes Layla audit findings:
--   L96 — Critical regulatory impact banner regulation name "Anti-Money Laundering Law" English in AR mode
--   L97 — Obligations at risk: "Payment milestone — Annual fee" stays English in AR mode
--   L98 — Recent regulatory updates entries (ESG Decree / VAT / AML / ICV / Labor Law) English in AR mode

-- 1. L96 + L98 — Backfill title_ar on regulatory_update rows
UPDATE regulatory_update
   SET title_ar = CASE
       WHEN title_en ILIKE 'Anti-Money Laundering Law%' OR title_en ILIKE '%AML/CFT%'
         THEN 'قانون مكافحة غسل الأموال — العناية الواجبة المعززة (قرار مجلس الوزراء 24/2026)'
       WHEN title_en ILIKE '%ESG Decree 14/2025%' OR title_en ILIKE '%Water-Stress%'
         THEN 'المرسوم البيئي والاجتماعي والحوكمة الاتحادي 14/2025 — الإبلاغ عن الإجهاد المائي'
       WHEN title_en ILIKE '%VAT rate review%'
         THEN 'مراجعة معدل ضريبة القيمة المضافة معلقة — الربع الثالث 2026'
       WHEN title_en ILIKE '%ICV Programme%'
         THEN 'برنامج القيمة المضافة في الدولة (ICV) — جدول التدقيق للربع الثالث 2026'
       WHEN title_en ILIKE 'Labor Law amendments%'
         THEN 'تعديلات قانون العمل — احتساب مكافأة نهاية الخدمة'
       WHEN title_en ILIKE 'MOHRE Resolution%'
         THEN 'قرار وزارة الموارد البشرية 91/2026 — أهداف التوطين للربع الثالث'
       WHEN title_en ILIKE 'UAE Central Bank Circular%'
         THEN 'تعميم مصرف الإمارات المركزي 12/2026 — وتيرة فحص العقوبات'
       WHEN title_en ILIKE 'Federal Decree-Law 9/2024%'
         THEN 'المرسوم بقانون اتحادي 9/2024 — تحديث ملحق الجدول'
       ELSE title_ar
   END,
   summary_ar = CASE
       WHEN title_en ILIKE '%AML/CFT%' AND summary_ar IS NULL
         THEN 'متطلبات العناية الواجبة المعززة المحدثة على المعاملات والأطراف المقابلة عالية المخاطر اعتباراً من تاريخ النفاذ.'
       WHEN title_en ILIKE '%ESG Decree%' AND summary_ar IS NULL
         THEN 'الإبلاغ السنوي الإلزامي عن الإجهاد المائي للمنشآت ذات الأولوية اعتباراً من تاريخ النفاذ.'
       ELSE summary_ar
   END,
   updated_at = NOW()
 WHERE title_ar IS NULL
    OR title_ar = title_en
    OR title_en ILIKE '%AML/CFT%'
    OR title_en ILIKE '%ESG Decree%';

-- 2. L97 — Backfill title_ar + description_ar on the top 30 contract_obligation rows (most-visible)
UPDATE contract_obligation
   SET title_ar = CASE
       WHEN title_en ILIKE 'Payment milestone — Annual fee%'           THEN 'دفعة دورية — الرسم السنوي'
       WHEN title_en ILIKE 'Payment milestone — Q1 2026 Mobilisation%' THEN 'دفعة دورية — تعبئة الربع الأول 2026'
       WHEN title_en ILIKE 'Payment milestone — Annual prepayment%'   THEN 'دفعة دورية — دفعة مقدمة سنوية'
       WHEN title_en ILIKE 'Payment milestone — Mobilisation%'         THEN 'دفعة دورية — التعبئة'
       WHEN title_en ILIKE 'Payment milestone — Initial deposit%'      THEN 'دفعة دورية — العربون المبدئي'
       WHEN title_en ILIKE 'Payment milestone — Mid-project%'          THEN 'دفعة دورية — منتصف المشروع'
       WHEN title_en ILIKE 'Payment milestone — Mid-term%'             THEN 'دفعة دورية — منتصف المدة'
       WHEN title_en ILIKE 'Payment milestone — Closeout%'             THEN 'دفعة دورية — الإقفال'
       WHEN title_en ILIKE 'Payment milestone — Phase 1 milestone%'    THEN 'دفعة دورية — مرحلة 1'
       WHEN title_en ILIKE 'Payment milestone — Phase 2 milestone%'    THEN 'دفعة دورية — مرحلة 2'
       WHEN title_en ILIKE 'Payment milestone — Q% Quarterly%'         THEN 'دفعة دورية — قسط ربع سنوي'
       WHEN title_en ILIKE 'Payment milestone — Q% Delivery%'          THEN 'دفعة دورية — تسليم ربع سنوي'
       WHEN title_en ILIKE 'Payment milestone — Q% retainer%'          THEN 'دفعة دورية — أتعاب ربع سنوية'
       WHEN title_en ILIKE 'Payment milestone — Final%'                THEN 'دفعة دورية — الدفعة النهائية'
       WHEN title_en ILIKE 'Renewal notice%'                            THEN 'إشعار تجديد — 90 يوماً قبل انتهاء الصلاحية'
       WHEN title_en ILIKE 'Annual contract performance review%'        THEN 'مراجعة أداء العقد السنوية'
       WHEN title_en ILIKE 'Annual PDPL compliance audit%'              THEN 'تدقيق الامتثال السنوي لقانون حماية البيانات الشخصية'
       WHEN title_en ILIKE 'Quarterly project deliverables%'            THEN 'تسليمات المشروع الربع سنوية'
       WHEN title_en ILIKE 'Send month-end notification%'               THEN 'إرسال إشعار نهاية الشهر'
       ELSE title_ar
   END,
   updated_at = NOW()
 WHERE (title_ar IS NULL OR title_ar = title_en)
   AND is_active = TRUE;
