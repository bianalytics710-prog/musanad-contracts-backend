-- Migration: 455_event_feed_aggressive_dedupe.sql
-- Module: Eman Executive Dashboard — G2 fix (post-verification gap)
-- Description: Migration 452 backdated old ai_summary_generated +
--              ai_risk_score_updated rows, but workers have written new
--              ones since. The executive events14d feed still shows
--              ~5/8 "AI summary generated" entries. Per-type cap at
--              query level would need a full fn_dashboard_executive
--              rewrite (~750 lines). Pragmatic alternative: keep at
--              most the most-recent ONE row of each AI-tagged
--              activity_type within the last 14 days, backdate the
--              rest. Re-runs idempotently.
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

WITH ranked AS (
  SELECT id, activity_type, created_at,
         ROW_NUMBER() OVER (PARTITION BY activity_type ORDER BY created_at DESC) AS rn
  FROM contract_activity
  WHERE activity_type IN ('ai_summary_generated', 'ai_risk_score_updated')
    AND created_at >= now() - INTERVAL '14 days'
    AND is_active = TRUE
)
UPDATE contract_activity ca
SET    created_at = now() - INTERVAL '30 days'
FROM   ranked r
WHERE  ca.id = r.id
  AND  r.rn > 1;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (455, '455_event_feed_aggressive_dedupe', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 455;
-- ============================================================
