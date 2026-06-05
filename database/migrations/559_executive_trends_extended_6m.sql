-- MIGRATION: 559_executive_trends_extended_6m.sql
-- Date: 2026-06-05
-- Description:
--   Companion fn for the executive dashboard charts "Contract Value over
--   time" + "Contracts created over time". The legacy
--   fn_dashboard_executive trends block follows p_window_days which is 90
--   by default → only ~4 months on the chart. Per executive review, the
--   chart should show the last 2 quarters (6 months) regardless of the
--   KPI windowDays.
--
--   Rather than redefine the 753-line fn_dashboard_executive, we ship a
--   tiny side-car fn that returns ONLY the two trend arrays for the
--   requested month count (default 6). The FE calls it after the main
--   dashboard payload loads and substitutes the arrays in place.
--
--   Same role gate as fn_dashboard_executive.

BEGIN;

CREATE OR REPLACE FUNCTION fn_dashboard_executive_trends_extended(
  p_months INTEGER DEFAULT 6
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_user_id BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  v_role TEXT;
  v_window INTERVAL;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive_trends_extended: unauthorized'
      USING ERRCODE = '42501';
  END IF;
  IF p_months < 2 OR p_months > 24 THEN
    RAISE EXCEPTION 'fn_dashboard_executive_trends_extended: months must be 2..24'
      USING ERRCODE = '22023';
  END IF;
  SELECT r.name INTO v_role FROM "user" u JOIN role r ON r.id = u.role_id WHERE u.id = v_user_id;
  IF v_role NOT IN ('executive', 'platform_admin', 'Super Admin')
     AND NOT fn_current_user_has_permission('insights.executive') THEN
    RAISE EXCEPTION 'fn_dashboard_executive_trends_extended: forbidden'
      USING ERRCODE = '42501';
  END IF;

  -- p_months back from today. Subtract (p_months - 1) months so the
  -- generate_series window produces exactly p_months buckets including the
  -- current month.
  v_window := ((p_months - 1) || ' months')::interval;

  RETURN jsonb_build_object(
    'months', p_months,
    'valueOverTimeByMonth', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'month',         to_char(month_start, 'YYYY-MM'),
          'totalValueAed', COALESCE(c.total_value_aed, 0)
        ) ORDER BY month_start
      )
      FROM generate_series(
        date_trunc('month', CURRENT_DATE) - v_window,
        date_trunc('month', CURRENT_DATE),
        INTERVAL '1 month'
      ) AS gs(month_start)
      LEFT JOIN (
        SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS total_value_aed
          FROM contract
         WHERE is_active = TRUE
           AND created_at >= date_trunc('month', CURRENT_DATE) - v_window
         GROUP BY 1
      ) c ON c.m = month_start
    ), '[]'::jsonb),
    'contractsCreatedByMonth', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'month', to_char(month_start, 'YYYY-MM'),
          'count', COALESCE(c.cnt, 0)
        ) ORDER BY month_start
      )
      FROM generate_series(
        date_trunc('month', CURRENT_DATE) - v_window,
        date_trunc('month', CURRENT_DATE),
        INTERVAL '1 month'
      ) AS gs(month_start)
      LEFT JOIN (
        SELECT date_trunc('month', created_at) AS m, COUNT(*) AS cnt
          FROM contract
         WHERE is_active = TRUE
           AND created_at >= date_trunc('month', CURRENT_DATE) - v_window
         GROUP BY 1
      ) c ON c.m = month_start
    ), '[]'::jsonb)
  );
END $$;

REVOKE EXECUTE ON FUNCTION fn_dashboard_executive_trends_extended(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_executive_trends_extended(INTEGER) TO neondb_owner;
COMMENT ON FUNCTION fn_dashboard_executive_trends_extended(INTEGER) IS
  'Side-car fn for executive trend charts — returns valueOverTimeByMonth + contractsCreatedByMonth for the last p_months months (default 6 = last 2 quarters). Decouples chart time-span from KPI window.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (559, '559_executive_trends_extended_6m', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
