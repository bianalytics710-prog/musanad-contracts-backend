-- Migration: 398_layla_seed_advisory_templates_module.sql
-- Unit: Layla Counsel QA Phase 3.7 follow-up — L49 Advisory templates sidebar entry
--
-- product_module catalog does not have an "advisory_templates" row, so the
-- Sidebar component (which reads effectiveModules from the BE) never surfaces
-- the route. Insert the module + grant default access to legal_counsel +
-- platform_admin + Super Admin.

INSERT INTO product_module (
  key, bundle_code, parent_key, label_key, sidebar_path,
  owned_route_prefixes, owned_permission_prefixes, default_role_codes,
  default_enabled, is_core, display_order, created_at, updated_at, is_active
)
SELECT
  'legal.advisory_templates',
  'ecip',
  'advisory_queue',
  'admin.modules.ecip.legal_advisory_templates',
  '/app/admin/advisory-templates',
  '["/api/v1/advisory-templates"]'::jsonb,
  '["advisory.template."]'::jsonb,
  '["Super Admin","platform_admin","legal_counsel"]'::jsonb,
  TRUE, FALSE, 355, NOW(), NOW(), TRUE
WHERE NOT EXISTS (SELECT 1 FROM product_module WHERE key = 'legal.advisory_templates');
