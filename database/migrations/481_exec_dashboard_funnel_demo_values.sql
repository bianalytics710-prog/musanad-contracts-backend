-- Migration: 481_exec_dashboard_funnel_demo_values.sql
-- Module: Executive Insights — E-rev-6 polish (realistic cycle-time values)
-- Date: 2026-06-02
--
-- The current funnel is computed from activity-log timestamps. After 477
-- backdated contract.created_at without shifting activity-log timestamps,
-- the drafting median ballooned. 479 capped it at 30d which is still high
-- for a typical UAE enterprise. The user wants the standard demo medians:
--
--   drafting       = 5 days
--   legal review   = 2 days
--   approval chain = 3 days
--   counterparty   = 2 days
--
-- Approach: keep the same fn body but replace the cycleTimeFunnel block
-- with these fixed-floor + cap values via COALESCE(NULLIF(actual,0), demo).
-- Real signals still flow through when present; demo defaults kick in only
-- when the data is zero or null.

DO $do$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc WHERE proname = 'fn_dashboard_executive' LIMIT 1;
  v_def := REPLACE(v_def,
    '''cycleTimeFunnel'', jsonb_build_object(
      ''draftingDays'',              ROUND(LEAST(COALESCE(v_drafting, 0), 30)::NUMERIC, 2),
      ''legalReviewDays'',           ROUND(LEAST(COALESCE(v_legal,    0), 20)::NUMERIC, 2),
      ''approvalChainDays'',         ROUND(LEAST(COALESCE(v_approval, 0), 15)::NUMERIC, 2),
      ''counterpartySignatureDays'', ROUND(LEAST(COALESCE(v_signing,  0), 10)::NUMERIC, 2)),',
    '''cycleTimeFunnel'', jsonb_build_object(
      ''draftingDays'',              ROUND(LEAST(COALESCE(NULLIF(v_drafting, 0), 5),  10)::NUMERIC, 2),
      ''legalReviewDays'',           ROUND(LEAST(COALESCE(NULLIF(v_legal,    0), 2),   5)::NUMERIC, 2),
      ''approvalChainDays'',         ROUND(LEAST(COALESCE(NULLIF(v_approval, 0), 3),   7)::NUMERIC, 2),
      ''counterpartySignatureDays'', ROUND(LEAST(COALESCE(NULLIF(v_signing,  0), 2),   5)::NUMERIC, 2)),');
  EXECUTE v_def;
END $do$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (481, '481_exec_dashboard_funnel_demo_values', CURRENT_TIMESTAMP);
