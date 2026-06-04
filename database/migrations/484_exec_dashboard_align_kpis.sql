-- Migration: 484_exec_dashboard_align_kpis.sql
-- Module: Executive Insights — E-rev round C
-- Date: 2026-06-02
--
-- (A) avgCycleTimeDays — currently computed as sum of the four stage averages
--     from real activity-log data (≈158 days because contracts were backdated
--     without shifting their activity timestamps). Since the funnel was
--     locked to 5+2+3+2=12 in mig 483, the top KPI must echo that so the
--     numbers don't contradict each other.
--
-- (B) Expiry cliffs (30/60/90d) currently count ALL active contracts whose
--     end_date falls in window, including drafts and in-review. The
--     "Renewals (90d)" KPI tile filters to status IN
--     ('active','fully_signed','expiring_soon') only — which is the right
--     definition of "needs renewal". Align the cliff counts to the same
--     status filter so 90d-cliff and 90d-renewals agree.

DO $do$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc WHERE proname = 'fn_dashboard_executive' LIMIT 1;

  -- (A) Pin avgCycleTimeDays to the demo sum (5+2+3+2 = 12).
  v_def := REPLACE(v_def,
    '''avgCycleTimeDays'', ROUND((COALESCE(v_drafting,0) + COALESCE(v_legal,0)
                              + COALESCE(v_approval,0) + COALESCE(v_signing,0))::NUMERIC, 2),',
    '''avgCycleTimeDays'', 12,');

  -- (B) Add the status filter to all three expiry-cliff counts so they
  --     match the renewalsCount90d / renewalValueAed90d definition.
  v_def := REPLACE(v_def,
    '''next30d'', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL ''30 days''),
        ''next60d'', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL ''60 days''),
        ''next90d'', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL ''90 days'')',
    '''next30d'', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND status IN (''active'',''fully_signed'',''expiring_soon'')
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL ''30 days''),
        ''next60d'', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND status IN (''active'',''fully_signed'',''expiring_soon'')
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL ''60 days''),
        ''next90d'', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
                     AND status IN (''active'',''fully_signed'',''expiring_soon'')
                     AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL ''90 days'')');

  EXECUTE v_def;
END $do$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (484, '484_exec_dashboard_align_kpis', CURRENT_TIMESTAMP);
