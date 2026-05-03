-- ============================================================================
-- 014_m1b_fix_payment_schedule_rls_with_check.sql — Codex BE-M1b-006
-- ============================================================================
-- Module:    M1b (post-Codex round-1 fix)
-- Depends:   009 (payment_schedule + RLS policies)
-- ----------------------------------------------------------------------------
-- Codex flagged that payment_schedule_update_parent_writable's WITH CHECK
-- clause is `(TRUE)`. Postgres applies WITH CHECK to the *post-image* of an
-- UPDATE; with a permissive check, a user with edit-rights on contract A
-- can reassign one of their own payment_schedule rows to contract B's
-- contract_id (privilege escalation: I edit my own schedule, then re-point
-- the rows to your contract).
--
-- Fix: drop the policy and recreate it with WITH CHECK mirroring USING —
-- the post-image must satisfy the same parent-visibility predicate as the
-- pre-image, so reassignment to a contract the caller cannot edit is
-- denied at write time.
-- ----------------------------------------------------------------------------

BEGIN;

DROP POLICY IF EXISTS payment_schedule_update_parent_writable ON payment_schedule;

CREATE POLICY payment_schedule_update_parent_writable ON payment_schedule
  FOR UPDATE USING (
    is_active = TRUE
    AND EXISTS (SELECT 1 FROM contract c WHERE c.id = payment_schedule.contract_id AND c.is_active = TRUE)
    AND (
      fn_current_user_has_permission('contract.edit')
      OR (
        fn_current_user_has_permission('contract.draft')
        AND EXISTS (
          SELECT 1 FROM contract c
          WHERE c.id = payment_schedule.contract_id
            AND c.drafted_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND c.status IN ('draft','resubmission_requested')
        )
      )
    )
  )
  WITH CHECK (
    -- Post-image must point at a contract the caller can write to under the
    -- same predicate set used for USING. This blocks contract_id reassignment
    -- (Codex BE-M1b-006). is_active = TRUE excluded from WITH CHECK so soft-
    -- delete-style updates remain feasible.
    EXISTS (SELECT 1 FROM contract c WHERE c.id = payment_schedule.contract_id AND c.is_active = TRUE)
    AND (
      fn_current_user_has_permission('contract.edit')
      OR (
        fn_current_user_has_permission('contract.draft')
        AND EXISTS (
          SELECT 1 FROM contract c
          WHERE c.id = payment_schedule.contract_id
            AND c.drafted_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND c.status IN ('draft','resubmission_requested')
        )
      )
    )
  );

COMMENT ON POLICY payment_schedule_update_parent_writable ON payment_schedule IS
  'M1b UPDATE policy. USING enforces that the caller can edit the row''s current parent contract. WITH CHECK enforces that the post-image (after UPDATE) still points at a contract the caller can edit — Codex BE-M1b-006 fix prevents privilege escalation via contract_id reassignment.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (14, 'm1b_fix_payment_schedule_rls_with_check', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 014_m1b_fix_payment_schedule_rls_with_check.sql
-- ============================================================================
-- ROLLBACK BEGIN
BEGIN;
  DROP POLICY IF EXISTS payment_schedule_update_parent_writable ON payment_schedule;
  -- Restore the 009 version with WITH CHECK (TRUE).
  CREATE POLICY payment_schedule_update_parent_writable ON payment_schedule
    FOR UPDATE USING (
      is_active = TRUE
      AND EXISTS (SELECT 1 FROM contract c WHERE c.id = payment_schedule.contract_id AND c.is_active = TRUE)
      AND (
        fn_current_user_has_permission('contract.edit')
        OR (
          fn_current_user_has_permission('contract.draft')
          AND EXISTS (
            SELECT 1 FROM contract c
            WHERE c.id = payment_schedule.contract_id
              AND c.drafted_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
              AND c.status IN ('draft','resubmission_requested')
          )
        )
      )
    )
    WITH CHECK (TRUE);
  DELETE FROM schema_migrations WHERE version = 14;
COMMIT;
-- ROLLBACK END
