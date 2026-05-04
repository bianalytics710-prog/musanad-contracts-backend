-- ============================================================================
-- 021_m1c_fix_rls_anti_reassignment.sql
--   M1c Codex BE round-1 follow-up: replace self-referencing RLS subqueries
--   on import_batch with a BEFORE UPDATE trigger.
-- ============================================================================
-- Module:    M1c (Bulk & Manual Import) — Codex BE round-1 patch (Finding C1)
-- Owner:     DB Implementation Agent (Agent 6, bug-fix mode — cycle 3)
-- Depends:   001..020 (M0 + M1a + M1b + M1c base + M1c cycle-1 + cycle-2).
--            Targets policies created in 016_m1c_import_batch.sql.
-- ----------------------------------------------------------------------------
-- Why this migration exists (Codex BE round-1, finding C1 — CRITICAL):
--
-- Migration 016 created two RLS policies on import_batch that embedded a
-- self-referencing SELECT against the same table inside their USING/WITH CHECK
-- clauses:
--
--   import_batch_update_runner_or_admin (PERMISSIVE UPDATE):
--     WITH CHECK (...
--       AND initiated_by =
--           (SELECT b.initiated_by FROM import_batch b WHERE b.id = import_batch.id)
--     )
--
--   import_batch_deny_direct_is_active_update (RESTRICTIVE UPDATE):
--     WITH CHECK (
--       is_active =
--           (SELECT b.is_active FROM import_batch b WHERE b.id = import_batch.id)
--     )
--
-- Two defects:
--
--   (a) Under FORCE ROW LEVEL SECURITY (which 016 sets), those self-
--       referencing SELECTs themselves trigger RLS re-evaluation. Either
--       Postgres recurses (rare in practice — the planner usually flattens it)
--       or, more commonly, the inner SELECT comes back empty because the
--       inner row itself has not committed yet during the WITH CHECK
--       evaluation. Either way, every legitimate UPDATE is blocked.
--
--   (b) Even ignoring (a), `import_batch.id` inside the inner SELECT is
--       NOT guaranteed to resolve to the OLD pre-image — the planner can
--       resolve it against NEW. The intent is "compare post-image to pre-
--       image", which a subquery cannot reliably express. Only a BEFORE
--       UPDATE trigger sees both OLD and NEW rows directly.
--
-- This anti-pattern family is the same one Codex flagged as BE-M1b-006 in
-- the M1b round; recurring here under a new mechanism (anti-reassignment
-- guard via subquery, not policy WITH CHECK = TRUE).
--
-- Fix:
--
--   (1) Create a BEFORE UPDATE trigger fn_trg_import_batch_immutable_fields
--       that compares OLD vs NEW directly. RAISEs SQLSTATE 42501 when
--       initiated_by or is_active is being changed. The BE translatePgError
--       maps 42501 → 403 Forbidden.
--
--   (2) ALTER POLICY import_batch_update_runner_or_admin to drop the
--       self-referencing WITH CHECK clause; keep the role + ownership check.
--
--   (3) DROP the import_batch_deny_direct_is_active_update policy entirely
--       — the trigger now enforces the same invariant cleanly.
--
-- Net behaviour preserved:
--   • UPDATE that changes initiated_by → trigger raises 42501 → BE → 403
--   • UPDATE that changes is_active → trigger raises 42501 → BE → 403
--   • UPDATE that legitimately changes status / counters / completed_at →
--     ok (admin or initiator only — RLS policy still enforces that)
--   • Hard DELETE → still blocked by import_batch_deny_direct_delete
--     (RESTRICTIVE FOR DELETE USING (FALSE)) — unchanged.
-- ----------------------------------------------------------------------------
-- Method: CREATE FUNCTION + CREATE TRIGGER + DROP POLICY + DROP+CREATE POLICY
-- ============================================================================

BEGIN;

-- ============================================================
-- 1. Trigger function — direct OLD vs NEW immutability check
-- ============================================================
CREATE OR REPLACE FUNCTION fn_trg_import_batch_immutable_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  -- initiated_by: cannot be reassigned after creation. Anti-takeover guard.
  IF NEW.initiated_by IS DISTINCT FROM OLD.initiated_by THEN
    RAISE EXCEPTION
      'fn_trg_import_batch_immutable_fields: initiated_by cannot be reassigned (was %, attempted %)',
      OLD.initiated_by, NEW.initiated_by
      USING ERRCODE = '42501';  -- insufficient_privilege; BE translatePgError → 403
  END IF;

  -- is_active: cannot be toggled directly. Cancellation goes through
  -- status='cancelled', not soft-delete. M1c has no fn_ that flips is_active.
  IF NEW.is_active IS DISTINCT FROM OLD.is_active THEN
    RAISE EXCEPTION
      'fn_trg_import_batch_immutable_fields: is_active cannot be toggled directly (use status=cancelled)'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION fn_trg_import_batch_immutable_fields() IS
  'M1c BEFORE UPDATE trigger function for import_batch. Replaces the '
  'self-referencing RLS subquery anti-pattern in 016 (Codex BE round-1 '
  'finding C1). Compares OLD vs NEW directly. RAISEs SQLSTATE 42501 '
  '(insufficient_privilege) when initiated_by or is_active is changed; BE '
  'translatePgError maps to 403.';

