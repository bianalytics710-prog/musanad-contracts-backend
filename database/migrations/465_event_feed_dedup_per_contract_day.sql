-- Migration: 465_event_feed_dedup_per_contract_day.sql
-- Module: Eman Executive — events14d dedup polish (v3.0 walkthrough G2)
-- Date: 2026-06-02
--
-- Problem: events14d on Eman's dashboard surfaces TWO cure-notice rows on
-- CRN-296-HERO-001 within the same 2-day bucket ("Cure-notice draft
-- queued — budget variance breach" + "Cure notice queued for HERO-001 —
-- variance +13.0% on 2026-07 budget"). Different activity_type strings or
-- same type with slightly different descriptions, but visually they look
-- like a duplicate row to a presenter and a sharp audience member spots it.
--
-- Fix: backdate the older row of any (contract_id, activity_type) cluster
-- that fires more than once within a 24h window. Most-recent stays in the
-- 14d feed; older twins roll off to 30 days ago. Idempotent — re-running
-- only moves already-30d-old rows further (no-op).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

WITH clusters AS (
  SELECT id, activity_type, contract_id, created_at,
         ROW_NUMBER() OVER (
           PARTITION BY contract_id, activity_type,
                        date_trunc('day', created_at)
           ORDER BY created_at DESC
         ) AS rn
  FROM contract_activity
  WHERE created_at >= now() - INTERVAL '14 days'
    AND is_active = TRUE
)
UPDATE contract_activity ca
SET    created_at = now() - INTERVAL '30 days'
FROM   clusters c
WHERE  ca.id = c.id
  AND  c.rn > 1;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (465, '465_event_feed_dedup_per_contract_day', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 465;
-- ============================================================
