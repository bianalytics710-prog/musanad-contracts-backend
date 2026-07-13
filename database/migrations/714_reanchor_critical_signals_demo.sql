-- Migration: 714_reanchor_critical_signals_demo.sql
-- Module: Executive Critical Impact tile — restore the demo-week 5 signals
-- Date: 2026-07-08
--
-- fn_dashboard_executive_critical_impacts (migration 543) filters
--   osint_signal.published_date >= CURRENT_DATE - 7 days
-- and the executive dashboard KPI tile renders that row count.
--
-- The five critical signals that back the "5 critical impacts" demo view
-- were last re-anchored by migration 599 (2026-06-08). A month of calendar
-- drift has pushed all five back outside the 7-day window (they now sit at
-- 2026-06-04 .. 2026-06-19), so the tile reads 0.
--
-- Re-anchor the same five signals to dates INSIDE the past 7 days, spaced
-- so the timeline reads as a realistic multi-day surge. Unlike 599 these
-- are anchored RELATIVE to CURRENT_DATE (not hard-coded) so re-applying on
-- a future "today" lands them in-window again. Order matches the story:
--   • CURRENT_DATE-1 → Hormuz Strait routing disruption (most recent ops)
--   • CURRENT_DATE-2 → Arabian Gulf tropical cyclone forecast
--   • CURRENT_DATE-3 → CRQ-GAS-014 day-rate ceiling breach
--   • CURRENT_DATE-4 → CRQ-ONS-023 day-rate ceiling breach
--   • CURRENT_DATE-6 → Sub-contractor sanctions event (oldest)
--
-- The two open critical risk_case rows (ids 8, 24) are intentionally left
-- outside the window so the tile shows exactly 5, matching the demo.
--
-- No schema change, no fn change. Risk window stays at 7 days. Idempotent.

BEGIN;

UPDATE osint_signal
   SET published_date = CURRENT_DATE - INTERVAL '1 day' + TIME '08:30',
       updated_at = NOW()
 WHERE id = 7290235  -- Hormuz Strait routing disruption
   AND severity = 'critical' AND is_active = TRUE;

UPDATE osint_signal
   SET published_date = CURRENT_DATE - INTERVAL '2 days' + TIME '16:00',
       updated_at = NOW()
 WHERE id = 7290250  -- Arabian Gulf tropical cyclone forecast
   AND severity = 'critical' AND is_active = TRUE;

UPDATE osint_signal
   SET published_date = CURRENT_DATE - INTERVAL '3 days' + TIME '14:15',
       updated_at = NOW()
 WHERE id = 7290223  -- CRQ-GAS-014 day-rate ceiling breach
   AND severity = 'critical' AND is_active = TRUE;

UPDATE osint_signal
   SET published_date = CURRENT_DATE - INTERVAL '4 days' + TIME '11:00',
       updated_at = NOW()
 WHERE id = 7290226  -- CRQ-ONS-023 day-rate ceiling breach
   AND severity = 'critical' AND is_active = TRUE;

UPDATE osint_signal
   SET published_date = CURRENT_DATE - INTERVAL '6 days' + TIME '09:45',
       updated_at = NOW()
 WHERE id = 3801230  -- Sub-contractor sanctions event
   AND severity = 'critical' AND is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (714, '714_reanchor_critical_signals_demo', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- UPDATE osint_signal SET published_date = '2026-06-19'::timestamptz WHERE id = 7290235;
-- UPDATE osint_signal SET published_date = '2026-06-17'::timestamptz WHERE id = 7290250;
-- UPDATE osint_signal SET published_date = '2026-06-16'::timestamptz WHERE id = 7290223;
-- UPDATE osint_signal SET published_date = '2026-06-04'::timestamptz WHERE id = 7290226;
-- UPDATE osint_signal SET published_date = '2026-06-18'::timestamptz WHERE id = 3801230;
-- DELETE FROM schema_migrations WHERE version = 714;
-- COMMIT;
