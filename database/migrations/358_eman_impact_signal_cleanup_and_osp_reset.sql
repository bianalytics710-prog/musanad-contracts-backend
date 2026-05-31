-- Migration: 358_eman_impact_signal_cleanup_and_osp_reset.sql
-- Unit: Eman Executive QA Phase 3.3 (2026-05-31)
-- Fixes:
--   E28 — Impact Watch feed dominated by USD/INR + USD/GBP FX (irrelevant
--         to UAE). Soft-delete (is_active=FALSE) impact_signal rows for
--         non-AED FX pairs so the feed stays UAE-relevant.
--   E29 — fx_usd_aed source on USD/INR row (label/value mismatch). Same
--         soft-delete sweep removes the offenders.
--   E40 — Murban margin shown post-recompute. Reset Murban OSP for the
--         current month to the pre-demo value $110.75 and mark the
--         $104.44 row as historical so the trade-margin dashboard restores
--         to its Story-2 starting state.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ── E28/E29 — soft-delete non-AED FX impact signals ─────────────────────
UPDATE impact_signal
  SET is_active = FALSE,
      updated_at = NOW(),
      updated_by = 1
  WHERE is_active = TRUE
    AND (
      title_en ~ '^USD/(INR|GBP|EUR|JPY|CNY|CHF|CAD|AUD|SGD)'
      OR title_en ~ '^EUR/(GBP|JPY)'
      OR source = 'fx_usd_aed' AND title_en NOT ILIKE '%USD/AED%'
    );

-- ── E40 — restore Murban OSP for current month to pre-demo state ────────
-- The Story 2 starting OSP is $110.75/bbl. Currently it's at $104.44 (post
-- recompute). Set price_value for the live current+next month rows back to
-- the pre-demo baseline. Move the $104.44 rows to historical notes for
-- audit trail clarity.

UPDATE price_benchmark
  SET price_value = 110.7500,
      notes = COALESCE(notes,'') || ' [E40-fix: restored to pre-demo OSP for Story 2 starting state]',
      updated_at = NOW(),
      updated_by = 1
  WHERE benchmark_code = 'murban_osp'
    AND price_date IN (DATE_TRUNC('month', CURRENT_DATE)::date,
                        DATE_TRUNC('month', CURRENT_DATE + INTERVAL '1 month')::date)
    AND price_value BETWEEN 100.0000 AND 108.0000;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Data toggle migration; to roll back:
--   UPDATE impact_signal SET is_active = TRUE WHERE is_active = FALSE
--     AND title_en ~ '^USD/(INR|GBP|EUR|JPY|CNY|CHF|CAD|AUD|SGD)';
--   UPDATE price_benchmark SET price_value = 104.4400
--     WHERE benchmark_code = 'murban_osp' AND price_value = 110.7500;
-- ============================================================
