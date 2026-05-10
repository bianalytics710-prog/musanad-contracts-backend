-- Migration: 121_crb_seed_adnoc_graph.sql
-- Module: M9 — Counterparty Graph (CR-B)
-- Description: Seed 5 hero UBO chains + ~23 party_relationship edges + alias backfills on top 10 counterparties +
--              self-FK shortcuts on key parties + ~35 scaffold parties to reach ~70 active counterparties.
--              Idempotent: every INSERT uses ON CONFLICT DO NOTHING.
-- Tenant: ADNOC (UUID 00000000-0000-0000-0000-000000000001 from M7 101 seed)

BEGIN;

-- ============================================================
-- A. Net-new hero-chain parties (5 chains; ~23 net-new + 2 reused-by-name from M_parity if present)
--    Note: seed-data.ts marks Schlumberger / Halliburton as isExisting=true; in this branch they are NOT
--    in the M_parity baseline. INSERT them with ON CONFLICT DO NOTHING — safe whether they exist or not.
-- ============================================================

-- Chain 1 — OFAC sanctions chain
INSERT INTO party (party_type, name_en, name_ar, country, sanctions_status, esg_score, icv_status, icv_pct, aliases, metadata, is_seed, created_by)
VALUES
  ('company', 'Synthetic Holdings Cyprus Ltd', NULL, 'Cyprus',
     'sanctioned', NULL, NULL, NULL,
     '["Synthetic Cyprus","SHCY"]'::jsonb,
     '{"sanctionsList":"OFAC SDN","demoSeedChain":1}'::jsonb,
     TRUE, NULL),
  ('company', 'Mid-East Energy Holdings BV', NULL, 'Netherlands',
     'under_review', 35, NULL, NULL,
     '["MEEH BV"]'::jsonb,
     '{"demoSeedChain":1}'::jsonb,
     TRUE, NULL),
  ('company', 'Schlumberger Limited', 'شلمبرجير ليمتد', 'United States',
     'clean', 78, 'certified', 65.5,
     '["Schlumberger","SLB","Schlumberger Ltd"]'::jsonb,
     '{}'::jsonb,
     TRUE, NULL)
ON CONFLICT DO NOTHING;

-- Chain 2 — ESG sub-contractor chain
INSERT INTO party (party_type, name_en, name_ar, country, sanctions_status, esg_score, icv_status, icv_pct, aliases, metadata, is_seed, created_by)
VALUES
  ('company', 'Generic Drilling Services LLC', 'شركة جينريك للخدمات', 'United Arab Emirates',
     'clean', 22, 'pending', 12.0,
     '["GDS","Generic Drilling"]'::jsonb,
     '{"demoSeedChain":2}'::jsonb,
     TRUE, NULL),
  ('company', 'Halliburton Worldwide', NULL, 'United States',
     'clean', 71, 'certified', 58.0,
     '["Halliburton","HAL","HALLIBURTON"]'::jsonb,
     '{}'::jsonb,
     TRUE, NULL),
  ('company', 'Halliburton Energy Holdings Inc.', NULL, 'United States',
     'clean', 78, NULL, NULL,
     '["HEH"]'::jsonb,
     '{"demoSeedChain":2}'::jsonb,
     TRUE, NULL),
  ('company', 'Sahara Logistics LLC', 'الصحراء للخدمات اللوجستية', 'United Arab Emirates',
     'clean', 55, 'certified', 45.0,
     '[]'::jsonb,
     '{"demoSeedChain":2}'::jsonb,
     TRUE, NULL),
  ('company', 'Gulf Crane Services LLC', NULL, 'United Arab Emirates',
     'clean', 60, 'certified', 50.0,
     '["GCS"]'::jsonb,
     '{"demoSeedChain":2}'::jsonb,
     TRUE, NULL),
  ('company', 'Emirates Industrial Coatings LLC', NULL, 'United Arab Emirates',
     'clean', 67, 'certified', 53.5,
     '["EIC"]'::jsonb,
     '{"demoSeedChain":2}'::jsonb,
     TRUE, NULL)
ON CONFLICT DO NOTHING;

