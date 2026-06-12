-- Migration: 617_drop_fn_contract_list_legacy_overload.sql
-- Module: AI Risk Assistant fix
-- Date: 2026-06-11
--
-- Migration 562 added p_risk_bucket as the 22nd parameter to
-- fn_contract_list, creating a CREATE OR REPLACE on a NEW signature
-- rather than replacing the existing one. The result: Postgres holds
-- TWO overloads of fn_contract_list:
--   - 21 args  (legacy, pre-mig 562)
--   - 22 args  (canonical, with p_risk_bucket)
--
-- The AI Risk Assistant service (risk-assistant.service.ts) still
-- positionally passes 21 arguments and binds them all as `unknown` via
-- node-postgres. Postgres cannot disambiguate between the two overloads
-- and errors with:
--   function fn_contract_list(unknown, ... x21) is not unique
--
-- This breaks every AI Risk Assistant chat invocation. The Contracts
-- controller is unaffected because mig 517 updated it to pass all 22
-- args including the trailing p_risk_bucket.
--
-- Fix: drop the legacy 21-arg signature so only the canonical 22-arg
-- version remains. The Risk Assistant service is patched in the same
-- changeset to pass the 22nd arg (NULL).
--
-- Rollback block at the bottom recreates the 21-arg shim that simply
-- forwards to the 22-arg canonical function with NULL risk_bucket — so
-- a rollback restores call resolution for any historical caller.

BEGIN;

-- ------------------------------------------------------------------
-- Drop the legacy 21-arg overload.
-- ------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.fn_contract_list(
  integer,   -- p_page
  integer,   -- p_limit
  text,      -- p_status
  text,      -- p_contract_type
  bigint,    -- p_counterparty_id
  bigint,    -- p_drafted_by
  bigint,    -- p_approved_by
  date,      -- p_start_date_from
  date,      -- p_start_date_to
  date,      -- p_end_date_from
  date,      -- p_end_date_to
  text[],    -- p_tags
  text,      -- p_search
  bigint,    -- p_actor_id
  text,      -- p_actor_role
  bigint,    -- p_import_batch_id
  integer,   -- p_import_confidence_min
  integer,   -- p_import_confidence_max
  text,      -- p_language
  text,      -- p_governing_law
  text       -- p_sort
);

-- ------------------------------------------------------------------
-- Sanity: confirm exactly one overload remains.
-- ------------------------------------------------------------------
DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'fn_contract_list';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly 1 fn_contract_list overload after drop, found %', v_count;
  END IF;
END $$;

COMMIT;

-- ==================================================================
-- ROLLBACK (manual only — not auto-applied):
-- ==================================================================
-- BEGIN;
-- CREATE OR REPLACE FUNCTION public.fn_contract_list(
--   p_page integer, p_limit integer, p_status text, p_contract_type text,
--   p_counterparty_id bigint, p_drafted_by bigint, p_approved_by bigint,
--   p_start_date_from date, p_start_date_to date,
--   p_end_date_from date, p_end_date_to date,
--   p_tags text[], p_search text,
--   p_actor_id bigint, p_actor_role text,
--   p_import_batch_id bigint, p_import_confidence_min integer, p_import_confidence_max integer,
--   p_language text, p_governing_law text, p_sort text
-- ) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $shim$
--   SELECT public.fn_contract_list(
--     p_page, p_limit, p_status, p_contract_type, p_counterparty_id,
--     p_drafted_by, p_approved_by, p_start_date_from, p_start_date_to,
--     p_end_date_from, p_end_date_to, p_tags, p_search,
--     p_actor_id, p_actor_role, p_import_batch_id,
--     p_import_confidence_min, p_import_confidence_max,
--     p_language, p_governing_law, p_sort, NULL::text
--   );
-- $shim$;
-- COMMIT;
