-- Migration: 406_pari_cluster1_perm_backfill.sql
-- Unit: Pari Procurement QA Phase 3.7 (2026-06-01) — Cluster 1 / P27 P28 P34 P35 P44 P45 P47 P48
-- Closes:
--   P27/P28 — /api/v1/parties/{id} returns 403 for Pari → contract detail Parties block shows em-dashes.
--             Root cause: fn_party_get_by_id (mig 070) gates on contract.read.department OR
--             contract.edit. Pari has neither, even though mig 379 granted party.read.all to her role.
--   P34/P35/P44/P48 — /app/reports returns 403 (report.read never granted to procurement_supplier_risk;
--                     mig 262 predated the role's creation in mig 292). Also resolves P35/P44 (sidebar +
--                     mobile-more list the entry) and the P48 ⌘K trap (palette lists Reports).
--   P45/P47 — /app/profile/notification-preferences returns 403
--             (notification.preferences.{read,write}.self was attempted in mig 220 but the role
--             didn't exist then; the conditional grant silently no-op'd).
--
-- Strategy:
--   1. Grant report.read to procurement_supplier_risk
--   2. Grant notification.preferences.read.self + write.self to procurement_supplier_risk
--   3. Rewrite fn_party_get_by_id to ALSO accept party.read.all (semantically correct)

BEGIN;

-- ============================================================
-- STEP 1 — report.read grant (P34/P35/P44/P48)
-- ============================================================

INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
  FROM role r CROSS JOIN permission p
 WHERE r.name = 'procurement_supplier_risk'
   AND p.code = 'report.read'
ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = TRUE;

-- ============================================================
-- STEP 2 — notification.preferences.{read,write}.self grants (P45/P47)
-- Idempotent re-apply of mig 220 backfill for this role
-- ============================================================

INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
  FROM role r CROSS JOIN permission p
 WHERE r.name = 'procurement_supplier_risk'
   AND p.code IN ('notification.preferences.read.self', 'notification.preferences.write.self')
ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = TRUE;

-- ============================================================
-- STEP 3 — fn_party_get_by_id: accept party.read.all (P27/P28)
-- Original (mig 070) required contract.read.department OR contract.edit.
-- Now also accepts party.read.all so persona roles with explicit party-read
-- grants (mig 379) can see parties on contracts they're scoped to.
-- ============================================================

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
  IF NOT (
    fn_current_user_has_permission('party.read.all')
    OR fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.edit')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

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

REVOKE EXECUTE ON FUNCTION fn_party_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (406, '406_pari_cluster1_perm_backfill', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DELETE FROM role_permission
--   WHERE role_id = (SELECT id FROM role WHERE name = 'procurement_supplier_risk')
--     AND permission_id IN (SELECT id FROM permission WHERE code IN (
--       'report.read', 'notification.preferences.read.self', 'notification.preferences.write.self'));
-- -- fn_party_get_by_id revert: restore body from mig 070_lc_fix_party_get_camelcase.sql
-- DELETE FROM schema_migrations WHERE version = 406;
-- COMMIT;
-- ============================================================
