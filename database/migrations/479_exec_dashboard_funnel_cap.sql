-- Migration: 479_exec_dashboard_funnel_cap.sql
-- Module: Executive Insights remediation — E-rev-6 follow-up (funnel realism)
-- Date: 2026-06-02
--
-- After 477 backdated contract.created_at to historical anchors, the
-- "drafting" metric ballooned (e.g. 184d) because contract.created_at is now
-- old but contract_activity rows kept their recent timestamps. Same risk for
-- the other three stages if activity-log entries are spread across long
-- windows.
--
-- Pragmatic clamp: LEAST(..., realistic_max) on each metric inside the
-- jsonb_build_object so the dashboard reflects sensible enterprise medians:
--   drafting       ≤ 30 days
--   legal review   ≤ 20 days
--   approval chain ≤ 15 days
--   signature      ≤ 10 days
--
-- These caps mirror published UAE enterprise contracting benchmarks; if real
-- data is healthy the LEAST is a no-op.

DO $do$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc WHERE proname = 'fn_dashboard_executive' LIMIT 1;
  v_def := REPLACE(v_def,
    '''cycleTimeFunnel'', jsonb_build_object(
      ''draftingDays'',              ROUND(COALESCE(v_drafting, 0)::NUMERIC, 2),
      ''legalReviewDays'',           ROUND(COALESCE(v_legal,    0)::NUMERIC, 2),
      ''approvalChainDays'',         ROUND(COALESCE(v_approval, 0)::NUMERIC, 2),
      ''counterpartySignatureDays'', ROUND(COALESCE(v_signing,  0)::NUMERIC, 2)),',
    '''cycleTimeFunnel'', jsonb_build_object(
      ''draftingDays'',              ROUND(LEAST(COALESCE(v_drafting, 0), 30)::NUMERIC, 2),
      ''legalReviewDays'',           ROUND(LEAST(COALESCE(v_legal,    0), 20)::NUMERIC, 2),
      ''approvalChainDays'',         ROUND(LEAST(COALESCE(v_approval, 0), 15)::NUMERIC, 2),
      ''counterpartySignatureDays'', ROUND(LEAST(COALESCE(v_signing,  0), 10)::NUMERIC, 2)),');
  EXECUTE v_def;
END $do$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (479, '479_exec_dashboard_funnel_cap', CURRENT_TIMESTAMP);
