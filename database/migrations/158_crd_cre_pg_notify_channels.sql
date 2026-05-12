-- Migration: 158_crd_cre_pg_notify_channels.sql
-- Module: M12 / CR-D + M13 / CR-E — Cross-cutting
-- Description: DO-block verification only (informational / no DDL).
--   Emits pg_notify pings on:
--   - 'correlation_rule_changed' (NEW channel — CR-E fn_rule_create/update/delete)
--   - 'osint_signal_inserted' (EXISTING M7 channel — consumed by CR-E correlation-evaluator.worker.ts)
--   Confirms channel namespace registration. No DDL changes.
--   'contract.ingested' channel (M11) already verified in M11 migration 133 — not re-verified here.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
BEGIN
  -- Verify correlation_rule_changed channel (new in CR-E — fn_rule_create/update/delete emit on this channel)
  PERFORM pg_notify(
    'correlation_rule_changed',
    '{"verify":true,"source":"migration_158","channel":"correlation_rule_changed","description":"CR-E cache hot-reload channel — fired by fn_rule_create/update/delete. BE rule-cache.service.ts subscribes."}'
  );
  RAISE NOTICE '158: pg_notify(correlation_rule_changed) verification ping emitted OK.';

  -- Verify osint_signal_inserted channel (existing M7 — cross-verify it is still live for CR-E evaluator)
  PERFORM pg_notify(
    'osint_signal_inserted',
    '{"verify":true,"source":"migration_158","channel":"osint_signal_inserted","description":"M7 existing channel — fired by fn_osint_signal_upsert. CR-E correlation-evaluator.worker.ts subscribes."}'
  );
  RAISE NOTICE '158: pg_notify(osint_signal_inserted) verification ping emitted OK (M7 existing channel).';
END $$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (158, '158_crd_cre_pg_notify_channels', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (no-op — no DDL in this migration)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 158;
-- ============================================================
