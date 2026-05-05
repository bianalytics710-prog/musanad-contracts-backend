-- ============================================================================
-- 054_m6_insights_permissions_and_grants.sql
-- ============================================================================
-- Module:    M6 (Dashboards & Reporting)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   M0 (permission, role, role_permission, schema_migrations tables).
-- ----------------------------------------------------------------------------
-- MANDATORY FIRST migration for M6. Resolves M6-CRIT-2 — without this,
-- fn_dashboard_executive (056) returns 403 universally for executive-role
-- callers because the insights.executive permission code path is unseeded.
-- Mirrors M2 028 / M3 037 / M4 044 / M5 046 precedent (pre-emptive Super
-- Admin grant per M1a 006 / M1c 018 lesson).
--
-- 1 new permission code:
--   insights.executive  -> Super Admin, platform_admin, executive (3 grants)
--
-- Bundles ARCH-NEW-3 option (c) per locked Gate 2 decision:
--   CREATE POLICY schema_migrations_select_admin (SELECT) for
--   platform_admin + Super Admin so fn_health_check (056, INVOKER) can read
--   MAX(version) without a DEFINER carve-out. Sustains S2-21
--   zero-PUBLIC-DEFINER policy at PUBLIC count = 5.
--
-- All INSERTs use ON CONFLICT DO NOTHING — idempotent.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. Permission (1 new code) — db-design.md §7.1
-- ============================================================================
INSERT INTO permission (code, module, action, description, is_active) VALUES
  ('insights.executive', 'insights', 'read',
   'View the executive insights dashboard (system-wide enterprise overview — total active value AED, expiry cliffs, counterparty concentration, value distribution, regulatory exposure, AI cost summary).',
   TRUE)
ON CONFLICT (code) DO NOTHING;

-- ============================================================================
-- 2. Role-permission grants (3 distinct rows; M5 046 JOIN pattern)
--    Per locked Gate 2 Q8: executive + platform_admin + Super Admin.
--    Pre-emptive Super Admin grant (M2/M3/M4/M5 precedent).
--    contract_drafter / contract_approver / contract_approver_2 /
--    contract_recipient / legal_counsel: NO grants on insights.executive
--    (their dashboards are role-specific via in-body role checks).
-- ============================================================================
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM (VALUES
  ('Super Admin',    'insights.executive'),
  ('platform_admin', 'insights.executive'),
  ('executive',      'insights.executive')
) AS grants(role_name, perm_code)
JOIN role r       ON r.name = grants.role_name AND r.is_active = TRUE
JOIN permission p ON p.code = grants.perm_code AND p.is_active = TRUE
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ============================================================================
-- 3. ARCH-NEW-3 option (c) — schema_migrations admin SELECT policy
--    Allows fn_health_check (INVOKER) to read MAX(version). Pre-existing
--    schema_migrations_deny_all (ALL command, RESTRICTIVE-style) continues
--    to block INSERT/UPDATE/DELETE for non-superuser callers. Adding a
--    PERMISSIVE SELECT policy alongside RESTRICTIVE deny-all does NOT widen
--    INSERT/UPDATE/DELETE access (PostgreSQL ANDs RESTRICTIVE policies and
--    ORs PERMISSIVE ones — the new policy applies only to SELECT).
-- ============================================================================
CREATE POLICY schema_migrations_select_admin ON schema_migrations
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin', 'Super Admin')
          AND u.is_active = TRUE
          AND r.is_active = TRUE
    )
  );

COMMENT ON POLICY schema_migrations_select_admin ON schema_migrations IS
  'M6 (054) — admin SELECT carve-out for fn_health_check.db.latestMigration. ARCH-NEW-3 option (c). The pre-existing schema_migrations_deny_all (ALL command) remains for INSERT/UPDATE/DELETE — only super-user (migration runner) writes. Adding a permissive SELECT alongside RESTRICTIVE deny-all does NOT widen write access.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (54, 'm6_insights_permissions_and_grants', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP POLICY IF EXISTS schema_migrations_select_admin ON schema_migrations;
DELETE FROM role_permission
  WHERE permission_id IN (
    SELECT id FROM permission WHERE code = 'insights.executive'
  );
DELETE FROM permission WHERE code = 'insights.executive';
DELETE FROM schema_migrations WHERE version = 54;
COMMIT;
-- ROLLBACK END
