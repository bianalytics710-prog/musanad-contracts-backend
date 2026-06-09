-- Migration: 604_seed_oqood_003_history_and_msa.sql
-- Module: Demo seed — version history + parent MSA for OQOOD-2026-003
-- Date: 2026-06-09
--
-- OQOOD-2026-003 "Mubadala Investment Advisory" sits at Layla's
-- (legal_counsel) pending step inside the approval chain — perfect
-- demo target for the Versions tab + Related-contracts surface.
--
-- Current state (pre-migration):
--   • contract.drafted_by = 4 (Layla)            ← wrong persona for demo
--   • 1 contract_version row (v1, 2026-05-12) with
--       changed_by = NULL, created_by = NULL    ← FE renders "Removed User"
--       diff_summary = '', change_note = ''     ← Versions tab is blank
--   • parent_contract_id = NULL                  ← no related-contracts link
--
-- This migration:
--   1. Reassigns contract.drafted_by → 5 (Hala Al Suwaidi) so the
--      contract persona story reads "Hala drafted; Layla reviewed".
--   2. Backfills the existing v1 row with proper actor + narrative
--      (changed_by = 5, diff_summary, change_note).
--   3. Inserts 4 new version rows narrating the redline cycle:
--      v2 (Mubadala redline) → v3 (Layla legal) → v4 (Hala rework)
--      → v5 (Hala final).
--   4. Sets contract.current_version = 5.
--   5. Creates a parent MSA — "Mubadala Investment Company — Master
--      Services Agreement (Framework)" — fully_signed since Oct 2025.
--   6. Links OQOOD-2026-003 to the new MSA via parent_contract_id +
--      relationship_type = 'sow_under_msa'.
--
-- Idempotent — short-circuits on the new MSA contract_number key. The
-- v1 backfill is also conditional on changed_by IS NULL so re-running
-- doesn't overwrite a real edit.

BEGIN;

DO $$
DECLARE
  v_tenant   UUID   := '00000000-0000-0000-0000-000000000001';
  v_drafter  BIGINT := 5;   -- Hala Al Suwaidi
  v_legal    BIGINT := 4;   -- Layla Al Hashemi
  v_approver BIGINT := 6;   -- Aisha Al Marri
  v_our      BIGINT := 14;  -- OqoodAI Technologies FZ-LLC
  v_cp       BIGINT := 17;  -- Mubadala Investment Company
  v_contract BIGINT := 7;   -- OQOOD-2026-003
  v_msa_id   BIGINT;
  v_msa_body TEXT;
  v_already  BOOLEAN;
