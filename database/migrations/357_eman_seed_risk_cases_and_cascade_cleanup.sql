-- Migration: 357_eman_seed_risk_cases_and_cascade_cleanup.sql
-- Unit: Eman Executive QA Phase 3.3 (2026-05-31)
-- Fixes:
--   E32 — Risk cases list is empty for Eman. Seed 8 risk cases in non-terminal
--         states (open / in_progress / awaiting_evidence) spanning priority +
--         case_type so the page tells an enterprise-risk story.
--
--   E34 — 5 cascade runs visible, 3 within 1-minute window. DELETE the
--         duplicate-replay rows (keep one canonical run per regulation), then
--         spread the remaining run_at across recent weeks.
--
--   E35 — Penalty exposure jumps 10× between runs (16→132 contractors).
--         The 10× jump is a reseed artifact, not operational reality. After
--         the dedup in E34, normalize the surviving run summary to the
--         scaled-up version (132 contractors, AED 12.8M penalty).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ── E32 — seed risk cases for the enterprise (Eman sees all) ────────────
DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
  v_now    TIMESTAMPTZ := NOW();
  v_actor  BIGINT := 1;
  v_hero   BIGINT;
  v_c1     BIGINT;  v_c2 BIGINT;  v_c3 BIGINT;
  v_c4     BIGINT;  v_c5 BIGINT;  v_c6 BIGINT;
  v_c7     BIGINT;
  v_contract_count INT;
BEGIN
  -- Test-branch guard
  SELECT COUNT(*) INTO v_contract_count FROM contract WHERE is_active = TRUE;
  IF v_contract_count < 20 THEN
    RAISE NOTICE 'Skipping risk-case seed — only % contracts (need >=20).', v_contract_count;
    RETURN;
  END IF;
  SELECT id INTO v_hero FROM contract WHERE contract_number ILIKE '%HERO-001%' LIMIT 1;
  SELECT id INTO v_c1 FROM contract WHERE is_active AND ai_risk_score IS NOT NULL ORDER BY ai_risk_score DESC NULLS LAST OFFSET 0 LIMIT 1;
  SELECT id INTO v_c2 FROM contract WHERE is_active AND ai_risk_score IS NOT NULL ORDER BY ai_risk_score DESC NULLS LAST OFFSET 1 LIMIT 1;
  SELECT id INTO v_c3 FROM contract WHERE is_active AND ai_risk_score IS NOT NULL ORDER BY ai_risk_score DESC NULLS LAST OFFSET 2 LIMIT 1;
  SELECT id INTO v_c4 FROM contract WHERE is_active AND ai_risk_score IS NOT NULL ORDER BY ai_risk_score DESC NULLS LAST OFFSET 3 LIMIT 1;
  SELECT id INTO v_c5 FROM contract WHERE is_active ORDER BY value_aed DESC NULLS LAST OFFSET 5 LIMIT 1;
  SELECT id INTO v_c6 FROM contract WHERE is_active ORDER BY value_aed DESC NULLS LAST OFFSET 8 LIMIT 1;
  SELECT id INTO v_c7 FROM contract WHERE is_active ORDER BY value_aed DESC NULLS LAST OFFSET 12 LIMIT 1;

  -- Open / high — HERO-001 budget breach
  IF v_hero IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE contract_id = v_hero AND status IN ('open','in_review')) THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_hero, 'correlation_alert', 'high',
              'CRN-296-HERO-001 — budget breach projected by year-end',
              'Variance +13% in 2026-07. Projected overrun AED 42M if trend continues. Cure-notice drafted.',
              'finance_treasury', 'open', 48, v_now + INTERVAL '2 days',
              'eman-seed-hero-budget', 'restricted', v_now - INTERVAL '6 hours', v_now - INTERVAL '6 hours', v_actor, v_actor, TRUE);
  END IF;

  -- In progress / critical — sanctions exposure
  IF v_c1 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'eman-seed-sanctions-1') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c1, 'correlation_alert', 'critical',
              'OFAC designation — counterparty chain exposure under review',
              'Counterparty parent flagged on OFAC SDN list 2026-05-14. Compliance freeze pending.',
              'compliance_esg', 'in_review', 4, v_now + INTERVAL '4 hours',
              'eman-seed-sanctions-1', 'sensitive', v_now - INTERVAL '18 hours', v_now - INTERVAL '6 hours', v_actor, v_actor, TRUE);
  END IF;

  -- Open / high — Hormuz weather FM
  IF v_c2 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'eman-seed-hormuz-1') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c2, 'correlation_alert', 'high',
              'Hormuz Strait disruption — FM clause eligibility review',
              'Vessel diversion observed via marine traffic. Force-majeure clause review queued for legal.',
              'legal_counsel', 'open', 24, v_now + INTERVAL '1 day',
              'eman-seed-hormuz-1', 'restricted', v_now - INTERVAL '11 hours', v_now - INTERVAL '11 hours', v_actor, v_actor, TRUE);
  END IF;

  -- Awaiting evidence / medium — Brent price
  IF v_c3 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'eman-seed-brent-1') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c3, 'correlation_alert', 'medium',
              'Brent crude band breach — price review trigger',
              'Brent sustained below USD 100/bbl for 7 consecutive days. Price-review clause activation pending counterparty acknowledgment.',
              'finance_treasury', 'snoozed', 72, v_now + INTERVAL '3 days',
              'eman-seed-brent-1', 'restricted', v_now - INTERVAL '2 days', v_now - INTERVAL '1 day', v_actor, v_actor, TRUE);
  END IF;

  -- Open / medium — ESG water stress
  IF v_c4 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'eman-seed-esg-1') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c4, 'correlation_alert', 'medium',
              'High water-stress facility — ESG concern memo drafted',
              'WRI Aqueduct flagged facility as extreme water-stress. ESG memo prepared for executive review.',
              'compliance_esg', 'open', 168, v_now + INTERVAL '5 days',
              'eman-seed-esg-1', 'internal', v_now - INTERVAL '3 days', v_now - INTERVAL '3 days', v_actor, v_actor, TRUE);
  END IF;

  -- In progress / medium — EPC SLA
  IF v_c5 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'eman-seed-epc-1') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c5, 'sla_breach', 'medium',
              'EPC milestone slippage — penalty window review',
              'Construction milestone Q2 missed by 11 days. LD-clause penalty exposure AED 1.4M.',
              'operations', 'in_review', 96, v_now + INTERVAL '4 days',
              'eman-seed-epc-1', 'restricted', v_now - INTERVAL '4 days', v_now - INTERVAL '12 hours', v_actor, v_actor, TRUE);
  END IF;

  -- Open / low — Labor cascade
  IF v_c6 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'eman-seed-labor-1') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c6, 'manual', 'low',
              'Federal Decree-Law No. 9/2024 — schedule annex refresh required',
              'New labor-relations amendments. 132 contractors flagged for annex refresh. Penalty exposure AED 12.8M if unaddressed.',
              'legal_counsel', 'open', 240, v_now + INTERVAL '10 days',
              'eman-seed-labor-1', 'internal', v_now - INTERVAL '5 days', v_now - INTERVAL '5 days', v_actor, v_actor, TRUE);
  END IF;

  -- Awaiting evidence / high — Supplier concentration
  IF v_c7 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'eman-seed-conc-1') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c7, 'manual', 'high',
              'Counterparty concentration > 18% of portfolio — diversification review',
              'Single counterparty exposure exceeds board-set 15% threshold. Diversification options under procurement review.',
              'procurement_supplier_risk', 'snoozed', 120, v_now + INTERVAL '5 days',
              'eman-seed-conc-1', 'restricted', v_now - INTERVAL '6 days', v_now - INTERVAL '2 days', v_actor, v_actor, TRUE);
  END IF;
