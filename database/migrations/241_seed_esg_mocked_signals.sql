-- Migration: 241_seed_esg_mocked_signals.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: 30 mocked ESG news signals exercising the rule.esg.sub_contractor_violation regex
--              `(?i)(labour|labor|forced|child|environmental|pollution|spill|violation|fine)`.
--              All signals reference sub-contractors of existing parties to enable chain-traversal in the rule.
-- Date: 2026-05-14

BEGIN;

INSERT INTO osint_signal (
  tenant_id, ext_id, source_id, source, kind, category, severity, severity_v2,
  title_en, title, summary, description_en, source_reliability, confidence,
  affected_clause_categories, geographies, affected_entities,
  published_date, fetched_at, raw_payload, dedup_hash, metadata, data_classification,
  is_seed, is_active, created_at, updated_at
)
SELECT
  t.id,
  'esg-mock-' || row_number,
  'mock_social_x',
  'mock_social_x',
  'news',
  'geopolitical',  -- closest available category per impact_signal_category_check; CR-I extends taxonomy in pilot
  'medium',
  CASE WHEN row_number % 4 = 0 THEN 'high' ELSE 'medium' END,
  title,
  title,
  summary,
  description,
  0.55,
  0.65,
  ARRAY['environmental','compliance']::TEXT[],
  jsonb_build_array('UAE'),
  jsonb_build_array(jsonb_build_object('name', entity, 'role', 'subcontractor')),
  (NOW() - (row_number || ' days')::INTERVAL)::TIMESTAMPTZ,
  NOW(),
  jsonb_build_object('mocked', TRUE, 'rowNumber', row_number, 'entity', entity),
  encode(sha256(('esg-mock-' || row_number)::bytea), 'hex'),
  jsonb_build_object('adapterClass','MockSocialXAdapter','synthetic',TRUE),
  'demo',
  TRUE, TRUE, NOW(), NOW()
