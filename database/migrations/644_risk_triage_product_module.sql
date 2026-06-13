-- ============================================================================
-- Migration 644 — Phase B: register risk_triage product module + tenant enable
-- ============================================================================
-- The sidebar entry for "Risk Triage" only renders when product_module has a
-- matching row AND product_module_enable enables it for the tenant. Both
-- live alongside risk_cases (the sibling exec entry). default_role_codes is
-- scoped to Super Admin + platform_admin + executive — the same audience that
-- can hit the underlying risk.review.manage permission.
--
-- Idempotent.
-- ============================================================================

INSERT INTO product_module (
  key, bundle_code, parent_key, label_key, sidebar_path,
  owned_route_prefixes, owned_permission_prefixes,
  default_role_codes, display_order, is_active
)
VALUES (
  'risk_triage',
  'ecip',
  NULL,
  'admin.modules.ecip.risk_triage',
  '/app/exec/risk-triage',
  '["/app/exec/risk-triage"]'::jsonb,
  '["risk.review"]'::jsonb,
  '["Super Admin", "platform_admin", "executive"]'::jsonb,
  385,
  true
)
ON CONFLICT (key) DO UPDATE
  SET sidebar_path     = EXCLUDED.sidebar_path,
      default_role_codes = EXCLUDED.default_role_codes,
      display_order    = EXCLUDED.display_order,
      is_active        = EXCLUDED.is_active;

-- Enable for the ADNOC tenant explicitly (mirror what mig 674 did for my_work).
INSERT INTO product_module_enable (tenant_id, module_key, is_enabled, reason)
SELECT '00000000-0000-0000-0000-000000000001', 'risk_triage', true,
       'Phase B mig 644 — Executive Risk Triage sidebar entry'
ON CONFLICT (tenant_id, module_key) DO UPDATE SET is_enabled = true;

-- Sanity assertion — fn_user_effective_modules must now return risk_triage
-- for the executive role.
DO $$
DECLARE
  v_codes JSONB;
BEGIN
  SELECT default_role_codes INTO v_codes FROM product_module WHERE key = 'risk_triage';
  IF NOT (v_codes ? 'executive') THEN
    RAISE EXCEPTION 'mig 644: risk_triage missing executive role code (got %)', v_codes;
  END IF;
END $$;
