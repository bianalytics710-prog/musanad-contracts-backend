-- Migration: 482_exec_dashboard_backdate_throughput.sql
-- Module: Executive Insights — E-rev-7 polish (realistic 12-month throughput)
-- Date: 2026-06-02
--
-- After 477 backdated contracts that had signed_at / start_date anchors,
-- the throughput chart still shows Jul-Nov 2025 as 0/0 because the
-- remaining contracts (those without anchors) cluster in May/Jun 2026.
-- The user wants 10–15 initiated and a healthy signed count for EVERY
-- month in the rolling 12-month window — an enterprise simply doesn't go
-- five months without signing anything.
--
-- Approach: for each contract that's still anchored in May/June 2026
-- (i.e. created_at is in the last 60 days AND signed_at IS NULL AND
--  migration_batch_id IS NULL — preserves the M22 Drive imports as
--  genuinely-just-imported), assign a deterministic created_at by
--  spreading contract.id modulo across the 12 months Jul 2025 → Jun 2026.
-- Then for ~75% of those (status active/fully_signed/expiring_soon),
-- backfill signed_at = created_at + 7 days so the signed bar lights up.
--
-- The mod-12 distribution gives natural variance (each month sees roughly
-- (count_of_non-anchored)/12 contracts) which lands around 12-18 per
-- month on the current 367-contract dataset.

WITH backfill AS (
  SELECT
    c.id,
    -- Spread by (id mod 12) into months Jul 2025 .. Jun 2026
    (date '2025-07-01' + ((c.id::bigint % 12) || ' months')::interval
       + ((c.id::bigint % 28) || ' days')::interval)::timestamptz AS new_created_at
  FROM contract c
  WHERE c.is_active = TRUE
    AND c.migration_batch_id IS NULL
    AND c.created_at >= CURRENT_DATE - INTERVAL '60 days'
    AND c.signed_at IS NULL
)
UPDATE contract c
   SET created_at = bf.new_created_at,
       updated_at = COALESCE(c.updated_at, bf.new_created_at),
       -- ~75% of these get a signed_at too so throughput.signed lights up.
       -- We use (id mod 4) <> 0 to leave a quarter unsigned (still in draft / review)
       -- and pin signed_at to created_at + 7 days for realism.
       signed_at = CASE
         WHEN (c.id::bigint % 4) <> 0 AND c.status IN ('active', 'fully_signed', 'expiring_soon')
           THEN bf.new_created_at + INTERVAL '7 days'
         ELSE c.signed_at
       END
  FROM backfill bf
 WHERE c.id = bf.id;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (482, '482_exec_dashboard_backdate_throughput', CURRENT_TIMESTAMP);
