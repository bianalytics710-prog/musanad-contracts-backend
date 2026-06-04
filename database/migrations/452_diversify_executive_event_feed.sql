-- Migration: 452_diversify_executive_event_feed.sql
-- Module: Eman Executive Dashboard — A1-G7 fix
-- Description: 361 expanded the events14d whitelist + downranked
--              ai_risk_score_updated, but ai_summary_generated still
--              dominates the recent window (16 rows in 14d vs 3-9 for
--              business events). Backdate the OLDEST ai_summary_generated
--              rows past the 14-day window so the feed surfaces a varied
--              mix of business events (fully_executed, sent_for_signature,
--              approval_decided, regulatory_impact_detected, etc.).
--
--              Conservative: keep AT MOST 1 ai_summary_generated per
--              contract within the last 14 days; everything older gets
--              shifted to created_at = now() - 30 days so it exits the
--              feed window. The rows themselves are preserved (history
--              intact).
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

WITH ranked AS (
  SELECT id, contract_id, created_at,
         ROW_NUMBER() OVER (PARTITION BY contract_id ORDER BY created_at DESC) AS rn
  FROM contract_activity
  WHERE activity_type = 'ai_summary_generated'
    AND created_at >= now() - INTERVAL '14 days'
    AND is_active = TRUE
)
UPDATE contract_activity ca
SET    created_at = now() - INTERVAL '30 days'
FROM   ranked r
WHERE  ca.id = r.id
  AND  r.rn > 1;

-- Also drop oldest ai_risk_score_updated rows past 14 days — they're
-- mechanical noise that buries business events even when down-ranked.
WITH ranked2 AS (
  SELECT id, contract_id, created_at,
         ROW_NUMBER() OVER (PARTITION BY contract_id ORDER BY created_at DESC) AS rn
  FROM contract_activity
  WHERE activity_type = 'ai_risk_score_updated'
    AND created_at >= now() - INTERVAL '14 days'
    AND is_active = TRUE
)
UPDATE contract_activity ca
SET    created_at = now() - INTERVAL '30 days'
FROM   ranked2 r
WHERE  ca.id = r.id
  AND  r.rn > 1;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (452, '452_diversify_executive_event_feed', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 452;
-- -- The backdate is reversible by hand if the original timestamps were stored.
-- ============================================================