-- Chain 3 — International corporate hierarchy
INSERT INTO party (party_type, name_en, name_ar, country, sanctions_status, esg_score, icv_status, icv_pct, aliases, metadata, is_seed, created_by)
VALUES
  ('company', 'Petrolia Energy Group plc', NULL, 'United Kingdom',
     'clean', 82, NULL, NULL,
     '["PEG plc","Petrolia Group"]'::jsonb,
     '{"demoSeedChain":3}'::jsonb,
     TRUE, NULL),
  ('company', 'Petrolia MENA Holdings Ltd', NULL, 'British Virgin Islands',
     'clean', 79, NULL, NULL,
     '["PMENAH"]'::jsonb,
     '{"demoSeedChain":3}'::jsonb,
     TRUE, NULL),
  ('company', 'Petrolia Gulf Operations LLC', 'بتروليا الخليج للعمليات', 'United Arab Emirates',
     'clean', 76, 'certified', 62.0,
     '["PGO"]'::jsonb,
     '{"demoSeedChain":3}'::jsonb,
     TRUE, NULL),
  ('company', 'Petrolia Field Services FZ-LLC', 'بتروليا للخدمات الميدانية', 'United Arab Emirates',
     'clean', 74, 'certified', 60.0,
     '["PFS"]'::jsonb,
     '{"demoSeedChain":3}'::jsonb,
     TRUE, NULL)
ON CONFLICT DO NOTHING;

-- Chain 4 — Asia-Pacific holding chain
INSERT INTO party (party_type, name_en, name_ar, country, sanctions_status, esg_score, icv_status, icv_pct, aliases, metadata, is_seed, created_by)
VALUES
  ('company', 'Kowloon Petroleum Trust', NULL, 'Hong Kong',
     'clean', 65, NULL, NULL,
     '["KPT"]'::jsonb,
     '{"demoSeedChain":4}'::jsonb,
     TRUE, NULL),
  ('company', 'Asia Pacific Energy Holdings (KPT)', NULL, 'Singapore',
     'under_review', 48, NULL, NULL,
     '["APEH KPT","APEH"]'::jsonb,
     '{"demoSeedChain":4,"reviewReason":"PEP-association"}'::jsonb,
     TRUE, NULL),
  ('company', 'Sumatra Marine Logistics Pte Ltd', NULL, 'Indonesia',
     'clean', 52, NULL, NULL,
     '["SML","Sumatra Marine"]'::jsonb,
     '{"demoSeedChain":4}'::jsonb,
     TRUE, NULL),
  ('company', 'Sumatra Field Equipment LLC', NULL, 'United Arab Emirates',
     'clean', 56, 'pending', 22.0,
     '["SFE"]'::jsonb,
     '{"demoSeedChain":4}'::jsonb,
     TRUE, NULL)
ON CONFLICT DO NOTHING;

-- Chain 5 — JV / shared ownership
INSERT INTO party (party_type, name_en, name_ar, country, sanctions_status, esg_score, icv_status, icv_pct, aliases, metadata, is_seed, created_by)
VALUES
  ('company', 'Tarsus Energy Holdings (Turkey)', NULL, 'Turkey',
     'clean', 70, NULL, NULL,
     '["Tarsus EH","TEH"]'::jsonb,
     '{"demoSeedChain":5}'::jsonb,
     TRUE, NULL),
  ('company', 'Petrochem Industries (Saudi)', 'بتروكيم للصناعات', 'Saudi Arabia',
     'clean', 73, NULL, NULL,
     '["Petrochem Industries","PI"]'::jsonb,
     '{"demoSeedChain":5}'::jsonb,
     TRUE, NULL),
  ('company', 'Tarsus-Petrochem JV LLC', 'مشروع تارسوس-بتروكيم المشترك', 'United Arab Emirates',
     'clean', 68, 'certified', 55.0,
     '["TP-JV","Tarsus-Petrochem"]'::jsonb,
     '{"demoSeedChain":5}'::jsonb,
     TRUE, NULL),
  ('company', 'TP-JV Mechanical Subcon LLC', NULL, 'United Arab Emirates',
     'clean', 62, 'certified', 48.0,
     '[]'::jsonb,
     '{"demoSeedChain":5}'::jsonb,
     TRUE, NULL),
  ('company', 'TP-JV Electrical Subcon LLC', NULL, 'United Arab Emirates',
     'clean', 64, 'certified', 49.0,
     '[]'::jsonb,
     '{"demoSeedChain":5}'::jsonb,
     TRUE, NULL),
  ('company', 'TP-JV Civil Subcon LLC', NULL, 'United Arab Emirates',
     'clean', 61, 'certified', 46.0,
     '[]'::jsonb,
     '{"demoSeedChain":5}'::jsonb,
     TRUE, NULL),
  ('company', 'TP-JV Marine Subcon LLC', NULL, 'United Arab Emirates',
     'clean', 59, 'certified', 44.0,
     '[]'::jsonb,
     '{"demoSeedChain":5}'::jsonb,
     TRUE, NULL)
