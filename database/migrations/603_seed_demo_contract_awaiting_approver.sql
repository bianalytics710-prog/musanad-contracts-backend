-- Migration: 603_seed_demo_contract_awaiting_approver.sql
-- Module: Demo seed — one contract sitting at approver's step with action button live
-- Date: 2026-06-09
--
-- For the demo we need a contract where the Approver persona (Aisha)
-- can actually click an "Approve / Reject" action button. The trigger
-- requires THREE things together:
--   1. contract.status = 'in_approval'
--   2. an approval_chain in 'in_progress' state for that contract
--   3. an approval_step assigned to the current user (approver_user_id
--      = 6) in 'pending' state — and any earlier steps already in
--      'approved' state.
-- The existing seeded OQOOD-2026-016 .. 020 contracts in Aisha's queue
-- all have contract.status = 'active' (not 'in_approval'), so the
-- contract-detail page hides the action button per the FE gate at
-- ContractDetail.tsx line 406.
--
-- Seed contract OQOOD-2026-DEMO-AP1:
--   • Counterparty:    Mubadala Investment Company (party id=17)
--   • Our party:       OqoodAI Technologies FZ-LLC (party id=14)
--   • Drafter:         Hala Al Suwaidi (user id=5)
--   • Reviewer:        Layla Al Hashemi (user id=4)
--   • Approver step:   Aisha Al Marri (user id=6)
--   • Value:           AED 3,500,000   (sits in mid-tier)
--   • Status:          in_approval
--   • Chain:           step 1 legal_counsel = approved (Layla decided
--                      3 days ago); step 2 contract_approver = pending
--                      (Aisha)
--
-- Idempotent — the migration short-circuits on the contract_number key.
-- Re-running has no effect.

BEGIN;

