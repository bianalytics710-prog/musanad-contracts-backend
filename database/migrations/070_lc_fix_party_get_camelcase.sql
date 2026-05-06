-- Migration 070: R-LC0 LC-E6 — fix fn_party_get_by_id to return camelCase keys.
--
-- The 058 implementation used `to_jsonb(p)` which returned all columns as-is
-- (snake_case: name_en, name_ar, free_zone, etc.). The FE PartyDetail type
-- expects camelCase (nameEn, nameAr, freeZone). The list endpoint
-- (fn_party_list) already uses explicit camelCase via jsonb_build_object —
-- this migration brings the get-by-id endpoint into alignment.
--
-- Caught at R-LC0 Playwright verification: party names rendered as "—" in
-- the contract detail Parties card because partyResults[0].data.nameEn was
-- undefined (the field arrived as name_en).
--
-- Side effects: none. The recentContracts5 sub-array was already camelCase.
-- We only rebuild the top-level row projection.

CREATE OR REPLACE FUNCTION fn_party_get_by_id(
  p_actor_id BIGINT,
  p_party_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_row JSONB;
  v_contracts JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department') AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- R-LC0: build row with explicit camelCase keys (mirror fn_party_list shape).
  SELECT jsonb_build_object(
    'id',                 p.id,
    'partyType',          p.party_type,
    'nameEn',             p.name_en,
    'nameAr',             p.name_ar,
    'tradeLicenseNumber', p.trade_license_number,
    'tradeLicenseIssuer', p.trade_license_issuer,
    'emirate',            p.emirate,
    'freeZone',           p.free_zone,
    'country',            p.country,
    'contactEmail',       p.contact_email,
    'contactPhone',       p.contact_phone,
    'registeredAddress',  p.registered_address,
    'notes',              p.notes,
    'createdAt',          p.created_at,
    'updatedAt',          p.updated_at
  ) INTO v_row
  FROM party p
  WHERE p.id = p_party_id AND p.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'party_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- contract count + list (5 most recent) where this party is counterparty
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
END;
$$;

-- ROLLBACK BEGIN
-- No structural changes; rollback would require restoring the 058 body
-- exactly. CREATE OR REPLACE means there is no previous version to drop.
-- ROLLBACK END
