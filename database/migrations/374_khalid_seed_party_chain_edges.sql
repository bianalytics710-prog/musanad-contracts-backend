-- Migration: 374_khalid_seed_party_chain_edges.sql
-- Unit: Khalid Compliance QA Phase 3.6 (2026-05-31)
-- Fixes K1 (chain) + K2 (Sub-contractor chain view section was empty even
-- after 371) — seed party_relationship edges so fn_party_chain_summary
-- returns sanctionedNodesCount > 0 for at least 3-5 counterparties.

BEGIN;

SET LOCAL app.current_tenant_id = '00000000-0000-0000-0000-000000000001';

-- Create a synthetic sanctioned parent party that several counterparties
-- inherit a chain edge from. The parent itself is flagged 'sanctioned'.
WITH parent AS (
  INSERT INTO party (
    party_type, name_en, name_ar, sanctions_status,
    is_active, created_at, updated_at, created_by, updated_by
  )
  SELECT 'company', 'Sanctioned Parent Holdings Ltd', 'سانكشند برنت هولدنغز المحدودة',
         'sanctioned', TRUE, NOW(), NOW(), 1, 1
  WHERE NOT EXISTS (
    SELECT 1 FROM party WHERE name_en = 'Sanctioned Parent Holdings Ltd'
  )
  RETURNING id
),
existing_parent AS (
  SELECT id FROM party WHERE name_en = 'Sanctioned Parent Holdings Ltd' LIMIT 1
),
parent_id AS (
  SELECT COALESCE((SELECT id FROM parent), (SELECT id FROM existing_parent)) AS id
),
child_parties AS (
  SELECT id FROM party
   WHERE name_en IN (
     'Crescent Petroleum Company',
     'Gulf Marine Services',
     'Lamprell Energy',
     'Jereh Oil & Gas Equipment',
     'Target Engineering Construction'
   )
     AND is_active = TRUE
)
INSERT INTO party_relationship (
  tenant_id, parent_id, child_id, relationship_type, ownership_pct,
  source, confidence, metadata, data_classification,
  created_at, updated_at, created_by, updated_by, is_active
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  pid.id, cp.id, 'parent', 51.00,
  'demo_seed', 0.95,
  jsonb_build_object('note', 'K1/K2 fix — synthetic sanctioned chain'),
  'internal',
  NOW(), NOW(), 1, 1, TRUE
FROM parent_id pid CROSS JOIN child_parties cp
ON CONFLICT (tenant_id, parent_id, child_id, relationship_type) DO NOTHING;

COMMIT;

-- ============================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (374, '374_khalid_seed_party_chain_edges', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ROLLBACK:
--   DELETE FROM party_relationship WHERE metadata->>'note' = 'K1/K2 fix — synthetic sanctioned chain';
--   DELETE FROM party WHERE name_en = 'Sanctioned Parent Holdings Ltd';
--   DELETE FROM schema_migrations WHERE version = 374;