BEGIN
  PERFORM set_config('app.current_tenant_id', v_tenant::text, true);

  SELECT EXISTS(SELECT 1 FROM contract WHERE contract_number = 'OQOOD-2025-MSA-MUBADALA') INTO v_already;
  IF v_already THEN
    RAISE NOTICE 'Mubadala MSA already seeded — skipping.';
    RETURN;
  END IF;

  -- ── 1. Reassign drafted_by from Layla → Hala
  UPDATE contract
     SET drafted_by  = v_drafter,
         reviewed_by = v_legal,
         updated_at  = NOW(),
         updated_by  = v_drafter
   WHERE id = v_contract
     AND drafted_by = v_legal;

  -- ── 2. Backfill existing v1 row
  UPDATE contract_version
     SET changed_by   = v_drafter,
         created_by   = v_drafter,
         diff_summary = 'Initial draft from Investment Advisory template. Standard reporting cadence + fee schedule.',
         change_note  = 'Initial draft — created from the standard Investment Advisory template with default placeholders for reporting cadence, fee structure, and confidentiality scope.'
   WHERE contract_id = v_contract
     AND version_number = 1
     AND changed_by IS NULL;

  -- ── 3. Insert v2..v5 narrating the redline cycle
  INSERT INTO contract_version (
    contract_id, version_number, body_en, body_ar, diff_summary, change_note,
    changed_by, created_at, created_by, is_active, data_classification
  ) VALUES
    -- v2 — Mubadala counterparty redline (Hala records receipt of the redline)
    (v_contract, 2,
     E'INVESTMENT ADVISORY ENGAGEMENT — v2 (Mubadala redline)\n\n1. PARTIES. OqoodAI Technologies FZ-LLC ("Adviser") and Mubadala Investment Company ("Client").\n\n3. CONFIDENTIALITY. Adviser shall treat all Client data as strictly confidential. Client retains the right to disclose Adviser deliverables to its board and Sovereign Wealth Committee without prior notice.', NULL,
     'Counterparty redlines (Mubadala): tightened confidentiality scope; sovereign-wealth disclosure waiver carved out; renamed "Provider" → "Adviser" throughout.',
     'Mubadala''s legal team returned redlines on §§ 3 (Confidentiality), 4 (Reporting), and the recitals. Two material asks: (a) a carve-out so Mubadala can disclose advisory output to its board + sovereign-wealth committee without notice; (b) global rename of "Provider" to "Adviser" to match their internal nomenclature. No financial impact.',
     v_drafter,
     '2026-05-17 14:20:00+00'::timestamptz, v_drafter, TRUE, 'demo'),

    -- v3 — Layla legal review + rephrasing
    (v_contract, 3,
     E'INVESTMENT ADVISORY ENGAGEMENT — v3 (Legal review)\n\n7.2 INDEMNITY. Each Party shall indemnify the other against any third-party claim caused by negligence in the performance of this Agreement. Aggregate liability under this clause is capped at AED 250,000.\n\n11. GOVERNING LAW. UAE federal law; ADGM Courts venue.', NULL,
     'Legal review (Layla): rephrased indemnity § 7.2; LD cap added at AED 250K; venue locked to UAE federal law + ADGM Courts.',
     'Tightened the indemnity clause § 7.2 — replaced "any claim arising" with "any third-party claim caused by negligence" to keep the carve-out narrow. Added a liquidated-damages cap of AED 250,000 (was uncapped). Locked governing law to UAE federal + ADGM Courts venue.',
     v_legal,
     '2026-05-25 09:45:00+00'::timestamptz, v_legal, TRUE, 'demo'),

    -- v4 — Hala drafter rework
    (v_contract, 4,
     E'INVESTMENT ADVISORY ENGAGEMENT — v4 (Fee + KYC update)\n\n4. FEES. AED 950,000 total, payable as four (4) equal quarterly instalments of AED 237,500 each, due upon delivery of the quarterly briefing.\n\nANNEX C — KYC + Sanctions Screening. Both Parties shall maintain ongoing KYC and sanctions-screening records throughout the engagement.', NULL,
     'Drafter rework: fee schedule restructured to quarterly milestones; KYC + due-diligence Annex C inserted.',
     'Restructured the fee schedule from single lump-sum into 4 equal quarterly instalments (AED 237,500 each) keyed to delivery of the quarterly briefing. Added Annex C — KYC & sanctions-screening obligations on both sides — at Mubadala''s compliance team''s ask.',
     v_drafter,
     '2026-06-02 11:10:00+00'::timestamptz, v_drafter, TRUE, 'demo'),

    -- v5 — Hala final clean copy
    (v_contract, 5,
     E'INVESTMENT ADVISORY ENGAGEMENT — v5 (Final clean copy for legal counsel approval)\n\nThe Parties: OqoodAI Technologies FZ-LLC ("Adviser") and Mubadala Investment Company ("Client"), do hereby enter into this Investment Advisory Engagement effective 1 March 2026 for a six (6) month term. All redlines reconciled; ready for legal counsel sign-off.', NULL,
     'Final clean copy after operations sign-off; ready for legal counsel review.',
     'Operations team signed off on the fee schedule and KYC annex on 5 Jun. Pulled all tracked changes and cleaned formatting. This is the version submitted to legal-counsel review for final sign-off.',
     v_drafter,
     '2026-06-06 16:30:00+00'::timestamptz, v_drafter, TRUE, 'demo');

  -- ── 4. Bump contract.current_version to 5
  UPDATE contract
     SET current_version = 5,
         updated_at      = NOW(),
         updated_by      = v_drafter
   WHERE id = v_contract;

  -- ── 5. Create parent MSA
  v_msa_body := E'MASTER SERVICES AGREEMENT — Framework agreement between OqoodAI Technologies FZ-LLC ("Provider") and Mubadala Investment Company ("Client").\n\n1. PURPOSE. This MSA establishes the framework for all services Provider may deliver to Client. Individual engagements are governed by Statements of Work (SOWs) that reference this MSA.\n\n2. TERM. 3 years from Effective Date (1 September 2025 – 1 September 2028) with two 1-year auto-renewals unless either Party gives 90 days written notice.\n\n3. CEILING VALUE. Aggregate fees under all SOWs are capped at AED 25,000,000 over the initial term. Annual reviews recalibrate the ceiling.\n\n4. CONFIDENTIALITY. Mutual confidentiality, survives 5 years post-termination. Standard sovereign-wealth carve-outs apply.\n\n5. INDEMNITY + LIABILITY. Aggregate liability per SOW capped at the fees paid under that SOW in the preceding 12 months. Indemnity covers third-party IP claims.\n\n6. GOVERNING LAW. UAE federal law; ADGM Courts venue.';

  INSERT INTO contract (
    contract_number, title_en, title_ar, contract_type, language,
    our_party_id, counterparty_id, value_aed, currency,
    start_date, end_date, signed_at, expiry_notice_days, emirate, governing_law,
    body_en, status,
    drafted_by, reviewed_by, approved_by, ai_risk_score, ai_summary_en,
    current_version,
    created_at, updated_at, created_by, updated_by, is_active, data_classification
  ) VALUES (
    'OQOOD-2025-MSA-MUBADALA',
    'Mubadala Investment Company — Master Services Agreement (Framework)',
    'مبادلة — اتفاقية الخدمات الرئيسية (إطار)',
    'master_services', 'en',
    v_our, v_cp, 25000000.00, 'AED',
    DATE '2025-09-01', DATE '2028-09-01',
    '2025-10-15 13:00:00+00'::timestamptz, 90, 'Abu Dhabi', 'uae_federal',
    v_msa_body,
    'fully_signed',
    v_drafter, v_legal, v_approver, 18,
    '3-year framework MSA between OqoodAI Technologies and Mubadala Investment Company capping aggregate fees at AED 25M. Mutual confidentiality with sovereign-wealth carve-outs, per-SOW liability cap at 12-month fees, UAE federal law / ADGM Courts. Low-risk; standard framework terms.',
    1,
    '2025-08-15 10:00:00+00'::timestamptz, NOW(), v_drafter, v_drafter, TRUE, 'demo'
  ) RETURNING id INTO v_msa_id;

  -- Single version row for the MSA so its Versions tab isn't empty either
  INSERT INTO contract_version (
    contract_id, version_number, body_en, body_ar, diff_summary, change_note,
    changed_by, created_at, created_by, is_active, data_classification
  ) VALUES (
    v_msa_id, 1, v_msa_body, NULL,
    'Initial draft of framework MSA. Standard 3-year term, AED 25M aggregate ceiling.',
    'Initial draft created from the MSA template — populated counterparty + ceiling + term per Mubadala onboarding form.',
    v_drafter, '2025-08-15 10:00:00+00'::timestamptz, v_drafter, TRUE, 'demo'
  );

  INSERT INTO contract_activity (contract_id, activity_type, actor_id, description_en, created_at, is_active, data_classification)
  VALUES
    (v_msa_id, 'created',         v_drafter, 'Draft created from Master Services Agreement template.',  '2025-08-15 10:00:00+00'::timestamptz, TRUE, 'demo'),
    (v_msa_id, 'fully_executed',  v_approver, 'Both parties signed; framework now active.',             '2025-10-15 13:00:00+00'::timestamptz, TRUE, 'demo');

  -- ── 6. Link OQOOD-2026-003 to the new MSA
  UPDATE contract
     SET parent_contract_id = v_msa_id,
         relationship_type  = 'sow_under_msa',
         updated_at         = NOW(),
         updated_by         = v_drafter
   WHERE id = v_contract;

  -- ── Trail an activity entry on OQOOD-2026-003 so the Activity tab
  -- explains the new MSA link to anyone reviewing the contract.
  INSERT INTO contract_activity (contract_id, activity_type, actor_id, description_en, metadata, created_at, is_active, data_classification)
  VALUES (
    v_contract, 'amendment_initiated', v_drafter,
    'Linked to parent MSA OQOOD-2025-MSA-MUBADALA. This Advisory engagement is one of several SOWs under the framework agreement.',
    jsonb_build_object('parentContractNumber', 'OQOOD-2025-MSA-MUBADALA', 'parentContractId', v_msa_id, 'relationshipType', 'sow_under_msa'),
    NOW(), TRUE, 'demo'
  );

  RAISE NOTICE 'Seeded OQOOD-2026-003 history (v1..v5, drafted_by=Hala) + parent MSA id=%.', v_msa_id;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (604, '604_seed_oqood_003_history_and_msa', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- UPDATE contract SET parent_contract_id = NULL, relationship_type = NULL WHERE contract_number = 'OQOOD-2026-003';
-- DELETE FROM contract_activity WHERE contract_id = (SELECT id FROM contract WHERE contract_number = 'OQOOD-2025-MSA-MUBADALA');
-- DELETE FROM contract_version  WHERE contract_id = (SELECT id FROM contract WHERE contract_number = 'OQOOD-2025-MSA-MUBADALA');
-- DELETE FROM contract          WHERE contract_number = 'OQOOD-2025-MSA-MUBADALA';
-- DELETE FROM contract_version  WHERE contract_id = 7 AND version_number BETWEEN 2 AND 5;
-- UPDATE contract SET current_version = 1, drafted_by = 4, reviewed_by = NULL WHERE id = 7;
-- UPDATE contract_version SET changed_by = NULL, created_by = NULL, diff_summary = '', change_note = '' WHERE contract_id = 7 AND version_number = 1;
-- DELETE FROM schema_migrations WHERE version = 604;
-- COMMIT;
