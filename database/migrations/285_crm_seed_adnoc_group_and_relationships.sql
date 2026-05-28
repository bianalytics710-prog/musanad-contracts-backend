-- Migration: 285_crm_seed_adnoc_group_and_relationships.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: Seed ADNOC Group + 8 subsidiaries into party (9 rows) +
--              9 party_relationship edges (8 subsidiary + 1 Offshore→Drilling sub_contractor).
--              All idempotent: WHERE NOT EXISTS for party; ON CONFLICT DO NOTHING for relationship.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_adnoc_tenant UUID := '00000000-0000-0000-0000-000000000001';
  v_seed_user    BIGINT;
  v_group_id     BIGINT;
  v_onshore_id   BIGINT;
  v_offshore_id  BIGINT;
  v_drilling_id  BIGINT;
  v_gas_id       BIGINT;
  v_logistics_id BIGINT;
  v_dist_id      BIGINT;
  v_trading_id   BIGINT;
  v_agt_id       BIGINT;
BEGIN
  SELECT MIN(id) INTO v_seed_user FROM "user" WHERE is_active = TRUE;

  -- -------------------------------------------------------
  -- 1. ADNOC Group + 8 subsidiaries (party table)
  -- party is single-tenant (no tenant_id column)
  -- -------------------------------------------------------

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata,
                     created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company', 'ADNOC Group', 'مجموعة أدنوك', 'United Arab Emirates', 'abu_dhabi', TRUE,
         '{"groupRole":"parent","internalEntity":true,"orgLevel":0}'::jsonb,
         NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'ADNOC Group');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata,
                     created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company', 'ADNOC Onshore', 'أدنوك للحفر البري', 'United Arab Emirates', 'abu_dhabi', TRUE,
         '{"groupRole":"subsidiary","internalEntity":true,"orgLevel":1}'::jsonb,
         NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'ADNOC Onshore');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata,
                     created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company', 'ADNOC Offshore', 'أدنوك للبترول البحري', 'United Arab Emirates', 'abu_dhabi', TRUE,
         '{"groupRole":"subsidiary","internalEntity":true,"orgLevel":1}'::jsonb,
         NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'ADNOC Offshore');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata,
                     created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company', 'ADNOC Drilling', 'أدنوك للحفر', 'United Arab Emirates', 'abu_dhabi', TRUE,
         '{"groupRole":"subsidiary","internalEntity":true,"orgLevel":1}'::jsonb,
         NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'ADNOC Drilling');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata,
                     created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company', 'ADNOC Gas', 'أدنوك للغاز', 'United Arab Emirates', 'abu_dhabi', TRUE,
         '{"groupRole":"subsidiary","internalEntity":true,"orgLevel":1}'::jsonb,
         NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'ADNOC Gas');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata,
                     created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company', 'ADNOC Logistics & Services', 'أدنوك للخدمات اللوجستية', 'United Arab Emirates', 'abu_dhabi', TRUE,
         '{"groupRole":"subsidiary","internalEntity":true,"orgLevel":1}'::jsonb,
         NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'ADNOC Logistics & Services');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata,
                     created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company', 'ADNOC Distribution', 'أدنوك للتوزيع', 'United Arab Emirates', 'abu_dhabi', TRUE,
         '{"groupRole":"subsidiary","internalEntity":true,"orgLevel":1}'::jsonb,
         NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'ADNOC Distribution');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata,
                     created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company', 'ADNOC Trading', 'أدنوك للتجارة', 'United Arab Emirates', 'abu_dhabi', TRUE,
         '{"groupRole":"subsidiary","internalEntity":true,"orgLevel":1}'::jsonb,
         NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'ADNOC Trading');

  INSERT INTO party (party_type, name_en, name_ar, country, emirate, is_seed, metadata,
                     created_at, updated_at, created_by, updated_by, is_active)
  SELECT 'company', 'ADNOC Global Trading', 'أدنوك للتجارة الدولية', 'United Arab Emirates', 'abu_dhabi', TRUE,
         '{"groupRole":"subsidiary","internalEntity":true,"orgLevel":1,"ticker":"AGT"}'::jsonb,
         NOW(), NOW(), v_seed_user, v_seed_user, TRUE
  WHERE NOT EXISTS (SELECT 1 FROM party WHERE name_en = 'ADNOC Global Trading');

  -- -------------------------------------------------------
  -- 2. Resolve party IDs
  -- -------------------------------------------------------
  SELECT id INTO v_group_id     FROM party WHERE name_en = 'ADNOC Group';
  SELECT id INTO v_onshore_id   FROM party WHERE name_en = 'ADNOC Onshore';
  SELECT id INTO v_offshore_id  FROM party WHERE name_en = 'ADNOC Offshore';
  SELECT id INTO v_drilling_id  FROM party WHERE name_en = 'ADNOC Drilling';
  SELECT id INTO v_gas_id       FROM party WHERE name_en = 'ADNOC Gas';
  SELECT id INTO v_logistics_id FROM party WHERE name_en = 'ADNOC Logistics & Services';
  SELECT id INTO v_dist_id      FROM party WHERE name_en = 'ADNOC Distribution';
  SELECT id INTO v_trading_id   FROM party WHERE name_en = 'ADNOC Trading';
  SELECT id INTO v_agt_id       FROM party WHERE name_en = 'ADNOC Global Trading';

  -- -------------------------------------------------------
  -- 3. party_relationship: 8 subsidiary edges (Group → subsidiary)
  --    + 1 contracting edge (Offshore → Drilling, ownership_pct NULL)
  -- -------------------------------------------------------
  INSERT INTO party_relationship
    (tenant_id, parent_id, child_id, relationship_type, ownership_pct, source,
     created_at, updated_at, created_by, updated_by, is_active)
  VALUES
    (v_adnoc_tenant, v_group_id, v_onshore_id,   'subsidiary',    100.00, 'demo_seed', NOW(), NOW(), v_seed_user, v_seed_user, TRUE),
    (v_adnoc_tenant, v_group_id, v_offshore_id,  'subsidiary',    100.00, 'demo_seed', NOW(), NOW(), v_seed_user, v_seed_user, TRUE),
    (v_adnoc_tenant, v_group_id, v_drilling_id,  'subsidiary',    100.00, 'demo_seed', NOW(), NOW(), v_seed_user, v_seed_user, TRUE),
    (v_adnoc_tenant, v_group_id, v_gas_id,       'subsidiary',    100.00, 'demo_seed', NOW(), NOW(), v_seed_user, v_seed_user, TRUE),
    (v_adnoc_tenant, v_group_id, v_logistics_id, 'subsidiary',    100.00, 'demo_seed', NOW(), NOW(), v_seed_user, v_seed_user, TRUE),
    (v_adnoc_tenant, v_group_id, v_dist_id,      'subsidiary',    100.00, 'demo_seed', NOW(), NOW(), v_seed_user, v_seed_user, TRUE),
    (v_adnoc_tenant, v_group_id, v_trading_id,   'subsidiary',    100.00, 'demo_seed', NOW(), NOW(), v_seed_user, v_seed_user, TRUE),
    (v_adnoc_tenant, v_group_id, v_agt_id,       'subsidiary',    100.00, 'demo_seed', NOW(), NOW(), v_seed_user, v_seed_user, TRUE),
    -- Key contracting edge: Offshore → Drilling (used by Story 1 / CR-N)
    (v_adnoc_tenant, v_offshore_id, v_drilling_id, 'sub_contractor', NULL, 'demo_seed', NOW(), NOW(), v_seed_user, v_seed_user, TRUE)
  ON CONFLICT (tenant_id, parent_id, child_id, relationship_type) DO NOTHING;

END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (285, '285_crm_seed_adnoc_group_and_relationships', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 285;
-- DELETE FROM party_relationship WHERE source = 'demo_seed'
--   AND (parent_id IN (SELECT id FROM party WHERE name_en IN ('ADNOC Group','ADNOC Offshore'))
--        OR child_id IN (SELECT id FROM party WHERE name_en LIKE 'ADNOC%'));
-- DELETE FROM party WHERE name_en IN ('ADNOC Group','ADNOC Onshore','ADNOC Offshore',
--   'ADNOC Drilling','ADNOC Gas','ADNOC Logistics & Services','ADNOC Distribution',
--   'ADNOC Trading','ADNOC Global Trading') AND is_seed = TRUE;
-- COMMIT;
-- ============================================================
