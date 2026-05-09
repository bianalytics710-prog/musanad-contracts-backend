-- Migration: 100_m7_permissions_seed.sql
-- Module: M7 — OSINT Source Framework + Adapter Protocol (CR-A)
-- Description: Seed 4 net-new permissions (source.read, source.manage, signal.read.all, osint.signal.upsert)
--              and grant 9 unconditional role_permission rows + 1 guarded compliance_esg row.
-- Rollback: See ROLLBACK section below.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- 1. Insert 4 new permissions (idempotent).
INSERT INTO permission (code, module, action, description) VALUES
  ('source.read',         'osint', 'read',
     'Read OSINT source registry + health monitor.'),
  ('source.manage',       'osint', 'manage',
     'Create/update/delete sources, set credentials, trigger test-pull.'),
  ('signal.read.all',     'osint', 'signal.read.all',
     'Read OSINT signals across tenant.'),
  ('osint.signal.upsert', 'osint', 'signal.upsert',
     'Insert OSINT signals — system-only marker; no role grant; enforced via DEFINER + REVOKE FROM PUBLIC on fn_osint_signal_upsert.')
ON CONFLICT (code) DO NOTHING;

-- 2. Grant 9 unconditional role_permission rows via JOIN-based pattern (M2 028 / M3 037 / M4 044 / R-PA 094 precedent).
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r
CROSS JOIN permission p
WHERE (r.name, p.code) IN (
  ('platform_admin', 'source.read'),
  ('platform_admin', 'source.manage'),
  ('platform_admin', 'signal.read.all'),
  ('executive',      'source.read'),
  ('executive',      'signal.read.all'),
  ('legal_counsel',  'signal.read.all'),
  ('Super Admin',    'source.read'),
  ('Super Admin',    'source.manage'),
  ('Super Admin',    'signal.read.all')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- 3. Guarded compliance_esg grant — no-op if role does not yet exist (CR-G activation migration will fill it later).
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r, permission p
WHERE r.name = 'compliance_esg'
  AND r.is_active = TRUE
  AND p.code = 'signal.read.all'
  AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (100, 'm7_permissions_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM role_permission
--   WHERE permission_id IN (SELECT id FROM permission WHERE code IN ('source.read','source.manage','signal.read.all','osint.signal.upsert'));
-- DELETE FROM permission
--   WHERE code IN ('source.read','source.manage','signal.read.all','osint.signal.upsert');
-- DELETE FROM schema_migrations WHERE version = 100;
-- COMMIT;
-- ============================================================
