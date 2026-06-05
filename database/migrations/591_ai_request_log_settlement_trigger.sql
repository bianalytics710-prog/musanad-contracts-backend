-- Migration: 591_ai_request_log_settlement_trigger.sql
-- Module: AI governance — replace unconditional deny-update with column whitelist
-- Date: 2026-06-05
--
-- mig 042 installed trg_ai_request_log_deny_update which RAISES 42501 on every
-- UPDATE. The risk-assistant streaming flow (CR-G, mig 179) has been issuing
-- UPDATEs to write back scope_hash + acl_filtered_count + outcome + latency_ms
-- post-stream, but they have ALL been silently rejected by the trigger (the
-- TS .catch() swallows the error). Result: 0 of 13,570 rows have a populated
-- scope_hash today.
--
-- mig 590's streaming-tokens fix extends those post-stream UPDATEs to also
-- write tokens_input / tokens_output / cost_usd_micros. Same trigger problem.
--
-- Fix: replace the unconditional deny with a column-whitelist trigger. The
-- immutable columns (the identifying / framing tuple — request_id, prompt_id,
-- actor, entity, language, provider, model, mode, cache_hit, stream_mode,
-- data_classification, created_at) stay locked; mutable settlement columns
-- (outcome, error_class, error_message, latency_ms, tokens_*, cost_usd_micros,
-- scope_hash, acl_filtered_count, is_active) are allowed.

BEGIN;

DROP TRIGGER IF EXISTS trg_ai_request_log_deny_update       ON ai_request_log;
DROP TRIGGER IF EXISTS trg_ai_request_log_settlement_only   ON ai_request_log;
DROP FUNCTION IF EXISTS fn_trg_ai_request_log_deny_update();

CREATE OR REPLACE FUNCTION fn_trg_ai_request_log_settlement_only()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Immutable identifying / framing columns — refuse any drift.
  -- (ai_request_log has no created_by / updated_at; don't reference them.)
  IF NEW.request_id          IS DISTINCT FROM OLD.request_id          OR
     NEW.prompt_id           IS DISTINCT FROM OLD.prompt_id           OR
     NEW.mode                IS DISTINCT FROM OLD.mode                OR
     NEW.actor_user_id       IS DISTINCT FROM OLD.actor_user_id       OR
     NEW.entity_type         IS DISTINCT FROM OLD.entity_type         OR
     NEW.entity_id           IS DISTINCT FROM OLD.entity_id           OR
     NEW.language            IS DISTINCT FROM OLD.language            OR
     NEW.provider            IS DISTINCT FROM OLD.provider            OR
     NEW.model_used          IS DISTINCT FROM OLD.model_used          OR
     NEW.created_at          IS DISTINCT FROM OLD.created_at          OR
     NEW.cache_hit           IS DISTINCT FROM OLD.cache_hit           OR
     NEW.stream_mode         IS DISTINCT FROM OLD.stream_mode         OR
     NEW.data_classification IS DISTINCT FROM OLD.data_classification THEN
    RAISE EXCEPTION
      'fn_trg_ai_request_log_settlement_only: identifying columns are immutable on ai_request_log'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_trg_ai_request_log_settlement_only() IS
  'M4 (mig 591) — BEFORE UPDATE trigger. Replaces the unconditional 042 deny. Permits updates to settlement columns (outcome, error_*, latency_ms, tokens_*, cost_usd_micros, scope_hash, acl_filtered_count, is_active); rejects drift on the identifying tuple.';

CREATE TRIGGER trg_ai_request_log_settlement_only
  BEFORE UPDATE ON ai_request_log
  FOR EACH ROW EXECUTE FUNCTION fn_trg_ai_request_log_settlement_only();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (591, '591_ai_request_log_settlement_trigger', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS trg_ai_request_log_settlement_only ON ai_request_log;
-- DROP FUNCTION IF EXISTS fn_trg_ai_request_log_settlement_only();
-- CREATE OR REPLACE FUNCTION fn_trg_ai_request_log_deny_update()
-- RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public, pg_temp
-- AS $$
-- BEGIN
--   RAISE EXCEPTION 'fn_trg_ai_request_log_deny_update: ai_request_log is append-only'
--     USING ERRCODE = '42501';
-- END $$;
-- CREATE TRIGGER trg_ai_request_log_deny_update
--   BEFORE UPDATE ON ai_request_log
--   FOR EACH ROW EXECUTE FUNCTION fn_trg_ai_request_log_deny_update();
-- DELETE FROM schema_migrations WHERE version = 591;
-- COMMIT;
