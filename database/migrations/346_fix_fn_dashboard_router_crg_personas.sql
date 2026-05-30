-- Migration: 346_fix_fn_dashboard_router_crg_personas.sql
-- Module: Post-v1.5 hardening
-- Description: Extend fn_dashboard_router CASE to handle the 4 CR-G ADNOC
--              persona roles added in migrations 181-184 (2026-05-13):
--                operations, finance_treasury, compliance_esg, procurement_supplier_risk
--              Before this fix they fell through to the `ELSE 'recipient'`
--              default so InsightsRouter sent every CR-G persona to the
--              recipient dashboard — wrong for all 4.
--
-- Maps each new role to its dashboardKey (the FE InsightsRouter resolves
-- the key to a route via DASHBOARD_TO_PATH; the matching FE routes already
-- exist at /app/dashboards/operations | finance-treasury | compliance-esg |
-- procurement, and the matching BE fn_dashboard_<name> functions exist in
-- migrations 183-186).
--
-- This is an additive CASE extension. Return shape, permissions summary,
-- SECURITY INVOKER, REVOKE/GRANT, exception handling — all preserved
-- byte-for-byte from migration 056.
--
-- Rollback: see ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION fn_dashboard_router()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id   BIGINT;
  v_user      JSONB;
  v_role      TEXT;
  v_dash_key  TEXT;
  v_perms     JSONB;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_router: unauthorized' USING ERRCODE = '42501';
  END IF;

  v_user := fn_user_get_by_id(v_user_id);
  IF v_user IS NULL OR v_user = 'null'::jsonb THEN
    RAISE EXCEPTION 'fn_dashboard_router: user not found' USING ERRCODE = '42501';
  END IF;

  -- Live fn_user_get_by_id returns nested 'role':{id,name}; defensive fallbacks.
  v_role := COALESCE(v_user->'role'->>'name', v_user->>'roleName', 'unknown');

  v_dash_key := CASE
    WHEN v_role = 'Super Admin'                                  THEN 'admin'
    WHEN v_role = 'platform_admin'                               THEN 'admin'
    WHEN v_role = 'legal_counsel'                                THEN 'legal_counsel'
    WHEN v_role = 'contract_drafter'                             THEN 'drafter'
    WHEN v_role IN ('contract_approver', 'contract_approver_2')  THEN 'approver'
    WHEN v_role = 'contract_recipient'                           THEN 'recipient'
    WHEN v_role = 'executive'                                    THEN 'executive'
    -- Post-v1.5 hardening: CR-G persona roles added migrations 181-184.
    WHEN v_role = 'operations'                                   THEN 'operations'
    WHEN v_role = 'finance_treasury'                             THEN 'finance_treasury'
    WHEN v_role = 'compliance_esg'                               THEN 'compliance_esg'
    WHEN v_role = 'procurement_supplier_risk'                    THEN 'procurement'
    ELSE 'recipient'
  END;

  v_perms := jsonb_build_object(
    'canViewAdminDashboard',     v_role IN ('platform_admin', 'Super Admin'),
    'canViewExecutiveDashboard', v_role IN ('executive', 'platform_admin', 'Super Admin')
  );

  RETURN jsonb_build_object(
    'userId', v_user_id,
    'primaryRole', v_role,
    'dashboardKey', v_dash_key,
    'permissionsSummary', v_perms
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_router: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_router() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_router() TO neondb_owner;

COMMENT ON FUNCTION fn_dashboard_router() IS
  'Returns the user''s primary dashboard key + permission summary. Post-v1.5 (mig 346): added CR-G personas operations/finance_treasury/compliance_esg/procurement_supplier_risk.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (346, 'fix(fn_dashboard_router): map 4 CR-G ADNOC persona roles', now())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (manual)
-- ============================================================
-- BEGIN;
-- -- Restore the original M6 body by re-running migration 056 lines 646-700,
-- -- which has the 7-role CASE and ELSE 'recipient' default. The 4 CR-G
-- -- personas will fall back to 'recipient' (the pre-346 behavior).
-- DELETE FROM schema_migrations WHERE version = 346;
-- COMMIT;
