-- Migration: 396_layla_fn_party_list_contracts_count.sql
-- Unit: Layla Counsel QA Phase 3.7 follow-up — L70 finish
-- Extend fn_party_list to return contractsCount (subquery against contract
-- table counting where party is our_party_id OR counterparty_id).

CREATE OR REPLACE FUNCTION public.fn_party_list(p_actor_id bigint, p_party_type character varying DEFAULT NULL::character varying, p_search character varying DEFAULT NULL::character varying, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_total INTEGER;
  v_data  JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department')
     AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM party p
  WHERE p.is_active = TRUE
    AND (p_party_type IS NULL OR p.party_type = p_party_type)
    AND (p_search IS NULL OR p.name_en ILIKE '%' || p_search || '%' OR p.name_ar ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(row_obj ORDER BY row_created_at DESC), '[]'::jsonb)
    INTO v_data
  FROM (
    SELECT
      jsonb_build_object(
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
        'parentId',             p.parent_id,
        'aliases',              p.aliases,
        'sanctionsStatus',      p.sanctions_status,
        'sanctionsLastChecked', p.sanctions_last_checked,
        'icvStatus',            p.icv_status,
        'icvPct',               p.icv_pct,
        -- L70 — Contracts column on FE: count contracts where this party is
        -- our_party_id or counterparty_id and the contract is active.
        'contractsCount',       (
          SELECT COUNT(*)::INT FROM contract c
          WHERE c.is_active = TRUE
            AND (c.our_party_id = p.id OR c.counterparty_id = p.id)
        )
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
$function$;
