-- ================================================================
-- Migration 082 — R-DA9-3 fix: drop audit trigger from contract_watch
-- ================================================================
-- Up: BEGIN
-- 081 added audit_contract_watch_changes -> fn_audit_trigger, but
-- contract_watch is a junction table with composite PK (user_id,
-- contract_id) and no `id` column. fn_audit_trigger references
-- COALESCE(NEW.id, OLD.id), which causes:
--   "record \"new\" has no field \"id\""
-- on every INSERT/UPDATE/DELETE.
--
-- Fix: drop the trigger. contract_watch is a personal-preference
-- toggle (watch ON/OFF). Audit needs are already covered by
-- application-level activity entries when watching is meaningful;
-- raw row-level audit on a per-user toggle adds noise without
-- a forensic use case. Junction tables in this codebase are not
-- generally audited (e.g. impact_signal_contract is also unaudited).
-- ================================================================

DROP TRIGGER IF EXISTS audit_contract_watch_changes ON contract_watch;

-- ================================================================
-- Up: END
-- Down: BEGIN
-- ================================================================
-- CREATE TRIGGER audit_contract_watch_changes
--   AFTER INSERT OR UPDATE OR DELETE ON contract_watch
--   FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();
-- ================================================================
-- Down: END
