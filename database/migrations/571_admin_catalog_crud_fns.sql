-- Migration: 571_admin_catalog_crud_fns.sql
-- Module: Index-Linked Contracts repositioning (R-IL phase 6 of 7)
-- Date: 2026-06-05
--
-- Goal: Platform Admin CRUD fn_'s for industry + pricing_benchmark_catalog
-- + cost_component_catalog. Permission gate: platform.catalog.manage.
-- Seeds the permission and grants it to Super Admin + platform_admin.
--
-- Fn surface:
--   fn_industry_list()
--   fn_catalog_benchmark_list(p_industry_id, p_tenant_id)
--   fn_catalog_benchmark_upsert(p_id, p_industry_id, p_tenant_id, p_code, ...)
--   fn_catalog_benchmark_deactivate(p_id)
--   fn_catalog_cost_component_list(p_industry_id, p_tenant_id)
--   fn_catalog_cost_component_upsert(p_id, p_industry_id, p_tenant_id, p_code, ...)
--   fn_catalog_cost_component_deactivate(p_id)
--
-- All fns SECURITY DEFINER + in-body permission check (S2-21 pattern):
--   - PUBLIC EXECUTE revoked
--   - GRANT EXECUTE to platform_admin + Super Admin roles
--   - In-body fn_current_user_has_permission check (defense in depth)

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. Seed permission ───────────────────────────────────────
INSERT INTO permission (code, module, action, description)
VALUES (
  'platform.catalog.manage',
  'platform',
  'catalog.manage',
  'Manage Industry + pricing_benchmark_catalog + cost_component_catalog rows (Platform Admin). Industry-level entries are shared defaults; tenant-level entries are per-tenant overrides.'
)
ON CONFLICT (code) DO NOTHING;

-- Grant to Super Admin (id=1) + platform_admin (id=4)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM role r, permission p
WHERE r.name IN ('Super Admin', 'platform_admin')
  AND p.code = 'platform.catalog.manage'
ON CONFLICT DO NOTHING;

-- ── 2. fn_industry_list ──────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_industry_list()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT fn_current_user_has_permission('platform.catalog.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.catalog.manage required' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'data', COALESCE(jsonb_agg(jsonb_build_object(
      'id',                 i.id,
      'code',               i.code,
      'displayLabelEn',     i.display_label_en,
      'displayLabelAr',     i.display_label_ar,
      'description',        i.description,
      'isActive',           i.is_active,
      'tenantCount',        (SELECT COUNT(*) FROM tenant t WHERE t.industry_id = i.id),
      'benchmarkCount',     (SELECT COUNT(*) FROM pricing_benchmark_catalog c WHERE c.industry_id = i.id AND c.is_active = TRUE),
      'costComponentCount', (SELECT COUNT(*) FROM cost_component_catalog c   WHERE c.industry_id = i.id AND c.is_active = TRUE)
    ) ORDER BY i.display_label_en), '[]'::jsonb)
  ) INTO v_result
  FROM industry i
  WHERE i.is_active = TRUE;

  RETURN v_result;
END $$;

REVOKE EXECUTE ON FUNCTION fn_industry_list() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_industry_list() TO neondb_owner;

COMMENT ON FUNCTION fn_industry_list() IS
  'R-IL Platform Admin — list all active industries with tenant + catalog counts. Gated by platform.catalog.manage.';

