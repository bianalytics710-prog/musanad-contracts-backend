-- MIGRATION: 558_drafter_fix_and_counterparty_contracts_fn.sql
-- Date: 2026-06-05
-- Description:
--   Two coupled changes for the executive dashboard:
--
--   1) Reassign drafters for the remaining admin-drafted contracts in the
--      90-day expiry window so Executive can fire renewal alerts:
--        - CRQ-GAS-019  → Mariam Al Mansoori (user_id 19)
--        - OQOOD-2026-016 → Faisal Al Otaibi  (user_id 20)
--      (Mig 557 handled OQOOD-2026-008 → Mariam already.)
--
--   2) fn_dashboard_executive_counterparty_contracts(p_counterparty_id) —
--      powers the new "Top Business Partners" drilldown. Returns each
--      contract for the counterparty with {contractId, contractNumber,
--      titleEn, titleAr, counterpartyName, valueAed, currency, status}
--      sorted by value desc. Same role gate as the other executive fn's
--      (executive / platform_admin / Super Admin / insights.executive).

BEGIN;

-- 1. Reassign admin-drafted contracts in the 90d expiry window
UPDATE contract SET drafted_by = 19, updated_at = NOW(), updated_by = 1
 WHERE contract_number = 'CRQ-GAS-019'  AND drafted_by = 1;

UPDATE contract SET drafted_by = 20, updated_at = NOW(), updated_by = 1
 WHERE contract_number = 'OQOOD-2026-016' AND drafted_by = 1;

-- 2. fn_dashboard_executive_counterparty_contracts
CREATE OR REPLACE FUNCTION fn_dashboard_executive_counterparty_contracts(
  p_counterparty_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_role TEXT;
  v_user_id BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  v_rows JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive_counterparty_contracts: unauthorized'
      USING ERRCODE = '42501';
  END IF;
  IF p_counterparty_id IS NULL OR p_counterparty_id < 1 THEN
    RAISE EXCEPTION 'fn_dashboard_executive_counterparty_contracts: counterpartyId required'
      USING ERRCODE = '22023';
  END IF;
  SELECT r.name INTO v_role FROM "user" u JOIN role r ON r.id = u.role_id WHERE u.id = v_user_id;
  IF v_role NOT IN ('executive', 'platform_admin', 'Super Admin')
     AND NOT fn_current_user_has_permission('insights.executive') THEN
    RAISE EXCEPTION 'fn_dashboard_executive_counterparty_contracts: forbidden'
      USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'contractId',       c.id::text,
      'contractNumber',   c.contract_number,
      'titleEn',          c.title_en,
      'titleAr',          c.title_ar,
      'counterpartyName', cp.name_en,
      'valueAed',         c.value_aed,
      'currency',         c.currency,
      'status',           c.status,
      'endDate',          to_char(c.end_date, 'YYYY-MM-DD')
    ) ORDER BY COALESCE(c.value_aed, 0) DESC, c.id ASC
  ), '[]'::jsonb)
  INTO v_rows
  FROM contract c
  LEFT JOIN party cp ON cp.id = c.counterparty_id
  WHERE c.is_active = TRUE
    AND c.counterparty_id = p_counterparty_id
    AND c.status IN ('active', 'fully_signed', 'expiring_soon');

  RETURN jsonb_build_object(
    'counterpartyId', p_counterparty_id,
    'rows',           v_rows
  );
END $$;

REVOKE EXECUTE ON FUNCTION fn_dashboard_executive_counterparty_contracts(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_executive_counterparty_contracts(BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_executive_counterparty_contracts(BIGINT) IS
  'Drilldown for executive "Top Business Partners" tile (mig 558). Returns active/fully_signed/expiring_soon contracts for the counterparty sorted by value desc.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (558, '558_drafter_fix_and_counterparty_contracts_fn', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
