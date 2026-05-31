-- Migration: 373_khalid_fix_arabic_mojibake.sql
-- Unit: Khalid Compliance QA Phase 3.6 (2026-05-31)
-- Fixes K13 — 5-10 counterparty rows on the cascade detail ICV impact view
-- render with mojibake Arabic ("Ø´Ø±ÙƒØ©…" — UTF-8 bytes mis-decoded as Latin-1).
-- Half the rows show proper Arabic, half show garbled — confirming a specific
-- seed migration wrote bytes incorrectly. This migration UPDATEs party.name_ar
-- with proper Arabic strings for every affected counterparty.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Update by English name (stable across schema versions) to proper Arabic.
UPDATE party
   SET name_ar = CASE name_en
                   WHEN 'Al Mansoori Petroleum Services'    THEN 'شركة المنصوري لخدمات البترول'
                   WHEN 'Subsea 7 Abu Dhabi'                THEN 'سابسي 7 أبوظبي'
                   WHEN 'Aker Solutions UAE'                THEN 'آكر سولوشنز الإمارات'
                   WHEN 'McDermott Middle East'             THEN 'ماكدرموت الشرق الأوسط'
                   WHEN 'Al Ain Petrochemical Services'     THEN 'شركة العين للخدمات البتروكيماوية'
                   WHEN 'CB&I Middle East'                  THEN 'CB&I الشرق الأوسط'
                   WHEN 'Samsung C&T UAE'                   THEN 'سامسونج C&T الإمارات'
                   WHEN 'Prime EPC Group'                   THEN 'مجموعة برايم EPC'
                   WHEN 'National EPC Solutions'            THEN 'حلول EPC الوطنية'
                   WHEN 'Gulf Freight Carriers'             THEN 'ناقلات الشحن الخليجية'
                   WHEN 'Silver Star Shipping'              THEN 'شيبنغ النجمة الفضية'
                   WHEN 'Umm Al Quwain Shipping'            THEN 'شيبنغ أم القيوين'
                   WHEN 'Gulf Scaffold & Access'            THEN 'سقالات الخليج والوصول'
                   WHEN 'Al Qusais Oilfield Works'          THEN 'القصيص لأعمال حقول النفط'
                   WHEN 'Ajman Petroleum Services'          THEN 'خدمات البترول عجمان'
                   ELSE name_ar
                 END,
       updated_at = NOW(),
       updated_by = 1
 WHERE is_active = TRUE
   AND name_en IN (
     'Al Mansoori Petroleum Services',
     'Subsea 7 Abu Dhabi',
     'Aker Solutions UAE',
     'McDermott Middle East',
     'Al Ain Petrochemical Services',
     'CB&I Middle East',
     'Samsung C&T UAE',
     'Prime EPC Group',
     'National EPC Solutions',
     'Gulf Freight Carriers',
     'Silver Star Shipping',
     'Umm Al Quwain Shipping',
     'Gulf Scaffold & Access',
     'Al Qusais Oilfield Works',
     'Ajman Petroleum Services'
   );

-- Defensive sweep — any party whose name_ar contains mojibake markers
-- (Ø/Ù/Ú/Û are byte-pair signatures of UTF-8-as-Latin-1) gets a fallback
-- of the English name so we don't ship garbled glyphs even if the lookup
-- table above misses a counterparty.
UPDATE party
   SET name_ar = name_en,
       updated_at = NOW(),
       updated_by = 1
 WHERE is_active = TRUE
   AND name_ar ~ '[ØÙÚÛ]';

COMMIT;

-- ============================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (373, '373_khalid_fix_arabic_mojibake', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Data-only UPDATE; restore from a recent party backup if needed.
-- DELETE FROM schema_migrations WHERE version = 373;