DO $$
DECLARE
  v_tenant   UUID   := '00000000-0000-0000-0000-000000000001';
  v_drafter  BIGINT := 5;
  v_legal    BIGINT := 4;
  v_approver BIGINT := 6;
  v_our      BIGINT := 14;  -- OqoodAI Technologies FZ-LLC
  v_cp       BIGINT := 17;  -- Mubadala Investment Company
  v_contract BIGINT;
  v_chain    BIGINT;
  v_step1    BIGINT;
  v_step2    BIGINT;
  v_now      TIMESTAMPTZ := NOW();
  v_drafted  TIMESTAMPTZ := NOW() - INTERVAL '6 days';
  v_submit   TIMESTAMPTZ := NOW() - INTERVAL '5 days';
  v_legal_ok TIMESTAMPTZ := NOW() - INTERVAL '3 days';
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::text, true);

  -- Short-circuit if already seeded
  IF EXISTS (SELECT 1 FROM contract WHERE contract_number = 'OQOOD-2026-DEMO-AP1') THEN
    RAISE NOTICE 'OQOOD-2026-DEMO-AP1 already seeded — skipping.';
    RETURN;
  END IF;

  -- ── 1. Contract row
  INSERT INTO contract (
    contract_number, title_en, title_ar, contract_type, language,
    our_party_id, counterparty_id, value_aed, currency,
    start_date, end_date, expiry_notice_days, emirate, governing_law,
    body_en, body_ar, status,
    drafted_by, reviewed_by, ai_risk_score, ai_summary_en, ai_summary_ar,
    current_version,
    created_at, updated_at, created_by, updated_by, is_active, data_classification
  ) VALUES (
    'OQOOD-2026-DEMO-AP1',
    'Mubadala Sovereign Wealth Advisory — 12-Month Engagement',
    'مبادلة — اتفاقية الاستشارة لمدة 12 شهرًا',
    'services', 'en',
    v_our, v_cp, 3500000.00, 'AED',
    DATE '2026-06-15', DATE '2027-06-15', 30, 'Abu Dhabi', 'uae_federal',
    -- Body kept short — enough for the AI panels to summarise without
    -- generating financial-figure hallucinations.
    E'STATEMENT OF WORK — Sovereign-wealth advisory engagement between OqoodAI Technologies FZ-LLC ("Provider") and Mubadala Investment Company ("Client").\n\n1. SCOPE. Provider shall deliver quarterly investment-thesis briefings, deal-pipeline screening, and ad-hoc deal-room access for one year from the Effective Date.\n\n2. FEES. AED 3,500,000 payable in four equal quarterly instalments of AED 875,000 upon delivery of each quarterly briefing.\n\n3. CONFIDENTIALITY. Provider treats all Client data as strictly confidential per Annex A. Breach attracts liquidated damages capped at AED 1,000,000.\n\n4. GOVERNING LAW. UAE federal law; ADGM Courts.',
    NULL,
    'in_approval',
    v_drafter, v_legal, 28,
    'Twelve-month sovereign-wealth advisory engagement valued at AED 3.5M with quarterly briefing milestones. Confidentiality breach is liquidated-damage capped at AED 1M. UAE federal law, ADGM Courts. Low-moderate risk — moderate value, standard advisory terms, single counterparty with strong ICV record.',
    NULL,
    1,
    v_drafted, v_now, v_drafter, v_drafter, TRUE, 'demo'
  ) RETURNING id INTO v_contract;

  -- ── 2. Approval chain
  INSERT INTO approval_chain (
    contract_id, matrix_snapshot, status, current_step_order,
    initiated_by, initiated_at,
    created_at, updated_at, created_by, updated_by, is_active, data_classification
  ) VALUES (
    v_contract,
    jsonb_build_object(
      'matrixCode', 'ADV-MID-2STEP',
      'rule',       'value_aed between 1M and 10M → legal_counsel then contract_approver',
      'steps', jsonb_build_array(
        jsonb_build_object('order', 1, 'role', 'legal_counsel',     'requireUser', v_legal),
        jsonb_build_object('order', 2, 'role', 'contract_approver', 'requireUser', v_approver)
      )
    ),
    'in_progress', 2,
    v_drafter, v_submit,
    v_submit, v_now, v_drafter, v_drafter, TRUE, 'demo'
  ) RETURNING id INTO v_chain;

  -- ── 3. Approval steps
  -- Step 1 — legal counsel review (approved 3 days ago by Layla)
  INSERT INTO approval_step (
    approval_chain_id, step_order, approver_user_id, approver_role, is_required,
    status, decided_at,
    created_at, updated_at, created_by, updated_by, is_active, data_classification
  ) VALUES (
    v_chain, 1, v_legal, 'legal_counsel', TRUE,
    'approved', v_legal_ok,
    v_submit, v_legal_ok, v_drafter, v_legal, TRUE, 'demo'
  ) RETURNING id INTO v_step1;

  -- Step 2 — contract approver (pending — assigned to Aisha)
  INSERT INTO approval_step (
    approval_chain_id, step_order, approver_user_id, approver_role, is_required,
    status, decided_at,
    created_at, updated_at, created_by, updated_by, is_active, data_classification
  ) VALUES (
    v_chain, 2, v_approver, 'contract_approver', TRUE,
    'pending', NULL,
    v_submit, v_legal_ok, v_drafter, v_legal, TRUE, 'demo'
  ) RETURNING id INTO v_step2;

  -- ── 4. Approval decision for step 1 (legal counsel approval)
  INSERT INTO approval_decision (
    approval_step_id, decision, decided_by, decision_note,
    decided_at, created_at, created_by, is_active, data_classification
  ) VALUES (
    v_step1, 'approve', v_legal,
    'Reviewed terms; confidentiality + LD caps in line with policy. Cleared for management approval.',
    v_legal_ok, v_legal_ok, v_legal, TRUE, 'demo'
  );

  -- ── 5. Activity log — drafted → submitted → reviewed → awaiting approval
  INSERT INTO contract_activity (contract_id, activity_type, actor_id, description_en, metadata, created_at, is_active, data_classification)
  VALUES
    (v_contract, 'created',                  v_drafter, 'Draft created from blank template.',                       NULL, v_drafted, TRUE, 'demo'),
    (v_contract, 'ai_summary_generated',     v_drafter, NULL,                                                       NULL, v_drafted + INTERVAL '1 hour', TRUE, 'demo'),
    (v_contract, 'submitted_for_approval',   v_drafter, 'Submitted via 2-step legal + approver chain (mid-tier value).', jsonb_build_object('chainId', v_chain), v_submit, TRUE, 'demo'),
    (v_contract, 'approval_decided',         v_legal,   'Legal counsel approved step 1.',                            jsonb_build_object('stepId', v_step1, 'decision', 'approved'), v_legal_ok, TRUE, 'demo');

  RAISE NOTICE 'Seeded OQOOD-2026-DEMO-AP1 (contract id %, chain id %, awaiting approver step %).', v_contract, v_chain, v_step2;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (603, '603_seed_demo_contract_awaiting_approver', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DELETE FROM approval_decision
--  WHERE approval_step_id IN (SELECT s.id FROM approval_step s JOIN approval_chain ch ON ch.id = s.approval_chain_id JOIN contract c ON c.id = ch.contract_id WHERE c.contract_number = 'OQOOD-2026-DEMO-AP1');
-- DELETE FROM approval_step
--  WHERE approval_chain_id IN (SELECT ch.id FROM approval_chain ch JOIN contract c ON c.id = ch.contract_id WHERE c.contract_number = 'OQOOD-2026-DEMO-AP1');
-- DELETE FROM approval_chain
--  WHERE contract_id IN (SELECT id FROM contract WHERE contract_number = 'OQOOD-2026-DEMO-AP1');
-- DELETE FROM contract_activity
--  WHERE contract_id IN (SELECT id FROM contract WHERE contract_number = 'OQOOD-2026-DEMO-AP1');
-- DELETE FROM contract WHERE contract_number = 'OQOOD-2026-DEMO-AP1';
-- DELETE FROM schema_migrations WHERE version = 603;
-- COMMIT;
