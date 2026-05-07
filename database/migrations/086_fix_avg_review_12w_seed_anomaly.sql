-- ================================================================
-- Migration 086 — R-LC1-D2 fix: avgReview12w negative-hours seed
-- anomaly on the Legal Counsel dashboard.
-- ================================================================
-- Up: BEGIN
-- The R-LC1 dashboard-history seed inserted 6 approval_decision
-- rows with `decided_at` back-dated to historical weeks
-- (2026-01-09 .. 2026-02-27, plus one recent at -48h) so the
-- avg-review-time 12w chart had data points to plot. The matching
-- approval_step.created_at values stayed at seeding time
-- (2026-05-05), making `decided_at - created_at` negative for
-- every affected row. The FE clamps the value to 0, which masks
-- the bug; the DB still emits negative review_hours.
--
-- Fix: back-date approval_step.created_at to a realistic interval
-- BEFORE the matching decision. Use a per-role offset so the chart
-- shows a believable spread:
--   - contract_approver: 12h review window (faster sign-off)
--   - legal_counsel:     24h review window (deeper read)
--
-- Idempotent — predicate `decided_at < step.created_at` only
-- matches the broken rows; after the update the predicate is
-- false so re-running this migration is a no-op.
--
-- After this migration, the chart's existing FE clamp becomes
-- redundant; the FE can drop the LEAST/GREATEST guard
-- independently.
-- ================================================================

UPDATE approval_step s
SET created_at = ad.decided_at - (
  CASE
    WHEN s.approver_role = 'legal_counsel' THEN INTERVAL '24 hours'
    ELSE INTERVAL '12 hours'
  END
)
FROM approval_decision ad
WHERE ad.approval_step_id = s.id
  AND ad.decided_at < s.created_at
  AND ad.is_active = TRUE
  AND s.is_active = TRUE;

-- ================================================================
-- Up: END
-- Down: BEGIN
-- (No reverse — restoring the broken state would re-introduce
-- the negative-review-hours bug. If a rollback is required, take
-- the affected step ids from the audit query and replay 2026-05-05
-- timestamps manually.)
-- ================================================================
-- Down: END
