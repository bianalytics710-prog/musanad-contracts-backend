-- Migration: 303_crn_seed_hero_contract_clauses.sql
-- Module: CR-N — Services-Contract Budget Burn (M21 Financial Intelligence, Cost half)
-- Description: Seed hero contract (CRN-296-HERO-001: ADNOC Offshore→Drilling AED 4.22B) +
--              2 smaller services contracts (HERO-002 + HERO-003) + contract_version rows
--              + cure_period + liquidated_damages extracted clauses on hero contract.
--              Idempotency: WHERE NOT EXISTS on contract_number.
--              NOTE: contract table has NO tenant_id column (verified from live schema).
--              our_party_id = ADNOC Offshore; counterparty_id = ADNOC Drilling (mig 285).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_seed_user  BIGINT;
  v_tenant_id  UUID := '00000000-0000-0000-0000-000000000001';

  -- Party IDs (seeded in mig 285)
  v_adnoc_offshore_id BIGINT;
  v_adnoc_onshore_id  BIGINT;
  v_adnoc_drilling_id BIGINT;

  -- Contract IDs (resolved after insert)
  v_hero1_id   BIGINT;
  v_hero2_id   BIGINT;
  v_hero3_id   BIGINT;

  -- Contract version IDs
  v_cv1_id     BIGINT;
  v_cv2_id     BIGINT;
  v_cv3_id     BIGINT;

