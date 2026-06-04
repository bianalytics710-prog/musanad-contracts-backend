-- Migration: 480_exec_dashboard_expiring_contracts_fn.sql
-- Module: Executive Insights — E-rev-3 drilldown (Expiry cliff action modal)
-- Date: 2026-06-02
--
-- Powers the expiry-cliff click-through dialog: returns each contract
-- expiring within p_window_days plus the drafter's name + email so the FE
-- can render contract # / title / counterparty / drafter and let the
-- executive multi-select before firing renewal alerts.

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
      'drafterId',        c.drafted_by::text,
      'drafterName',      CASE
                            WHEN du.id IS NOT NULL
                              THEN TRIM(CONCAT(du.first_name, ' ', du.last_name))
                            ELSE NULL
                          END,
      'drafterEmail',     du.email,
      'endDate',          to_char(c.end_date, 'YYYY-MM-DD'),
      'daysToExpiry',     (c.end_date - CURRENT_DATE)
    ) ORDER BY c.end_date ASC
  ), '[]'::jsonb)
  INTO v_rows
  FROM contract c
  LEFT JOIN party cp ON cp.id = c.counterparty_id
  LEFT JOIN "user" du ON du.id = c.drafted_by
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
  'E-rev-3 — list contracts expiring within window with drafter info for the executive expiry-cliff drilldown modal.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (480, '480_exec_dashboard_expiring_contracts_fn', CURRENT_TIMESTAMP);
