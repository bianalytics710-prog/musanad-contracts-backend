-- Migration: 120_crb_party_update_and_get_extend.sql
-- Module: M9 — Counterparty Graph (CR-B)
-- Description: 3 fn_'s — fn_party_update (NEW INVOKER) + fn_party_get_by_id (CREATE OR REPLACE — extend projection
--              with 11 new columns) + fn_party_list (CREATE OR REPLACE — extend projection with 6 badge fields).
--              Each with COMMENT + REVOKE/GRANT trio tail.
--              CRITICAL (B14): re-applies REVOKE FROM PUBLIC + GRANT TO neondb_owner trio for all 3 fns.
-- Rollback: Restore prior bodies from migrations 070/075.

BEGIN;

-- ============================================================
-- 3.4 fn_party_update — NEW. Editable subset only; sanctions_* fields not accepted (Q-DA4 defence-in-depth)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_update(
  p_actor_id              BIGINT,
  p_party_id              BIGINT,
  p_name_en               VARCHAR(200) DEFAULT NULL,
  p_name_ar               VARCHAR(200) DEFAULT NULL,
  p_parent_id             BIGINT       DEFAULT NULL,
  p_ubo_id                BIGINT       DEFAULT NULL,
  p_aliases               JSONB        DEFAULT NULL,
  p_esg_score             INTEGER      DEFAULT NULL,
  p_icv_status            TEXT         DEFAULT NULL,
  p_icv_pct               NUMERIC(5,2) DEFAULT NULL,
  p_icv_last_checked      TIMESTAMPTZ  DEFAULT NULL,
  p_metadata              JSONB        DEFAULT NULL,
  p_emirate               VARCHAR(40)  DEFAULT NULL,
  p_free_zone             VARCHAR(80)  DEFAULT NULL,
  p_country               VARCHAR(60)  DEFAULT NULL,
  p_contact_email         VARCHAR(255) DEFAULT NULL,
  p_contact_phone         VARCHAR(40)  DEFAULT NULL,
  p_registered_address    TEXT         DEFAULT NULL,
  p_notes                 TEXT         DEFAULT NULL,
  p_trade_license_number  VARCHAR(80)  DEFAULT NULL,
  p_trade_license_issuer  VARCHAR(80)  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  -- 1. Permission gate: contract.edit OR party.graph.manage
  IF NOT fn_current_user_has_permission('contract.edit')
     AND NOT fn_current_user_has_permission('party.graph.manage') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- 2. Existence
  IF NOT EXISTS (SELECT 1 FROM party WHERE id = p_party_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'party_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- 3. Self-reference guards (only if non-NULL and not the unset sentinel -1)
  IF p_parent_id IS NOT NULL AND p_parent_id <> -1 AND p_parent_id = p_party_id THEN
    RAISE EXCEPTION 'self_reference_not_allowed' USING ERRCODE = '22023';
  END IF;
  IF p_ubo_id IS NOT NULL AND p_ubo_id <> -1 AND p_ubo_id = p_party_id THEN
    RAISE EXCEPTION 'self_reference_not_allowed' USING ERRCODE = '22023';
  END IF;

  -- 4. parent_id / ubo_id pointee active-check (S2-23 FK pre-validation parity)
  IF p_parent_id IS NOT NULL AND p_parent_id <> -1 THEN
    IF NOT EXISTS (SELECT 1 FROM party WHERE id = p_parent_id AND is_active = TRUE) THEN
      RAISE EXCEPTION 'parentId:party_not_found' USING ERRCODE = 'P0002';
    END IF;
  END IF;
  IF p_ubo_id IS NOT NULL AND p_ubo_id <> -1 THEN
    IF NOT EXISTS (SELECT 1 FROM party WHERE id = p_ubo_id AND is_active = TRUE) THEN
      RAISE EXCEPTION 'uboId:party_not_found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  -- 5. aliases shape validation
  IF p_aliases IS NOT NULL THEN
    IF jsonb_typeof(p_aliases) <> 'array'
       OR EXISTS (
         SELECT 1
         FROM jsonb_array_elements(p_aliases) e
         WHERE jsonb_typeof(e) <> 'string'
       ) THEN
      RAISE EXCEPTION 'invalid_aliases_shape' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 6. UPDATE — sanctions_* intentionally NOT in SET clause (Q-DA4 defence-in-depth)
  UPDATE party SET
    name_en              = COALESCE(p_name_en, name_en),
    name_ar              = COALESCE(p_name_ar, name_ar),
    parent_id            = CASE
                             WHEN p_parent_id = -1 THEN NULL
                             WHEN p_parent_id IS NOT NULL THEN p_parent_id
                             ELSE parent_id
                           END,
    ubo_id               = CASE
                             WHEN p_ubo_id = -1 THEN NULL
                             WHEN p_ubo_id IS NOT NULL THEN p_ubo_id
                             ELSE ubo_id
                           END,
    aliases              = COALESCE(p_aliases, aliases),
    esg_score            = COALESCE(p_esg_score, esg_score),
    icv_status           = COALESCE(p_icv_status, icv_status),
    icv_pct              = COALESCE(p_icv_pct, icv_pct),
    icv_last_checked     = COALESCE(p_icv_last_checked, icv_last_checked),
    metadata             = COALESCE(p_metadata, metadata),
    emirate              = COALESCE(p_emirate, emirate),
    free_zone            = COALESCE(p_free_zone, free_zone),
    country              = COALESCE(p_country, country),
    contact_email        = COALESCE(p_contact_email, contact_email),
    contact_phone        = COALESCE(p_contact_phone, contact_phone),
    registered_address   = COALESCE(p_registered_address, registered_address),
    notes                = COALESCE(p_notes, notes),
    trade_license_number = COALESCE(p_trade_license_number, trade_license_number),
    trade_license_issuer = COALESCE(p_trade_license_issuer, trade_license_issuer),
    updated_at           = CURRENT_TIMESTAMP,
    updated_by           = p_actor_id
  WHERE id = p_party_id AND is_active = TRUE;

  -- 7. Return via fn_party_get_by_id (extended projection)
  v_result := fn_party_get_by_id(p_actor_id, p_party_id);
  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_update: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_update(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, JSONB, INTEGER, TEXT, NUMERIC, TIMESTAMPTZ, JSONB, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT, VARCHAR, VARCHAR) IS
  'M9 — partial update of party (editable subset). sanctions_* columns intentionally NOT accepted (Q-DA4 defence-in-depth). parentId/uboId support -1 sentinel for explicit unset; NULL = leave unchanged. Permission: contract.edit OR party.graph.manage.';
REVOKE EXECUTE ON FUNCTION fn_party_update(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, JSONB, INTEGER, TEXT, NUMERIC, TIMESTAMPTZ, JSONB, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT, VARCHAR, VARCHAR) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_update(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, JSONB, INTEGER, TEXT, NUMERIC, TIMESTAMPTZ, JSONB, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT, VARCHAR, VARCHAR) TO neondb_owner;


-- ============================================================
-- 4.6 fn_party_get_by_id — CREATE OR REPLACE (extend projection with 11 new columns)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_get_by_id(
  p_actor_id BIGINT,
  p_party_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_row       JSONB;
  v_contracts JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department')
     AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    -- Existing M_parity 058 + R-LC 070 + R-LC 075 fields
    'id',                       p.id,
    'partyType',                p.party_type,
    'nameEn',                   p.name_en,
    'nameAr',                   p.name_ar,
    'tradeLicenseNumber',       p.trade_license_number,
    'tradeLicenseIssuer',       p.trade_license_issuer,
    'emirate',                  p.emirate,
    'freeZone',                 p.free_zone,
    'country',                  p.country,
    'contactEmail',             p.contact_email,
    'contactPhone',             p.contact_phone,
    'registeredAddress',        p.registered_address,
    'notes',                    p.notes,
    'isVerified',               p.is_verified,
    'createdAt',                p.created_at,
    'updatedAt',                p.updated_at,
    -- M9 (CR-B) net-new 11 fields
    'parentId',                 p.parent_id,
    'uboId',                    p.ubo_id,
    'sanctionsStatus',          p.sanctions_status,
    'sanctionsLastChecked',     p.sanctions_last_checked,
    'sanctionsMatchSignalId',   p.sanctions_match_signal_id,
    'esgScore',                 p.esg_score,
    'icvStatus',                p.icv_status,
    'icvPct',                   p.icv_pct,
    'icvLastChecked',           p.icv_last_checked,
    'aliases',                  p.aliases,
    'metadata',                 p.metadata
  ) INTO v_row
  FROM party p
  WHERE p.id = p_party_id AND p.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'party_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- recentContracts5 sub-array unchanged from 070
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             c.id,
    'contractNumber', c.contract_number,
    'titleEn',        c.title_en,
    'status',         c.status,
    'valueAed',       c.value_aed,
    'updatedAt',      c.updated_at
  ) ORDER BY c.updated_at DESC), '[]'::jsonb) INTO v_contracts
  FROM (
    SELECT id, contract_number, title_en, status, value_aed, updated_at
    FROM contract
    WHERE counterparty_id = p_party_id AND is_active = TRUE
    ORDER BY updated_at DESC
    LIMIT 5
  ) c;

  RETURN v_row || jsonb_build_object('recentContracts5', v_contracts);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_get_by_id(BIGINT, BIGINT) IS
  'M9 — extends 070/075 projection with 11 CR-B columns (parentId/uboId/sanctions*/esg*/icv*/aliases/metadata). camelCase keys. Same arg signature; additive widening only.';