-- ── 3. fn_catalog_benchmark_list ─────────────────────────────
-- Lists pricing_benchmark_catalog rows scoped to industry OR tenant. Pass
-- p_industry_id (NULL ok) and/or p_tenant_id (NULL ok); rows are filtered
-- by whichever is non-null. Always returns industry rows when p_industry_id
-- is set; always returns tenant rows when p_tenant_id is set.
CREATE OR REPLACE FUNCTION fn_catalog_benchmark_list(
  p_industry_id BIGINT DEFAULT NULL,
  p_tenant_id   UUID   DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT fn_current_user_has_permission('platform.catalog.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.catalog.manage required' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'data', COALESCE(jsonb_agg(jsonb_build_object(
      'id',               c.id,
      'industryId',       c.industry_id,
      'tenantId',         c.tenant_id,
      'code',             c.code,
      'displayLabelEn',   c.display_label_en,
      'displayLabelAr',   c.display_label_ar,
      'unitLabel',        c.unit_label,
      'volumeUnitLabel',  c.volume_unit_label,
      'typicalLow',       c.typical_low::text,
      'typicalHigh',      c.typical_high::text,
      'kickerText',       c.kicker_text,
      'isFx',             c.is_fx,
      'sortOrder',        c.sort_order,
      'isActive',         c.is_active
    ) ORDER BY c.sort_order, c.code), '[]'::jsonb)
  ) INTO v_result
  FROM pricing_benchmark_catalog c
  WHERE
    (p_industry_id IS NOT NULL AND c.industry_id = p_industry_id)
    OR
    (p_tenant_id IS NOT NULL AND c.tenant_id = p_tenant_id);

  RETURN v_result;
END $$;

REVOKE EXECUTE ON FUNCTION fn_catalog_benchmark_list(BIGINT, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_catalog_benchmark_list(BIGINT, UUID) TO neondb_owner;

COMMENT ON FUNCTION fn_catalog_benchmark_list(BIGINT, UUID) IS
  'R-IL Platform Admin — list pricing_benchmark_catalog rows for one industry OR one tenant. Pass exactly one of p_industry_id / p_tenant_id (or both — they OR).';

-- ── 4. fn_catalog_benchmark_upsert ──────────────────────────
CREATE OR REPLACE FUNCTION fn_catalog_benchmark_upsert(
  p_id                 BIGINT,           -- NULL = create, non-null = update
  p_industry_id        BIGINT,           -- XOR with p_tenant_id
  p_tenant_id          UUID,             -- XOR with p_industry_id
  p_code               TEXT,
  p_display_label_en   TEXT,
  p_display_label_ar   TEXT,
  p_unit_label         TEXT,
  p_volume_unit_label  TEXT,
  p_typical_low        NUMERIC,
  p_typical_high       NUMERIC,
  p_kicker_text        TEXT,
  p_is_fx              BOOLEAN,
  p_sort_order         INTEGER
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.catalog.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.catalog.manage required' USING ERRCODE = '42501';
  END IF;

  -- XOR scope check at fn boundary (defense in depth alongside table CHECK)
  IF (p_industry_id IS NOT NULL)::int + (p_tenant_id IS NOT NULL)::int <> 1 THEN
    RAISE EXCEPTION 'exactly one of industryId / tenantId must be set' USING ERRCODE = '22023';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO pricing_benchmark_catalog (
      industry_id, tenant_id, code, display_label_en, display_label_ar,
      unit_label, volume_unit_label, typical_low, typical_high,
      kicker_text, is_fx, sort_order
    ) VALUES (
      p_industry_id, p_tenant_id, p_code, p_display_label_en, p_display_label_ar,
      p_unit_label, p_volume_unit_label, p_typical_low, p_typical_high,
      p_kicker_text, COALESCE(p_is_fx, FALSE), COALESCE(p_sort_order, 100)
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE pricing_benchmark_catalog
    SET
      display_label_en   = p_display_label_en,
      display_label_ar   = p_display_label_ar,
      unit_label         = p_unit_label,
      volume_unit_label  = p_volume_unit_label,
      typical_low        = p_typical_low,
      typical_high       = p_typical_high,
      kicker_text        = p_kicker_text,
      is_fx              = COALESCE(p_is_fx, is_fx),
      sort_order         = COALESCE(p_sort_order, sort_order),
      updated_at         = NOW()
    WHERE id = p_id
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'pricing_benchmark_catalog row % not found', p_id USING ERRCODE = 'P0002';
    END IF;
  END IF;

  RETURN jsonb_build_object('id', v_id);
END $$;

REVOKE EXECUTE ON FUNCTION fn_catalog_benchmark_upsert(BIGINT, BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TEXT, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_catalog_benchmark_upsert(BIGINT, BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TEXT, BOOLEAN, INTEGER) TO neondb_owner;

COMMENT ON FUNCTION fn_catalog_benchmark_upsert(BIGINT, BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TEXT, BOOLEAN, INTEGER) IS
  'R-IL Platform Admin — create (p_id NULL) or update (p_id set) a pricing_benchmark_catalog row.';

-- ── 5. fn_catalog_benchmark_deactivate ──────────────────────
CREATE OR REPLACE FUNCTION fn_catalog_benchmark_deactivate(p_id BIGINT)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.catalog.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.catalog.manage required' USING ERRCODE = '42501';
  END IF;

  UPDATE pricing_benchmark_catalog
  SET is_active = FALSE, updated_at = NOW()
  WHERE id = p_id
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'pricing_benchmark_catalog row % not found', p_id USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('id', v_id, 'isActive', FALSE);
END $$;

REVOKE EXECUTE ON FUNCTION fn_catalog_benchmark_deactivate(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_catalog_benchmark_deactivate(BIGINT) TO neondb_owner;

-- ── 6. fn_catalog_cost_component_list ───────────────────────
CREATE OR REPLACE FUNCTION fn_catalog_cost_component_list(
  p_industry_id BIGINT DEFAULT NULL,
  p_tenant_id   UUID   DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT fn_current_user_has_permission('platform.catalog.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.catalog.manage required' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'data', COALESCE(jsonb_agg(jsonb_build_object(
      'id',             c.id,
      'industryId',     c.industry_id,
      'tenantId',       c.tenant_id,
      'code',           c.code,
      'displayLabelEn', c.display_label_en,
      'displayLabelAr', c.display_label_ar,
      'sign',           c.sign,
      'isRevenue',      c.is_revenue,
      'sortOrder',      c.sort_order,
      'description',    c.description,
      'isActive',       c.is_active
    ) ORDER BY c.sort_order, c.code), '[]'::jsonb)
  ) INTO v_result
  FROM cost_component_catalog c
  WHERE
    (p_industry_id IS NOT NULL AND c.industry_id = p_industry_id)
    OR
    (p_tenant_id IS NOT NULL AND c.tenant_id = p_tenant_id);

  RETURN v_result;
END $$;

REVOKE EXECUTE ON FUNCTION fn_catalog_cost_component_list(BIGINT, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_catalog_cost_component_list(BIGINT, UUID) TO neondb_owner;

-- ── 7. fn_catalog_cost_component_upsert ─────────────────────
CREATE OR REPLACE FUNCTION fn_catalog_cost_component_upsert(
  p_id                 BIGINT,
  p_industry_id        BIGINT,
  p_tenant_id          UUID,
  p_code               TEXT,
  p_display_label_en   TEXT,
  p_display_label_ar   TEXT,
  p_sign               TEXT,
  p_is_revenue         BOOLEAN,
  p_sort_order         INTEGER,
  p_description        TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.catalog.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.catalog.manage required' USING ERRCODE = '42501';
  END IF;

  IF (p_industry_id IS NOT NULL)::int + (p_tenant_id IS NOT NULL)::int <> 1 THEN
    RAISE EXCEPTION 'exactly one of industryId / tenantId must be set' USING ERRCODE = '22023';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO cost_component_catalog (
      industry_id, tenant_id, code, display_label_en, display_label_ar,
      sign, is_revenue, sort_order, description
    ) VALUES (
      p_industry_id, p_tenant_id, p_code, p_display_label_en, p_display_label_ar,
      p_sign, COALESCE(p_is_revenue, FALSE), COALESCE(p_sort_order, 100), p_description
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE cost_component_catalog
    SET
      display_label_en = p_display_label_en,
      display_label_ar = p_display_label_ar,
      sign             = p_sign,
      is_revenue       = COALESCE(p_is_revenue, is_revenue),
      sort_order       = COALESCE(p_sort_order, sort_order),
      description      = p_description,
      updated_at       = NOW()
    WHERE id = p_id
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'cost_component_catalog row % not found', p_id USING ERRCODE = 'P0002';
    END IF;
  END IF;

  RETURN jsonb_build_object('id', v_id);
END $$;

REVOKE EXECUTE ON FUNCTION fn_catalog_cost_component_upsert(BIGINT, BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INTEGER, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_catalog_cost_component_upsert(BIGINT, BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INTEGER, TEXT) TO neondb_owner;

-- ── 8. fn_catalog_cost_component_deactivate ─────────────────
CREATE OR REPLACE FUNCTION fn_catalog_cost_component_deactivate(p_id BIGINT)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.catalog.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.catalog.manage required' USING ERRCODE = '42501';
  END IF;

  UPDATE cost_component_catalog
  SET is_active = FALSE, updated_at = NOW()
  WHERE id = p_id
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'cost_component_catalog row % not found', p_id USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('id', v_id, 'isActive', FALSE);
END $$;

REVOKE EXECUTE ON FUNCTION fn_catalog_cost_component_deactivate(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_catalog_cost_component_deactivate(BIGINT) TO neondb_owner;

-- ── 9. Record migration ─────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (571, '571_admin_catalog_crud_fns', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_catalog_cost_component_deactivate(BIGINT);
-- DROP FUNCTION IF EXISTS fn_catalog_cost_component_upsert(BIGINT, BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INTEGER, TEXT);
-- DROP FUNCTION IF EXISTS fn_catalog_cost_component_list(BIGINT, UUID);
-- DROP FUNCTION IF EXISTS fn_catalog_benchmark_deactivate(BIGINT);
-- DROP FUNCTION IF EXISTS fn_catalog_benchmark_upsert(BIGINT, BIGINT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, TEXT, BOOLEAN, INTEGER);
-- DROP FUNCTION IF EXISTS fn_catalog_benchmark_list(BIGINT, UUID);
-- DROP FUNCTION IF EXISTS fn_industry_list();
-- DELETE FROM role_permission WHERE permission_id = (SELECT id FROM permission WHERE code = 'platform.catalog.manage');
-- DELETE FROM permission WHERE code = 'platform.catalog.manage';
-- DELETE FROM schema_migrations WHERE version = 571;
-- COMMIT;
-- ============================================================