ON CONFLICT DO NOTHING;


-- ============================================================
-- B. Backfill aliases on top-10 existing counterparties (idempotent — only update if currently empty)
-- ============================================================

-- Schlumberger / Halliburton already inserted above with aliases; UPDATE clauses below also no-op for them.

UPDATE party SET aliases = '["ADNOC","Abu Dhabi National Oil Company","ADNOC Dist."]'::jsonb
  WHERE name_en = 'ADNOC Distribution PJSC' AND jsonb_array_length(aliases) = 0;

UPDATE party SET aliases = '["ADNOC","Abu Dhabi National Oil Company","ADNOC Distribution"]'::jsonb
  WHERE name_en = 'ADNOC Distribution' AND jsonb_array_length(aliases) = 0;

UPDATE party SET aliases = '["ADNOC","Abu Dhabi Onshore","ADCO (legacy)"]'::jsonb
  WHERE name_en = 'ADNOC Onshore' AND jsonb_array_length(aliases) = 0;

UPDATE party SET aliases = '["DEWA","Dubai Electricity Water Authority"]'::jsonb
  WHERE name_en = 'DEWA — Dubai Electricity & Water Authority' AND jsonb_array_length(aliases) = 0;

UPDATE party SET aliases = '["Mubadala","MIC"]'::jsonb
  WHERE name_en = 'Mubadala Investment Company' AND jsonb_array_length(aliases) = 0;

UPDATE party SET aliases = '["Emirates NBD","ENBD"]'::jsonb
  WHERE name_en = 'Emirates NBD Bank PJSC' AND jsonb_array_length(aliases) = 0;

UPDATE party SET aliases = '["Etisalat","e&"]'::jsonb
  WHERE name_en = 'Etisalat Group (e&)' AND jsonb_array_length(aliases) = 0;

UPDATE party SET aliases = '["Microsoft","Azure UAE"]'::jsonb
  WHERE name_en = 'Microsoft (Azure UAE) FZ-LLC' AND jsonb_array_length(aliases) = 0;

UPDATE party SET aliases = '["IBM","IBM Middle East"]'::jsonb
  WHERE name_en = 'IBM Middle East FZ-LLC' AND jsonb_array_length(aliases) = 0;

UPDATE party SET aliases = '["Crescent","Crescent Petroleum"]'::jsonb
  WHERE name_en = 'Crescent Petroleum Company' AND jsonb_array_length(aliases) = 0;


-- ============================================================
-- C. ~23 party_relationship rows across 5 chains (tenant-scoped)
-- ============================================================
WITH t AS (SELECT '00000000-0000-0000-0000-000000000001'::uuid AS tenant_id)
INSERT INTO party_relationship (
  tenant_id, parent_id, child_id, relationship_type, ownership_pct,
  effective_from, source, confidence, metadata, data_classification, created_by
)
SELECT
  t.tenant_id, p_par.id, p_chi.id, rt.rel_type, rt.own_pct,
  rt.eff_from, 'demo_seed', rt.conf, rt.meta::jsonb,
  'demo', NULL
