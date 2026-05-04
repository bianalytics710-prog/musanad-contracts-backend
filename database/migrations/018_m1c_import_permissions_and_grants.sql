-- ============================================================================
-- 018_m1c_import_permissions_and_grants.sql — M1c permissions + role grants
-- ============================================================================
-- Module:    M1c (Bulk & Manual Import)
-- Owner:     DB Implementation Agent (Agent 6) — applies Agent 4 design verbatim
-- Depends:   001_foundation.sql (permission, role, role_permission tables),
--            003_m1a_contracts.sql (M1a roles platform_admin/legal_counsel/
--            contract_drafter), 016_m1c_import_batch.sql.
-- ----------------------------------------------------------------------------
-- INSERTs:
--   1. 2 new permission rows (import.run, import.review) ON CONFLICT DO NOTHING.
--   2. 7 role_permission grants ON CONFLICT (role_id, permission_id) DO NOTHING.
--      Includes the M0 Super Admin pre-emptive grant per M1a 006 lesson — avoids
--      the post-smoke patch cycle that M1a needed.
-- ----------------------------------------------------------------------------
-- Per HITL Gate 2 ratification of HQ4:
--   - platform_admin    : both (run + review)
--   - legal_counsel     : review only (admin oversight; does not initiate batches)
--   - contract_drafter  : both — review naturally narrowed to own batches via
--                         RLS import_batch_select_role_aware + fn_import_batch_list
--                         v_role_can_see_all gate.
--   - Super Admin (M0)  : both (pre-emptive M0 grant per M1a 006 lesson — AE-4)
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. New permissions (M1c-introduced)
-- ============================================================================

INSERT INTO permission (code, module, action, description) VALUES
  ('import.run',    'import', 'run',
   'Initiate and operate an import batch (create, update counters, pause/resume/cancel).'),
  ('import.review', 'import', 'review',
   'View import batches across users (admin oversight). Required for the Admin Imports list and per-batch drill-down.')
ON CONFLICT (code) DO NOTHING;

-- ============================================================================
-- 2. Role-permission grants (M1c — AE-4)
--    Resolves (role.name, permission.code) -> (role_id, permission_id) at apply
--    time so future role_id renumbering does not break the seed.
-- ============================================================================

INSERT INTO role_permission (role_id, permission_id, is_active)
SELECT r.id, p.id, TRUE
FROM role r
CROSS JOIN permission p
WHERE (r.name, p.code) IN (
    ('platform_admin',    'import.run'),
    ('platform_admin',    'import.review'),
    ('legal_counsel',     'import.review'),
    ('contract_drafter',  'import.run'),
    ('contract_drafter',  'import.review'),
    ('Super Admin',       'import.run'),     -- pre-emptive M0 grant (M1a 006 lesson)
    ('Super Admin',       'import.review')   -- pre-emptive M0 grant (M1a 006 lesson)
  )
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ============================================================================
-- 3. Record migration
-- ============================================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (18, 'm1c_import_permissions_and_grants', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 018_m1c_import_permissions_and_grants.sql
-- ============================================================================
-- ROLLBACK BEGIN
BEGIN;
  -- Remove grants first (FK to permission would otherwise block permission delete)
  DELETE FROM role_permission rp
   USING role r, permission p
   WHERE rp.role_id = r.id
     AND rp.permission_id = p.id
     AND p.code IN ('import.run', 'import.review');

  -- Then remove the permissions themselves
  DELETE FROM permission WHERE code IN ('import.run', 'import.review');

  DELETE FROM schema_migrations WHERE version = 18;
COMMIT;
-- ROLLBACK END
