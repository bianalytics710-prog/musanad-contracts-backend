-- Migration: 404_layla_avg_review_current_week.sql
-- Unit: Layla Counsel QA medium-pass — L8 finish
--
-- Mig 400 seeded decisions for weeks 1-12 but week 0 (current week) was empty,
-- so the "Current week: 0h" tile still read 0. Add 3 fresh approval_decisions
-- within the last 6 days so week 0 has data and shows a realistic 4-7h avg.

DO $$
DECLARE
  v_chain_id BIGINT;
  v_step_id BIGINT;
  v_decided_at TIMESTAMPTZ;
  v_created_at TIMESTAMPTZ;
  v_layla BIGINT;
  i INT;
BEGIN
  SELECT id INTO v_layla FROM "user" WHERE email = 'legal@musanad.local' LIMIT 1;

  SELECT ch.id INTO v_chain_id
    FROM approval_chain ch
    JOIN contract c ON c.id = ch.contract_id
   WHERE c.is_active = TRUE
   ORDER BY ch.id LIMIT 1;
  IF v_chain_id IS NULL THEN RETURN; END IF;

  FOR i IN 1..3 LOOP
    -- Skip if already seeded
    IF EXISTS (SELECT 1 FROM approval_decision
                WHERE metadata->>'seed' = 'L8-w0-' || i::text) THEN
      CONTINUE;
    END IF;

    v_decided_at := NOW() - (i * INTERVAL '1 day') - INTERVAL '3 hours';
    v_created_at := v_decided_at - (INTERVAL '1 hour' * (3 + i * 2));

    INSERT INTO approval_step (
      approval_chain_id, step_order, parallel_group,
      approver_role, is_required, status, decided_at,
      created_at, updated_at, created_by, is_active, data_classification
    )
    VALUES (
      v_chain_id, 1, NULL, 'legal_counsel', TRUE, 'approved', v_decided_at,
      v_created_at, v_decided_at, 1, TRUE, 'pilot'
    )
    RETURNING id INTO v_step_id;

    INSERT INTO approval_decision (
      approval_step_id, decision, decided_by, decision_note, metadata,
      decided_at, created_at, created_by, is_active, data_classification
    )
    VALUES (
      v_step_id, 'approve', COALESCE(v_layla, 1),
      'Reviewed and approved (this-week seed)',
      jsonb_build_object('seed', 'L8-w0-' || i::text),
      v_decided_at, NOW(), 1, TRUE, 'pilot'
    );
  END LOOP;
END $$;
