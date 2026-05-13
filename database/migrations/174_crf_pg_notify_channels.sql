-- Migration: 174_crf_pg_notify_channels.sql
-- Module: M14 — CR-F (5-Dim Risk Scoring + MaR + AVaR)
-- Description: Informational verification ping for new channel 'correlation_inserted'.
--   Mirrors migration 158 idiom (osint_signal_inserted + correlation_rule_changed channels).
--   No DDL changes. Channel-name collision check: confirmed 'correlation_inserted' is absent from
--   migrations 158 and earlier (existing channels: correlation_rule_changed + osint_signal_inserted +
--   contract.ingested). No naming collision.
--   The channel is emitted by fn_rule_evaluate (migration 172) post-LOOP when v_inserted > 0.
--   Consumed by score-recompute.worker.ts (Agent 7 — CR-F) subscribing via LISTEN.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
BEGIN
  PERFORM pg_notify(
    'correlation_inserted',
    '{"verify":true,"source":"migration_174","channel":"correlation_inserted","description":"CR-F new channel — emitted by fn_rule_evaluate post-LOOP when v_inserted > 0. score-recompute.worker.ts (CR-F) subscribes via LISTEN."}'
  );
  RAISE NOTICE '174: pg_notify(correlation_inserted) verification ping emitted OK.';
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (174, '174_crf_pg_notify_channels', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 174;
-- [No DDL to undo — pg_notify is fire-and-forget; channel disappears when no subscribers remain]
-- ============================================================
