-- Migration: 295_crm_seed_contractor_contracts_clauses_icv.sql
-- Module: CR-M — Labor-Law Cascade demo-data fix
-- Description: Seeds contracts, employment-clause extracted rows, and ICV certificate
--              attachments for 10 representative contractor parties (spread across 20-49
--              and 50+ headcount bands, including the Jereh anchor). This makes
--              fn_regulatory_cascade_run produce non-empty affected_clause_ids,
--              affected_contract_ids, and icv_attachment_ids for those contractors,
--              enabling the Draft-amendment button and ICV-impact section in the FE.
--
--   Why needed: migration 286 seeded ~40 contractor party + party_workforce rows but
--   created NO contracts. fn_regulatory_cascade_run (migration 289) discovers affected
--   clauses and ICV attachments via the contract table (counterparty_id join). Without
--   contracts there is nothing to join, so every item has empty arrays and the
--   Draft-amendment button is permanently disabled.
--
--   Selection rationale:
--     - 5 non-compliant 50+ contractors (Lamprell, Gulf Marine, Khalifa Industrial,
--       Prime Oilfield, Neptune Marine) — highest penalty exposure band
--     - 5 non-compliant 20-49 contractors (Jereh anchor, Target Engineering,
--       Gulf Petro Drilling, Arabian Well Services, Saraya Engineering)
--   Each contractor gets 1 ADNOC-subsidiary-owned services contract + 1-2 extracted
--   employment clauses (clause_type_v2 IN ('icv_in_country_value','strike_lockout',
--   'key_personnel') — the exact set fn_regulatory_cascade_run matches).
--   5 of the 10 contracts also get an icv_certificate contract_attachment.
--
-- Cascade function join chain confirmed from migration 289 (fn_regulatory_cascade_run):
--   party_contracts CTE:  contract.counterparty_id + contract.is_active = TRUE
--   affected_clauses CTE: contract_clause_extracted.tenant_id + clause_type_v2 + is_active
--   party_icv CTE:        contract_attachment.kind = 'icv_certificate' + is_active
--   All three CTEs join on contract_id, scoped to party_ids from party_workforce.
--
-- Idempotency: WHERE NOT EXISTS on contract_number + storage_path + clause idempotency key.
-- Rollback: See ROLLBACK section below.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_tenant_id     UUID   := '00000000-0000-0000-0000-000000000001';
  v_seed_user     BIGINT;

  -- ADNOC subsidiary party ids (owners on our_party_id side)
  v_adnoc_offshore_id    BIGINT;
  v_adnoc_onshore_id     BIGINT;
  v_adnoc_drilling_id    BIGINT;
  v_adnoc_gas_id         BIGINT;
  v_adnoc_logistics_id   BIGINT;

  -- Contractor party ids (counterparty_id side)
  v_jereh_id             BIGINT;
  v_lamprell_id          BIGINT;
  v_gulf_marine_id       BIGINT;
  v_khalifa_iz_id        BIGINT;
  v_prime_oilfield_id    BIGINT;
  v_neptune_id           BIGINT;
  v_target_eng_id        BIGINT;
  v_gulf_petro_id        BIGINT;
  v_arabian_well_id      BIGINT;
  v_saraya_id            BIGINT;

  -- Contract ids (resolved after INSERT or WHERE NOT EXISTS)
  v_c1  BIGINT; v_c2  BIGINT; v_c3  BIGINT; v_c4  BIGINT; v_c5  BIGINT;
  v_c6  BIGINT; v_c7  BIGINT; v_c8  BIGINT; v_c9  BIGINT; v_c10 BIGINT;

  -- Contract version ids
  v_cv1  BIGINT; v_cv2  BIGINT; v_cv3  BIGINT; v_cv4  BIGINT; v_cv5  BIGINT;
  v_cv6  BIGINT; v_cv7  BIGINT; v_cv8  BIGINT; v_cv9  BIGINT; v_cv10 BIGINT;

