-- Migration: 578_internal_system_fns.sql
-- Module: Internal Systems integrations registry (Platform Admin, feature A)
-- Date: 2026-06-05
--
-- Goal: CRUD fns + permission + role grants + sample ADNOC seed rows for
-- the registry table introduced by mig 577.
--
-- Fn surface:
--   fn_internal_system_list(p_kind, p_status, p_search)
--   fn_internal_system_get(p_id)
--   fn_internal_system_upsert(p_id, p_system_code, p_display_name, ...)
--   fn_internal_system_deactivate(p_id)
--   fn_internal_system_set_health(p_id, p_status, p_error)
--
-- All fns SECURITY DEFINER, in-body permission check on
-- platform.integrations.manage (new permission seeded here).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ── 1. Seed permission + role grants ─────────────────────────
INSERT INTO permission (code, module, action, description)
VALUES (
  'platform.integrations.manage', 'platform', 'integrations.manage',
  'Manage the registry of internal-system integrations (ERP, Finance, HRMS, CRM, etc.). Platform Admin + Super Admin only.'
)
ON CONFLICT (code) DO NOTHING;

INSERT INTO role_permission (role_id, permission_id, created_at)
SELECT r.id, p.id, NOW()
  FROM role r, permission p
 WHERE p.code = 'platform.integrations.manage'
   AND r.name IN ('platform_admin','Super Admin')
ON CONFLICT DO NOTHING;

