-- MIGRATION: 535_seed_approver_decisions.sql
-- Date: 2026-06-03
-- Description:
--   Seed realistic decision history for the approver personas so the
--   "Decision velocity" + "Decision mix" + "Recent decisions" widgets
--   render meaningful counts.
--
--   For each approver:
--     - 24 approvals
--     - 6 rejections
--     - 4 info-requested
--   spread across the last 90 days with varied decision durations
--   (between 2h and 72h waiting).
--
--   Each seed decision creates a full approval_chain → approval_step →
--   approval_decision row triple so RLS + downstream joins behave like
--   real history. Chains are marked status='approved' (or matching
--   terminal) with completed_at populated.

BEGIN;

DO $seed$
DECLARE
  v_actor             BIGINT;
  v_contract_ids      BIGINT[];
  v_contract_id       BIGINT;
  v_n                 INTEGER;
  v_decision_text     TEXT;
  v_step_status       TEXT;
  v_chain_status      TEXT;
  v_decided_at        TIMESTAMPTZ;
  v_step_created_at   TIMESTAMPTZ;
  v_hours_waiting     NUMERIC;
  v_chain_id          BIGINT;
  v_step_id           BIGINT;
  v_note              TEXT;
  v_mix               JSONB;
  v_i                 INTEGER;
  v_approvers         BIGINT[];
  v_approver_id       BIGINT;
BEGIN
  -- Eligible contracts to attach synthetic chains to. Use ones that already
  -- exist and are active — chain rows on them are independent of any other
  -- chain because chains are not unique per contract.
  SELECT array_agg(id) INTO v_contract_ids
    FROM (
      SELECT id FROM contract
       WHERE is_active = TRUE
         AND id NOT IN (5, 6, 7, 8, 9, 25, 26, 27)
       ORDER BY id
       LIMIT 100
    ) c;

  IF v_contract_ids IS NULL OR array_length(v_contract_ids, 1) < 30 THEN
    RAISE EXCEPTION 'seed: not enough candidate contracts (% found)', COALESCE(array_length(v_contract_ids, 1), 0);
  END IF;

  -- Approvers to seed. Aisha Al Nahyan (user_id depends on seed order).
  SELECT array_agg(u.id) INTO v_approvers
    FROM "user" u
    JOIN role r ON r.id = u.role_id
   WHERE r.name IN ('contract_approver', 'contract_approver_2')
     AND u.is_active = TRUE;

  IF v_approvers IS NULL THEN
    RAISE EXCEPTION 'seed: no approver users found';
  END IF;

  -- Build per-approver decision distribution.
  -- 24 approve, 6 reject, 4 request_info per approver. We label them and
  -- then iterate.
  v_mix := jsonb_build_array(
    -- (decision, count)
    jsonb_build_object('decision', 'approve',      'n', 24),
    jsonb_build_object('decision', 'reject',       'n', 6),
    jsonb_build_object('decision', 'request_info', 'n', 4)
  );

  FOREACH v_approver_id IN ARRAY v_approvers LOOP

    FOR v_n IN 0 .. jsonb_array_length(v_mix) - 1 LOOP
      v_decision_text := v_mix->v_n->>'decision';

      FOR v_i IN 1 .. (v_mix->v_n->>'n')::int LOOP
        -- Pick a contract round-robin.
        v_contract_id := v_contract_ids[((v_i + v_n * 50 + v_approver_id::int) % array_length(v_contract_ids, 1)) + 1];

        -- decided_at: spread across last 89 days, weighted toward recent.
        -- Use a deterministic hash so re-running the migration produces
        -- the same dataset (idempotent re-seed).
        v_decided_at := fn_demo_now()
                      - ((v_i + v_n * 13 + v_approver_id::int * 7) % 88 + 1) * INTERVAL '1 day'
                      - (((v_i * 31 + v_n) % 24) * INTERVAL '1 hour');

        v_hours_waiting := 2 + ((v_i * 7 + v_n * 5 + v_approver_id::int) % 70);
        v_step_created_at := v_decided_at - (v_hours_waiting * INTERVAL '1 hour');

        IF v_decision_text = 'approve' THEN
          v_step_status  := 'approved';
          v_chain_status := 'approved';
          v_note := 'Approved — terms reviewed, value within delegation, risk acceptable.';
        ELSIF v_decision_text = 'reject' THEN
          v_step_status  := 'rejected';
          v_chain_status := 'rejected';
          v_note := 'Rejected — counterparty risk profile exceeds delegation; escalate to legal.';
        ELSE  -- request_info
          v_step_status  := 'resubmission_requested';
          v_chain_status := 'resubmission_requested';
          v_note := 'More information needed — clarify scope of liability cap and termination clause.';
        END IF;

        -- Insert chain. matrix_snapshot is JSONB NOT NULL; we synthesise
        -- a minimal snapshot.
        INSERT INTO approval_chain
          (contract_id, matrix_snapshot, status, current_step_order, initiated_by,
           initiated_at, completed_at, data_classification, is_active, created_at, updated_at)
        VALUES
          (v_contract_id,
           jsonb_build_object('synthetic', TRUE, 'seedMigration', 535),
           v_chain_status, 1, v_approver_id,
           v_step_created_at,
           v_decided_at,
           'demo', TRUE, v_step_created_at, v_decided_at)
        RETURNING id INTO v_chain_id;

        INSERT INTO approval_step
          (approval_chain_id, step_order, parallel_group, approver_role, approver_user_id,
           status, is_required, decided_at, data_classification, is_active, created_at, updated_at)
        VALUES
          (v_chain_id, 1, NULL, 'contract_approver', v_approver_id,
           v_step_status, TRUE, v_decided_at,
           'demo', TRUE, v_step_created_at, v_decided_at)
        RETURNING id INTO v_step_id;

        INSERT INTO approval_decision
          (approval_step_id, decision, decided_by, decided_at, decision_note,
           data_classification, is_active, created_at, created_by)
        VALUES
          (v_step_id, v_decision_text, v_approver_id, v_decided_at, v_note,
           'demo', TRUE, v_decided_at, v_approver_id);

      END LOOP;
    END LOOP;

  END LOOP;
END;
$seed$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (535, 'seed_approver_decisions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