FROM t,
     (VALUES
       -- Chain 1 — OFAC sanctions chain (3 edges)
       (1, 'Synthetic Holdings Cyprus Ltd', 'Mid-East Energy Holdings BV', 'parent', 100.00::numeric, '2018-03-01'::date, 1.00::numeric, '{"demoChain":1}'),
       (1, 'Mid-East Energy Holdings BV',   'Schlumberger Limited',         'parent',   8.50::numeric, '2019-06-15'::date, 1.00::numeric, '{"demoChain":1}'),
       (1, 'Synthetic Holdings Cyprus Ltd', 'Schlumberger Limited',         'ubo',      NULL::numeric, '2019-06-15'::date, 0.85::numeric, '{"demoChain":1,"note":"UBO shortcut (transitive)"}'),
       -- Chain 2 — ESG sub-contractor chain (5 edges)
       (2, 'Halliburton Worldwide',           'Generic Drilling Services LLC',     'sub_contractor', NULL::numeric, '2024-01-01'::date, 1.00::numeric, '{"demoChain":2}'),
       (2, 'Halliburton Energy Holdings Inc.','Halliburton Worldwide',             'parent',         100.00::numeric, '2010-01-01'::date, 1.00::numeric, '{"demoChain":2}'),
       (2, 'Halliburton Worldwide',           'Sahara Logistics LLC',              'sub_contractor', NULL::numeric, '2024-01-01'::date, 1.00::numeric, '{"demoChain":2}'),
       (2, 'Halliburton Worldwide',           'Gulf Crane Services LLC',           'sub_contractor', NULL::numeric, '2024-01-01'::date, 1.00::numeric, '{"demoChain":2}'),
       (2, 'Halliburton Worldwide',           'Emirates Industrial Coatings LLC',  'sub_contractor', NULL::numeric, '2024-01-01'::date, 1.00::numeric, '{"demoChain":2}'),
       -- Chain 3 — International corporate hierarchy (4 edges)
       (3, 'Petrolia Energy Group plc',  'Petrolia MENA Holdings Ltd',     'parent',                 100.00::numeric, '2015-01-01'::date, 1.00::numeric, '{"demoChain":3}'),
       (3, 'Petrolia MENA Holdings Ltd', 'Petrolia Gulf Operations LLC',   'parent',                  60.00::numeric, '2017-06-01'::date, 1.00::numeric, '{"demoChain":3}'),
       (3, 'Petrolia Gulf Operations LLC','Petrolia Field Services FZ-LLC','parent',                  85.00::numeric, '2020-09-01'::date, 1.00::numeric, '{"demoChain":3}'),
       (3, 'Petrolia Energy Group plc',  'Petrolia Gulf Operations LLC',   'controlling_shareholder', 60.00::numeric, '2017-06-01'::date, 0.90::numeric, '{"demoChain":3,"note":"transitive controlling shareholder"}'),
       -- Chain 4 — Asia-Pacific holding chain (5 edges)
       (4, 'Kowloon Petroleum Trust',              'Asia Pacific Energy Holdings (KPT)', 'parent',                  100.00::numeric, '2014-04-01'::date, 1.00::numeric, '{"demoChain":4}'),
       (4, 'Asia Pacific Energy Holdings (KPT)',   'Sumatra Marine Logistics Pte Ltd',   'parent',                   75.00::numeric, '2018-08-01'::date, 1.00::numeric, '{"demoChain":4}'),
       (4, 'Sumatra Marine Logistics Pte Ltd',     'Sumatra Field Equipment LLC',        'parent',                   90.00::numeric, '2021-02-01'::date, 1.00::numeric, '{"demoChain":4}'),
       (4, 'Kowloon Petroleum Trust',              'Asia Pacific Energy Holdings (KPT)', 'ubo',                       NULL::numeric, '2014-04-01'::date, 1.00::numeric, '{"demoChain":4}'),
       (4, 'Asia Pacific Energy Holdings (KPT)',   'Sumatra Field Equipment LLC',        'controlling_shareholder',   NULL::numeric, '2021-02-01'::date, 0.85::numeric, '{"demoChain":4}'),
       -- Chain 5 — JV / shared ownership (6 edges)
       (5, 'Tarsus Energy Holdings (Turkey)', 'Tarsus-Petrochem JV LLC',     'jv',             50.00::numeric, '2022-01-01'::date, 1.00::numeric, '{"demoChain":5}'),
       (5, 'Petrochem Industries (Saudi)',    'Tarsus-Petrochem JV LLC',     'jv',             50.00::numeric, '2022-01-01'::date, 1.00::numeric, '{"demoChain":5}'),
       (5, 'Tarsus-Petrochem JV LLC',         'TP-JV Mechanical Subcon LLC', 'sub_contractor', NULL::numeric,  '2023-04-01'::date, 1.00::numeric, '{"demoChain":5}'),
       (5, 'Tarsus-Petrochem JV LLC',         'TP-JV Electrical Subcon LLC', 'sub_contractor', NULL::numeric,  '2023-04-01'::date, 1.00::numeric, '{"demoChain":5}'),
       (5, 'Tarsus-Petrochem JV LLC',         'TP-JV Civil Subcon LLC',      'sub_contractor', NULL::numeric,  '2023-04-01'::date, 1.00::numeric, '{"demoChain":5}'),
       (5, 'Tarsus-Petrochem JV LLC',         'TP-JV Marine Subcon LLC',     'sub_contractor', NULL::numeric,  '2023-04-01'::date, 1.00::numeric, '{"demoChain":5}')
     ) AS rt(chain_no, parent_name, child_name, rel_type, own_pct, eff_from, conf, meta)
JOIN party p_par ON p_par.name_en = rt.parent_name AND p_par.is_active = TRUE
JOIN party p_chi ON p_chi.name_en = rt.child_name  AND p_chi.is_active = TRUE
ON CONFLICT (tenant_id, parent_id, child_id, relationship_type) DO NOTHING;


