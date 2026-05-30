-- Migration: 339_cru_v15_seed_bundles.sql
-- Module: CR-U — Product Module Toggle (wave v1.5)
-- Description: Seeds the three product_bundle rows. is_core=TRUE only for
--              'platform' — UI must lock that toggle. Idempotent.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- Set seed actor to a Super Admin (uses minimum id; consistent with
-- migration 333 pattern) so audit + created_by are populated.
DO $$
DECLARE
  v_actor BIGINT;
BEGIN
  SELECT MIN(u.id) INTO v_actor
  FROM "user" u
  JOIN role r ON r.id = u.role_id
  WHERE r.name = 'Super Admin'
    AND u.is_active = TRUE
    AND r.is_active = TRUE;

  PERFORM set_config('app.current_user_id', COALESCE(v_actor::text, ''), false);

  INSERT INTO product_bundle (code, label_key, is_core, created_by, updated_by)
  VALUES
    ('clm',      'admin.modules.bundle.clm.label',      FALSE, v_actor, v_actor),
    ('ecip',     'admin.modules.bundle.ecip.label',     FALSE, v_actor, v_actor),
    ('platform', 'admin.modules.bundle.platform.label', TRUE,  v_actor, v_actor)
  ON CONFLICT (code) DO NOTHING;

  RAISE NOTICE '339: product_bundle seeded (3 rows: clm, ecip, platform).';
END;
$$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (339, 'cru_v15_seed_bundles', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DELETE FROM product_bundle WHERE code IN ('clm','ecip','platform');
-- DELETE FROM schema_migrations WHERE version = 339;
-- COMMIT;
-- ROLLBACK END
