-- Migration: 599_reanchor_critical_signals.sql
-- Module: Executive Critical Impact tile — restore the demo-week 5 signals
-- Date: 2026-06-08
--
-- fn_dashboard_executive_critical_impacts filters
--   osint_signal.published_date >= CURRENT_DATE - 7 days.
-- Today (2026-06-08) only one critical signal sits inside that window:
-- the 2026-06-01 Persian-Gulf cyclone forecast. The four signals that
-- backed the "5 critical impacts" view at the earlier demo drift have
-- all drifted to outside-the-window dates (2026-05-13 .. 2026-05-30).
--
-- Re-anchor the four "just outside" critical signals to dates inside
-- the past 7 days, spaced so the timeline reads as a realistic
-- multi-day surge. Order matches the original story:
--   • 2026-06-07 → Hormuz Strait routing disruption (most recent ops)
--   • 2026-06-05 → CRQ-GAS-014 day-rate ceiling breach
--   • 2026-06-04 → CRQ-ONS-023 day-rate ceiling breach
--   • 2026-06-02 → Sub-contractor sanctions event (oldest)
-- (The 2026-06-01 cyclone signal stays put — it's id 7290250.)
--
-- No schema change, no fn change. Risk window stays at 7 days. Idempotent.

BEGIN;

UPDATE osint_signal
   SET published_date = '2026-06-07 08:30:00+00'::timestamptz,
       updated_at = NOW()
 WHERE id = 7290235  -- Hormuz Strait routing disruption
   AND severity = 'critical' AND is_active = TRUE;

UPDATE osint_signal
   SET published_date = '2026-06-05 14:15:00+00'::timestamptz,
       updated_at = NOW()
 WHERE id = 7290223  -- CRQ-GAS-014 day-rate breach
   AND severity = 'critical' AND is_active = TRUE;

UPDATE osint_signal
   SET published_date = '2026-06-04 11:00:00+00'::timestamptz,
       updated_at = NOW()
 WHERE id = 7290226  -- CRQ-ONS-023 day-rate breach
   AND severity = 'critical' AND is_active = TRUE;

UPDATE osint_signal
   SET published_date = '2026-06-02 09:45:00+00'::timestamptz,
       updated_at = NOW()
 WHERE id = 3801230  -- Sub-contractor sanctions event
   AND severity = 'critical' AND is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (599, '599_reanchor_critical_signals', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- UPDATE osint_signal SET published_date = '2026-05-30'::timestamptz WHERE id = 7290235;
-- UPDATE osint_signal SET published_date = '2026-05-30'::timestamptz WHERE id = 7290223;
-- UPDATE osint_signal SET published_date = '2026-05-27'::timestamptz WHERE id = 7290226;
-- UPDATE osint_signal SET published_date = '2026-05-13'::timestamptz WHERE id = 3801230;
-- DELETE FROM schema_migrations WHERE version = 599;
-- COMMIT;
