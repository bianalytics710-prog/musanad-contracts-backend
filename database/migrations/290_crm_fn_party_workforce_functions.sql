-- Migration: 290_crm_fn_party_workforce_functions.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: 3 workforce fn_'s:
--              fn_party_workforce_set  (INVOKER VOLATILE — upsert one active row per tenant+party)
--              fn_party_workforce_get  (INVOKER STABLE — get current row + party names)
--              fn_party_workforce_list (INVOKER STABLE — paginated list with band/compliance filters)
--              Mandatory dedicated fn migration. Each fn: COMMENT ON + REVOKE + GRANT (B14/S2-21).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- D.1 fn_party_workforce_set
-- VOLATILE, SECURITY INVOKER (RLS enforces tenant + party.workforce.manage)
-- Upsert: one active row per (tenant, party)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_party_workforce_set(
  p_actor_id BIGINT,
  p_party_id BIGINT,
  p_data     JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id              UUID;
  v_headcount              INTEGER;
  v_emiratisation_target   INTEGER;
  v_emiratisation_actual   INTEGER;
  v_headcount_band         TEXT;
  v_is_compliant           BOOLEAN;
  v_category               TEXT;
  v_notes                  TEXT;
  v_wf_id                  BIGINT;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- Input validation
  IF p_data->>'headcount' IS NULL THEN
    RAISE EXCEPTION 'headcount is required' USING ERRCODE = '22023';
  END IF;
  IF p_data->>'emiratisationTarget' IS NULL THEN
    RAISE EXCEPTION 'emiratisationTarget is required' USING ERRCODE = '22023';
  END IF;
  IF p_data->>'emiratisationActual' IS NULL THEN
    RAISE EXCEPTION 'emiratisationActual is required' USING ERRCODE = '22023';
  END IF;

  v_headcount            := (p_data->>'headcount')::integer;
  v_emiratisation_target := (p_data->>'emiratisationTarget')::integer;
  v_emiratisation_actual := (p_data->>'emiratisationActual')::integer;
  v_category             := COALESCE(p_data->>'category', 'operational_support');
  v_notes                := p_data->>'notes';

  IF v_headcount < 0 THEN
    RAISE EXCEPTION 'headcount must be >= 0' USING ERRCODE = '22023';
  END IF;
  IF v_emiratisation_target < 0 THEN
    RAISE EXCEPTION 'emiratisationTarget must be >= 0' USING ERRCODE = '22023';
  END IF;
  IF v_emiratisation_actual < 0 THEN
    RAISE EXCEPTION 'emiratisationActual must be >= 0' USING ERRCODE = '22023';
  END IF;

  -- Validate party exists and is active
  IF NOT EXISTS (SELECT 1 FROM party WHERE id = p_party_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'Party not found: %', p_party_id USING ERRCODE = 'P0002';
  END IF;

  -- Validate category
  IF v_category NOT IN ('drilling','logistics','epc','operational_support','other') THEN
    RAISE EXCEPTION 'Invalid category: %. Must be drilling/logistics/epc/operational_support/other', v_category
      USING ERRCODE = '22023';
  END IF;

  -- Derive headcount_band from headcount
  v_headcount_band := CASE
    WHEN v_headcount < 20  THEN '<20'
    WHEN v_headcount <= 49 THEN '20-49'
    ELSE '50+'
  END;

  -- Derive is_compliant
  v_is_compliant := (v_emiratisation_actual >= v_emiratisation_target);

  -- Upsert: soft-deactivate existing active row first, then insert new
  -- (The partial unique index: ON CONFLICT ON CONSTRAINT uq_party_workforce_tenant_party_active
  --  cannot be used in an INSERT...ON CONFLICT UPDATE with SET is_active easily.
  --  Pattern: update existing row in-place if found, else insert.)
  UPDATE party_workforce
  SET headcount              = v_headcount,
      headcount_band         = v_headcount_band,
      emiratisation_target   = v_emiratisation_target,
      emiratisation_actual   = v_emiratisation_actual,
      is_compliant           = v_is_compliant,
      category               = v_category,
      source                 = 'manual',
      notes                  = v_notes,
      updated_by             = p_actor_id,
      updated_at             = NOW()
  WHERE tenant_id = v_tenant_id
    AND party_id  = p_party_id
    AND is_active = TRUE
  RETURNING id INTO v_wf_id;

  IF v_wf_id IS NULL THEN
    -- No existing active row — insert new
    INSERT INTO party_workforce
      (tenant_id, party_id, headcount, headcount_band,
       emiratisation_target, emiratisation_actual, is_compliant,
       category, source, notes, data_classification,
       created_at, updated_at, created_by, updated_by, is_active)
    VALUES
      (v_tenant_id, p_party_id, v_headcount, v_headcount_band,
       v_emiratisation_target, v_emiratisation_actual, v_is_compliant,
       v_category, 'manual', v_notes, 'demo',
       NOW(), NOW(), p_actor_id, p_actor_id, TRUE)
    RETURNING id INTO v_wf_id;
  END IF;

  RETURN fn_party_workforce_get(p_actor_id, p_party_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_workforce_set: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_workforce_set(BIGINT, BIGINT, JSONB) IS
  'CR-M — upsert the current workforce row for a contractor party (one active row per tenant+party). Derives headcount_band and is_compliant. Gated: party.workforce.manage (RLS).';
REVOKE EXECUTE ON FUNCTION fn_party_workforce_set(BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_workforce_set(BIGINT, BIGINT, JSONB) TO neondb_owner;

-- ============================================================
-- D.2 fn_party_workforce_get
-- STABLE, SECURITY INVOKER
-- Gating: party.workforce.read (RLS)
-- Returns NULL if no active row exists (controller → 404)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_party_workforce_get(
  p_actor_id BIGINT,
  p_party_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_result    JSONB;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  SELECT jsonb_build_object(
    'id',                    w.id,
    'partyId',               w.party_id,
    'partyNameEn',           p.name_en,
    'partyNameAr',           p.name_ar,
    'headcount',             w.headcount,
    'headcountBand',         w.headcount_band,
    'emiratisationTarget',   w.emiratisation_target,
    'emiratisationActual',   w.emiratisation_actual,
    'isCompliant',           w.is_compliant,
    'category',              w.category,
    'source',                w.source,
    'updatedAt',             to_char(w.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ) INTO v_result
  FROM party_workforce w
  JOIN party p ON p.id = w.party_id
  WHERE w.tenant_id = v_tenant_id
    AND w.party_id  = p_party_id
    AND w.is_active = TRUE
  LIMIT 1;

  RETURN v_result;  -- NULL if not found (controller → 404)

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_workforce_get: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_workforce_get(BIGINT, BIGINT) IS
  'CR-M — get current workforce snapshot for a contractor party (joins party for names). Returns NULL if no active row (controller → 404). Gated: party.workforce.read (RLS).';
REVOKE EXECUTE ON FUNCTION fn_party_workforce_get(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_workforce_get(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- D.3 fn_party_workforce_list
-- STABLE, SECURITY INVOKER
-- Gating: party.workforce.read (RLS)
-- Offset-based pagination (not page-based)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_party_workforce_list(
  p_actor_id BIGINT,
  p_band     TEXT    DEFAULT NULL,
  p_compliant BOOLEAN DEFAULT NULL,
  p_search   VARCHAR DEFAULT NULL,
  p_limit    INTEGER DEFAULT 100,
  p_offset   INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_total     INTEGER;
  v_data      JSONB;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- Validate band if provided
  IF p_band IS NOT NULL AND p_band NOT IN ('<20','20-49','50+') THEN
    RAISE EXCEPTION 'Invalid headcount_band: %. Must be one of <20 / 20-49 / 50+', p_band
      USING ERRCODE = '22023';
  END IF;

  SELECT COUNT(*)::integer INTO v_total
  FROM party_workforce w
  JOIN party p ON p.id = w.party_id
  WHERE w.tenant_id = v_tenant_id
    AND w.is_active = TRUE
    AND (p_band IS NULL      OR w.headcount_band = p_band)
    AND (p_compliant IS NULL OR w.is_compliant   = p_compliant)
    AND (p_search IS NULL    OR p.name_en ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',                    w.id,
      'partyId',               w.party_id,
      'partyNameEn',           p.name_en,
      'partyNameAr',           p.name_ar,
      'headcount',             w.headcount,
      'headcountBand',         w.headcount_band,
      'emiratisationTarget',   w.emiratisation_target,
      'emiratisationActual',   w.emiratisation_actual,
      'isCompliant',           w.is_compliant,
      'category',              w.category,
      'source',                w.source,
      'updatedAt',             to_char(w.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ) ORDER BY p.name_en ASC
  ), '[]'::jsonb) INTO v_data
  FROM party_workforce w
  JOIN party p ON p.id = w.party_id
  WHERE w.tenant_id = v_tenant_id
    AND w.is_active = TRUE
    AND (p_band IS NULL      OR w.headcount_band = p_band)
    AND (p_compliant IS NULL OR w.is_compliant   = p_compliant)
    AND (p_search IS NULL    OR p.name_en ILIKE '%' || p_search || '%')
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',  v_total,
      'limit',  p_limit,
      'offset', p_offset
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_workforce_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_workforce_list(BIGINT, TEXT, BOOLEAN, VARCHAR, INTEGER, INTEGER) IS
  'CR-M — paginated list of contractor workforce records (filterable by headcount_band / is_compliant / party name search). Offset-based pagination. Gated: party.workforce.read (RLS).';
REVOKE EXECUTE ON FUNCTION fn_party_workforce_list(BIGINT, TEXT, BOOLEAN, VARCHAR, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_workforce_list(BIGINT, TEXT, BOOLEAN, VARCHAR, INTEGER, INTEGER) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (290, '290_crm_fn_party_workforce_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 290;
-- DROP FUNCTION IF EXISTS fn_party_workforce_set(BIGINT, BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_party_workforce_get(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_party_workforce_list(BIGINT, TEXT, BOOLEAN, VARCHAR, INTEGER, INTEGER);
-- COMMIT;
-- ============================================================