REVOKE EXECUTE ON FUNCTION fn_party_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_get_by_id(BIGINT, BIGINT) TO neondb_owner;


-- ============================================================
-- 4.7 fn_party_list — CREATE OR REPLACE (extend with 6 badge fields)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_party_list(
  p_actor_id     BIGINT,
  p_party_type   VARCHAR DEFAULT NULL,
  p_search       VARCHAR DEFAULT NULL,
  p_limit        INTEGER DEFAULT 20,
  p_offset       INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_total INTEGER;
  v_data  JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department')
     AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- Total count
  SELECT COUNT(*) INTO v_total
  FROM party p
  WHERE p.is_active = TRUE
    AND (p_party_type IS NULL OR p.party_type = p_party_type)
    AND (p_search IS NULL OR p.name_en ILIKE '%' || p_search || '%' OR p.name_ar ILIKE '%' || p_search || '%');

  -- Page data
  SELECT COALESCE(jsonb_agg(row_obj ORDER BY row_created_at DESC), '[]'::jsonb)
    INTO v_data
  FROM (
    SELECT
      jsonb_build_object(
        -- Existing M_parity + R-LC fields
        'id',                   p.id,
        'partyType',            p.party_type,
        'nameEn',               p.name_en,
        'nameAr',               p.name_ar,
        'tradeLicenseNumber',   p.trade_license_number,
        'tradeLicenseIssuer',   p.trade_license_issuer,
        'emirate',              p.emirate,
        'freeZone',             p.free_zone,
        'country',              p.country,
        'contactEmail',         p.contact_email,
        'contactPhone',         p.contact_phone,
        'createdAt',            p.created_at,
        'isVerified',           p.is_verified,
        -- M9 (CR-B) badge fields — 6 added
        'parentId',             p.parent_id,
        'aliases',              p.aliases,
        'sanctionsStatus',      p.sanctions_status,
        'sanctionsLastChecked', p.sanctions_last_checked,
        'icvStatus',            p.icv_status,
        'icvPct',               p.icv_pct
      ) AS row_obj,
      p.created_at AS row_created_at
    FROM party p
    WHERE p.is_active = TRUE
      AND (p_party_type IS NULL OR p.party_type = p_party_type)
      AND (p_search IS NULL OR p.name_en ILIKE '%' || p_search || '%' OR p.name_ar ILIKE '%' || p_search || '%')
    ORDER BY p.created_at DESC
    LIMIT p_limit OFFSET p_offset
  ) sub;

  RETURN jsonb_build_object(
    'data',       v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       CASE WHEN p_limit > 0 THEN (p_offset / p_limit) + 1 ELSE 1 END,
      'limit',      p_limit,
      'totalPages', CASE WHEN p_limit > 0 THEN CEIL(v_total::FLOAT / p_limit)::INTEGER ELSE 1 END
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_party_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_party_list(BIGINT, VARCHAR, VARCHAR, INTEGER, INTEGER) IS
  'M9 — extends 075 projection with 6 CR-B badge fields (parentId / aliases / sanctionsStatus / sanctionsLastChecked / icvStatus / icvPct). Same arg signature; additive widening only. camelCase keys.';
REVOKE EXECUTE ON FUNCTION fn_party_list(BIGINT, VARCHAR, VARCHAR, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_list(BIGINT, VARCHAR, VARCHAR, INTEGER, INTEGER) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (120, 'crb_party_update_and_get_extend', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- (Restore prior fn_party_get_by_id from migration 070; fn_party_list from 075. fn_party_update is net-new — DROP.)
-- DROP FUNCTION IF EXISTS fn_party_update(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, JSONB, INTEGER, TEXT, NUMERIC, TIMESTAMPTZ, JSONB, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT, VARCHAR, VARCHAR);
-- DELETE FROM schema_migrations WHERE version = 120;
-- COMMIT;
