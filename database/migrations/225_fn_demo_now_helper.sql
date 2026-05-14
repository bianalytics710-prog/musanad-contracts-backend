-- Migration: 225_fn_demo_now_helper.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: fn_demo_now() STABLE INVOKER helper — single source of "now" for time-sensitive business logic.
--              Created FIRST so all time-freeze refactor consumers in migrations 240+ can reference it.
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_demo_now()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
  SELECT coalesce(
    NULLIF(current_setting('app.demo.time_now', true), '')::timestamptz,
    now()
  );
$$;

COMMENT ON FUNCTION fn_demo_now() IS 'STABLE helper: returns app.demo.time_now GUC if set, else now(). Single source of time for time-sensitive business logic. Audit columns continue to use raw now().';
REVOKE EXECUTE ON FUNCTION fn_demo_now() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_now() TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (225, '225_fn_demo_now_helper', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 225;
-- DROP FUNCTION IF EXISTS fn_demo_now();
-- ============================================================
