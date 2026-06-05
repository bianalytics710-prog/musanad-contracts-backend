-- Migration: 572_tenant_catalog_readers.sql
-- Module: Index-Linked Contracts repositioning (R-IL phase 7 of 7)
-- Date: 2026-06-05
--
-- Goal: tenant-side readers that surface the resolved catalog
-- (industry rows UNION tenant rows, tenant wins on code collision) so
-- the FE module can render labels + units + sort-orders coming from the
-- catalog instead of hard-coded oil-trade strings.
--
-- Resolution rule:
--   FOR a tenant whose industry is X:
--     - Industry rows: catalog row with industry_id = X, is_active.
--     - Tenant rows:   catalog row with tenant_id = current tenant, is_active.
--     - When both exist with the same `code`, the tenant row wins.
--
-- Fn surface:
--   fn_catalog_benchmarks_for_current_tenant()
--   fn_catalog_cost_components_for_current_tenant()
--
-- Permission gate: finance.margin.read (same as the rest of the
-- Index-Linked Contracts module). The resolution itself is correct only
-- when app.current_tenant_id GUC is set — the controller sets it from
-- the JWT before calling.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. fn_catalog_benchmarks_for_current_tenant ─────────────
CREATE OR REPLACE FUNCTION fn_catalog_benchmarks_for_current_tenant()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id   UUID;
  v_industry_id BIGINT;
  v_result      jsonb;
BEGIN
  IF NOT fn_current_user_has_permission('finance.margin.read') THEN
    RAISE EXCEPTION 'forbidden: finance.margin.read required' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;

  SELECT industry_id INTO v_industry_id FROM tenant WHERE id = v_tenant_id;
  -- v_industry_id NULL is fine — caller gets only tenant rows (or empty).

  WITH industry_rows AS (
    SELECT c.* FROM pricing_benchmark_catalog c
    WHERE c.industry_id = v_industry_id AND c.is_active = TRUE
  ),
  tenant_rows AS (
    SELECT c.* FROM pricing_benchmark_catalog c
    WHERE c.tenant_id = v_tenant_id AND c.is_active = TRUE
  ),
  -- Tenant row wins on code collision: prefer tenant_rows, fall back to
  -- industry_rows for codes not in tenant_rows.
  resolved AS (
    SELECT * FROM tenant_rows
    UNION ALL
    SELECT * FROM industry_rows ir
    WHERE NOT EXISTS (SELECT 1 FROM tenant_rows tr WHERE tr.code = ir.code)
  )
  SELECT jsonb_build_object(
    'data', COALESCE(jsonb_agg(jsonb_build_object(
      'id',              r.id,
      'code',            r.code,
      'displayLabelEn',  r.display_label_en,
      'displayLabelAr',  r.display_label_ar,
      'unitLabel',       r.unit_label,
      'volumeUnitLabel', r.volume_unit_label,
      'typicalLow',      r.typical_low::text,
      'typicalHigh',     r.typical_high::text,
      'kickerText',      r.kicker_text,
      'isFx',            r.is_fx,
      'sortOrder',       r.sort_order,
      'scope',           CASE WHEN r.tenant_id IS NOT NULL THEN 'tenant' ELSE 'industry' END
    ) ORDER BY r.sort_order, r.code), '[]'::jsonb)
  ) INTO v_result
  FROM resolved r;

  RETURN v_result;
END $$;

REVOKE EXECUTE ON FUNCTION fn_catalog_benchmarks_for_current_tenant() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_catalog_benchmarks_for_current_tenant() TO neondb_owner;

COMMENT ON FUNCTION fn_catalog_benchmarks_for_current_tenant() IS
  'R-IL — Returns the resolved pricing_benchmark_catalog (industry rows ∪ tenant overrides, tenant wins on code collision) for the current tenant. scope=tenant or scope=industry marks each row''s origin for the FE.';

-- ── 2. fn_catalog_cost_components_for_current_tenant ────────
CREATE OR REPLACE FUNCTION fn_catalog_cost_components_for_current_tenant()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id   UUID;
  v_industry_id BIGINT;
  v_result      jsonb;
BEGIN
  IF NOT fn_current_user_has_permission('finance.margin.read') THEN
    RAISE EXCEPTION 'forbidden: finance.margin.read required' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context missing' USING ERRCODE = '22023';
  END IF;

  SELECT industry_id INTO v_industry_id FROM tenant WHERE id = v_tenant_id;

  WITH industry_rows AS (
    SELECT c.* FROM cost_component_catalog c
    WHERE c.industry_id = v_industry_id AND c.is_active = TRUE
  ),
  tenant_rows AS (
    SELECT c.* FROM cost_component_catalog c
    WHERE c.tenant_id = v_tenant_id AND c.is_active = TRUE
  ),
  resolved AS (
    SELECT * FROM tenant_rows
    UNION ALL
    SELECT * FROM industry_rows ir
    WHERE NOT EXISTS (SELECT 1 FROM tenant_rows tr WHERE tr.code = ir.code)
  )
  SELECT jsonb_build_object(
    'data', COALESCE(jsonb_agg(jsonb_build_object(
      'id',             r.id,
      'code',           r.code,
      'displayLabelEn', r.display_label_en,
      'displayLabelAr', r.display_label_ar,
      'sign',           r.sign,
      'isRevenue',      r.is_revenue,
      'sortOrder',      r.sort_order,
      'description',    r.description,
      'scope',          CASE WHEN r.tenant_id IS NOT NULL THEN 'tenant' ELSE 'industry' END
    ) ORDER BY r.sort_order, r.code), '[]'::jsonb)
  ) INTO v_result
  FROM resolved r;

  RETURN v_result;
END $$;

REVOKE EXECUTE ON FUNCTION fn_catalog_cost_components_for_current_tenant() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_catalog_cost_components_for_current_tenant() TO neondb_owner;

COMMENT ON FUNCTION fn_catalog_cost_components_for_current_tenant() IS
  'R-IL — Returns the resolved cost_component_catalog (industry rows ∪ tenant overrides, tenant wins on code collision) for the current tenant.';

-- ── 3. Record migration ─────────────────────────────────────
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (572, '572_tenant_catalog_readers', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_catalog_cost_components_for_current_tenant();
-- DROP FUNCTION IF EXISTS fn_catalog_benchmarks_for_current_tenant();
-- DELETE FROM schema_migrations WHERE version = 572;
-- COMMIT;
-- ============================================================