FROM tenant t
CROSS JOIN (VALUES
  ( 1, 'Galadari Brothers',           'Galadari sub-contractor cited for labour rights violation in Sharjah industrial zone',     'Workplace inspection finds labour violation at sub-contractor site; OSHA-equivalent fine pending.'),
  ( 2, 'Galadari Brothers',           'Environmental fine issued to Galadari steel supplier for pollution discharge',              'Local authority fines secondary supplier for environmental pollution discharge into Sharjah creek.'),
  ( 3, 'Crescent Petroleum',          'Crescent sub-contractor faces forced labour allegations in Pakistani operations',         'NGO report alleges forced labour conditions at upstream operations contractor.'),
  ( 4, 'Crescent Petroleum',          'Crescent EPC subcontractor cited for environmental spill at Hamriyah port',                 'Oil spill at sub-contractor facility under environmental investigation.'),
  ( 5, 'IBM Middle East FZ-LLC',      'IBM Middle East data-centre contractor cited for labour violation',                         'Construction sub-contractor cited by Ministry of Human Resources for excessive overtime violation.'),
  ( 6, 'IBM Middle East FZ-LLC',      'Environmental violation at IBM ME server-cooling supplier',                                 'Cooling-water discharge above permitted limits; remediation order issued.'),
  ( 7, 'Microsoft (Azure UAE)',       'Azure UAE construction sub-contractor faces child labour investigation',                    'Investigation opened into child labour allegations at construction site sub-contractor.'),
  ( 8, 'Microsoft (Azure UAE)',       'Pollution violation at Azure UAE generator-fuel supplier',                                  'Fuel storage spill at upstream supplier triggers environmental remediation order.'),
  ( 9, 'DEWA',                        'DEWA cable-laying sub-contractor cited for labour rights violation',                        'Labour court fines sub-contractor for unpaid overtime violation.'),
  (10, 'DEWA',                        'Environmental spill at DEWA transformer supplier facility',                                 'Oil spill at transformer manufacturing sub-contractor under environmental review.'),
  (11, 'Etisalat Group',              'Etisalat tower-installation contractor faces labour rights complaint',                      'Worker complaints filed alleging violation of mandatory rest-break regulations.'),
  (12, 'Etisalat Group',              'Pollution fine at Etisalat civil-works supplier',                                           'Construction debris discharge fine issued by Abu Dhabi environmental agency.'),
  (13, 'Mubadala Investment',         'Mubadala maritime sub-contractor cited for fuel spill violation',                          'Bilge water discharge violation at sub-contractor vessel; fine issued.'),
  (14, 'Mubadala Investment',         'Forced-labour allegation at Mubadala EPC tier-2 supplier',                                  'International watchdog flags forced-labour conditions at downstream supplier.'),
  (15, 'Emirates NBD Bank',           'ENBD ATM-installation contractor faces labour violation',                                   'Sub-contractor cited for unpaid wage violation.'),
  (16, 'Emirates NBD Bank',           'Environmental fine at ENBD branch-construction supplier',                                   'Improper waste disposal fine issued to construction sub-contractor.'),
  (17, 'ADNOC Distribution',          'ADNOC Distribution fuel-tanker sub-contractor cited for spill violation',                   'Fuel spill at sub-contractor tanker facility under investigation.'),
  (18, 'ADNOC Distribution',          'Labour violation at ADNOC Distribution car-wash franchise',                                 'Franchise sub-contractor fined for excessive working hours violation.'),
  (19, 'Galadari Brothers',           'Child labour allegations at Galadari restaurant supplier',                                  'Investigation opened into food-supplier sub-contractor child labour allegations.'),
  (20, 'Crescent Petroleum',          'Pollution spill at Crescent maritime contractor',                                           'Oil discharge violation at sub-contractor vessel; cleanup order issued.'),
  (21, 'IBM Middle East FZ-LLC',      'Environmental violation at IBM ME data destruction sub-contractor',                         'Electronic waste improperly disposed at sub-contractor facility; fine issued.'),
  (22, 'Microsoft (Azure UAE)',       'Forced labour allegations at Azure UAE security sub-contractor',                            'Worker testimony alleges forced labour conditions; investigation pending.'),
  (23, 'DEWA',                        'Pollution discharge at DEWA water-treatment sub-contractor',                                'Chemical discharge violation under environmental remediation order.'),
  (24, 'Etisalat Group',              'Labour-rights violation at Etisalat customer-service outsourcer',                           'Outsourcer sub-contractor cited for wage-protection violation.'),
  (25, 'Mubadala Investment',         'Environmental spill at Mubadala industrial sub-contractor',                                 'Hazardous material spill at downstream operations sub-contractor.'),
  (26, 'Emirates NBD Bank',           'Labour violation at ENBD security sub-contractor',                                          'Sub-contractor cited for unpaid overtime violation.'),
  (27, 'ADNOC Distribution',          'Pollution fine at ADNOC fuel-station construction supplier',                                'Construction waste improperly handled; environmental fine issued.'),
  (28, 'Galadari Brothers',           'Forced labour case opened at Galadari logistics sub-contractor',                            'Workers report passport-confiscation forced-labour conditions.'),
  (29, 'Crescent Petroleum',          'Child labour investigation at Crescent downstream supplier',                                'Audit finds underage workers at downstream supplier site.'),
  (30, 'IBM Middle East FZ-LLC',      'Environmental violation and fine at IBM ME catering sub-contractor',                       'Waste-water discharge violation at catering services sub-contractor.')
) AS x(row_number, entity, title, description)
CROSS JOIN LATERAL (SELECT description AS summary) s
WHERE t.is_active = TRUE AND t.slug = 'adnoc'
ON CONFLICT (tenant_id, dedup_hash) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (241, '241_seed_esg_mocked_signals', CURRENT_TIMESTAMP);

COMMIT;
