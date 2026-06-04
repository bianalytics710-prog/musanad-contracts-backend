-- Migration: 477_exec_dashboard_backdate_contracts.sql
-- Module: Executive Insights remediation — E-rev-7 (throughput) + E-rev-2 (prior-period KPI)
-- Date: 2026-06-02
--
-- Symptom: Executive dashboard throughput chart shows all 367 contracts in
-- May/June 2026; prior-period delta tiles show "no prior data".
--
-- Root cause: All `contract.created_at` rows are in the last 30 days (seed
-- data drop). The 12-month throughput SQL groups by created_at, so every
-- contract ends up in May/Jun 2026. The kpiPrev block compares
-- created-this-window vs created-prior-window — when nothing was created
-- before, both prior totals are 0 → delta tiles read empty.
--
-- Fix: backdate `contract.created_at` to a sensible historical anchor:
--   1. If signed_at is set → use signed_at minus 14 days (drafting time)
--   2. Else if start_date is set → use start_date minus 30 days
--   3. Else leave created_at untouched (recently drafted)
--
-- Applied to dev + test branches. Idempotent (only writes when current
-- created_at is within last 60 days, so re-runs don't keep shifting back).
-- Migration-imported contracts (migration_batch_id IS NOT NULL) are NOT
-- shifted — those are real "imported just now" rows.

UPDATE contract
   SET created_at = anchor.new_created_at,
       updated_at = COALESCE(updated_at, anchor.new_created_at)
  FROM (
    SELECT id,
           CASE
             WHEN signed_at IS NOT NULL THEN signed_at - INTERVAL '14 days'
             WHEN start_date IS NOT NULL THEN start_date::timestamptz - INTERVAL '30 days'
             ELSE created_at
           END AS new_created_at
      FROM contract
     WHERE migration_batch_id IS NULL
       AND created_at >= CURRENT_DATE - INTERVAL '60 days'
       AND (signed_at IS NOT NULL OR start_date IS NOT NULL)
  ) AS anchor
 WHERE contract.id = anchor.id
   AND contract.migration_batch_id IS NULL;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (477, '477_exec_dashboard_backdate_contracts', CURRENT_TIMESTAMP);
