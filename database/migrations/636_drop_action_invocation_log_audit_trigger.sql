-- MIGRATION: 636_drop_action_invocation_log_audit_trigger.sql
-- Date: 2026-06-12
-- Module: AI Chat Actions — fix
-- Description:
--   action_invocation_log is itself an append-only audit log of chat
--   actions. The fn_audit_trigger we attached in mig 635 duplicates that
--   audit into audit_log, and audit_log's CR-C tamper-chain (prev_hash
--   NOT NULL constraint) breaks when called via the fn_audit_trigger
--   path that doesn't compute the chain. Drop the trigger — the table's
--   own append-only model + DELETE policy is the audit trail.

BEGIN;

DROP TRIGGER IF EXISTS audit_action_invocation_log_changes ON public.action_invocation_log;

COMMIT;