-- ── 2. fn_internal_system_list ───────────────────────────────
CREATE OR REPLACE FUNCTION fn_internal_system_list(
  p_kind   TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_search TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant UUID := current_setting('app.current_tenant_id', true)::uuid;
  v_data   JSONB;
  v_total  BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.integrations.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.integrations.manage required' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(row ORDER BY row->>'displayName'), '[]'::jsonb), COUNT(*)
    INTO v_data, v_total
    FROM (
      SELECT jsonb_build_object(
        'id',                 s.id,
        'systemCode',         s.system_code,
        'displayName',        s.display_name,
        'displayNameAr',      s.display_name_ar,
        'kind',               s.kind,
        'vendor',             s.vendor,
        'baseUrl',            s.base_url,
        'apiEndpoint',        s.api_endpoint,
        'authMethod',         s.auth_method,
        'pullScheduleCron',   s.pull_schedule_cron,
        'lastPullAt',         s.last_pull_at,
        'lastStatus',         s.last_status,
        'lastStatusAt',       s.last_status_at,
        'lastError',          s.last_error,
        'notes',              s.notes,
        'dataClassification', s.data_classification,
        'isActive',           s.is_active,
        'createdAt',          s.created_at,
        'updatedAt',          s.updated_at
      ) AS row
      FROM internal_system_source s
      WHERE s.tenant_id = v_tenant
        AND s.is_active = TRUE
        AND (p_kind IS NULL OR s.kind = p_kind)
        AND (p_status IS NULL OR s.last_status = p_status)
        AND (p_search IS NULL OR
             s.display_name ILIKE '%' || p_search || '%' OR
             s.system_code  ILIKE '%' || p_search || '%' OR
             COALESCE(s.vendor, '') ILIKE '%' || p_search || '%')
    ) sub;

  RETURN jsonb_build_object('data', v_data, 'total', v_total);
END $$;

REVOKE ALL ON FUNCTION fn_internal_system_list(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_internal_system_list(TEXT, TEXT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_internal_system_list(TEXT, TEXT, TEXT) IS
  'List internal-system rows for the current tenant with optional kind / status / search filters. Permission: platform.integrations.manage.';

-- ── 3. fn_internal_system_get ────────────────────────────────
CREATE OR REPLACE FUNCTION fn_internal_system_get(p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant UUID := current_setting('app.current_tenant_id', true)::uuid;
  v_row    JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('platform.integrations.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.integrations.manage required' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',                 s.id,
    'systemCode',         s.system_code,
    'displayName',        s.display_name,
    'displayNameAr',      s.display_name_ar,
    'kind',               s.kind,
    'vendor',             s.vendor,
    'baseUrl',            s.base_url,
    'apiEndpoint',        s.api_endpoint,
    'authMethod',         s.auth_method,
    'pullScheduleCron',   s.pull_schedule_cron,
    'lastPullAt',         s.last_pull_at,
    'lastStatus',         s.last_status,
    'lastStatusAt',       s.last_status_at,
    'lastError',          s.last_error,
    'notes',              s.notes,
    'dataClassification', s.data_classification,
    'isActive',           s.is_active,
    'createdAt',          s.created_at,
    'updatedAt',          s.updated_at
  ) INTO v_row
  FROM internal_system_source s
  WHERE s.id = p_id AND s.tenant_id = v_tenant AND s.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'internal_system % not found', p_id USING ERRCODE = 'P0002';
  END IF;

  RETURN v_row;
END $$;

REVOKE ALL ON FUNCTION fn_internal_system_get(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_internal_system_get(BIGINT) TO neondb_owner;

-- ── 4. fn_internal_system_upsert ─────────────────────────────
CREATE OR REPLACE FUNCTION fn_internal_system_upsert(
  p_actor_id          BIGINT,
  p_id                BIGINT,         -- NULL = create
  p_system_code       TEXT,
  p_display_name      TEXT,
  p_display_name_ar   TEXT,
  p_kind              TEXT,
  p_vendor            TEXT,
  p_base_url          TEXT,
  p_api_endpoint      TEXT,
  p_auth_method       TEXT,
  p_pull_schedule_cron TEXT,
  p_notes             TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant UUID := current_setting('app.current_tenant_id', true)::uuid;
  v_id     BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.integrations.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.integrations.manage required' USING ERRCODE = '42501';
  END IF;

  -- Light input validation. CHECK constraints on the table itself enforce
  -- the rest (kind, auth_method enums).
  IF p_system_code IS NULL OR LENGTH(TRIM(p_system_code)) = 0 THEN
    RAISE EXCEPTION 'systemCode is required' USING ERRCODE = '22023';
  END IF;
  IF p_system_code !~ '^[a-z][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'systemCode must be lowercase, alphanumeric with underscores (start with a letter)' USING ERRCODE = '22023';
  END IF;
  IF p_display_name IS NULL OR LENGTH(TRIM(p_display_name)) = 0 THEN
    RAISE EXCEPTION 'displayName is required' USING ERRCODE = '22023';
  END IF;
  IF p_kind IS NULL OR LENGTH(TRIM(p_kind)) = 0 THEN
    RAISE EXCEPTION 'kind is required' USING ERRCODE = '22023';
  END IF;

  IF p_id IS NULL THEN
    BEGIN
      INSERT INTO internal_system_source (
        tenant_id, system_code, display_name, display_name_ar, kind, vendor,
        base_url, api_endpoint, auth_method, pull_schedule_cron, notes,
        created_by, updated_by
      ) VALUES (
        v_tenant, LOWER(TRIM(p_system_code)), TRIM(p_display_name),
        NULLIF(TRIM(COALESCE(p_display_name_ar, '')), ''),
        p_kind, NULLIF(TRIM(COALESCE(p_vendor, '')), ''),
        NULLIF(TRIM(COALESCE(p_base_url, '')), ''),
        NULLIF(TRIM(COALESCE(p_api_endpoint, '')), ''),
        COALESCE(p_auth_method, 'none'),
        NULLIF(TRIM(COALESCE(p_pull_schedule_cron, '')), ''),
        NULLIF(TRIM(COALESCE(p_notes, '')), ''),
        p_actor_id, p_actor_id
      )
      RETURNING id INTO v_id;
    EXCEPTION
      WHEN unique_violation THEN
        RAISE EXCEPTION 'systemCode already exists for this tenant' USING ERRCODE = '23505';
    END;
  ELSE
    UPDATE internal_system_source
    SET display_name        = TRIM(p_display_name),
        display_name_ar     = NULLIF(TRIM(COALESCE(p_display_name_ar, '')), ''),
        kind                = p_kind,
        vendor              = NULLIF(TRIM(COALESCE(p_vendor, '')), ''),
        base_url            = NULLIF(TRIM(COALESCE(p_base_url, '')), ''),
        api_endpoint        = NULLIF(TRIM(COALESCE(p_api_endpoint, '')), ''),
        auth_method         = COALESCE(p_auth_method, auth_method),
        pull_schedule_cron  = NULLIF(TRIM(COALESCE(p_pull_schedule_cron, '')), ''),
        notes               = NULLIF(TRIM(COALESCE(p_notes, '')), ''),
        updated_at          = NOW(),
        updated_by          = p_actor_id
    WHERE id = p_id AND tenant_id = v_tenant AND is_active = TRUE
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'internal_system % not found', p_id USING ERRCODE = 'P0002';
    END IF;
  END IF;

  RETURN fn_internal_system_get(v_id);
END $$;

REVOKE ALL ON FUNCTION fn_internal_system_upsert(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_internal_system_upsert(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO neondb_owner;

-- ── 5. fn_internal_system_deactivate ─────────────────────────
CREATE OR REPLACE FUNCTION fn_internal_system_deactivate(p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant UUID := current_setting('app.current_tenant_id', true)::uuid;
  v_id     BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.integrations.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.integrations.manage required' USING ERRCODE = '42501';
  END IF;

  UPDATE internal_system_source
  SET is_active = FALSE, updated_at = NOW()
  WHERE id = p_id AND tenant_id = v_tenant AND is_active = TRUE
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'internal_system % not found', p_id USING ERRCODE = 'P0002';
  END IF;

  -- Cascade-deactivate credentials so they don't dangle.
  UPDATE internal_system_credential
  SET is_active = FALSE, updated_at = NOW()
  WHERE internal_system_id = p_id AND is_active = TRUE;

  RETURN jsonb_build_object('id', v_id, 'isActive', FALSE);
END $$;

REVOKE ALL ON FUNCTION fn_internal_system_deactivate(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_internal_system_deactivate(BIGINT) TO neondb_owner;

-- ── 6. fn_internal_system_set_health ─────────────────────────
-- Called by the BE test-connection endpoint. Updates last_status +
-- last_status_at + last_error in one shot.
CREATE OR REPLACE FUNCTION fn_internal_system_set_health(
  p_actor_id BIGINT,
  p_id       BIGINT,
  p_status   TEXT,
  p_error    TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant UUID := current_setting('app.current_tenant_id', true)::uuid;
  v_id     BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('platform.integrations.manage') THEN
    RAISE EXCEPTION 'forbidden: platform.integrations.manage required' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('untested','healthy','degraded','failing','unauthorised') THEN
    RAISE EXCEPTION 'invalid status %', p_status USING ERRCODE = '22023';
  END IF;

  UPDATE internal_system_source
  SET last_status     = p_status,
      last_status_at  = NOW(),
      last_error      = NULLIF(TRIM(COALESCE(p_error, '')), ''),
      updated_at      = NOW(),
      updated_by      = p_actor_id
  WHERE id = p_id AND tenant_id = v_tenant AND is_active = TRUE
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'internal_system % not found', p_id USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('id', v_id, 'lastStatus', p_status);
END $$;

REVOKE ALL ON FUNCTION fn_internal_system_set_health(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_internal_system_set_health(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

-- ── 7. Sample ADNOC seed rows ────────────────────────────────
-- Pre-populate with realistic-looking systems so the page isn't empty on
-- first load. All untested + last_status='untested' so the admin sees a
-- meaningful starting state.
INSERT INTO internal_system_source (
  tenant_id, system_code, display_name, kind, vendor,
  base_url, auth_method, last_status, notes, data_classification
)
VALUES
  ('00000000-0000-0000-0000-000000000001'::uuid, 'sap_s4_finance',
   'SAP S/4HANA Finance', 'finance', 'sap_s4',
   'https://s4hana-finance.adnoc.ae', 'oauth2', 'untested',
   'GL + AP + AR. Owner: CFO Office. POC: Khalid (CFO Operations).', 'demo'),
  ('00000000-0000-0000-0000-000000000001'::uuid, 'sap_ariba_procurement',
   'SAP Ariba — Procurement', 'erp', 'sap_ariba',
   'https://procurement.adnoc.ae/ariba', 'oauth2', 'untested',
   'Supplier qualification, POs, contracts. Owner: SCM. POC: Ahmed.', 'demo'),
  ('00000000-0000-0000-0000-000000000001'::uuid, 'workday_hcm',
   'Workday HCM', 'hrms', 'workday',
   'https://impl-cc.workday.com/adnoc', 'oauth2', 'untested',
   'Headcount + reporting structure. Owner: HR.', 'demo'),
  ('00000000-0000-0000-0000-000000000001'::uuid, 'salesforce_sales',
   'Salesforce — Sales Cloud', 'crm', 'salesforce',
   'https://adnoc.my.salesforce.com', 'oauth2', 'untested',
   'Customer master + opportunity pipeline.', 'demo'),
  ('00000000-0000-0000-0000-000000000001'::uuid, 'servicenow_itsm',
   'ServiceNow ITSM', 'itsm', 'servicenow',
   'https://adnoc.service-now.com', 'oauth2', 'untested',
   'Incident + change. Used for SLA breach signals.', 'demo'),
  ('00000000-0000-0000-0000-000000000001'::uuid, 'primavera_p6',
   'Oracle Primavera P6', 'scm', 'oracle_primavera',
   'https://p6.adnoc.ae', 'basic', 'untested',
   'Capital project schedules — drives milestone slippage detection.', 'demo')
ON CONFLICT (tenant_id, system_code) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (578, '578_internal_system_fns', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_internal_system_set_health(BIGINT, BIGINT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_internal_system_deactivate(BIGINT);
-- DROP FUNCTION IF EXISTS fn_internal_system_upsert(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_internal_system_get(BIGINT);
-- DROP FUNCTION IF EXISTS fn_internal_system_list(TEXT, TEXT, TEXT);
-- DELETE FROM role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code='platform.integrations.manage');
-- DELETE FROM permission WHERE code = 'platform.integrations.manage';
-- DELETE FROM schema_migrations WHERE version = 578;
-- COMMIT;
-- ============================================================
