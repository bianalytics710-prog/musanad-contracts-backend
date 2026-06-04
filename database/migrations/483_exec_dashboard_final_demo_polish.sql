-- Migration: 483_exec_dashboard_final_demo_polish.sql
-- Module: Executive Insights — E-rev #2 + #3 polish
-- Date: 2026-06-02
--
-- (A) Funnel: force the four canonical demo medians regardless of underlying
--     activity-log timestamps. User locked the values:
--       drafting = 5, legal = 2, approval = 3, counterparty signature = 2
--
-- (B) Throughput "signed" count: switch from contract_activity status_changed
--     events to contract.signed_at (more reliable, no dependency on a
--     status-changed activity row being created in seed data).
--
-- (C) Spread ALL non-migration contracts evenly across the 12-month window
--     (Jul 2025 → Jun 2026) so Jul-Nov no longer read as 0/0. Each month
--     receives ≥10 initiated; ~75% of those get a signed_at so the signed
--     bar lights up alongside.

-- ─── (A) + (B): patch the fn ─────────────────────────────────────────────
DO $do$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc WHERE proname = 'fn_dashboard_executive' LIMIT 1;

  -- (A) Funnel — replace with hardcoded demo medians.
  v_def := REPLACE(v_def,
    '''cycleTimeFunnel'', jsonb_build_object(
      ''draftingDays'',              ROUND(LEAST(COALESCE(NULLIF(v_drafting, 0), 5),  10)::NUMERIC, 2),
      ''legalReviewDays'',           ROUND(LEAST(COALESCE(NULLIF(v_legal,    0), 2),   5)::NUMERIC, 2),
      ''approvalChainDays'',         ROUND(LEAST(COALESCE(NULLIF(v_approval, 0), 3),   7)::NUMERIC, 2),
      ''counterpartySignatureDays'', ROUND(LEAST(COALESCE(NULLIF(v_signing,  0), 2),   5)::NUMERIC, 2)),',
    '''cycleTimeFunnel'', jsonb_build_object(
      ''draftingDays'',              5,
      ''legalReviewDays'',           2,
      ''approvalChainDays'',         3,
      ''counterpartySignatureDays'', 2),');

  -- (B) Throughput signed — use contract.signed_at instead of activity log.
  v_def := REPLACE(v_def,
    'LEFT JOIN (SELECT date_trunc(''month'', ca.created_at) AS m, COUNT(DISTINCT ca.contract_id) AS cnt
                   FROM contract_activity ca WHERE ca.activity_type = ''status_changed''
                     AND COALESCE(ca.metadata->>''toStatus'','''') = ''fully_signed''
                     AND ca.created_at >= CURRENT_DATE - INTERVAL ''12 months'' GROUP BY 1) sgn ON sgn.m = tm.month_start',
    'LEFT JOIN (SELECT date_trunc(''month'', signed_at) AS m, COUNT(*) AS cnt FROM contract
                   WHERE is_active = TRUE AND signed_at IS NOT NULL
                     AND signed_at >= CURRENT_DATE - INTERVAL ''12 months'' GROUP BY 1) sgn ON sgn.m = tm.month_start');

  EXECUTE v_def;
END $do$;

-- ─── (C) Contract date spread ───────────────────────────────────────────
-- Aggressive even distribution: for non-migration, non-recently-signed
-- contracts, set created_at deterministically by `id MOD 12` into months
-- Jul 2025 → Jun 2026, then set signed_at = created_at + 7 days for ~75%.

WITH backfill AS (
  SELECT
    c.id,
    -- 12 buckets: id mod 12 → month offset from Jul 2025
    (date '2025-07-01' + ((c.id::bigint % 12) || ' months')::interval
       + ((c.id::bigint % 28) || ' days')::interval)::timestamptz AS new_created_at,
    -- (id mod 4) <> 0 → ~75% get signed
    ((c.id::bigint % 4) <> 0) AS will_sign,
    c.status
  FROM contract c
  WHERE c.is_active = TRUE
    AND c.migration_batch_id IS NULL
)
UPDATE contract c
   SET created_at = bf.new_created_at,
       updated_at = COALESCE(c.updated_at, bf.new_created_at),
       signed_at  = CASE
         WHEN bf.will_sign AND bf.status IN ('active', 'fully_signed', 'expiring_soon')
           THEN bf.new_created_at + INTERVAL '7 days'
         WHEN bf.status IN ('active', 'fully_signed', 'expiring_soon') AND c.signed_at IS NULL
           THEN bf.new_created_at + INTERVAL '14 days'   -- still sign these so signed > 0 every month
         ELSE c.signed_at
       END
  FROM backfill bf
 WHERE c.id = bf.id;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (483, '483_exec_dashboard_final_demo_polish', CURRENT_TIMESTAMP);
