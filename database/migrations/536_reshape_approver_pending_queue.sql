-- MIGRATION: 536_reshape_approver_pending_queue.sql
-- Date: 2026-06-03
-- Description:
--   Reshape each approver's pending queue to a balanced demo state — 5
--   contracts waiting, exactly one overdue past the 48h SLA.
--
--   Steps:
--     1. Soft-cancel every currently-pending chain assigned to the approver
--        personas. (status='cancelled', is_active=FALSE on chains so they
--        drop out of dashboard queries; their decision history stays.)
--     2. Insert 5 fresh in-progress chains per approver with controlled
--        hoursWaiting values: 96h overdue + 12h / 24h / 36h / 44h within
--        SLA.
--
--   Idempotent: re-running cancels any chains seeded by a prior run before
--   inserting again.

BEGIN;

DO $reshape$
DECLARE
  v_approvers        BIGINT[];
  v_approver_id      BIGINT;
  v_contracts        BIGINT[];
  v_target_hours     INTEGER[] := ARRAY[96, 12, 24, 36, 44];
  v_hours            INTEGER;
  v_idx              INTEGER;
  v_contract_id      BIGINT;
  v_chain_id         BIGINT;
  v_step_id          BIGINT;
  v_created_at       TIMESTAMPTZ;
BEGIN
  -- Approvers (contract_approver, contract_approver_2).
  SELECT array_agg(u.id) INTO v_approvers
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE r.name IN ('contract_approver', 'contract_approver_2')
     AND u.is_active = TRUE;

  IF v_approvers IS NULL THEN
    RAISE EXCEPTION 'reshape: no approvers found';
  END IF;

  -- Cancel ALL currently-pending chains assigned to these approvers.
  UPDATE approval_step
     SET status = 'skipped', decided_at = fn_demo_now()
   WHERE COALESCE(delegated_to, reassigned_to, approver_user_id) = ANY(v_approvers)
     AND status = 'pending' AND is_active = TRUE;

  UPDATE approval_chain ch
     SET status = 'cancelled', completed_at = fn_demo_now(), is_active = FALSE
    FROM approval_step step
   WHERE step.approval_chain_id = ch.id
     AND step.approver_user_id = ANY(v_approvers)
     AND ch.is_active = TRUE
     AND ch.status = 'in_progress';

  -- Eligible contracts to attach fresh queues to. Avoid:
  --  - the contracts that already have history (5..9, 25, 26, 27 — those
  --    show decisions and could double-up confusingly)
  --  - any contracts currently in an active in-progress chain
  SELECT array_agg(id ORDER BY id)
    INTO v_contracts
    FROM (
      SELECT c.id
        FROM contract c
       WHERE c.is_active = TRUE
         AND c.id NOT IN (5, 6, 7, 8, 9, 25, 26, 27)
         AND NOT EXISTS (
           SELECT 1 FROM approval_chain ch
            WHERE ch.contract_id = c.id
              AND ch.is_active = TRUE
              AND ch.status = 'in_progress'
         )
       ORDER BY c.id
       LIMIT 200
    ) t;

  IF v_contracts IS NULL OR array_length(v_contracts, 1) < array_length(v_approvers, 1) * 5 THEN
    RAISE EXCEPTION 'reshape: not enough free contracts (% found)', COALESCE(array_length(v_contracts, 1), 0);
  END IF;

  v_idx := 1;

  FOREACH v_approver_id IN ARRAY v_approvers LOOP

    FOR i IN 1 .. array_length(v_target_hours, 1) LOOP
      v_hours := v_target_hours[i];
      v_contract_id := v_contracts[v_idx];
      v_idx := v_idx + 1;

      v_created_at := fn_demo_now() - (v_hours || ' hours')::interval;

      INSERT INTO approval_chain
        (contract_id, matrix_snapshot, status, current_step_order, initiated_by,
         initiated_at, data_classification, is_active, created_at, updated_at)
      VALUES
        (v_contract_id,
         jsonb_build_object('synthetic', TRUE, 'seedMigration', 536),
         'in_progress', 1, 1,
         v_created_at,
         'demo', TRUE, v_created_at, v_created_at)
      RETURNING id INTO v_chain_id;

      INSERT INTO approval_step
        (approval_chain_id, step_order, parallel_group, approver_role, approver_user_id,
         status, is_required, data_classification, is_active, created_at, updated_at)
      VALUES
        (v_chain_id, 1, NULL, 'contract_approver', v_approver_id,
         'pending', TRUE, 'demo', TRUE, v_created_at, v_created_at);
    END LOOP;

  END LOOP;
END;
$reshape$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (536, 'reshape_approver_pending_queue', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
