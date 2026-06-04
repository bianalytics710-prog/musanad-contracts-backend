-- Migration: 496_drafter_deny_procurement_dashboard.sql
-- Module: Drafter sidebar — align BE effective set with FE D48 intent
-- Date: 2026-06-02
--
-- Problem: Dana (contract_drafter) does not see the "Insights" entry in
-- the sidebar. Root cause: BE's fn_user_effective_modules returns
-- dashboards.procurement for the drafter (it is in pm.default_role_codes
-- for that module key). The FE sidebar filter
-- (modulesForEffectiveSet → PERSONA_DASHBOARDS) then drops the
-- "Insights" link because the user "already has a persona dashboard".
--
-- FE comment D48 already documents the intent: dashboards.procurement is
-- Pari's persona surface; surfacing it on the drafter added noise and
-- did not intersect her workflow. The FE static ROLE_MODULES map honors
-- this, but the runtime BE-driven path doesn't.
--
-- Fix: insert an explicit DENY in role_module_access for
-- (role_id = contract_drafter, module_key = 'dashboards.procurement',
--  tenant_id = NULL). This is the system default deny that survives the
-- "default_role_codes" allow, so fn_user_effective_modules will exclude
-- procurement → FE filter sees no persona dashboard → "Insights" renders.

DO $$
DECLARE
  v_role_id BIGINT;
BEGIN
  SELECT id INTO v_role_id FROM role WHERE name = 'contract_drafter';
  IF v_role_id IS NULL THEN
    RAISE NOTICE 'contract_drafter role not found — skipping';
    RETURN;
  END IF;

  -- Upsert (deny is_allowed=FALSE at tenant_id IS NULL scope)
  INSERT INTO role_module_access (
    tenant_id, role_id, module_key, is_allowed, reason,
    created_by, updated_by, is_active
  ) VALUES (
    NULL, v_role_id, 'dashboards.procurement', FALSE,
    'D48 — procurement supplier-risk is Pari''s persona surface; drafter''s home is Insights',
    1, 1, TRUE
  )
  ON CONFLICT (tenant_id, role_id, module_key)
  DO UPDATE SET
    is_allowed = FALSE,
    is_active  = TRUE,
    reason     = EXCLUDED.reason,
    updated_at = NOW(),
    updated_by = 1;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (496, '496_drafter_deny_procurement_dashboard', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;
