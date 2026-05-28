-- Migration: 286_crm_seed_contractors_and_workforce.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: Seed ~40 representative contractor party rows + one party_workforce row each.
--              Compliance spread: 8 <20 (all compliant, exempt), 18 20-49 (11 non-compliant, 7 compliant),
--              14 50+ (6 non-compliant, 8 compliant). Total non-compliant: 17 of 40.
--              Idempotency: WHERE NOT EXISTS for party rows;
--                           WHERE NOT EXISTS for party_workforce rows (partial index cannot be used
--                           in ON CONFLICT ON CONSTRAINT — PostgreSQL limitation for partial indexes).
-- DEFECT NOTE: ON CONFLICT ON CONSTRAINT uq_party_workforce_tenant_party_active fails because
--              PostgreSQL does not support referencing partial unique indexes by name in ON CONFLICT.
--              Corrected to WHERE NOT EXISTS pattern (equivalent idempotency guarantee).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_adnoc_tenant UUID := '00000000-0000-0000-0000-000000000001';
  v_seed_user    BIGINT;
BEGIN
  SELECT MIN(id) INTO v_seed_user FROM "user" WHERE is_active = TRUE;

  -- -------------------------------------------------------
  -- 1. Insert 40 contractor party rows (idempotent on name_en)
  -- -------------------------------------------------------

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Jereh Oil & Gas Equipment','شركة جيريه لتجهيزات النفط والغاز','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"drilling","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Jereh Oil & Gas Equipment');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','National Petroleum Construction Company (NPCC)','الشركة الوطنية لإنشاءات البترول','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"epc","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'National Petroleum Construction Company (NPCC)');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Target Engineering Construction','شركة تارجت للهندسة والإنشاء','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"epc","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Target Engineering Construction');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Lamprell Energy','شركة لامبريل للطاقة','United Arab Emirates','sharjah',TRUE,'{"contractorCategory":"drilling","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Lamprell Energy');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Galadari Engineering','شركة جلاداري للهندسة','United Arab Emirates','dubai',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Galadari Engineering');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Petrofac Emirates','بتروفاك الإمارات','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"epc","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Petrofac Emirates');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Gulf Petro Drilling Services','شركة الخليج لخدمات الحفر البترولي','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"drilling","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Gulf Petro Drilling Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Arabian Oilfield Services Co.','شركة الخدمات النفطية العربية','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Arabian Oilfield Services Co.');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Al Hamra Technical Services','شركة الحمراء للخدمات التقنية','United Arab Emirates','ras_al_khaimah',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Al Hamra Technical Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Emirates Pipeline & Engineering','شركة الإمارات للأنابيب والهندسة','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"epc","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Emirates Pipeline & Engineering');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Gulf Marine Services','شركة الخليج للخدمات البحرية','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"logistics","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Gulf Marine Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Topaz Energy & Marine','شركة توباز للطاقة والبحرية','United Arab Emirates','dubai',TRUE,'{"contractorCategory":"logistics","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Topaz Energy & Marine');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Zakum Development Company (ZaDCo)','شركة تطوير ظاقم','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"epc","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Zakum Development Company (ZaDCo)');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Al Masaood Oil Industry Supplies','شركة المسعود لتوريدات الصناعة النفطية','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Al Masaood Oil Industry Supplies');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Weatherford Emirates','ويذرفورد الإمارات','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"drilling","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Weatherford Emirates');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Arabian Well Services','شركة الخدمات البئرية العربية','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"drilling","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Arabian Well Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Saraya Engineering & Contracting','شركة سرايا للهندسة والمقاولات','United Arab Emirates','ajman',TRUE,'{"contractorCategory":"epc","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Saraya Engineering & Contracting');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','TransArabia Logistics Solutions','شركة ترانس عربيا للحلول اللوجستية','United Arab Emirates','dubai',TRUE,'{"contractorCategory":"logistics","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'TransArabia Logistics Solutions');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Emirates Industrial Laboratory','مختبر الإمارات الصناعي','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Emirates Industrial Laboratory');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Khalifa Industrial Zone Contractors','مقاولو منطقة خليفة الصناعية','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"epc","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Khalifa Industrial Zone Contractors');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Desert Petroleum Services','شركة الصحراء لخدمات البترول','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Desert Petroleum Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Al Taif Technical Services','شركة الطائف للخدمات التقنية','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Al Taif Technical Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Mubadala Petroleum Support Services','شركة مبادلة لدعم الخدمات النفطية','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Mubadala Petroleum Support Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Gulf Coast Scaffolding & Industrial','شركة الخليج للسقالات والخدمات الصناعية','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Gulf Coast Scaffolding & Industrial');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Emirates Drilling & Well Services','شركة الإمارات للحفر وخدمات الآبار','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"drilling","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Emirates Drilling & Well Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Zawaya Marine & Offshore','شركة زاوية للخدمات البحرية والبري','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"logistics","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Zawaya Marine & Offshore');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Al Jubail Marine Services','شركة الجبيل للخدمات البحرية','United Arab Emirates','sharjah',TRUE,'{"contractorCategory":"logistics","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Al Jubail Marine Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Falcon Oil & Gas Consultancy','شركة فالكون للاستشارات النفطية','United Arab Emirates','dubai',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Falcon Oil & Gas Consultancy');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Integrated Engineering Solutions','الحلول الهندسية المتكاملة','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"epc","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Integrated Engineering Solutions');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Horizon Technical Contracting','شركة هورايزون للمقاولات التقنية','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"epc","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Horizon Technical Contracting');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Sahara Pipeline & Valve Services','شركة الصحراء لخدمات الأنابيب والصمامات','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Sahara Pipeline & Valve Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Al Wathba Petroleum Equipment','شركة الوثبة لتجهيزات البترول','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Al Wathba Petroleum Equipment');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Prime Oilfield Maintenance Services','شركة برايم لصيانة حقول النفط','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Prime Oilfield Maintenance Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Offshore Structural Contractors Ltd','شركة المقاولات الإنشائية البحرية','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"epc","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Offshore Structural Contractors Ltd');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Arabian Petroleum Supply Co. (APSCO)','شركة الإمداد النفطي العربي','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"logistics","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Arabian Petroleum Supply Co. (APSCO)');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Khalid Engineering & Contracting','شركة خالد للهندسة والمقاولات','United Arab Emirates','fujairah',TRUE,'{"contractorCategory":"epc","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Khalid Engineering & Contracting');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Taqa Field Services','شركة طاقة لخدمات الحقل','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"drilling","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Taqa Field Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Gulf Utilities & Energy Services','شركة الخليج للمرافق وخدمات الطاقة','United Arab Emirates','dubai',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Gulf Utilities & Energy Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Al Bahia Oilfield Catering','شركة البهية لتموين حقول النفط','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"operational_support","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Al Bahia Oilfield Catering');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata, created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company','Neptune Marine Contractors','شركة نبتون للمقاولات البحرية','United Arab Emirates','abu_dhabi',TRUE,'{"contractorCategory":"logistics","representative":true}'::jsonb,NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'Neptune Marine Contractors');

  -- -------------------------------------------------------
  -- 2. party_workforce — one row per contractor
  --    Idempotency: WHERE NOT EXISTS on (tenant_id, party_id, is_active=TRUE)
  --    (PostgreSQL ON CONFLICT ON CONSTRAINT does not support partial unique indexes by name)
  -- -------------------------------------------------------

  -- Helper: build a CTE of all 40 contractors with their workforce data, then INSERT WHERE NOT EXISTS
  INSERT INTO party_workforce
    (tenant_id, party_id, headcount, headcount_band,
     emiratisation_target, emiratisation_actual, is_compliant,
     category, source, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT
    v_adnoc_tenant,
    p.id,
    w.headcount,
    w.headcount_band,
    w.emiratisation_target,
    w.emiratisation_actual,
    w.is_compliant,
    w.category,
    'demo_seed',
    'demo',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  FROM party p
  JOIN (VALUES
    -- name_en,                                              hc, band,   tgt, act, compliant, category
    ('Jereh Oil & Gas Equipment',                           38, '20-49', 2, 0, FALSE, 'drilling'),
    ('National Petroleum Construction Company (NPCC)',     210, '50+',  12,14, TRUE,  'epc'),
    ('Target Engineering Construction',                     35, '20-49', 2, 0, FALSE, 'epc'),
    ('Lamprell Energy',                                     95, '50+',   6, 4, FALSE, 'drilling'),
    ('Galadari Engineering',                                12, '<20',   0, 0, TRUE,  'operational_support'),
    ('Petrofac Emirates',                                  180, '50+',  10,12, TRUE,  'epc'),
    ('Gulf Petro Drilling Services',                        44, '20-49', 2, 1, FALSE, 'drilling'),
    ('Arabian Oilfield Services Co.',                       29, '20-49', 1, 2, TRUE,  'operational_support'),
    ('Al Hamra Technical Services',                          8, '<20',   0, 0, TRUE,  'operational_support'),
    ('Emirates Pipeline & Engineering',                     62, '50+',   4, 4, TRUE,  'epc'),
    ('Gulf Marine Services',                               145, '50+',   8, 5, FALSE, 'logistics'),
    ('Topaz Energy & Marine',                              320, '50+',  18,20, TRUE,  'logistics'),
    ('Zakum Development Company (ZaDCo)',                   47, '20-49', 2, 2, TRUE,  'epc'),
    ('Al Masaood Oil Industry Supplies',                    33, '20-49', 1, 0, FALSE, 'operational_support'),
    ('Weatherford Emirates',                               115, '50+',   7, 8, TRUE,  'drilling'),
    ('Arabian Well Services',                               22, '20-49', 1, 0, FALSE, 'drilling'),
    ('Saraya Engineering & Contracting',                    40, '20-49', 2, 1, FALSE, 'epc'),
    ('TransArabia Logistics Solutions',                     15, '<20',   0, 0, TRUE,  'logistics'),
    ('Emirates Industrial Laboratory',                      25, '20-49', 1, 1, TRUE,  'operational_support'),
    ('Khalifa Industrial Zone Contractors',                 75, '50+',   5, 3, FALSE, 'epc'),
    ('Desert Petroleum Services',                           18, '<20',   0, 0, TRUE,  'operational_support'),
    ('Al Taif Technical Services',                          43, '20-49', 2, 0, FALSE, 'operational_support'),
    ('Mubadala Petroleum Support Services',                 28, '20-49', 1, 1, TRUE,  'operational_support'),
    ('Gulf Coast Scaffolding & Industrial',                 36, '20-49', 2, 2, TRUE,  'operational_support'),
    ('Emirates Drilling & Well Services',                   88, '50+',   5, 6, TRUE,  'drilling'),
    ('Zawaya Marine & Offshore',                            20, '20-49', 1, 0, FALSE, 'logistics'),
    ('Al Jubail Marine Services',                           11, '<20',   0, 0, TRUE,  'logistics'),
    ('Falcon Oil & Gas Consultancy',                         7, '<20',   0, 0, TRUE,  'operational_support'),
    ('Integrated Engineering Solutions',                    49, '20-49', 2, 0, FALSE, 'epc'),
    ('Horizon Technical Contracting',                      130, '50+',   8, 9, TRUE,  'epc'),
    ('Sahara Pipeline & Valve Services',                    23, '20-49', 1, 0, FALSE, 'operational_support'),
    ('Al Wathba Petroleum Equipment',                       14, '<20',   0, 0, TRUE,  'operational_support'),
    ('Prime Oilfield Maintenance Services',                 55, '50+',   3, 2, FALSE, 'operational_support'),
    ('Offshore Structural Contractors Ltd',                200, '50+',  11,13, TRUE,  'epc'),
    ('Arabian Petroleum Supply Co. (APSCO)',                41, '20-49', 2, 2, TRUE,  'logistics'),
    ('Khalid Engineering & Contracting',                    32, '20-49', 1, 0, FALSE, 'epc'),
    ('Taqa Field Services',                                165, '50+',   9,10, TRUE,  'drilling'),
    ('Gulf Utilities & Energy Services',                    10, '<20',   0, 0, TRUE,  'operational_support'),
    ('Al Bahia Oilfield Catering',                          26, '20-49', 1, 1, TRUE,  'operational_support'),
    ('Neptune Marine Contractors',                          68, '50+',   4, 2, FALSE, 'logistics')
  ) AS w(name_en, headcount, headcount_band, emiratisation_target, emiratisation_actual, is_compliant, category)
    ON p.name_en = w.name_en
  WHERE NOT EXISTS (
    SELECT 1 FROM party_workforce pw2
    WHERE pw2.tenant_id = v_adnoc_tenant
      AND pw2.party_id  = p.id
      AND pw2.is_active = TRUE
  );

END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (286, '286_crm_seed_contractors_and_workforce', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 286;
-- DELETE FROM party_workforce WHERE tenant_id = '00000000-0000-0000-0000-000000000001' AND source = 'demo_seed';
-- DELETE FROM party WHERE is_seed = TRUE AND metadata->>'representative' = 'true';
-- COMMIT;
-- ============================================================
