-- ============================================================================
-- 010_m1b_extend_m1a.sql — M1b cross-module writes against M1a + M0
-- ============================================================================
-- Module:    M1b
-- Depends:   003_m1a_contracts.sql (contract_activity table + 7-value CHECK enum +
--                                   contract.export permission + contract_drafter role)
-- ----------------------------------------------------------------------------
-- CMW-1: Extend contract_activity.activity_type CHECK enum 7→9 values.
--        M1a's CHECK constraint is autonamed; lookup name dynamically via
--        pg_constraint, DROP it, ADD with stable name (W3).
-- CMW-2: Grant contract.export to contract_drafter via role_permission row
--        (Q7). Idempotent via ON CONFLICT (role_id, permission_id) DO NOTHING.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- CMW-1 — contract_activity activity_type enum 7 → 9 values
-- ============================================================
-- M1a's CREATE TABLE contract_activity created an anonymous CHECK constraint
-- (Postgres auto-named, conventionally contract_activity_activity_type_check
--  but not guaranteed — VERIFY at apply time per W3).
-- We look it up via pg_constraint to be safe, then DROP + re-ADD with a
-- stable name so future modules (M2 will add 'approval_decided', M3 'signed',
-- etc.) can extend cleanly.

DO $$
DECLARE
  v_constraint_name TEXT;
BEGIN
  SELECT con.conname INTO v_constraint_name
    FROM pg_constraint con
    INNER JOIN pg_class      c  ON c.oid = con.conrelid
    INNER JOIN pg_attribute  a  ON a.attrelid = c.oid AND a.attnum = ANY(con.conkey)
    WHERE c.relname = 'contract_activity'
      AND a.attname = 'activity_type'
      AND con.contype = 'c'  -- CHECK
    LIMIT 1;

  IF v_constraint_name IS NULL THEN
    RAISE EXCEPTION 'M1b 010: cannot find existing CHECK constraint on contract_activity.activity_type — was M1a 003 applied?';
  END IF;

  EXECUTE format('ALTER TABLE contract_activity DROP CONSTRAINT %I', v_constraint_name);
END;
$$;

-- Add the new CHECK with a stable name. Strictly additive: 7 original values + 2 new.
ALTER TABLE contract_activity
  ADD CONSTRAINT contract_activity_activity_type_check
  CHECK (activity_type IN (
    'created',
    'updated',
    'status_changed',
    'version_created',
    'tagged',
    'soft_deleted',
    'restored',
    'payment_schedule_replaced',  -- NEW (M1b)
    'exported'                    -- NEW (M1b)
  ));

COMMENT ON CONSTRAINT contract_activity_activity_type_check ON contract_activity IS
  'M1b 010 stable name. Future modules (M2 approval_decided, M3 signed, etc.) extend by DROP + ADD this constraint by its known name. See M1a 003 contract_activity COMMENT for the canonical extension protocol.';

-- ============================================================
-- CMW-2 — Grant contract.export to contract_drafter (Q7)
-- ============================================================
-- M1a explicitly anticipated this grant: contract.export permission was seeded
-- in M1a 003 with description noting it is "Required by M1b but defined in M1a
-- so role seeds reference it." This adds the actual junction row.

INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
  FROM role r
  CROSS JOIN permission p
  WHERE r.name = 'contract_drafter'
    AND p.code = 'contract.export'
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ============================================================
-- Record migration
-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (10, 'm1b_extend_m1a', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 010_m1b_extend_m1a.sql
-- ============================================================================
-- IMPORTANT: rollback only safe if no contract_activity rows with the new
-- enum values ('payment_schedule_replaced','exported') exist. Migration 011
-- and any production runtime emit them; rollback must run AFTER 011 rollback
-- AND with no live traffic. Aborts if rows present (operator must clean first).
-- ROLLBACK BEGIN
BEGIN;
  -- Guard: refuse rollback if extended values are in use (would otherwise
  -- create a CHECK violation when we ADD the original 7-value constraint).
  DO $$
  DECLARE v_count BIGINT;
  BEGIN
    SELECT COUNT(*) INTO v_count
      FROM contract_activity
      WHERE activity_type IN ('payment_schedule_replaced','exported');
    IF v_count > 0 THEN
      RAISE EXCEPTION 'M1b 010 rollback: refusing — % contract_activity rows use M1b-only enum values. Delete or migrate them first.', v_count;
    END IF;
  END;
  $$;

  -- Drop M1b stable-name CHECK; re-add the M1a-style anonymous-equivalent
  -- (we give it a temporary name we will not rely on, since the original
  -- was anonymous; M1a 003 rollback drops the entire table anyway, so this
  -- is a transitional shape).
  ALTER TABLE contract_activity DROP CONSTRAINT IF EXISTS contract_activity_activity_type_check;
  ALTER TABLE contract_activity
    ADD CONSTRAINT contract_activity_activity_type_check_m1a_restore
    CHECK (activity_type IN (
      'created','updated','status_changed','version_created','tagged','soft_deleted','restored'
    ));

  -- CMW-2 rollback: remove the drafter ↔ contract.export grant
  DELETE FROM role_permission
    WHERE role_id = (SELECT id FROM role WHERE name = 'contract_drafter')
      AND permission_id = (SELECT id FROM permission WHERE code = 'contract.export');

  DELETE FROM schema_migrations WHERE version = 10;
COMMIT;
-- ROLLBACK END
