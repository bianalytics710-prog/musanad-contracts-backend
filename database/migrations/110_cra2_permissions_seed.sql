-- Migration: 110_cra2_permissions_seed.sql
-- Module: M8 — Internal Signal Data Path (CR-A2)
-- Description: Seed 3 net-new permissions (internal_signal.ingest / .read / .resolve) and grant
--              role_permission rows per the Q-DA3 hardcoded mapping. Layout:
--                (1) INSERT 3 permissions ON CONFLICT (code) DO NOTHING.
--                (2) Unconditional CROSS-JOIN grants (M2 028 / M3 037 / M4 044 / M7 100 precedent):
--                      Super Admin pre-emptive on all 3
--                      platform_admin / legal_counsel / executive on internal_signal.read
--                      platform_admin on internal_signal.resolve
--                      Super Admin + platform_admin on internal_signal.ingest
--                (3) Conditional WHERE-EXISTS no-op grants for deferred CR-G roles
--                    (operations / finance_treasury / procurement / compliance_esg)
--                    on internal_signal.read AND internal_signal.resolve. These produce no row when
--                    the role does not yet exist; CR-G activation backfills automatically.
--                NOTE: internal_signal.ingest is system-only at the fn-EXECUTE layer — REVOKE FROM
--                PUBLIC + no role GRANT EXECUTE on fn_internal_signal_ingest (mirroring
--                fn_osint_signal_upsert / AC-S7-05). Granting the *permission* row to platform_admin
--                +Super Admin still allows them to hit the route (which calls the fn through the
--                neondb_owner connection).
-- Rollback: see ROLLBACK section below.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ----------------------------------------------------------------
-- 1. Insert 3 net-new permissions (idempotent)
-- ----------------------------------------------------------------
INSERT INTO permission (code, module, action, description) VALUES
  ('internal_signal.ingest',  'internal_signal', 'ingest',
     'Insert internal signals via fn_internal_signal_ingest. System-only marker; fn EXECUTE is REVOKE-FROM-PUBLIC + no role grant. Permission row granted to platform_admin / Super Admin so they can hit the route.'),
  ('internal_signal.read',    'internal_signal', 'read',
     'Read internal signals + admin viewer of internal_signal_kind catalogue.'),
  ('internal_signal.resolve', 'internal_signal', 'resolve',
     'Resolve internal signals. Role mapping per signal_type is hardcoded inside fn_internal_signal_resolve body (Q-DA3 lock).')
ON CONFLICT (code) DO NOTHING;

-- ----------------------------------------------------------------
-- 2. Unconditional CROSS-JOIN role_permission grants
-- ----------------------------------------------------------------
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r
CROSS JOIN permission p
WHERE (r.name, p.code) IN (
  -- internal_signal.read — broad read access at v1
  ('platform_admin', 'internal_signal.read'),
  ('legal_counsel',  'internal_signal.read'),
  ('executive',      'internal_signal.read'),
  ('Super Admin',    'internal_signal.read'),
  -- internal_signal.resolve — Super Admin + platform_admin only at v1
  -- (resolver-by-role mapping per Q-DA3 deferred until CR-G roles land)
  ('Super Admin',    'internal_signal.resolve'),
  ('platform_admin', 'internal_signal.resolve'),
  -- internal_signal.ingest — Super Admin + platform_admin (demo-override path per brief)
  ('Super Admin',    'internal_signal.ingest'),
  ('platform_admin', 'internal_signal.ingest')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ----------------------------------------------------------------
-- 3. Conditional WHERE-EXISTS no-op grants for CR-G deferred roles
--    (M7 100 precedent — separate INSERT block per role so each is a no-op
--     when the role does not yet exist)
-- ----------------------------------------------------------------

-- internal_signal.read — operations
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r, permission p
WHERE r.name = 'operations' AND r.is_active = TRUE
  AND p.code = 'internal_signal.read' AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- internal_signal.read — finance_treasury
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r, permission p
WHERE r.name = 'finance_treasury' AND r.is_active = TRUE
  AND p.code = 'internal_signal.read' AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- internal_signal.read — procurement
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r, permission p
WHERE r.name = 'procurement' AND r.is_active = TRUE
  AND p.code = 'internal_signal.read' AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- internal_signal.read — compliance_esg
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r, permission p
WHERE r.name = 'compliance_esg' AND r.is_active = TRUE
  AND p.code = 'internal_signal.read' AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- internal_signal.resolve — operations (milestone_slippage / sla_breach / vendor_incident / ics_incident per Q-DA3)
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r, permission p
WHERE r.name = 'operations' AND r.is_active = TRUE
  AND p.code = 'internal_signal.resolve' AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- internal_signal.resolve — finance_treasury (payment_delay / invoice_dispute per Q-DA3)
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r, permission p
WHERE r.name = 'finance_treasury' AND r.is_active = TRUE
  AND p.code = 'internal_signal.resolve' AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- internal_signal.resolve — procurement (icv_status_change / vendor_incident per Q-DA3)
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r, permission p
WHERE r.name = 'procurement' AND r.is_active = TRUE
  AND p.code = 'internal_signal.resolve' AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- internal_signal.resolve — compliance_esg (icv_status_change / certificate_expiry per Q-DA3)
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r, permission p
WHERE r.name = 'compliance_esg' AND r.is_active = TRUE
  AND p.code = 'internal_signal.resolve' AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ----------------------------------------------------------------
-- Record this migration
-- ----------------------------------------------------------------
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (110, 'cra2_permissions_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM role_permission
--   WHERE permission_id IN (
--     SELECT id FROM permission
--     WHERE code IN ('internal_signal.ingest','internal_signal.read','internal_signal.resolve')
--   );
-- DELETE FROM permission
--   WHERE code IN ('internal_signal.ingest','internal_signal.read','internal_signal.resolve');
-- DELETE FROM schema_migrations WHERE version = 110;
-- COMMIT;
-- ============================================================
