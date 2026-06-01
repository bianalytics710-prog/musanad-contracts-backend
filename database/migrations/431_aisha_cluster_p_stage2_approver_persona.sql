-- Migration: 431_aisha_cluster_p_stage2_approver_persona.sql
-- Unit: Aisha Approver PM-grade audit fix pass (2026-06-01) — Cluster P follow-up
-- Defect addressed:
--   A38 (follow-up) — fn_approval_delegate_candidates returns an empty list
--                     for Aisha because she's currently the ONLY active
--                     contract_approver. Seed a Stage-2 approver persona
--                     so the picker has at least one peer and the demo
--                     can exercise the Delegate happy-path end-to-end.
-- Behaviour: idempotently insert one contract_approver user (Sarah Stage)
-- with the same password hash pattern as the other demo personas (the
-- bcrypt(ChangeMe@123) hash is the standard demo password).
-- Test-branch-safe: WHERE NOT EXISTS guard; role lookup is null-safe.
-- Rollback: DELETE the seeded user row + persona button entry.

BEGIN;

DO $$
DECLARE
  v_tenant UUID;
  v_role_id BIGINT;
  v_existing INT;
BEGIN
  SELECT id INTO v_tenant FROM tenant ORDER BY created_at LIMIT 1;
  SELECT id INTO v_role_id FROM role WHERE name = 'contract_approver' LIMIT 1;
  IF v_role_id IS NULL THEN
    RAISE NOTICE '431 A38-follow-up: contract_approver role missing — skipping.';
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_existing FROM "user" WHERE email = 'approver2@musanad.local';
  IF v_existing > 0 THEN
    RAISE NOTICE '431 A38-follow-up: Stage-2 approver persona already exists — skipping.';
    RETURN;
  END IF;

  -- Schema note: the "user" table does NOT carry tenant_id (single-tenant
  -- demo); insert only the columns that exist.
  INSERT INTO "user" (
    email, password_hash, first_name, last_name,
    role_id, is_active, created_at, updated_at, created_by, updated_by
  ) VALUES (
    'approver2@musanad.local',
    -- bcrypt hash for "ChangeMe@123" (same password as all other demo personas).
    '$2b$12$5UNT0iuxc2DT9Hgmt/Re5OK6dTw5TY7JrXwwI7zXkLbXrnYJlVvyq',
    'Sarah', 'Stage', v_role_id, TRUE, NOW(), NOW(), 1, 1
  );

  RAISE NOTICE '431 A38-follow-up: seeded Stage-2 approver persona (sarah.stage@musanad.local).';
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (431, 'A38 follow-up Aisha — seed Stage-2 approver peer for Delegate picker', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
--   DELETE FROM "user" WHERE email='approver2@musanad.local';
--   DELETE FROM schema_migrations WHERE version=431;
-- COMMIT;
-- ROLLBACK END
