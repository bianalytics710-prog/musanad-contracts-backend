-- Migration: 622_product_module_my_work.sql
-- Module: Work Order Queue (M21) — module catalog registration
-- Date: 2026-06-11
--
-- Mig 618 added the work_order table + permissions but did NOT register
-- the new module in product_module — the canonical catalog that powers
--   1. Platform Admin's Role × Module matrix UI
--   2. The /api/v1/auth/me effectiveModules JWT claim that the FE sidebar
--      reads to decide what to render
--
-- Without this row the sidebar entry only shows for tokens minted before
-- CR-V (static fallback to ROLE_MODULES). Modern tokens lose it because
-- effectiveModules.includes('my_work') === false.
--
-- This migration:
--   - Inserts the 'my_work' product_module row (bundle=clm, displayOrder=90
--     so it sits above Insights for the drafter)
--   - default_role_codes includes contract_drafter (gets it by default)
--     + Super Admin + platform_admin + executive (assignment surface)
--   - is_core=false (tenant can toggle off)

BEGIN;

INSERT INTO public.product_module (
  key,
  bundle_code,
  label_key,
  sidebar_path,
  owned_route_prefixes,
  owned_permission_prefixes,
  default_role_codes,
  default_enabled,
  is_core,
  display_order,
  created_at, updated_at, is_active
)
VALUES (
  'my_work',
  'clm',
  'admin.modules.clm.my_work',
  '/app/work',
  '["/api/v1/work-orders"]'::jsonb,
  '["work."]'::jsonb,
  '["Super Admin","platform_admin","contract_drafter","executive"]'::jsonb,
  TRUE,
  FALSE,
  90,
  now(), now(), TRUE
)
ON CONFLICT (key) DO UPDATE
  SET bundle_code              = EXCLUDED.bundle_code,
      label_key                = EXCLUDED.label_key,
      sidebar_path             = EXCLUDED.sidebar_path,
      owned_route_prefixes     = EXCLUDED.owned_route_prefixes,
      owned_permission_prefixes= EXCLUDED.owned_permission_prefixes,
      default_role_codes       = EXCLUDED.default_role_codes,
      default_enabled          = EXCLUDED.default_enabled,
      display_order            = EXCLUDED.display_order,
      updated_at               = now(),
      is_active                = TRUE;

-- Per-tenant enable: auto-on for every existing tenant. Without this the
-- BE auth resolver treats the module as "not enabled in tenant" and skips
-- it from effectiveModules even though the catalog row exists.
INSERT INTO public.product_module_enable
  (tenant_id, module_key, is_enabled, reason, created_at, updated_at, created_by, updated_by, is_active)
SELECT t.id, 'my_work', TRUE,
       'M21 auto-enable on module registration', now(), now(), 1, 1, TRUE
FROM public.tenant t
ON CONFLICT DO NOTHING;

COMMIT;