-- ============================================================
-- 2. Attach trigger to import_batch
-- ============================================================
DROP TRIGGER IF EXISTS trg_import_batch_immutable_fields ON import_batch;

CREATE TRIGGER trg_import_batch_immutable_fields
  BEFORE UPDATE ON import_batch
  FOR EACH ROW
  EXECUTE FUNCTION fn_trg_import_batch_immutable_fields();

-- ============================================================
-- 3. Replace import_batch_update_runner_or_admin — drop self-ref subquery
-- ============================================================
-- Prior WITH CHECK (016 lines 188-200):
--   is_active = TRUE
--   AND (admin-role OR initiated_by = current_user_id)
--   AND initiated_by = (SELECT b.initiated_by FROM import_batch b WHERE b.id = import_batch.id)  ← REMOVED
--
-- The trailing self-ref clause is now enforced by the trigger above.
-- Keep is_active = TRUE in WITH CHECK as a defense-in-depth signal — the
-- trigger prevents flipping it, but the WITH CHECK also blocks any post-
-- image row that has is_active=FALSE from passing policy evaluation.
DROP POLICY IF EXISTS import_batch_update_runner_or_admin ON import_batch;

CREATE POLICY import_batch_update_runner_or_admin ON import_batch
  AS PERMISSIVE
  FOR UPDATE
  USING (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
          INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin', 'legal_counsel', 'Super Admin')
      )
      OR initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
    )
  )
  WITH CHECK (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
          INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin', 'legal_counsel', 'Super Admin')
      )
      OR initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
    )
  );

COMMENT ON POLICY import_batch_update_runner_or_admin ON import_batch IS
  'M1c update gate. Admin role or initiator may update an active batch. '
  'Codex BE round-1 patch (021): the prior anti-reassignment clause '
  '(initiated_by = OLD.initiated_by via self-ref subquery) was removed and '
  'replaced by trg_import_batch_immutable_fields, which compares OLD vs NEW '
  'directly without triggering nested RLS evaluation.';

-- ============================================================
-- 4. Drop import_batch_deny_direct_is_active_update — trigger replaces it
-- ============================================================
-- The RESTRICTIVE policy enforced post-image is_active = pre-image is_active
-- via the same self-ref subquery anti-pattern. The trigger now enforces this
-- invariant cleanly. Dropping the policy is the cleanest fix; leaving it as
-- a tautology would be misleading dead code.
DROP POLICY IF EXISTS import_batch_deny_direct_is_active_update ON import_batch;

-- ============================================================
-- 5. Record migration
-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (21, 'm1c_fix_rls_anti_reassignment', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 021_m1c_fix_rls_anti_reassignment.sql
-- ============================================================================
-- Restores the 016-shape policies (self-referencing subquery anti-pattern)
-- and removes the trigger. Run this manually if 021 must be reversed; under
-- FORCE ROW LEVEL SECURITY the restored policies will likely block all
-- legitimate UPDATEs again. Not recommended.
-- ROLLBACK BEGIN
BEGIN;

DROP TRIGGER IF EXISTS trg_import_batch_immutable_fields ON import_batch;
DROP FUNCTION IF EXISTS fn_trg_import_batch_immutable_fields();

DROP POLICY IF EXISTS import_batch_update_runner_or_admin ON import_batch;

CREATE POLICY import_batch_update_runner_or_admin ON import_batch
  AS PERMISSIVE
  FOR UPDATE
  USING (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
          INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin', 'legal_counsel', 'Super Admin')
      )
      OR initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
    )
  )
  WITH CHECK (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
          INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin', 'legal_counsel', 'Super Admin')
      )
      OR initiated_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
    )
    AND initiated_by = (SELECT b.initiated_by FROM import_batch b WHERE b.id = import_batch.id)
  );

CREATE POLICY import_batch_deny_direct_is_active_update ON import_batch
  AS RESTRICTIVE
  FOR UPDATE
  USING (TRUE)
  WITH CHECK (
    is_active = (SELECT b.is_active FROM import_batch b WHERE b.id = import_batch.id)
  );

DELETE FROM schema_migrations WHERE version = 21;
COMMIT;
-- ROLLBACK END
