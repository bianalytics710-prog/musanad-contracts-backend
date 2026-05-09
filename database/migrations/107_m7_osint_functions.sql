-- Migration: 107_m7_osint_functions.sql
-- Module: M7 — OSINT Source Framework + Adapter Protocol (CR-A)
-- Description: All CR-A fn_'s except fn_tenant_get_current (created in 101 alongside its table).
--              11 fn_'s: 6 osint_source CRUD + read, 1 source_credential write, 2 osint_signal
--              (DEFINER upsert + INVOKER list), 2 source_health (DEFINER record + INVOKER list),
--              1 osint_source_test_pull.
--              Every fn_ ends with the grant-trio tail block (COMMENT + REVOKE FROM PUBLIC +
--              GRANT TO neondb_owner) per S2-21 + S2-27 + B14. Two DEFINER fn_'s
--              (fn_osint_signal_upsert + fn_source_health_record) get NO role grant — only
--              neondb_owner via OWNER privilege; AC-S7-05 invariant.
-- Rollback: DROP FUNCTION ... CASCADE for each (11 statements).
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- 1. fn_osint_source_create — INVOKER, source.manage
-- ============================================================
CREATE OR REPLACE FUNCTION fn_osint_source_create(
  p_actor_id BIGINT,
  p_data     JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_id        BIGINT;
  v_kind      TEXT;
  v_format    TEXT;
  v_refresh   INTEGER;
  v_rel       NUMERIC;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- 2. Permission gate
  IF NOT fn_current_user_has_permission('source.manage') THEN
    RAISE EXCEPTION 'forbidden: source.manage required' USING ERRCODE = '42501';
  END IF;

  -- 3. Required-field validation
  IF p_data->>'sourceId' IS NULL OR length(trim(p_data->>'sourceId')) = 0 THEN
    RAISE EXCEPTION 'sourceId is required' USING ERRCODE = '22023';
  END IF;
  IF p_data->>'displayName' IS NULL OR length(trim(p_data->>'displayName')) = 0 THEN
    RAISE EXCEPTION 'displayName is required' USING ERRCODE = '22023';
  END IF;
  IF p_data->>'kind' IS NULL THEN
    RAISE EXCEPTION 'kind is required' USING ERRCODE = '22023';
  END IF;
  IF p_data->>'format' IS NULL THEN
    RAISE EXCEPTION 'format is required' USING ERRCODE = '22023';
  END IF;
  IF p_data->>'refreshSeconds' IS NULL THEN
    RAISE EXCEPTION 'refreshSeconds is required' USING ERRCODE = '22023';
  END IF;
  IF p_data->>'sourceReliability' IS NULL THEN
    RAISE EXCEPTION 'sourceReliability is required' USING ERRCODE = '22023';
  END IF;

  -- 4. Enum + range validation (defence-in-depth before CHECK constraints fire)
  v_kind   := p_data->>'kind';
  v_format := p_data->>'format';
  v_refresh := (p_data->>'refreshSeconds')::int;
  v_rel    := (p_data->>'sourceReliability')::numeric;

  IF v_kind NOT IN ('sanctions','news','weather','commodity','fx','social','regulatory','internal') THEN
    RAISE EXCEPTION 'kind must be one of sanctions/news/weather/commodity/fx/social/regulatory/internal'
      USING ERRCODE = '22023';
  END IF;
  IF v_format NOT IN ('xml','csv','json','rss','api') THEN
    RAISE EXCEPTION 'format must be one of xml/csv/json/rss/api' USING ERRCODE = '22023';
  END IF;
  IF v_refresh < 60 THEN
    RAISE EXCEPTION 'refreshSeconds must be >= 60' USING ERRCODE = '22023';
  END IF;
  IF v_rel < 0 OR v_rel > 1 THEN
    RAISE EXCEPTION 'sourceReliability must be between 0 and 1' USING ERRCODE = '22023';
  END IF;

  -- 5. INSERT
  BEGIN
    INSERT INTO osint_source (
      tenant_id, source_id, display_name, display_name_ar,
      kind, url, format, refresh_seconds, source_reliability, enabled,
      rate_limit, severity_mapping, geography_filter, licensing_note,
      metadata, data_classification, created_by, updated_by
    ) VALUES (
      v_tenant_id,
      p_data->>'sourceId',
      p_data->>'displayName',
      p_data->>'displayNameAr',
      v_kind,
      p_data->>'url',
      v_format,
      v_refresh,
      v_rel,
      COALESCE((p_data->>'enabled')::boolean, TRUE),
      p_data->'rateLimit',
      p_data->'severityMapping',
      p_data->'geographyFilter',
      p_data->>'licensingNote',
      COALESCE(p_data->'metadata', '{}'::jsonb),
      COALESCE(p_data->>'dataClassification', 'demo'),
      p_actor_id,
      p_actor_id
    )
    RETURNING id INTO v_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'Source ID already exists for this tenant' USING ERRCODE = '23505';
  END;

  -- 6. Return via get_by_id
  RETURN fn_osint_source_get_by_id(p_actor_id, v_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_osint_source_create: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_osint_source_create(BIGINT, JSONB) IS
  'M7 — creates a new OSINT source registry row for the current tenant. Validates kind/format/refreshSeconds/sourceReliability; tenant from app.current_tenant_id GUC. Permission: source.manage.';
REVOKE EXECUTE ON FUNCTION fn_osint_source_create(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_osint_source_create(BIGINT, JSONB) TO neondb_owner;

-- ============================================================
-- 2. fn_osint_source_get_by_id — INVOKER STABLE, source.read
-- (defined BEFORE fn_osint_source_create's body uses it because we use
--  CREATE OR REPLACE — ordering inside one transaction is fine, but to be
--  safe, get_by_id is defined now.)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_osint_source_get_by_id(
  p_actor_id BIGINT,
  p_id       BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_row       JSONB;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF NOT fn_current_user_has_permission('source.read') THEN
    RAISE EXCEPTION 'forbidden: source.read required' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',                 s.id,
    'tenantId',           s.tenant_id,
    'sourceId',           s.source_id,
    'displayName',        s.display_name,
    'displayNameAr',      s.display_name_ar,
    'kind',               s.kind,
    'url',                s.url,
    'format',             s.format,
    'refreshSeconds',     s.refresh_seconds,
    'sourceReliability',  s.source_reliability,
    'enabled',            s.enabled,
    'rateLimit',          s.rate_limit,
    'severityMapping',    s.severity_mapping,
    'geographyFilter',    s.geography_filter,
    'licensingNote',      s.licensing_note,
    'metadata',           s.metadata,
    'dataClassification', s.data_classification,
    'createdAt',          s.created_at,
    'updatedAt',          s.updated_at,
    'health', (
      SELECT jsonb_build_object(
        'state',            sh.state,
        'lastSuccessAt',    sh.last_success_at,
        'lastFailureAt',    sh.last_failure_at,
        'signals24h',       sh.signals_24h,
        'lastErrorMessage', sh.last_error_message,
        'checkedAt',        sh.checked_at
      )
      FROM source_health sh
      WHERE sh.osint_source_id = s.id AND sh.tenant_id = s.tenant_id
    ),
    'credential', (
      SELECT jsonb_build_object(
        'kind',          c.credential_kind,
        'lastRotatedAt', c.last_rotated_at
      )
      -- credential_ref intentionally NOT projected (AC-S3-04 invariant).
      FROM source_credential c
      WHERE c.osint_source_id = s.id
        AND c.tenant_id = s.tenant_id
        AND c.is_active = TRUE
    )
  ) INTO v_row
  FROM osint_source s
  WHERE s.id = p_id AND s.tenant_id = v_tenant_id AND s.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'Source not found' USING ERRCODE = '22023';
  END IF;

  RETURN v_row;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_osint_source_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_osint_source_get_by_id(BIGINT, BIGINT) IS
  'M7 — single source detail with health badge + credential metadata (kind + lastRotatedAt only; credentialRef NEVER projected per AC-S3-04). Permission: source.read.';
REVOKE EXECUTE ON FUNCTION fn_osint_source_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_osint_source_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- 3. fn_osint_source_update — INVOKER, source.manage
-- ============================================================
CREATE OR REPLACE FUNCTION fn_osint_source_update(
  p_actor_id BIGINT,
  p_id       BIGINT,
  p_data     JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_kind      TEXT;
  v_format    TEXT;
  v_refresh   INTEGER;
  v_rel       NUMERIC;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF NOT fn_current_user_has_permission('source.manage') THEN
    RAISE EXCEPTION 'forbidden: source.manage required' USING ERRCODE = '42501';
  END IF;

  -- S2-23 FK pre-validation
  IF NOT EXISTS (
    SELECT 1 FROM osint_source
    WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Source not found' USING ERRCODE = '22023';
  END IF;

  -- sourceId is immutable
  IF p_data ? 'sourceId' THEN
    RAISE EXCEPTION 'sourceId is immutable' USING ERRCODE = '22023';
  END IF;

  -- Re-validate optional fields if present
  IF p_data ? 'kind' THEN
    v_kind := p_data->>'kind';
    IF v_kind NOT IN ('sanctions','news','weather','commodity','fx','social','regulatory','internal') THEN
      RAISE EXCEPTION 'kind must be one of sanctions/news/weather/commodity/fx/social/regulatory/internal'
        USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_data ? 'format' THEN
    v_format := p_data->>'format';
    IF v_format NOT IN ('xml','csv','json','rss','api') THEN
      RAISE EXCEPTION 'format must be one of xml/csv/json/rss/api' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_data ? 'refreshSeconds' THEN
    v_refresh := (p_data->>'refreshSeconds')::int;
    IF v_refresh < 60 THEN
      RAISE EXCEPTION 'refreshSeconds must be >= 60' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_data ? 'sourceReliability' THEN
    v_rel := (p_data->>'sourceReliability')::numeric;
    IF v_rel < 0 OR v_rel > 1 THEN
      RAISE EXCEPTION 'sourceReliability must be between 0 and 1' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Partial UPDATE
  UPDATE osint_source SET
    display_name        = COALESCE(p_data->>'displayName',         display_name),
    display_name_ar     = COALESCE(p_data->>'displayNameAr',       display_name_ar),
    kind                = COALESCE(p_data->>'kind',                kind),
    url                 = COALESCE(p_data->>'url',                 url),
    format              = COALESCE(p_data->>'format',              format),
    refresh_seconds     = COALESCE((p_data->>'refreshSeconds')::int, refresh_seconds),
    source_reliability  = COALESCE((p_data->>'sourceReliability')::numeric, source_reliability),
    enabled             = COALESCE((p_data->>'enabled')::boolean,  enabled),
    rate_limit          = COALESCE(p_data->'rateLimit',            rate_limit),
    severity_mapping    = COALESCE(p_data->'severityMapping',      severity_mapping),
    geography_filter    = COALESCE(p_data->'geographyFilter',      geography_filter),
    licensing_note      = COALESCE(p_data->>'licensingNote',       licensing_note),
    metadata            = COALESCE(p_data->'metadata',             metadata),
    data_classification = COALESCE(p_data->>'dataClassification',  data_classification),
    updated_at          = now(),
    updated_by          = p_actor_id
  WHERE id = p_id AND tenant_id = v_tenant_id;

  RETURN fn_osint_source_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_osint_source_update: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_osint_source_update(BIGINT, BIGINT, JSONB) IS
  'M7 — partial update of an osint_source row. sourceId is immutable. Permission: source.manage.';
REVOKE EXECUTE ON FUNCTION fn_osint_source_update(BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_osint_source_update(BIGINT, BIGINT, JSONB) TO neondb_owner;

-- ============================================================
-- 4. fn_osint_source_delete — INVOKER, source.manage (soft-delete)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_osint_source_delete(
  p_actor_id BIGINT,
  p_id       BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF NOT fn_current_user_has_permission('source.manage') THEN
    RAISE EXCEPTION 'forbidden: source.manage required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM osint_source
    WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Source not found' USING ERRCODE = '22023';
  END IF;

  UPDATE osint_source
    SET is_active = FALSE, enabled = FALSE,
        updated_at = now(), updated_by = p_actor_id
    WHERE id = p_id AND tenant_id = v_tenant_id;

  RETURN jsonb_build_object(
    'id',          p_id,
    'deactivated', TRUE,
    'message',     'Source deactivated. Existing signals remain queryable.'
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_osint_source_delete: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_osint_source_delete(BIGINT, BIGINT) IS
  'M7 — soft-deletes an osint_source (is_active=false AND enabled=false). Annex B.7.3 decommissioning. Permission: source.manage.';
REVOKE EXECUTE ON FUNCTION fn_osint_source_delete(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_osint_source_delete(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- 5. fn_osint_source_list — INVOKER STABLE, source.read
-- ============================================================
CREATE OR REPLACE FUNCTION fn_osint_source_list(
  p_actor_id BIGINT,
  p_filter   JSONB,
  p_page     INTEGER,
  p_limit    INTEGER
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_page      INTEGER;
  v_limit     INTEGER;
  v_offset    INTEGER;
  v_kind      TEXT;
  v_state     TEXT;
  v_search    TEXT;
  v_total     INTEGER;
  v_rows      JSONB;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF NOT fn_current_user_has_permission('source.read') THEN
    RAISE EXCEPTION 'forbidden: source.read required' USING ERRCODE = '42501';
  END IF;

  v_page  := COALESCE(p_page, 1);
  v_limit := LEAST(COALESCE(p_limit, 20), 100);
  v_offset := (v_page - 1) * v_limit;

  v_kind   := p_filter->>'kind';
  v_state  := p_filter->>'state';
  v_search := p_filter->>'search';

  -- COUNT total (LEFT JOIN to source_health for state filter)
  SELECT COUNT(*) INTO v_total
  FROM osint_source s
  LEFT JOIN source_health sh
    ON sh.osint_source_id = s.id AND sh.tenant_id = s.tenant_id
  WHERE s.tenant_id = v_tenant_id
    AND s.is_active = TRUE
    AND (v_kind   IS NULL OR s.kind = v_kind)
    AND (v_state  IS NULL OR sh.state = v_state)
    AND (v_search IS NULL
         OR s.source_id    ILIKE '%' || v_search || '%'
         OR s.display_name ILIKE '%' || v_search || '%');

  -- Page rows — flat subquery + LEFT JOIN, then jsonb_agg in outer SELECT.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                 q.id,
    'tenantId',           q.tenant_id,
    'sourceId',           q.source_id,
    'displayName',        q.display_name,
    'displayNameAr',      q.display_name_ar,
    'kind',               q.kind,
    'url',                q.url,
    'format',             q.format,
    'refreshSeconds',     q.refresh_seconds,
    'sourceReliability',  q.source_reliability,
    'enabled',            q.enabled,
    'rateLimit',          q.rate_limit,
    'severityMapping',    q.severity_mapping,
    'geographyFilter',    q.geography_filter,
    'licensingNote',      q.licensing_note,
    'metadata',           q.metadata,
    'dataClassification', q.data_classification,
    'createdAt',          q.created_at,
    'updatedAt',          q.updated_at,
    'health', CASE
      WHEN q.health_state IS NOT NULL THEN
        jsonb_build_object(
          'state',            q.health_state,
          'lastSuccessAt',    q.health_last_success_at,
          'lastFailureAt',    q.health_last_failure_at,
          'signals24h',       q.health_signals_24h,
          'lastErrorMessage', q.health_last_error_message,
          'checkedAt',        q.health_checked_at
        )
      ELSE NULL
    END
  ) ORDER BY q.display_name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT s.*,
           sh.state              AS health_state,
           sh.last_success_at    AS health_last_success_at,
           sh.last_failure_at    AS health_last_failure_at,
           sh.signals_24h        AS health_signals_24h,
           sh.last_error_message AS health_last_error_message,
           sh.checked_at         AS health_checked_at
    FROM osint_source s
    LEFT JOIN source_health sh
      ON sh.osint_source_id = s.id AND sh.tenant_id = s.tenant_id
    WHERE s.tenant_id = v_tenant_id
      AND s.is_active = TRUE
      AND (v_kind   IS NULL OR s.kind = v_kind)
      AND (v_state  IS NULL OR sh.state = v_state)
      AND (v_search IS NULL
           OR s.source_id    ILIKE '%' || v_search || '%'
           OR s.display_name ILIKE '%' || v_search || '%')
    ORDER BY s.display_name
    LIMIT v_limit OFFSET v_offset
  ) q;

  RETURN jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', CASE WHEN v_limit = 0 THEN 0 ELSE CEIL(v_total::numeric / v_limit)::int END
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_osint_source_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_osint_source_list(BIGINT, JSONB, INTEGER, INTEGER) IS
  'M7 — paginated source list with health badge. Filterable by kind/state/search. Permission: source.read.';
REVOKE EXECUTE ON FUNCTION fn_osint_source_list(BIGINT, JSONB, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_osint_source_list(BIGINT, JSONB, INTEGER, INTEGER) TO neondb_owner;

-- ============================================================
-- 6. fn_source_credential_set — DEFINER, source.manage gate
-- ============================================================
CREATE OR REPLACE FUNCTION fn_source_credential_set(
  p_actor_id        BIGINT,
  p_osint_source_id BIGINT,
  p_credential_kind TEXT,
  p_credential_ref  TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_id        BIGINT;
  v_kind      TEXT;
  v_rotated   TIMESTAMPTZ;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- DEFINER carve-out: defence-in-depth permission check
  IF NOT fn_current_user_has_permission('source.manage') THEN
    RAISE EXCEPTION 'forbidden: source.manage required' USING ERRCODE = '42501';
  END IF;

  -- S2-23 FK pre-validation
  IF NOT EXISTS (
    SELECT 1 FROM osint_source
    WHERE id = p_osint_source_id
      AND tenant_id = v_tenant_id
      AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'osint_source_id not found' USING ERRCODE = '23503';
  END IF;

  -- credential_kind enum validation
  IF p_credential_kind NOT IN ('api_key','oauth_token','basic_auth','none') THEN
    RAISE EXCEPTION 'credentialKind must be one of api_key/oauth_token/basic_auth/none'
      USING ERRCODE = '22023';
  END IF;

  -- credential_ref validation
  IF p_credential_ref IS NULL OR length(trim(p_credential_ref)) < 3 THEN
    RAISE EXCEPTION 'credentialRef must be at least 3 chars' USING ERRCODE = '22023';
  END IF;
  IF p_credential_ref !~ '^(env:|vault:)' THEN
    RAISE EXCEPTION 'credentialRef must use env: or vault: scheme' USING ERRCODE = '22023';
  END IF;
  -- Heuristic plain-text reject
  IF p_credential_ref ~ '^[A-Za-z0-9_]{20,}$' AND p_credential_ref NOT LIKE 'env:%' THEN
    RAISE EXCEPTION 'credentialRef appears to be a plain-text secret' USING ERRCODE = '22023';
  END IF;

  -- Upsert
  INSERT INTO source_credential (
    tenant_id, osint_source_id, credential_kind, credential_ref,
    last_rotated_at, created_by, updated_by
  )
  VALUES (
    v_tenant_id, p_osint_source_id, p_credential_kind, p_credential_ref,
    now(), p_actor_id, p_actor_id
  )
  ON CONFLICT (tenant_id, osint_source_id) DO UPDATE
  SET credential_kind  = EXCLUDED.credential_kind,
      credential_ref   = EXCLUDED.credential_ref,
      last_rotated_at  = now(),
      updated_at       = now(),
      updated_by       = p_actor_id,
      is_active        = TRUE
  RETURNING id, credential_kind, last_rotated_at INTO v_id, v_kind, v_rotated;

  -- credentialRef NEVER returned in response.
  RETURN jsonb_build_object(
    'id',             v_id,
    'credentialKind', v_kind,
    'lastRotatedAt',  v_rotated
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_source_credential_set: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_source_credential_set(BIGINT, BIGINT, TEXT, TEXT) IS
  'M7 — DEFINER. Upserts credential indirection (env:VARNAME or vault:path). credentialRef never returned in response; redacted in audit_log + Pino logs. Permission: source.manage (enforced inside body).';
REVOKE EXECUTE ON FUNCTION fn_source_credential_set(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_source_credential_set(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

-- ============================================================
-- 7. fn_osint_signal_upsert — DEFINER SYSTEM-ONLY, NO role grant
-- ============================================================
CREATE OR REPLACE FUNCTION fn_osint_signal_upsert(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id        UUID;
  v_osint_source_id  BIGINT;
  v_actor            BIGINT;
  v_id               BIGINT;
  v_inserted         BOOLEAN;
  v_kind             TEXT;
  v_severity         TEXT;
BEGIN
  -- 1. Tenant context
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- 2. Required-field check
  IF p_payload->>'sourceId' IS NULL THEN
    RAISE EXCEPTION 'sourceId is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'sourceReliability' IS NULL THEN
    RAISE EXCEPTION 'sourceReliability is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'fetchedAt' IS NULL THEN
    RAISE EXCEPTION 'fetchedAt is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'kind' IS NULL THEN
    RAISE EXCEPTION 'kind is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'title' IS NULL OR length(trim(p_payload->>'title')) = 0 THEN
    RAISE EXCEPTION 'title is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'severity' IS NULL THEN
    RAISE EXCEPTION 'severity is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'confidence' IS NULL THEN
    RAISE EXCEPTION 'confidence is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->'rawPayload' IS NULL THEN
    RAISE EXCEPTION 'rawPayload is required' USING ERRCODE = '22023';
  END IF;
  IF p_payload->>'dedupHash' IS NULL THEN
    RAISE EXCEPTION 'dedupHash is required' USING ERRCODE = '22023';
  END IF;

  -- 3. Enum validation
  v_kind     := p_payload->>'kind';
  v_severity := p_payload->>'severity';
  IF v_kind NOT IN ('geopolitical','sanctions','weather','commodity','fx','logistics','esg','regulatory','news','internal') THEN
    RAISE EXCEPTION 'kind must be one of geopolitical/sanctions/weather/commodity/fx/logistics/esg/regulatory/news/internal'
      USING ERRCODE = '22023';
  END IF;
  IF v_severity NOT IN ('informational','low','medium','high','critical') THEN
    RAISE EXCEPTION 'severity must be one of informational/low/medium/high/critical'
      USING ERRCODE = '23514';
  END IF;

  -- 4. S2-23 FK pre-validation — resolve osint_source_id
  SELECT id INTO v_osint_source_id
  FROM osint_source
  WHERE tenant_id = v_tenant_id
    AND source_id = p_payload->>'sourceId'
    AND is_active = TRUE;
  IF v_osint_source_id IS NULL THEN
    RAISE EXCEPTION 'Source not registered: %', p_payload->>'sourceId' USING ERRCODE = '22023';
  END IF;

  -- 5. S2-20 actor sentinel
  BEGIN
    v_actor := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  EXCEPTION WHEN OTHERS THEN
    v_actor := NULL;
  END;
  IF v_actor = 0 THEN v_actor := NULL; END IF;

  -- 6. Idempotent INSERT (UNIQUE on (tenant_id, dedup_hash))
  INSERT INTO osint_signal (
    tenant_id, osint_source_id, source_id, source_reliability,
    fetched_at, event_date_v2, kind, signal_kind_subtype,
    title, summary, geographies, affected_entities,
    severity_v2, confidence, url, raw_payload, dedup_hash,
    data_classification, created_by, updated_by,
    -- R-LC back-compat NOT-NULL columns must be synthesised:
    ext_id, category, source, severity, title_en, published_date
  )
  VALUES (
    v_tenant_id, v_osint_source_id, p_payload->>'sourceId',
    (p_payload->>'sourceReliability')::numeric,
    (p_payload->>'fetchedAt')::timestamptz,
    NULLIF(p_payload->>'eventDate','')::timestamptz,
    v_kind,
    p_payload->>'signalKindSubtype',
    p_payload->>'title',
    p_payload->>'summary',
    COALESCE(p_payload->'geographies',      '[]'::jsonb),
    COALESCE(p_payload->'affectedEntities', '[]'::jsonb),
    v_severity,
    (p_payload->>'confidence')::numeric,
    p_payload->>'url',
    p_payload->'rawPayload',
    p_payload->>'dedupHash',
    COALESCE(p_payload->>'dataClassification', 'demo'),
    v_actor, v_actor,
    -- R-LC compat (synthesised)
    'osint:' || left(p_payload->>'dedupHash', 24),
    CASE v_kind
      WHEN 'regulatory'    THEN 'regulatory'
      WHEN 'commodity'     THEN 'commodity_prices'
      WHEN 'logistics'     THEN 'supply_chain'
      WHEN 'fx'            THEN 'market_financial'
      WHEN 'geopolitical'  THEN 'geopolitical'
      ELSE 'geopolitical'
    END,
    left(p_payload->>'sourceId', 120),
    v_severity,
    p_payload->>'title',
    COALESCE(NULLIF(p_payload->>'eventDate','')::date,
             NULLIF(p_payload->>'fetchedAt','')::date,
             CURRENT_DATE)
  )
  ON CONFLICT (tenant_id, dedup_hash) DO NOTHING
  RETURNING id INTO v_id;

  v_inserted := (v_id IS NOT NULL);

  IF NOT v_inserted THEN
    SELECT id INTO v_id
    FROM osint_signal
    WHERE tenant_id = v_tenant_id
      AND dedup_hash = p_payload->>'dedupHash';
  ELSE
    -- Emit pg_notify only on insert path (AC-S7-04)
    PERFORM pg_notify(
      'osint_signal_inserted',
      jsonb_build_object(
        'id',        v_id,
        'tenantId',  v_tenant_id,
        'sourceId',  p_payload->>'sourceId',
        'severity',  v_severity,
        'kind',      v_kind
      )::text
    );
  END IF;

  RETURN jsonb_build_object(
    'id',         v_id,
    'inserted',   v_inserted,
    'dedupHash',  p_payload->>'dedupHash'
  );

EXCEPTION
  WHEN check_violation THEN
    RAISE EXCEPTION 'CHECK constraint violation: %', SQLERRM USING ERRCODE = '23514';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_osint_signal_upsert: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_osint_signal_upsert(JSONB) IS
  'M7 — DEFINER, SYSTEM-ONLY. Idempotent upsert via UNIQUE(tenant_id, dedup_hash). Emits pg_notify(osint_signal_inserted) only on insert path. NO role grant; only neondb_owner connection (fetch worker) invokes.';
REVOKE EXECUTE ON FUNCTION fn_osint_signal_upsert(JSONB) FROM PUBLIC;
-- AC-S7-05: NO role grant. Only neondb_owner (the fn owner) can EXECUTE.

-- ============================================================
-- 8. fn_osint_signal_list — INVOKER STABLE, signal.read.all
-- ============================================================
CREATE OR REPLACE FUNCTION fn_osint_signal_list(
  p_actor_id BIGINT,
  p_filter   JSONB,
  p_page     INTEGER,
  p_limit    INTEGER
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id        UUID;
  v_page             INTEGER;
  v_limit            INTEGER;
  v_offset           INTEGER;
  v_severity_order   INTEGER;
  v_kind             TEXT;
  v_source_id        TEXT;
  v_severity_min     TEXT;
  v_since            TIMESTAMPTZ;
  v_geo_country      TEXT;
  v_affected_id      TEXT;
  v_total            INTEGER;
  v_rows             JSONB;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF NOT (fn_current_user_has_permission('signal.read.all')
       OR fn_current_user_has_permission('contract.read.department')
       OR fn_current_user_has_permission('contract.edit')) THEN
    RAISE EXCEPTION 'forbidden: signal.read.all required' USING ERRCODE = '42501';
  END IF;

  v_page  := COALESCE(p_page, 1);
  v_limit := LEAST(COALESCE(p_limit, 20), 100);
  v_offset := (v_page - 1) * v_limit;

  v_kind         := p_filter->>'kind';
  v_source_id    := p_filter->>'sourceId';
  v_severity_min := p_filter->>'severityMin';
  v_since        := NULLIF(p_filter->>'since','')::timestamptz;
  v_geo_country  := p_filter->>'geographyIntersects';
  v_affected_id  := p_filter->>'affectedEntityId';

  v_severity_order := CASE v_severity_min
                        WHEN 'informational' THEN 1
                        WHEN 'low'           THEN 2
                        WHEN 'medium'        THEN 3
                        WHEN 'high'          THEN 4
                        WHEN 'critical'      THEN 5
                        ELSE 0
                      END;

  -- COUNT (RLS scopes by tenant; explicit predicate retained as defence-in-depth)
  SELECT COUNT(*) INTO v_total
  FROM osint_signal s
  WHERE s.tenant_id = v_tenant_id
    AND s.is_active = TRUE
    AND (v_kind         IS NULL OR s.kind = v_kind)
    AND (v_source_id    IS NULL OR s.source_id = v_source_id)
    AND (v_severity_min IS NULL OR
         CASE s.severity_v2
           WHEN 'informational' THEN 1 WHEN 'low' THEN 2 WHEN 'medium' THEN 3
           WHEN 'high' THEN 4 WHEN 'critical' THEN 5 ELSE 0
         END >= v_severity_order)
    AND (v_since        IS NULL OR s.fetched_at >= v_since)
    AND (v_geo_country  IS NULL OR
         s.geographies @> jsonb_build_array(jsonb_build_object('isoCountry', v_geo_country)))
    AND (v_affected_id  IS NULL OR
         s.affected_entities @> jsonb_build_array(jsonb_build_object('identifier', v_affected_id)));

  -- Page rows
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                 q.id,
    'tenantId',           q.tenant_id,
    'osintSourceId',      q.osint_source_id,
    'sourceId',           q.source_id,
    'sourceReliability',  q.source_reliability,
    'fetchedAt',          q.fetched_at,
    'eventDate',          q.event_date_v2,
    'kind',               q.kind,
    'signalKindSubtype',  q.signal_kind_subtype,
    'title',              q.title,
    'summary',            q.summary,
    'geographies',        q.geographies,
    'affectedEntities',   q.affected_entities,
    'severity',           q.severity_v2,
    'confidence',         q.confidence,
    'url',                q.url,
    'rawPayload',         q.raw_payload,
    'dedupHash',          q.dedup_hash,
    'dataClassification', q.data_classification,
    'createdAt',          q.created_at
  ) ORDER BY q.event_date_v2 DESC NULLS LAST, q.fetched_at DESC), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT *
    FROM osint_signal
    WHERE tenant_id = v_tenant_id
      AND is_active = TRUE
      AND (v_kind         IS NULL OR kind = v_kind)
      AND (v_source_id    IS NULL OR source_id = v_source_id)
      AND (v_severity_min IS NULL OR
           CASE severity_v2
             WHEN 'informational' THEN 1 WHEN 'low' THEN 2 WHEN 'medium' THEN 3
             WHEN 'high' THEN 4 WHEN 'critical' THEN 5 ELSE 0
           END >= v_severity_order)
      AND (v_since        IS NULL OR fetched_at >= v_since)
      AND (v_geo_country  IS NULL OR
           geographies @> jsonb_build_array(jsonb_build_object('isoCountry', v_geo_country)))
      AND (v_affected_id  IS NULL OR
           affected_entities @> jsonb_build_array(jsonb_build_object('identifier', v_affected_id)))
    ORDER BY event_date_v2 DESC NULLS LAST, fetched_at DESC
    LIMIT v_limit OFFSET v_offset
  ) q;

  RETURN jsonb_build_object(
    'data', v_rows,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', CASE WHEN v_limit = 0 THEN 0 ELSE CEIL(v_total::numeric / v_limit)::int END
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_osint_signal_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_osint_signal_list(BIGINT, JSONB, INTEGER, INTEGER) IS
  'M7 — paginated signal list. Filters: kind, sourceId, severityMin, since, geographyIntersects, affectedEntityId. Order: event_date DESC NULLS LAST, fetched_at DESC. RLS auto-scopes tenant. Permission: signal.read.all (or R-LC compat: contract.read.department / contract.edit).';
REVOKE EXECUTE ON FUNCTION fn_osint_signal_list(BIGINT, JSONB, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_osint_signal_list(BIGINT, JSONB, INTEGER, INTEGER) TO neondb_owner;

-- ============================================================
-- 9. fn_source_health_record — DEFINER cron-callable, NO role grant
-- ============================================================
CREATE OR REPLACE FUNCTION fn_source_health_record(
  p_osint_source_id    BIGINT,
  p_state              TEXT,
  p_last_error_message TEXT,
  p_signals_24h        INTEGER
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_msg       TEXT;
  v_id        BIGINT;
  v_state     TEXT;
  v_checked   TIMESTAMPTZ;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF p_state NOT IN ('healthy','degraded','failing','unauthorised') THEN
    RAISE EXCEPTION 'state must be one of healthy/degraded/failing/unauthorised'
      USING ERRCODE = '22023';
  END IF;

  -- S2-23 FK pre-validation
  IF NOT EXISTS (
    SELECT 1 FROM osint_source
    WHERE id = p_osint_source_id AND tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'osint_source not found' USING ERRCODE = '23503';
  END IF;

  v_msg := left(coalesce(p_last_error_message, ''), 500);

  INSERT INTO source_health (
    tenant_id, osint_source_id, state,
    last_success_at, last_failure_at, last_error_message,
    signals_24h, checked_at
  )
  VALUES (
    v_tenant_id, p_osint_source_id, p_state,
    CASE WHEN p_state = 'healthy' THEN now() ELSE NULL END,
    CASE WHEN p_state IN ('degraded','failing','unauthorised') THEN now() ELSE NULL END,
    CASE WHEN length(v_msg) > 0 THEN v_msg ELSE NULL END,
    GREATEST(coalesce(p_signals_24h, 0), 0),
    now()
  )
  ON CONFLICT (tenant_id, osint_source_id) DO UPDATE
  SET state              = EXCLUDED.state,
      last_success_at    = CASE WHEN EXCLUDED.state = 'healthy'
                                THEN now()
                                ELSE source_health.last_success_at END,
      last_failure_at    = CASE WHEN EXCLUDED.state IN ('degraded','failing','unauthorised')
                                THEN now()
                                ELSE source_health.last_failure_at END,
      last_error_message = COALESCE(NULLIF(EXCLUDED.last_error_message, ''),
                                    source_health.last_error_message),
      signals_24h        = EXCLUDED.signals_24h,
      checked_at         = now(),
      updated_at         = now()
  RETURNING id, state, checked_at INTO v_id, v_state, v_checked;

  RETURN jsonb_build_object(
    'id',         v_id,
    'state',      v_state,
    'checkedAt',  v_checked
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_source_health_record: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_source_health_record(BIGINT, TEXT, TEXT, INTEGER) IS
  'M7 — DEFINER, SYSTEM-ONLY. Upserts source_health from cron worker. last_error_message truncated to 500 chars. NO role grant; only neondb_owner (cron) invokes.';
REVOKE EXECUTE ON FUNCTION fn_source_health_record(BIGINT, TEXT, TEXT, INTEGER) FROM PUBLIC;
-- NO role grant.

-- ============================================================
-- 10. fn_source_health_list — INVOKER STABLE, source.read
-- ============================================================
CREATE OR REPLACE FUNCTION fn_source_health_list(p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_rows      JSONB;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF NOT fn_current_user_has_permission('source.read') THEN
    RAISE EXCEPTION 'forbidden: source.read required' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'sourceId',         s.source_id,
    'displayName',      s.display_name,
    'kind',             s.kind,
    'state',            sh.state,
    'lastSuccessAt',    sh.last_success_at,
    'lastFailureAt',    sh.last_failure_at,
    'signals24h',       sh.signals_24h,
    'lastErrorMessage', sh.last_error_message,
    'checkedAt',        sh.checked_at
  )
  ORDER BY
    CASE sh.state
      WHEN 'failing'      THEN 1
      WHEN 'unauthorised' THEN 2
      WHEN 'degraded'     THEN 3
      WHEN 'healthy'      THEN 4
      ELSE 5
    END,
    s.display_name
  ), '[]'::jsonb) INTO v_rows
  FROM source_health sh
  JOIN osint_source s
    ON s.id = sh.osint_source_id
   AND s.tenant_id = sh.tenant_id
  WHERE sh.tenant_id = v_tenant_id
    AND s.is_active = TRUE;

  RETURN v_rows;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_source_health_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_source_health_list(BIGINT) IS
  'M7 — health monitor list. Order: failing > unauthorised > degraded > healthy, then displayName. Permission: source.read.';
REVOKE EXECUTE ON FUNCTION fn_source_health_list(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_source_health_list(BIGINT) TO neondb_owner;

-- ============================================================
-- 11. fn_osint_source_test_pull — INVOKER, source.manage
-- ============================================================
CREATE OR REPLACE FUNCTION fn_osint_source_test_pull(
  p_actor_id BIGINT,
  p_id       BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_enabled   BOOLEAN;
  v_src       TEXT;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF NOT fn_current_user_has_permission('source.manage') THEN
    RAISE EXCEPTION 'forbidden: source.manage required' USING ERRCODE = '42501';
  END IF;

  SELECT enabled, source_id INTO v_enabled, v_src
  FROM osint_source
  WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE;

  IF v_enabled IS NULL THEN
    RAISE EXCEPTION 'Source not found' USING ERRCODE = '22023';
  END IF;
  IF v_enabled = FALSE THEN
    RAISE EXCEPTION 'Source is disabled — enable before test-pull' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_notify(
    'osint_test_pull',
    jsonb_build_object(
      'osintSourceId', p_id,
      'tenantId',      v_tenant_id,
      'sourceId',      v_src,
      'actorId',       p_actor_id,
      'requestedAt',   now()
    )::text
  );

  RETURN jsonb_build_object(
    'queued',      TRUE,
    'sourceId',    v_src,
    'requestedAt', now()
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_osint_source_test_pull: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_osint_source_test_pull(BIGINT, BIGINT) IS
  'M7 — emits pg_notify(osint_test_pull) so the worker dispatches a manual fetch. Permission: source.manage.';
REVOKE EXECUTE ON FUNCTION fn_osint_source_test_pull(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_osint_source_test_pull(BIGINT, BIGINT) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (107, 'm7_osint_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_osint_source_test_pull(BIGINT, BIGINT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_source_health_list(BIGINT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_source_health_record(BIGINT, TEXT, TEXT, INTEGER) CASCADE;
-- DROP FUNCTION IF EXISTS fn_osint_signal_list(BIGINT, JSONB, INTEGER, INTEGER) CASCADE;
-- DROP FUNCTION IF EXISTS fn_osint_signal_upsert(JSONB) CASCADE;
-- DROP FUNCTION IF EXISTS fn_source_credential_set(BIGINT, BIGINT, TEXT, TEXT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_osint_source_list(BIGINT, JSONB, INTEGER, INTEGER) CASCADE;
-- DROP FUNCTION IF EXISTS fn_osint_source_delete(BIGINT, BIGINT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_osint_source_update(BIGINT, BIGINT, JSONB) CASCADE;
-- DROP FUNCTION IF EXISTS fn_osint_source_get_by_id(BIGINT, BIGINT) CASCADE;
-- DROP FUNCTION IF EXISTS fn_osint_source_create(BIGINT, JSONB) CASCADE;
-- DELETE FROM schema_migrations WHERE version = 107;
-- COMMIT;
-- ============================================================
