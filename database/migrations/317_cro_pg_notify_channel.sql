-- Migration: 317_cro_pg_notify_channel.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: Informational verification ping for new channel 'margin_recompute_requested'.
--   Mirrors mig 174 idiom (CR-F — correlation_inserted channel registration/documentation).
--   No DDL changes. Channel-name collision check: confirmed 'margin_recompute_requested' is absent
--   from migrations 158/174 and earlier.
--   Existing channels: correlation_inserted (mig 174), osint_signal_inserted + correlation_rule_changed
--   (mig 158), contract.ingested (earlier), score_recompute_requested (mig 175 CR-F).
--   No naming collision with 'margin_recompute_requested'.
--   The channel is emitted by fn_margin_recompute_for_price_change (mig 315 D-2) via pg_notify.
--   Consumed by margin-recompute.worker.ts (BE Impl — mirrors score-recompute.worker.ts).
--   Worker is ENV-GATED: MARGIN_RECOMPUTE_WORKER_ENABLED (default off) — demo path is synchronous POST.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
BEGIN
  PERFORM pg_notify(
    'margin_recompute_requested',
    '{"verify":true,"source":"migration_317","channel":"margin_recompute_requested","description":"CR-O new channel — emitted by fn_margin_recompute_for_price_change (mig 315 D-2) when benchmark price changes and open forward positions are recomputed. margin-recompute.worker.ts (CR-O BE Impl) subscribes via LISTEN. Worker off by default (MARGIN_RECOMPUTE_WORKER_ENABLED). Demo path is synchronous POST /price-benchmarks/recompute."}'
  );
  RAISE NOTICE '317: pg_notify(margin_recompute_requested) verification ping emitted OK.';
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (317, '317_cro_pg_notify_channel', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 317;
-- [No DDL to undo — pg_notify is fire-and-forget; channel disappears when no subscribers remain]
-- ============================================================
