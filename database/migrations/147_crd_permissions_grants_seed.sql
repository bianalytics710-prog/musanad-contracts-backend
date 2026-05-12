-- Migration: 147_crd_permissions_grants_seed.sql
-- Module: M12 / CR-D — Clause Taxonomy + Two-Stage Extractor
-- Description: 4 net-new permissions + 20 role_permission grants (Annex A.11 per db-design.md §1.5).
--   clause.extract (Super Admin only) + clause.review (legal_counsel + platform_admin) +
--   clause.taxonomy.read (all 9 roles) + clause.search (8 contract-readable roles).
--   ON CONFLICT DO NOTHING — idempotent.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- 4 net-new permissions
-- NOTE (schema discovery): permission table columns: id, code, module, action, description, created_at, is_active
-- No updated_at column. module + action are NOT NULL. Derived from code: clause.X -> module=clause, action=X.
INSERT INTO permission (code, module, action, description, is_active, created_at)
VALUES
  ('clause.extract',       'clause', 'extract',       'Manual trigger of clause extraction. System break-glass.',              TRUE, NOW()),
  ('clause.review',        'clause', 'review',         'Access clause review queue and resolve extracted clause actions.',       TRUE, NOW()),
  ('clause.taxonomy.read', 'clause', 'taxonomy.read',  'Read clause taxonomy rows. Reference content for all roles.',           TRUE, NOW()),
  ('clause.search',        'clause', 'search',          'Use pgvector semantic search across extracted contract clauses.',        TRUE, NOW())
ON CONFLICT (code) DO NOTHING;

-- 20 role_permission grants
-- Role IDs: Super Admin=1, platform_admin=4, legal_counsel=5, contract_drafter=6,
--           contract_approver=7, contract_approver_2=8, contract_recipient=9, executive=10
-- (compliance_esg role does not exist yet — deferred to CR-G per HITL scopeNotes)

-- clause.extract × 1 (Super Admin only — break-glass per OPEN-DECISION-L pattern)
INSERT INTO role_permission (role_id, permission_id, is_active, created_at)
SELECT r.id, p.id, TRUE, NOW()
FROM role r, permission p
WHERE r.name = 'Super Admin' AND p.code = 'clause.extract'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- clause.review × 2 (legal_counsel + platform_admin)
INSERT INTO role_permission (role_id, permission_id, is_active, created_at)
SELECT r.id, p.id, TRUE, NOW()
FROM role r, permission p
WHERE r.name IN ('legal_counsel', 'platform_admin') AND p.code = 'clause.review'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- clause.taxonomy.read × 9 (all roles with any contract access)
INSERT INTO role_permission (role_id, permission_id, is_active, created_at)
SELECT r.id, p.id, TRUE, NOW()
FROM role r, permission p
WHERE r.name IN (
  'Super Admin', 'platform_admin', 'legal_counsel',
  'contract_drafter', 'contract_approver', 'contract_approver_2',
  'contract_recipient', 'executive'
  -- NOTE: compliance_esg deferred to CR-G (role not yet seeded)
) AND p.code = 'clause.taxonomy.read'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- clause.search × 8 (all contract-readable roles per db-design.md §1.5)
INSERT INTO role_permission (role_id, permission_id, is_active, created_at)
SELECT r.id, p.id, TRUE, NOW()
FROM role r, permission p
WHERE r.name IN (
  'legal_counsel', 'contract_drafter', 'contract_approver', 'contract_approver_2',
  'contract_recipient', 'executive', 'platform_admin', 'Super Admin'
  -- NOTE: compliance_esg deferred to CR-G (role not yet seeded)
) AND p.code = 'clause.search'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (147, '147_crd_permissions_grants_seed', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 147;
-- DELETE FROM role_permission
--   WHERE permission_id IN (SELECT id FROM permission WHERE code IN ('clause.extract','clause.review','clause.taxonomy.read','clause.search'));
-- DELETE FROM permission WHERE code IN ('clause.extract','clause.review','clause.taxonomy.read','clause.search');
-- ============================================================
