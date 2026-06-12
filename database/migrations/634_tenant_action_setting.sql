-- MIGRATION: 634_tenant_action_setting.sql
-- Date: 2026-06-12
-- Module: AI Chat Actions
-- Description:
--   Per-tenant override for the action_registry catalog. When a tenant has
--   no row for a given action, the catalog's enabled_by_default applies.
--   Platform admin toggles via /admin/ai-actions in the FE (mig writes the
--   override row).
--
--   Mirrors the notification_rule_v2 system-default + per-tenant-override
--   pattern (mig 581/582).
--
--   Reads + writes are intentionally gated by application code (only the
--   admin controller, gated by system.config.manage, touches this table)
--   rather than DB policy — the orchestrator service needs to read every
--   tenant's row at runtime when filtering the catalog for the caller.
--   Still, we apply FORCE RLS for defence-in-depth using the session GUC.
--
--   Provides:
--     - tenant_action_setting table
--     - fn_action_registry_for_tenant — returns the catalog joined with
--       the tenant's effective is_enabled (override OR default)
--     - fn_action_set_enabled — UPSERT helper called by the admin controller

BEGIN;

-- 1. Table -------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.tenant_action_setting (
  tenant_id    UUID         NOT NULL REFERENCES public.tenant(id) ON DELETE CASCADE,
  action_code  TEXT         NOT NULL REFERENCES public.action_registry(code) ON DELETE CASCADE,
  is_enabled   BOOLEAN      NOT NULL,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by   BIGINT       REFERENCES public."user"(id) ON DELETE SET NULL,
  updated_by   BIGINT       REFERENCES public."user"(id) ON DELETE SET NULL,
  is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
  PRIMARY KEY (tenant_id, action_code)
);

COMMENT ON TABLE  public.tenant_action_setting IS
  'Per-tenant override of action_registry.enabled_by_default. Sparse — only tenants who have toggled an action have rows here.';
COMMENT ON COLUMN public.tenant_action_setting.is_enabled IS
  'Tenant-specific effective state. When NULL (no row), the catalog default applies.';

CREATE INDEX IF NOT EXISTS idx_tenant_action_setting_tenant
  ON public.tenant_action_setting (tenant_id);

ALTER TABLE public.tenant_action_setting ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_action_setting FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_action_setting_tenant_isolation ON public.tenant_action_setting;
CREATE POLICY tenant_action_setting_tenant_isolation ON public.tenant_action_setting
  FOR ALL USING (
    tenant_id IS NOT DISTINCT FROM NULLIF(current_setting('app.current_tenant_id', true), '')::UUID
  );

-- No audit trigger — composite PK (tenant_id, action_code) means there's
-- no `id` column for fn_audit_trigger's NEW.id reference (see memory
-- feedback_audit_trigger_needs_id_column.md). Changes are sparse (only
-- platform_admin toggles via /admin/ai-actions) and the underlying admin
-- controller already logs each PATCH via Pino. Acceptable trade-off.

-- 2. fn_action_registry_for_tenant -------------------------------------

CREATE OR REPLACE FUNCTION public.fn_action_registry_for_tenant(
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_data JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'code', a.code,
      'kind', a.kind,
      'label', a.label,
      'descriptionForLlm', a.description_for_llm,
      'parametersSchema', a.parameters_schema,
      'requiredPermission', a.required_permission,
      'handlerId', a.handler_id,
      'isDestructive', a.is_destructive,
      'sortOrder', a.sort_order,
      'enabledByDefault', a.enabled_by_default,
      'tenantOverride', s.is_enabled,
      'effectiveEnabled', COALESCE(s.is_enabled, a.enabled_by_default)
    )
    ORDER BY a.sort_order, a.code
  )
  INTO v_data
  FROM public.action_registry a
  LEFT JOIN public.tenant_action_setting s
    ON s.tenant_id = v_tenant_id
   AND s.action_code = a.code
   AND s.is_active = TRUE
  WHERE a.is_active = TRUE;

  RETURN jsonb_build_object('data', COALESCE(v_data, '[]'::jsonb));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_action_registry_for_tenant(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_action_registry_for_tenant(BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_action_registry_for_tenant(BIGINT) IS
  'Returns the system action catalog joined with this tenant''s overrides. effectiveEnabled = COALESCE(tenant override, catalog default).';

-- 3. fn_action_set_enabled ---------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_action_set_enabled(
  p_code      TEXT,
  p_enabled   BOOLEAN,
  p_actor_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  PERFORM 1 FROM public.action_registry WHERE code = p_code AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'code:Action % not found', p_code USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.tenant_action_setting
    (tenant_id, action_code, is_enabled, created_by, updated_by)
  VALUES
    (v_tenant_id, p_code, p_enabled, p_actor_id, p_actor_id)
  ON CONFLICT (tenant_id, action_code) DO UPDATE
    SET is_enabled = EXCLUDED.is_enabled,
        updated_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id,
        is_active  = TRUE;

  RETURN jsonb_build_object(
    'code', p_code,
    'isEnabled', p_enabled,
    'tenantId', v_tenant_id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_action_set_enabled(TEXT, BOOLEAN, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_action_set_enabled(TEXT, BOOLEAN, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_action_set_enabled(TEXT, BOOLEAN, BIGINT) IS
  'Upserts the per-tenant action enabled override. Called by /admin/ai-actions PATCH handler.';

COMMIT;
