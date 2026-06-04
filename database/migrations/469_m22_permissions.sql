-- Migration: 469_m22_permissions.sql
-- Module: M22 / CR-MIG-DRIVE — 7 new permissions + role grants
-- Date: 2026-06-02
--
-- migration.purge.all is platform_admin + Super Admin ONLY — never legal_counsel
-- or drafters. integrations.catalog.read is granted to ALL active roles so the
-- source-picker tile grid renders for every authenticated user.

BEGIN;

-- ============================================================
-- Permissions
-- ============================================================
INSERT INTO permission (code, module, action, description, is_active) VALUES
  ('migration.connection.manage', 'migration', 'connection.manage', 'Create / disconnect external migration connections (OAuth-backed sources).', TRUE),
  ('migration.batch.trigger',     'migration', 'batch.trigger',     'Trigger a migration sync against a connected source.', TRUE),
  ('migration.batch.read.all',    'migration', 'batch.read.all',    'Read all migration batches + per-batch records in the tenant.', TRUE),
  ('migration.batch.rollback',    'migration', 'batch.rollback',    'Roll back a completed migration batch (soft-mark contracts).', TRUE),
  ('migration.review.resolve',    'migration', 'review.resolve',    'Resolve needs_review migration records (accept / edit / reject extracted fields).', TRUE),
  ('migration.purge.all',         'migration', 'purge.all',         'DEDICATED hard-delete: purge all migration-imported data via the danger-zone button.', TRUE),
  ('integrations.catalog.read',   'integrations','catalog.read',    'Read the public connector catalog (source-picker tile grid).', TRUE)
ON CONFLICT (code) DO NOTHING;

-- ============================================================
-- Role grants
-- ============================================================
DO $$
DECLARE
  v_super_admin BIGINT := (SELECT id FROM role WHERE name = 'Super Admin');
  v_platform   BIGINT := (SELECT id FROM role WHERE name = 'platform_admin');
  v_legal      BIGINT := (SELECT id FROM role WHERE name = 'legal_counsel');
  v_drafter    BIGINT := (SELECT id FROM role WHERE name = 'contract_drafter');
  v_approver   BIGINT := (SELECT id FROM role WHERE name = 'contract_approver');
  v_recipient  BIGINT := (SELECT id FROM role WHERE name = 'contract_recipient');
  v_executive  BIGINT := (SELECT id FROM role WHERE name = 'executive');
  v_ops        BIGINT := (SELECT id FROM role WHERE name = 'operations');
  v_finance    BIGINT := (SELECT id FROM role WHERE name = 'finance_treasury');
  v_compliance BIGINT := (SELECT id FROM role WHERE name = 'compliance_esg');
  v_procurement BIGINT := (SELECT id FROM role WHERE name = 'procurement_supplier_risk');

  v_p_conn      BIGINT := (SELECT id FROM permission WHERE code = 'migration.connection.manage');
  v_p_trigger   BIGINT := (SELECT id FROM permission WHERE code = 'migration.batch.trigger');
  v_p_read      BIGINT := (SELECT id FROM permission WHERE code = 'migration.batch.read.all');
  v_p_rollback  BIGINT := (SELECT id FROM permission WHERE code = 'migration.batch.rollback');
  v_p_review    BIGINT := (SELECT id FROM permission WHERE code = 'migration.review.resolve');
  v_p_purge     BIGINT := (SELECT id FROM permission WHERE code = 'migration.purge.all');
  v_p_catalog   BIGINT := (SELECT id FROM permission WHERE code = 'integrations.catalog.read');

  -- helper procedure inlined
BEGIN
  -- migration.connection.manage — platform_admin + Super Admin
  INSERT INTO role_permission (role_id, permission_id, is_active)
  SELECT r, v_p_conn, TRUE FROM unnest(ARRAY[v_super_admin, v_platform]) AS r
  WHERE r IS NOT NULL ON CONFLICT DO NOTHING;

  -- migration.batch.trigger — platform_admin + legal_counsel + drafter + Super Admin
  INSERT INTO role_permission (role_id, permission_id, is_active)
  SELECT r, v_p_trigger, TRUE FROM unnest(ARRAY[v_super_admin, v_platform, v_legal, v_drafter]) AS r
  WHERE r IS NOT NULL ON CONFLICT DO NOTHING;

  -- migration.batch.read.all — platform_admin + legal_counsel + Super Admin
  INSERT INTO role_permission (role_id, permission_id, is_active)
  SELECT r, v_p_read, TRUE FROM unnest(ARRAY[v_super_admin, v_platform, v_legal]) AS r
  WHERE r IS NOT NULL ON CONFLICT DO NOTHING;

  -- migration.batch.rollback — platform_admin + Super Admin
  INSERT INTO role_permission (role_id, permission_id, is_active)
  SELECT r, v_p_rollback, TRUE FROM unnest(ARRAY[v_super_admin, v_platform]) AS r
  WHERE r IS NOT NULL ON CONFLICT DO NOTHING;

  -- migration.review.resolve — platform_admin + legal_counsel + drafter
  INSERT INTO role_permission (role_id, permission_id, is_active)
  SELECT r, v_p_review, TRUE FROM unnest(ARRAY[v_super_admin, v_platform, v_legal, v_drafter]) AS r
  WHERE r IS NOT NULL ON CONFLICT DO NOTHING;

  -- migration.purge.all — Super Admin + platform_admin ONLY
  INSERT INTO role_permission (role_id, permission_id, is_active)
  SELECT r, v_p_purge, TRUE FROM unnest(ARRAY[v_super_admin, v_platform]) AS r
  WHERE r IS NOT NULL ON CONFLICT DO NOTHING;

  -- integrations.catalog.read — every authenticated role
  INSERT INTO role_permission (role_id, permission_id, is_active)
  SELECT r, v_p_catalog, TRUE FROM unnest(ARRAY[
    v_super_admin, v_platform, v_legal, v_drafter, v_approver, v_recipient,
    v_executive, v_ops, v_finance, v_compliance, v_procurement
  ]) AS r
  WHERE r IS NOT NULL ON CONFLICT DO NOTHING;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (469, '469_m22_permissions', CURRENT_TIMESTAMP);

COMMIT;