BEGIN
  -- Resolve seed actor
  SELECT MIN(id) INTO v_seed_user FROM "user" WHERE is_active = TRUE;

  -- Resolve party IDs (seeded mig 285)
  SELECT id INTO v_adnoc_offshore_id FROM party WHERE name_en = 'ADNOC Offshore'  AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_adnoc_onshore_id  FROM party WHERE name_en = 'ADNOC Onshore'   AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_adnoc_drilling_id FROM party WHERE name_en = 'ADNOC Drilling'  AND is_active = TRUE LIMIT 1;

  IF v_adnoc_offshore_id IS NULL OR v_adnoc_drilling_id IS NULL THEN
    RAISE EXCEPTION 'ADNOC Offshore or ADNOC Drilling party not found — ensure migration 285 has been applied'
      USING ERRCODE = 'P0002';
  END IF;

  -- ── HERO-001: ADNOC Offshore — Jack-Up Drilling Rigs + Manpower ──────────
  INSERT INTO contract (
    contract_number, title_en, title_ar, contract_type, status,
    our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date,
    emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT
    'CRN-296-HERO-001',
    'ADNOC Offshore — Jack-Up Drilling Rigs + Manpower (2 rigs)',
    'أدنوك للبترول البحري — منصات الحفر الرافعة + القوى العاملة (منصتان)',
    'services', 'active',
    v_adnoc_offshore_id, v_adnoc_drilling_id,
    4220000000.00, 'AED', '2024-01-01', '2028-12-31',
    'abu_dhabi', 'uae_federal', 'en',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (
    SELECT 1 FROM contract WHERE contract_number = 'CRN-296-HERO-001'
  );

  SELECT id INTO v_hero1_id FROM contract WHERE contract_number = 'CRN-296-HERO-001';

  -- contract_version for HERO-001
  INSERT INTO contract_version (
    contract_id, version_number, body_en,
    data_classification, ingestion_status,
    created_at, created_by, is_active
  )
  SELECT
    v_hero1_id, 1,
    'Day-rate services contract for two jack-up drilling rigs. Contractor shall provide drilling services at agreed day-rates. Performance standards, cure period, and liquidated damages provisions apply per Annexes B and C.',
    'demo', 'pending',
    NOW(), v_seed_user, TRUE
  WHERE NOT EXISTS (
    SELECT 1 FROM contract_version WHERE contract_id = v_hero1_id AND version_number = 1
  );

  SELECT id INTO v_cv1_id FROM contract_version WHERE contract_id = v_hero1_id AND version_number = 1;

  -- ── HERO-002: ADNOC Offshore — Subsea Fracturing & Stimulation ───────────
  INSERT INTO contract (
    contract_number, title_en, title_ar, contract_type, status,
    our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date,
    emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT
    'CRN-296-HERO-002',
    'ADNOC Offshore — Subsea Fracturing & Stimulation Services',
    'أدنوك للبترول البحري — خدمات التكسير والتحفيز تحت الماء',
    'services', 'active',
    v_adnoc_offshore_id, v_adnoc_drilling_id,
    180000000.00, 'AED', '2024-06-01', '2027-05-31',
    'abu_dhabi', 'uae_federal', 'en',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (
    SELECT 1 FROM contract WHERE contract_number = 'CRN-296-HERO-002'
  );

  SELECT id INTO v_hero2_id FROM contract WHERE contract_number = 'CRN-296-HERO-002';

  INSERT INTO contract_version (
    contract_id, version_number, body_en,
    data_classification, ingestion_status,
    created_at, created_by, is_active
  )
  SELECT
    v_hero2_id, 1,
    'Subsea fracturing and stimulation services contract. Performance standards apply.',
    'demo', 'pending',
    NOW(), v_seed_user, TRUE
  WHERE NOT EXISTS (
    SELECT 1 FROM contract_version WHERE contract_id = v_hero2_id AND version_number = 1
  );

  SELECT id INTO v_cv2_id FROM contract_version WHERE contract_id = v_hero2_id AND version_number = 1;

  -- ── HERO-003: ADNOC Onshore — Integrated Well Manpower Services ──────────
  INSERT INTO contract (
    contract_number, title_en, title_ar, contract_type, status,
    our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date,
    emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active
  )
  SELECT
    'CRN-296-HERO-003',
    'ADNOC Onshore — Integrated Well Manpower Services',
    'أدنوك للبر — خدمات القوى العاملة المتكاملة للآبار',
    'services', 'active',
    COALESCE(v_adnoc_onshore_id, v_adnoc_offshore_id),  -- fallback if onshore not seeded
    v_adnoc_drilling_id,
    95000000.00, 'AED', '2024-03-01', '2026-02-28',
    'abu_dhabi', 'uae_federal', 'en',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (
    SELECT 1 FROM contract WHERE contract_number = 'CRN-296-HERO-003'
  );

  SELECT id INTO v_hero3_id FROM contract WHERE contract_number = 'CRN-296-HERO-003';

  INSERT INTO contract_version (
    contract_id, version_number, body_en,
    data_classification, ingestion_status,
    created_at, created_by, is_active
  )
  SELECT
    v_hero3_id, 1,
    'Integrated well manpower services. Labour, supervision and tooling at agreed rates.',
    'demo', 'pending',
    NOW(), v_seed_user, TRUE
  WHERE NOT EXISTS (
    SELECT 1 FROM contract_version WHERE contract_id = v_hero3_id AND version_number = 1
  );

  SELECT id INTO v_cv3_id FROM contract_version WHERE contract_id = v_hero3_id AND version_number = 1;

  -- ── Extracted clauses on HERO-001 only ───────────────────────────────────
  -- Idempotency key: (tenant_id, contract_version_id, clause_type_v2, source_offset_start)
  -- clause_type_v2 values 'cure_period' + 'liquidated_damages' confirmed in mig 143.

  -- 1. cure_period clause
  INSERT INTO contract_clause_extracted (
    tenant_id, contract_id, contract_version_id, clause_type_v2,
    parameters, text_excerpts, page_no, source_offset_start,
    data_classification, created_by, updated_by, is_active,
    created_at, updated_at
  )
  SELECT
    v_tenant_id, v_hero1_id, v_cv1_id, 'cure_period',
    '{"cure_period_days":30,"notice_requirement":true}'::jsonb,
    '{"cure_period_days":"Contractor shall remedy any breach within 30 calendar days of written notice to cure."}'::jsonb,
    22, 0,
    'demo', v_seed_user, v_seed_user, TRUE,
    NOW(), NOW()
  WHERE NOT EXISTS (
    SELECT 1 FROM contract_clause_extracted
    WHERE tenant_id = v_tenant_id
      AND contract_version_id = v_cv1_id
      AND clause_type_v2 = 'cure_period'
      AND source_offset_start = 0
  );

  -- 2. liquidated_damages clause
  INSERT INTO contract_clause_extracted (
    tenant_id, contract_id, contract_version_id, clause_type_v2,
    parameters, text_excerpts, page_no, source_offset_start,
    data_classification, created_by, updated_by, is_active,
    created_at, updated_at
  )
  SELECT
    v_tenant_id, v_hero1_id, v_cv1_id, 'liquidated_damages',
    '{"ld_basis":"per_day_delay","ld_rate":730000,"ld_cap":63300000}'::jsonb,
    '{"ld_rate":"Liquidated damages of AED 730,000 per rig per day of non-availability, capped at AED 63.3M."}'::jsonb,
    24, 0,
    'demo', v_seed_user, v_seed_user, TRUE,
    NOW(), NOW()
  WHERE NOT EXISTS (
    SELECT 1 FROM contract_clause_extracted
    WHERE tenant_id = v_tenant_id
      AND contract_version_id = v_cv1_id
      AND clause_type_v2 = 'liquidated_damages'
      AND source_offset_start = 0
  );

END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (303, '303_crn_seed_hero_contract_clauses', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM contract_clause_extracted
--   WHERE contract_id IN (SELECT id FROM contract WHERE contract_number IN ('CRN-296-HERO-001'));
-- DELETE FROM contract_version
--   WHERE contract_id IN (SELECT id FROM contract WHERE contract_number IN ('CRN-296-HERO-001','CRN-296-HERO-002','CRN-296-HERO-003'));
-- DELETE FROM contract WHERE contract_number IN ('CRN-296-HERO-001','CRN-296-HERO-002','CRN-296-HERO-003');
-- DELETE FROM schema_migrations WHERE version = 303;
-- COMMIT;
-- ============================================================