END $$;

-- ── E34 — cascade run dedup + spread ───────────────────────────────────
-- Delete the duplicate-replay rows from 2026-05-30 (runs 4/5/6 are within
-- a 1-hour window of the same regulation). Keep the most recent (run #6)
-- as the canonical "Federal Decree-Law No. 9/2024" run; delete 4 + 5.
DELETE FROM regulatory_cascade_run
  WHERE id IN (4, 5)
    AND regulation_ref = 'Federal Decree-Law No. 9 of 2024';

-- Spread surviving runs across 4 different weeks for organic feel.
UPDATE regulatory_cascade_run SET run_at = NOW() - INTERVAL '21 days'  WHERE id = 1;
UPDATE regulatory_cascade_run SET run_at = NOW() - INTERVAL '12 days'  WHERE id = 2;
UPDATE regulatory_cascade_run SET run_at = NOW() - INTERVAL '6 days'   WHERE id = 3;
UPDATE regulatory_cascade_run SET run_at = NOW() - INTERVAL '1 day'    WHERE id = 6;

-- ── E35 — normalize penalty exposure on surviving runs ─────────────────
-- Bring runs 1/2 (16 contractors / AED 1.6M) up to the post-scale-up
-- baseline so the run-history doesn't show a confusing 10× jump.
UPDATE regulatory_cascade_run
  SET affected_contractor_count = 132,
      total_penalty_min_aed = 12800000,
      total_penalty_max_aed = 12850000
  WHERE id IN (1, 2)
    AND affected_contractor_count < 20;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Data seed; rollback by:
--   DELETE FROM risk_case WHERE dedupe_key LIKE 'eman-seed-%';
--   (cascade run dedup is irreversible without re-running CR-Q cascade)
-- ============================================================
