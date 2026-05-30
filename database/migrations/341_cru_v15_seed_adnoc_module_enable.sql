-- Migration: 341_cru_v15_seed_adnoc_module_enable.sql
-- Module: CR-U — Product Module Toggle (wave v1.5)
-- Description: Seeds product_module_enable rows for the ADNOC tenant
--              (tenant_id='00000000-0000-0000-0000-000000000001' — the
--              canonical demo tenant UUID used across CR-Q/CR-N/CR-O seeds).
--              Every module starts enabled (is_enabled=default_enabled=TRUE).
--              role_module_access starts empty — every role uses
--              product_module.default_role_codes until an admin overrides
--              a specific cell via fn_role_module_access_set.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_actor  BIGINT;
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
BEGIN
  SELECT MIN(u.id) INTO v_actor
  FROM "user" u
  JOIN role r ON r.id = u.role_id
  WHERE r.name = 'Super Admin' AND u.is_active = TRUE AND r.is_active = TRUE;
  PERFORM set_config('app.current_user_id', COALESCE(v_actor::text, ''), false);
  PERFORM set_config('app.current_tenant_id', v_tenant::text, false);

  INSERT INTO product_module_enable (
    tenant_id, module_key, is_enabled, reason, created_by, updated_by
  )
  SELECT
    v_tenant,
    pm.key,
    pm.default_enabled,
    'v1.5 initial seed — all defaults',
    v_actor,
    v_actor
  FROM product_module pm
  WHERE pm.is_active = TRUE
  ON CONFLICT (tenant_id, module_key) DO NOTHING;

  RAISE NOTICE '341: product_module_enable seeded for ADNOC tenant (expected 33 rows).';
END;
$$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (341, 'cru_v15_seed_adnoc_module_enable', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DELETE FROM product_module_enable
--   WHERE tenant_id = '00000000-0000-0000-0000-000000000001'
--     AND reason = 'v1.5 initial seed — all defaults';
-- DELETE FROM schema_migrations WHERE version = 341;
-- COMMIT;
-- ROLLBACK END
