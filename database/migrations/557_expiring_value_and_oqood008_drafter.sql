-- MIGRATION: 557_expiring_value_and_oqood008_drafter.sql
-- Date: 2026-06-04
-- Description:
--   Two coupled changes for the executive Expiry-Cliff frame:
--
--   1) Reassign OQOOD-2026-008's drafter from admin (user_id=1) to a real
--      contract_drafter (Mariam Al Mansoori, user_id=19). Per user
--      feedback, no contract should ship with "No drafter" in the frame.
--      Mariam is picked because Hala already owns the other 3 contracts
--      in the 30-day window; spreading the demo load makes the filter
--      dropdown more useful.
--
--   2) Extend fn_dashboard_executive_expiring_contracts to surface
--      valueAed + currency so the FE can render a Value column (placed
--      before Drafter) and sort by it.
--      Drafter-masking + escalation-event LATERAL join from mig 554 are
--      preserved verbatim.

BEGIN;

-- 1. Reassign OQOOD-2026-008 drafter
UPDATE contract
   SET drafted_by = 19,
       updated_at = NOW(),
       updated_by = 1
 WHERE contract_number = 'OQOOD-2026-008'
   AND drafted_by = 1;

-- 2. Extend the expiring-contracts fn to project valueAed + currency
CREATE OR REPLACE FUNCTION fn_dashboard_executive_expiring_contracts(
  p_window_days INTEGER DEFAULT 30
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_role TEXT;
  v_user_id BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  v_rows JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive_expiring_contracts: unauthorized'
      USING ERRCODE = '42501';
  END IF;
  IF p_window_days < 1 OR p_window_days > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_executive_expiring_contracts: windowDays must be 1..365'
      USING ERRCODE = '22023';
  END IF;
  SELECT r.name INTO v_role FROM "user" u JOIN role r ON r.id = u.role_id WHERE u.id = v_user_id;
  IF v_role NOT IN ('executive', 'platform_admin', 'Super Admin')
     AND NOT fn_current_user_has_permission('insights.executive') THEN
    RAISE EXCEPTION 'fn_dashboard_executive_expiring_contracts: forbidden'
      USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'contractId',       c.id::text,
      'contractNumber',   c.contract_number,
      'titleEn',          c.title_en,
      'titleAr',          c.title_ar,
      'counterpartyId',   c.counterparty_id::text,
      'counterpartyName', cp.name_en,
      'drafterId',        CASE
                            WHEN dr.name IN ('platform_admin', 'Super Admin') THEN NULL
                            ELSE c.drafted_by::text
                          END,
      'drafterName',      CASE
                            WHEN du.id IS NULL THEN NULL
                            WHEN dr.name IN ('platform_admin', 'Super Admin') THEN NULL
                            ELSE TRIM(CONCAT(du.first_name, ' ', du.last_name))
                          END,
      'drafterEmail',     CASE
                            WHEN du.id IS NULL THEN NULL
                            WHEN dr.name IN ('platform_admin', 'Super Admin') THEN NULL
                            ELSE du.email
                          END,
      'valueAed',         c.value_aed,
      'currency',         c.currency,
      'endDate',          to_char(c.end_date, 'YYYY-MM-DD'),
      'daysToExpiry',     (c.end_date - CURRENT_DATE),
      'escalatedAt',      ev.created_at,
      'escalatedByName',  ev.escalated_by_name,
      'escalationNote',   ev.note,
      'escalationCount',  ev.escalation_count
    ) ORDER BY c.end_date ASC, c.id ASC
  ), '[]'::jsonb)
  INTO v_rows
  FROM contract c
  LEFT JOIN party cp ON cp.id = c.counterparty_id
  LEFT JOIN "user" du ON du.id = c.drafted_by
  LEFT JOIN role dr ON dr.id = du.role_id AND dr.is_active = TRUE
  LEFT JOIN LATERAL (
    SELECT
      e.created_at,
      TRIM(CONCAT(eu.first_name, ' ', eu.last_name)) AS escalated_by_name,
      e.note,
      (SELECT COUNT(*) FROM contract_renewal_alert_event
        WHERE contract_id = c.id AND is_active = TRUE) AS escalation_count
    FROM contract_renewal_alert_event e
    LEFT JOIN "user" eu ON eu.id = e.escalated_by_user_id
    WHERE e.contract_id = c.id
      AND e.is_active = TRUE
    ORDER BY e.created_at DESC
    LIMIT 1
  ) ev ON TRUE
  WHERE c.is_active = TRUE
    AND c.status IN ('active', 'fully_signed', 'expiring_soon')
    AND c.end_date IS NOT NULL
    AND c.end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + (p_window_days || ' days')::interval;

  RETURN jsonb_build_object(
    'windowDays', p_window_days,
    'asOf',       CURRENT_DATE,
    'rows',       v_rows
  );
END $$;

REVOKE EXECUTE ON FUNCTION fn_dashboard_executive_expiring_contracts(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_executive_expiring_contracts(INTEGER) TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_executive_expiring_contracts(INTEGER) IS
  'Lists contracts expiring within window. Projects valueAed + currency for the FE Value column (mig 557). Drafter masking + escalation-event LATERAL join preserved.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (557, '557_expiring_value_and_oqood008_drafter', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