BEGIN
  -- ── 0. Resolve seed actor ───────────────────────────────────────────────
  SELECT MIN(id) INTO v_seed_user FROM "user" WHERE is_active = TRUE;

  -- ── 1. Resolve ADNOC subsidiary party ids ──────────────────────────────
  SELECT id INTO v_adnoc_offshore_id  FROM party WHERE name_en = 'ADNOC Offshore'            AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_adnoc_onshore_id   FROM party WHERE name_en = 'ADNOC Onshore'             AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_adnoc_drilling_id  FROM party WHERE name_en = 'ADNOC Drilling'            AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_adnoc_gas_id       FROM party WHERE name_en = 'ADNOC Gas'                 AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_adnoc_logistics_id FROM party WHERE name_en = 'ADNOC Logistics & Services' AND is_active = TRUE LIMIT 1;

  IF v_adnoc_offshore_id IS NULL OR v_adnoc_onshore_id IS NULL THEN
    RAISE EXCEPTION 'ADNOC subsidiary parties not found — ensure migration 285 has been applied'
      USING ERRCODE = 'P0002';
  END IF;

  -- ── 2. Resolve contractor party ids ────────────────────────────────────
  -- 50+ band (non-compliant)
  SELECT id INTO v_lamprell_id       FROM party WHERE name_en = 'Lamprell Energy'                     AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_gulf_marine_id    FROM party WHERE name_en = 'Gulf Marine Services'                AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_khalifa_iz_id     FROM party WHERE name_en = 'Khalifa Industrial Zone Contractors' AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_prime_oilfield_id FROM party WHERE name_en = 'Prime Oilfield Maintenance Services' AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_neptune_id        FROM party WHERE name_en = 'Neptune Marine Contractors'          AND is_active = TRUE LIMIT 1;
  -- 20-49 band (non-compliant)
  SELECT id INTO v_jereh_id          FROM party WHERE name_en = 'Jereh Oil & Gas Equipment'          AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_target_eng_id     FROM party WHERE name_en = 'Target Engineering Construction'    AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_gulf_petro_id     FROM party WHERE name_en = 'Gulf Petro Drilling Services'       AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_arabian_well_id   FROM party WHERE name_en = 'Arabian Well Services'              AND is_active = TRUE LIMIT 1;
  SELECT id INTO v_saraya_id         FROM party WHERE name_en = 'Saraya Engineering & Contracting'   AND is_active = TRUE LIMIT 1;

  IF v_jereh_id IS NULL THEN
    RAISE EXCEPTION 'Jereh contractor party not found — ensure migration 286 has been applied'
      USING ERRCODE = 'P0002';
  END IF;

  -- ── 3. Seed contracts (one per contractor; idempotent on contract_number) ─
  -- C1 — Lamprell Energy / ADNOC Offshore
  INSERT INTO contract (contract_number, title_en, contract_type, status, our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date, emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'CRM-295-C001','Offshore Drilling Services Agreement','services','active',
    v_adnoc_offshore_id, v_lamprell_id,
    45000000.00,'AED','2024-01-01','2026-12-31','abu_dhabi','uae_federal','en',
    NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM contract WHERE contract_number = 'CRM-295-C001');

  SELECT id INTO v_c1 FROM contract WHERE contract_number = 'CRM-295-C001';

  -- C2 — Gulf Marine Services / ADNOC Logistics
  INSERT INTO contract (contract_number, title_en, contract_type, status, our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date, emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'CRM-295-C002','Marine Logistics & Support Services','services','active',
    v_adnoc_logistics_id, v_gulf_marine_id,
    28000000.00,'AED','2024-03-01','2027-02-28','abu_dhabi','uae_federal','en',
    NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM contract WHERE contract_number = 'CRM-295-C002');

  SELECT id INTO v_c2 FROM contract WHERE contract_number = 'CRM-295-C002';

  -- C3 — Khalifa Industrial Zone Contractors / ADNOC Onshore
  INSERT INTO contract (contract_number, title_en, contract_type, status, our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date, emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'CRM-295-C003','Industrial EPC Services — Khalifa Zone','epc','active',
    v_adnoc_onshore_id, v_khalifa_iz_id,
    62000000.00,'AED','2023-07-01','2026-06-30','abu_dhabi','uae_federal','en',
    NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM contract WHERE contract_number = 'CRM-295-C003');

  SELECT id INTO v_c3 FROM contract WHERE contract_number = 'CRM-295-C003';

  -- C4 — Prime Oilfield Maintenance Services / ADNOC Onshore
  INSERT INTO contract (contract_number, title_en, contract_type, status, our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date, emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'CRM-295-C004','Oilfield Maintenance & Operations Contract','services','active',
    v_adnoc_onshore_id, v_prime_oilfield_id,
    19500000.00,'AED','2024-06-01','2026-05-31','abu_dhabi','uae_federal','en',
    NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM contract WHERE contract_number = 'CRM-295-C004');

  SELECT id INTO v_c4 FROM contract WHERE contract_number = 'CRM-295-C004';

  -- C5 — Neptune Marine Contractors / ADNOC Offshore
  INSERT INTO contract (contract_number, title_en, contract_type, status, our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date, emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'CRM-295-C005','Marine Contracting & Subsea Services','services','active',
    v_adnoc_offshore_id, v_neptune_id,
    33750000.00,'AED','2024-02-01','2027-01-31','abu_dhabi','uae_federal','en',
    NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM contract WHERE contract_number = 'CRM-295-C005');

  SELECT id INTO v_c5 FROM contract WHERE contract_number = 'CRM-295-C005';

  -- C6 — Jereh Oil & Gas (anchor) / ADNOC Drilling
  INSERT INTO contract (contract_number, title_en, contract_type, status, our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date, emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'CRM-295-C006','Drilling Equipment Supply & Services — Jereh','services','active',
    v_adnoc_drilling_id, v_jereh_id,
    12000000.00,'AED','2024-04-01','2026-03-31','abu_dhabi','uae_federal','en',
    NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM contract WHERE contract_number = 'CRM-295-C006');

  SELECT id INTO v_c6 FROM contract WHERE contract_number = 'CRM-295-C006';

  -- C7 — Target Engineering Construction / ADNOC Onshore
  INSERT INTO contract (contract_number, title_en, contract_type, status, our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date, emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'CRM-295-C007','Civil & Structural Engineering Works','epc','active',
    v_adnoc_onshore_id, v_target_eng_id,
    8750000.00,'AED','2024-05-01','2026-04-30','abu_dhabi','uae_federal','en',
    NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM contract WHERE contract_number = 'CRM-295-C007');

  SELECT id INTO v_c7 FROM contract WHERE contract_number = 'CRM-295-C007';

  -- C8 — Gulf Petro Drilling Services / ADNOC Drilling
  INSERT INTO contract (contract_number, title_en, contract_type, status, our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date, emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'CRM-295-C008','Petroleum Drilling Services Agreement','services','active',
    v_adnoc_drilling_id, v_gulf_petro_id,
    16200000.00,'AED','2024-01-15','2026-01-14','abu_dhabi','uae_federal','en',
    NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM contract WHERE contract_number = 'CRM-295-C008');

  SELECT id INTO v_c8 FROM contract WHERE contract_number = 'CRM-295-C008';

  -- C9 — Arabian Well Services / ADNOC Drilling
  INSERT INTO contract (contract_number, title_en, contract_type, status, our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date, emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'CRM-295-C009','Well Services & Completion Contract','services','active',
    v_adnoc_drilling_id, v_arabian_well_id,
    9400000.00,'AED','2024-03-01','2026-02-28','abu_dhabi','uae_federal','en',
    NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM contract WHERE contract_number = 'CRM-295-C009');

  SELECT id INTO v_c9 FROM contract WHERE contract_number = 'CRM-295-C009';

  -- C10 — Saraya Engineering & Contracting / ADNOC Gas
  INSERT INTO contract (contract_number, title_en, contract_type, status, our_party_id, counterparty_id,
    value_aed, currency, start_date, end_date, emirate, governing_law, language,
    created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'CRM-295-C010','Gas Processing Plant Engineering & Contracting','epc','active',
    v_adnoc_gas_id, v_saraya_id,
    21800000.00,'AED','2023-11-01','2025-10-31','ajman','uae_federal','en',
    NOW(),NOW(),v_seed_user,v_seed_user,TRUE
  WHERE NOT EXISTS (SELECT 1 FROM contract WHERE contract_number = 'CRM-295-C010');

  SELECT id INTO v_c10 FROM contract WHERE contract_number = 'CRM-295-C010';

  -- ── 4. Seed contract_version rows (one per contract, version_number=1) ──
  -- contract_clause_extracted.contract_version_id is NOT NULL — we need a version FK.
  -- Idempotent: ON CONFLICT DO NOTHING (uq_contract_version covers (contract_id, version_number)).

  INSERT INTO contract_version (contract_id, version_number, body_en, change_note, changed_by,
    created_at, created_by, is_active)
  SELECT v_c1,  1, 'Offshore drilling services — employment and ICV provisions apply per UAE Federal Decree-Law No.9/2024.',
    'Initial version (demo seed 295)', v_seed_user, NOW(), v_seed_user, TRUE
  WHERE v_c1 IS NOT NULL
  ON CONFLICT ON CONSTRAINT uq_contract_version DO NOTHING;

  SELECT id INTO v_cv1 FROM contract_version WHERE contract_id = v_c1 AND version_number = 1 LIMIT 1;

  INSERT INTO contract_version (contract_id, version_number, body_en, change_note, changed_by,
    created_at, created_by, is_active)
  SELECT v_c2, 1, 'Marine logistics services — ICV certificate and key-personnel provisions.',
    'Initial version (demo seed 295)', v_seed_user, NOW(), v_seed_user, TRUE
  WHERE v_c2 IS NOT NULL
  ON CONFLICT ON CONSTRAINT uq_contract_version DO NOTHING;

  SELECT id INTO v_cv2 FROM contract_version WHERE contract_id = v_c2 AND version_number = 1 LIMIT 1;

  INSERT INTO contract_version (contract_id, version_number, body_en, change_note, changed_by,
    created_at, created_by, is_active)
  SELECT v_c3, 1, 'Industrial EPC — strike/lockout limitation and ICV clause in Article 7.',
    'Initial version (demo seed 295)', v_seed_user, NOW(), v_seed_user, TRUE
  WHERE v_c3 IS NOT NULL
  ON CONFLICT ON CONSTRAINT uq_contract_version DO NOTHING;

  SELECT id INTO v_cv3 FROM contract_version WHERE contract_id = v_c3 AND version_number = 1 LIMIT 1;

  INSERT INTO contract_version (contract_id, version_number, body_en, change_note, changed_by,
    created_at, created_by, is_active)
  SELECT v_c4, 1, 'Oilfield maintenance — key-personnel schedule attached as Exhibit A.',
    'Initial version (demo seed 295)', v_seed_user, NOW(), v_seed_user, TRUE
  WHERE v_c4 IS NOT NULL
  ON CONFLICT ON CONSTRAINT uq_contract_version DO NOTHING;

  SELECT id INTO v_cv4 FROM contract_version WHERE contract_id = v_c4 AND version_number = 1 LIMIT 1;

  INSERT INTO contract_version (contract_id, version_number, body_en, change_note, changed_by,
    created_at, created_by, is_active)
  SELECT v_c5, 1, 'Marine contracting — ICV commitment percentage and key personnel provisions.',
    'Initial version (demo seed 295)', v_seed_user, NOW(), v_seed_user, TRUE
  WHERE v_c5 IS NOT NULL
  ON CONFLICT ON CONSTRAINT uq_contract_version DO NOTHING;

  SELECT id INTO v_cv5 FROM contract_version WHERE contract_id = v_c5 AND version_number = 1 LIMIT 1;

  INSERT INTO contract_version (contract_id, version_number, body_en, change_note, changed_by,
    created_at, created_by, is_active)
  SELECT v_c6, 1, 'Drilling equipment services — ICV in-country value clause Article 12, strike-lockout Article 18.',
    'Initial version (demo seed 295)', v_seed_user, NOW(), v_seed_user, TRUE
  WHERE v_c6 IS NOT NULL
  ON CONFLICT ON CONSTRAINT uq_contract_version DO NOTHING;

  SELECT id INTO v_cv6 FROM contract_version WHERE contract_id = v_c6 AND version_number = 1 LIMIT 1;

  INSERT INTO contract_version (contract_id, version_number, body_en, change_note, changed_by,
    created_at, created_by, is_active)
  SELECT v_c7, 1, 'Civil engineering works — ICV 40% commitment, key-personnel list in Schedule 2.',
    'Initial version (demo seed 295)', v_seed_user, NOW(), v_seed_user, TRUE
  WHERE v_c7 IS NOT NULL
  ON CONFLICT ON CONSTRAINT uq_contract_version DO NOTHING;

  SELECT id INTO v_cv7 FROM contract_version WHERE contract_id = v_c7 AND version_number = 1 LIMIT 1;

  INSERT INTO contract_version (contract_id, version_number, body_en, change_note, changed_by,
    created_at, created_by, is_active)
  SELECT v_c8, 1, 'Petroleum drilling services — key-personnel and strike-lockout provisions.',
    'Initial version (demo seed 295)', v_seed_user, NOW(), v_seed_user, TRUE
  WHERE v_c8 IS NOT NULL
  ON CONFLICT ON CONSTRAINT uq_contract_version DO NOTHING;

  SELECT id INTO v_cv8 FROM contract_version WHERE contract_id = v_c8 AND version_number = 1 LIMIT 1;

  INSERT INTO contract_version (contract_id, version_number, body_en, change_note, changed_by,
    created_at, created_by, is_active)
  SELECT v_c9, 1, 'Well services contract — ICV in-country value commitment in Article 9.',
    'Initial version (demo seed 295)', v_seed_user, NOW(), v_seed_user, TRUE
  WHERE v_c9 IS NOT NULL
  ON CONFLICT ON CONSTRAINT uq_contract_version DO NOTHING;

  SELECT id INTO v_cv9 FROM contract_version WHERE contract_id = v_c9 AND version_number = 1 LIMIT 1;

  INSERT INTO contract_version (contract_id, version_number, body_en, change_note, changed_by,
    created_at, created_by, is_active)
  SELECT v_c10, 1, 'Gas plant EPC — ICV in-country value clause and key-personnel certification requirements.',
    'Initial version (demo seed 295)', v_seed_user, NOW(), v_seed_user, TRUE
  WHERE v_c10 IS NOT NULL
  ON CONFLICT ON CONSTRAINT uq_contract_version DO NOTHING;

  SELECT id INTO v_cv10 FROM contract_version WHERE contract_id = v_c10 AND version_number = 1 LIMIT 1;

  -- ── 5. Seed contract_clause_extracted rows ────────────────────────────────
  -- clause_type_v2 values: 'icv_in_country_value' | 'strike_lockout' | 'key_personnel'
  -- These are the EXACT values fn_regulatory_cascade_run uses (line: v_clause_types default).
  -- Idempotency: ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING
  -- (tenant_id, contract_version_id, clause_type_v2, source_offset_start).
  -- source_offset_start=0 as a stable demo seed anchor (non-null for idempotency key).

  -- C1 / Lamprell: icv_in_country_value + key_personnel
  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c1, v_cv1, 'icv_in_country_value',
    '{"icvPercentage":35,"commitmentYear":2024}'::jsonb,
    '{"icvPercentage":"ICV commitment: 35% in-country value as per Federal Decree-Law No.9"}'::jsonb,
    3, 0, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c1 IS NOT NULL AND v_cv1 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c1, v_cv1, 'key_personnel',
    '{"roleTitle":"Drilling Superintendent","minYearsExperience":10}'::jsonb,
    '{"roleTitle":"Drilling Superintendent with minimum 10 years UAE oilfield experience"}'::jsonb,
    8, 100, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c1 IS NOT NULL AND v_cv1 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  -- C2 / Gulf Marine: icv_in_country_value + strike_lockout
  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c2, v_cv2, 'icv_in_country_value',
    '{"icvPercentage":40,"commitmentYear":2024}'::jsonb,
    '{"icvPercentage":"Contractor shall maintain 40% ICV ratio per ADNOC ICV Program requirements"}'::jsonb,
    4, 0, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c2 IS NOT NULL AND v_cv2 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c2, v_cv2, 'strike_lockout',
    '{"noStrikePeriodDays":90,"penaltyPerDayAed":50000}'::jsonb,
    '{"noStrikePeriodDays":"No strike or lockout permitted within 90 days of force-majeure notice"}'::jsonb,
    11, 100, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c2 IS NOT NULL AND v_cv2 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  -- C3 / Khalifa IZ: strike_lockout + icv_in_country_value
  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c3, v_cv3, 'strike_lockout',
    '{"noStrikePeriodDays":60,"penaltyPerDayAed":75000}'::jsonb,
    '{"noStrikePeriodDays":"Strike or work stoppage prohibited during any 60-day regulatory compliance period"}'::jsonb,
    7, 0, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c3 IS NOT NULL AND v_cv3 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c3, v_cv3, 'icv_in_country_value',
    '{"icvPercentage":45,"commitmentYear":2024}'::jsonb,
    '{"icvPercentage":"ICV 45% per ADNOC ICV scoring framework applicable from 2024"}'::jsonb,
    9, 100, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c3 IS NOT NULL AND v_cv3 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  -- C4 / Prime Oilfield: key_personnel
  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c4, v_cv4, 'key_personnel',
    '{"roleTitle":"Field Maintenance Manager","minYearsExperience":8}'::jsonb,
    '{"roleTitle":"Field Maintenance Manager — minimum 8 years UAE petroleum sector experience required"}'::jsonb,
    5, 0, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c4 IS NOT NULL AND v_cv4 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  -- C5 / Neptune Marine: icv_in_country_value + key_personnel
  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c5, v_cv5, 'icv_in_country_value',
    '{"icvPercentage":38,"commitmentYear":2024}'::jsonb,
    '{"icvPercentage":"Contractor ICV commitment: 38% as certified by ADNOC ICV Program administrator"}'::jsonb,
    6, 0, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c5 IS NOT NULL AND v_cv5 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c5, v_cv5, 'key_personnel',
    '{"roleTitle":"Marine Operations Lead","minYearsExperience":12}'::jsonb,
    '{"roleTitle":"Marine Operations Lead — minimum 12 years offshore/marine experience"}'::jsonb,
    10, 100, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c5 IS NOT NULL AND v_cv5 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  -- C6 / Jereh (anchor): icv_in_country_value + strike_lockout
  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c6, v_cv6, 'icv_in_country_value',
    '{"icvPercentage":30,"commitmentYear":2024}'::jsonb,
    '{"icvPercentage":"ICV 30% commitment per Schedule 3 — subject to ADNOC annual audit"}'::jsonb,
    4, 0, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c6 IS NOT NULL AND v_cv6 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c6, v_cv6, 'strike_lockout',
    '{"noStrikePeriodDays":30,"penaltyPerDayAed":25000}'::jsonb,
    '{"noStrikePeriodDays":"Work stoppages are prohibited during any 30-day notice period under this contract"}'::jsonb,
    12, 100, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c6 IS NOT NULL AND v_cv6 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  -- C7 / Target Engineering: icv_in_country_value + key_personnel
  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c7, v_cv7, 'icv_in_country_value',
    '{"icvPercentage":42,"commitmentYear":2024}'::jsonb,
    '{"icvPercentage":"42% ICV ratio certified annually per ADNOC ICV scoring methodology"}'::jsonb,
    5, 0, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c7 IS NOT NULL AND v_cv7 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c7, v_cv7, 'key_personnel',
    '{"roleTitle":"Project Manager","minYearsExperience":7}'::jsonb,
    '{"roleTitle":"Project Manager — Schedule 2 key personnel list — minimum 7 years UAE EPC"}'::jsonb,
    8, 100, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c7 IS NOT NULL AND v_cv7 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  -- C8 / Gulf Petro Drilling: key_personnel + strike_lockout
  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c8, v_cv8, 'key_personnel',
    '{"roleTitle":"Senior Driller","minYearsExperience":6}'::jsonb,
    '{"roleTitle":"Senior Driller as defined in Exhibit B — subject to ADNOC approval"}'::jsonb,
    3, 0, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c8 IS NOT NULL AND v_cv8 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c8, v_cv8, 'strike_lockout',
    '{"noStrikePeriodDays":45,"penaltyPerDayAed":40000}'::jsonb,
    '{"noStrikePeriodDays":"Industrial action prohibited within 45-day project-critical window"}'::jsonb,
    9, 100, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c8 IS NOT NULL AND v_cv8 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  -- C9 / Arabian Well Services: icv_in_country_value
  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c9, v_cv9, 'icv_in_country_value',
    '{"icvPercentage":28,"commitmentYear":2024}'::jsonb,
    '{"icvPercentage":"ICV 28% in-country value commitment in Article 9 per UAE ICV Policy 2024"}'::jsonb,
    6, 0, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c9 IS NOT NULL AND v_cv9 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  -- C10 / Saraya Engineering: icv_in_country_value + key_personnel
  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c10, v_cv10, 'icv_in_country_value',
    '{"icvPercentage":36,"commitmentYear":2024}'::jsonb,
    '{"icvPercentage":"ICV commitment 36% per Gas Processing EPC schedule 4"}'::jsonb,
    5, 0, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c10 IS NOT NULL AND v_cv10 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  INSERT INTO contract_clause_extracted
    (tenant_id, contract_id, contract_version_id, clause_type_v2,
     parameters, text_excerpts, page_no, source_offset_start,
     review_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_tenant_id, v_c10, v_cv10, 'key_personnel',
    '{"roleTitle":"EPC Contracts Engineer","minYearsExperience":5}'::jsonb,
    '{"roleTitle":"EPC Contracts Engineer — Schedule 2 approved personnel list"}'::jsonb,
    8, 100, 'auto', 'demo', NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c10 IS NOT NULL AND v_cv10 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_clause_extracted_idempotency_key DO NOTHING;

  -- ── 6. Seed ICV certificate contract_attachment rows ──────────────────────
  -- 5 of the 10 contracts get an icv_certificate attachment so the ICV-impact
  -- section populates for those contractors.
  -- contract_attachment has NO tenant_id column (migration 061); RLS gates on contract.
  -- Idempotency: ON CONFLICT ON CONSTRAINT contract_attachment_storage_path_uq DO NOTHING.
  -- kind='icv_certificate' (added by migration 196).
  -- description starts with 'valid_until=YYYY-MM-DD' per migration 196 encoding convention.

  -- ICV cert for C1 (Lamprell) — valid
  INSERT INTO contract_attachment
    (contract_id, filename, mime_type, size_bytes, storage_bucket, storage_path,
     uploaded_by, description, kind,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_c1, 'lamprell-icv-cert-2024.pdf', 'application/pdf', 204800,
    'contract-attachments', 'demo/crm-295/c001-lamprell-icv-cert.pdf',
    v_seed_user, 'valid_until=2025-12-31 ICV Certificate — ADNOC audit 2024. Score: 35%', 'icv_certificate',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c1 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_attachment_storage_path_uq DO NOTHING;

  -- ICV cert for C2 (Gulf Marine) — expiring within 90 days
  INSERT INTO contract_attachment
    (contract_id, filename, mime_type, size_bytes, storage_bucket, storage_path,
     uploaded_by, description, kind,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_c2, 'gulf-marine-icv-cert-2024.pdf', 'application/pdf', 188416,
    'contract-attachments', 'demo/crm-295/c002-gulf-marine-icv-cert.pdf',
    v_seed_user,
    ('valid_until=' || to_char(CURRENT_DATE + INTERVAL '45 days', 'YYYY-MM-DD') ||
     ' ICV Certificate — Gulf Marine ICV score 40%. Renewal due soon.')::text,
    'icv_certificate',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c2 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_attachment_storage_path_uq DO NOTHING;

  -- ICV cert for C5 (Neptune Marine) — valid
  INSERT INTO contract_attachment
    (contract_id, filename, mime_type, size_bytes, storage_bucket, storage_path,
     uploaded_by, description, kind,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_c5, 'neptune-icv-cert-2024.pdf', 'application/pdf', 176128,
    'contract-attachments', 'demo/crm-295/c005-neptune-icv-cert.pdf',
    v_seed_user, 'valid_until=2025-11-30 ICV Certificate — Neptune Marine score 38%.', 'icv_certificate',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c5 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_attachment_storage_path_uq DO NOTHING;

  -- ICV cert for C6 (Jereh anchor) — expired (negative demo to show expired bucket)
  INSERT INTO contract_attachment
    (contract_id, filename, mime_type, size_bytes, storage_bucket, storage_path,
     uploaded_by, description, kind,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_c6, 'jereh-icv-cert-2023.pdf', 'application/pdf', 163840,
    'contract-attachments', 'demo/crm-295/c006-jereh-icv-cert.pdf',
    v_seed_user, 'valid_until=2024-06-30 ICV Certificate — Jereh score 30%. EXPIRED — renewal required.', 'icv_certificate',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c6 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_attachment_storage_path_uq DO NOTHING;

  -- ICV cert for C7 (Target Engineering) — valid
  INSERT INTO contract_attachment
    (contract_id, filename, mime_type, size_bytes, storage_bucket, storage_path,
     uploaded_by, description, kind,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT v_c7, 'target-eng-icv-cert-2024.pdf', 'application/pdf', 192512,
    'contract-attachments', 'demo/crm-295/c007-target-eng-icv-cert.pdf',
    v_seed_user, 'valid_until=2026-02-28 ICV Certificate — Target Engineering 42% ICV.', 'icv_certificate',
    NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE v_c7 IS NOT NULL
  ON CONFLICT ON CONSTRAINT contract_attachment_storage_path_uq DO NOTHING;

END;
$$;

-- ============================================================
-- Record migration
-- ============================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (295, '295_crm_seed_contractor_contracts_clauses_icv', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 295;
-- -- Remove ICV attachments (by storage_path)
-- DELETE FROM contract_attachment
--   WHERE storage_path LIKE 'demo/crm-295/%' AND kind = 'icv_certificate';
-- -- Remove extracted clauses for our demo contracts
-- DELETE FROM contract_clause_extracted
--   WHERE contract_id IN (
--     SELECT id FROM contract WHERE contract_number LIKE 'CRM-295-%'
--   );
-- -- Remove contract_version rows
-- DELETE FROM contract_version
--   WHERE contract_id IN (
--     SELECT id FROM contract WHERE contract_number LIKE 'CRM-295-%'
--   );
-- -- Remove the seeded contracts
-- DELETE FROM contract WHERE contract_number LIKE 'CRM-295-%';
-- COMMIT;
-- ============================================================