-- ============================================================
-- D. Self-FK shortcuts (set parent_id / ubo_id on hero-chain anchor parties)
--    Idempotent — only set when currently NULL.
-- ============================================================

UPDATE party SET parent_id = (SELECT id FROM party WHERE name_en = 'Mid-East Energy Holdings BV' AND is_active = TRUE)
WHERE name_en = 'Schlumberger Limited' AND parent_id IS NULL AND is_active = TRUE;

UPDATE party SET ubo_id = (SELECT id FROM party WHERE name_en = 'Synthetic Holdings Cyprus Ltd' AND is_active = TRUE)
WHERE name_en = 'Schlumberger Limited' AND ubo_id IS NULL AND is_active = TRUE;

UPDATE party SET parent_id = (SELECT id FROM party WHERE name_en = 'Halliburton Energy Holdings Inc.' AND is_active = TRUE)
WHERE name_en = 'Halliburton Worldwide' AND parent_id IS NULL AND is_active = TRUE;

UPDATE party SET ubo_id = (SELECT id FROM party WHERE name_en = 'Kowloon Petroleum Trust' AND is_active = TRUE)
WHERE name_en = 'Sumatra Field Equipment LLC' AND ubo_id IS NULL AND is_active = TRUE;


-- ============================================================
-- E. Scaffold parties — UAE locals + GCC + international + individuals (~35 rows)
-- ============================================================

-- 12 UAE local SMEs
INSERT INTO party (party_type, name_en, country, sanctions_status, esg_score, icv_status, icv_pct, aliases, metadata, is_seed)
SELECT 'company',
       'UAE Local Services ' || lpad((g)::text, 2, '0') || ' LLC',
       'United Arab Emirates',
       'clean',
       50 + ((g - 1) % 5) * 5,
       'certified',
       (35.0 + ((g - 1) % 4) * 5.0)::numeric(5,2),
       '[]'::jsonb,
       '{"scaffold":true}'::jsonb,
       TRUE
FROM generate_series(1, 12) AS g
ON CONFLICT DO NOTHING;

-- 10 GCC regional companies (Saudi/Qatar alternating)
INSERT INTO party (party_type, name_en, country, sanctions_status, esg_score, aliases, metadata, is_seed)
SELECT 'company',
       'GCC Energy Partners ' || lpad((g)::text, 2, '0'),
       CASE WHEN (g - 1) % 2 = 0 THEN 'Saudi Arabia' ELSE 'Qatar' END,
       'clean',
       60 + ((g - 1) % 4) * 4,
       '[]'::jsonb,
       '{"scaffold":true}'::jsonb,
       TRUE
FROM generate_series(1, 10) AS g
ON CONFLICT DO NOTHING;

-- 8 international service providers
INSERT INTO party (party_type, name_en, country, sanctions_status, esg_score, icv_status, icv_pct, aliases, metadata, is_seed)
SELECT 'company',
       'International Service Provider ' || lpad((g)::text, 2, '0') || ' Ltd',
       (ARRAY['United States','United Kingdom','Germany','France','Japan','Singapore','Italy','Netherlands'])[g],
       'clean',
       70 + (g - 1),
       'pending',
       (15.0 + (g - 1) * 2.0)::numeric(5,2),
       jsonb_build_array('ISP-' || lpad((g)::text, 2, '0')),
       '{"scaffold":true}'::jsonb,
       TRUE
FROM generate_series(1, 8) AS g
ON CONFLICT DO NOTHING;

-- 5 individual UBO persons
INSERT INTO party (party_type, name_en, country, sanctions_status, aliases, metadata, is_seed)
SELECT 'individual',
       'Individual UBO ' || lpad((g)::text, 2, '0'),
       (ARRAY['United Arab Emirates','Saudi Arabia','Egypt','Lebanon','Jordan'])[g],
       'clean',
       '[]'::jsonb,
       '{"scaffold":true,"kind":"natural-person-UBO"}'::jsonb,
       TRUE
FROM generate_series(1, 5) AS g
ON CONFLICT DO NOTHING;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (121, 'crb_seed_adnoc_graph', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DELETE FROM party_relationship WHERE source = 'demo_seed' AND tenant_id = '00000000-0000-0000-0000-000000000001'::uuid;
-- UPDATE party SET parent_id = NULL, ubo_id = NULL
--  WHERE name_en IN ('Schlumberger Limited','Halliburton Worldwide','Sumatra Field Equipment LLC');
-- -- (Hero-chain + scaffold parties are left in place — they're idempotent seeds; remove manually if needed.)
-- DELETE FROM schema_migrations WHERE version = 121;
-- COMMIT;
