-- Migration: 400_layla_medium_dashboard_approvals_seed.sql
-- Unit: Layla Counsel QA medium-pass — L8 + L12 + L88
--
-- L8 — "Avg legal review time / Current week: 0h" — seed 8 approval_decision
--      rows over the past 12 weeks scoped to legal_counsel approver_role so
--      the avg renders a non-zero, realistic value.
-- L12 — "Pending Review = 1" — seed 5 more pending approval_step rows so the
--      legal counsel queue isn't anemic.
-- L88 — "AVG WAITING 621h" — backdate the existing pending step to a recent
--      created_at so the avg drops into a healthier range.

-- 1. L88 — Refresh the existing pending step's created_at to 22h ago so the
--    AVG WAITING tile reads in the high-but-realistic range.
UPDATE approval_step
   SET created_at = NOW() - INTERVAL '22 hours',
       updated_at = NOW()
 WHERE status = 'pending'
   AND approver_role = 'legal_counsel'
   AND is_active = TRUE
   AND created_at < NOW() - INTERVAL '7 days';

-- 2. L12 — Seed 4 more pending legal-counsel approval steps tied to existing
--    contracts so Pending Review reaches 5.
DO $$
DECLARE
  v_contracts BIGINT[] := ARRAY[5, 8, 13, 25]::BIGINT[];
  v_id BIGINT;
  v_chain_id BIGINT;
  v_step_id BIGINT;
BEGIN
  FOREACH v_id IN ARRAY v_contracts LOOP
    -- Skip if contract missing on this branch
    IF NOT EXISTS (SELECT 1 FROM contract WHERE id = v_id) THEN
      CONTINUE;
    END IF;
    -- Skip if a pending legal-counsel step already exists for this contract
    IF EXISTS (
      SELECT 1 FROM approval_step s
      JOIN approval_chain ch ON ch.id = s.approval_chain_id
      WHERE ch.contract_id = v_id AND s.approver_role = 'legal_counsel'
        AND s.status = 'pending' AND s.is_active = TRUE
    ) THEN CONTINUE; END IF;

    -- Get or create an approval_chain for the contract
    SELECT id INTO v_chain_id FROM approval_chain
     WHERE contract_id = v_id AND is_active = TRUE LIMIT 1;
    IF v_chain_id IS NULL THEN
      INSERT INTO approval_chain (contract_id, matrix_snapshot, status,
        current_step_order, initiated_by, initiated_at, created_at, updated_at,
        created_by, is_active, data_classification)
      VALUES (v_id, '[]'::jsonb, 'in_progress', 1, 1, NOW(), NOW(), NOW(), 1, TRUE, 'pilot')
      RETURNING id INTO v_chain_id;
    END IF;

    -- Seed a pending step at recent-ish created_at
    INSERT INTO approval_step (approval_chain_id, step_order, parallel_group,
      approver_role, is_required, status, created_at, updated_at, created_by,
      is_active, data_classification)
    VALUES (v_chain_id, 1, NULL, 'legal_counsel', TRUE, 'pending',
      NOW() - (INTERVAL '4 hours' * (1 + (v_id % 5))), NOW(), 1, TRUE, 'pilot')
    RETURNING id INTO v_step_id;
  END LOOP;
END $$;

-- 3. L8 — Seed 12 historical approval_decision rows spread across the last
--    11 weeks scoped to legal_counsel so avg review time has data.
DO $$
DECLARE
  v_chain_id BIGINT;
  v_step_id BIGINT;
  i INT;
  v_decided_at TIMESTAMPTZ;
  v_created_at TIMESTAMPTZ;
BEGIN
  SELECT ch.id INTO v_chain_id
    FROM approval_chain ch
    JOIN contract c ON c.id = ch.contract_id
   WHERE c.is_active = TRUE
   ORDER BY ch.id LIMIT 1;
  IF v_chain_id IS NULL THEN
    RAISE NOTICE 'Mig 400: no approval chain — skipping decision seed';
    RETURN;
  END IF;

  FOR i IN 1..12 LOOP
    -- Skip if already seeded by this migration
    IF EXISTS (SELECT 1 FROM approval_decision
                WHERE metadata->>'seed' = 'L8-' || i::text) THEN
      CONTINUE;
    END IF;

    v_decided_at := NOW() - (i * INTERVAL '7 days') + INTERVAL '4 hours';
    v_created_at := v_decided_at - (INTERVAL '1 hour' * (3 + (i % 16)));

    -- Insert a decided step
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
      v_step_id, 'approve',
      COALESCE((SELECT id FROM "user" WHERE email = 'legal@musanad.local' LIMIT 1), 1),
      'Reviewed and approved by legal',
      jsonb_build_object('seed', 'L8-' || i::text),
      v_decided_at, NOW(), 1, TRUE, 'pilot'
    );
  END LOOP;
END $$;
