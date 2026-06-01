-- Migration: 409_pari_cluster8_risk_case_seed.sql
-- Unit: Pari Procurement QA Phase 3.7 (2026-06-01) — Cluster 8 / P30
-- Closes: P30 — Pari's Risk Cases list had only 1 visible case (the snoozed counterparty
--         concentration one); too thin for a "procurement risk" persona demo.
-- Strategy: Seed 6 procurement-relevant cases assigned_role='procurement_supplier_risk'
--           spanning case_type and priority so the page tells a credible operating story.
--           Idempotent via dedupe_key.

BEGIN;

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
  v_now    TIMESTAMPTZ := NOW();
  v_actor  BIGINT := 1;
  v_c1 BIGINT; v_c2 BIGINT; v_c3 BIGINT; v_c4 BIGINT; v_c5 BIGINT; v_c6 BIGINT;
  v_contract_count INT;
BEGIN
  SELECT COUNT(*) INTO v_contract_count FROM contract WHERE is_active = TRUE;
  IF v_contract_count < 20 THEN
    RAISE NOTICE 'Skipping pari risk-case seed — only % contracts (need >=20).', v_contract_count;
    RETURN;
  END IF;

  -- Pick contracts: Mubadala (already has SLA breach signals), DEWA, IBM, etc.
  SELECT co.id INTO v_c1 FROM contract co JOIN party p ON p.id = co.counterparty_id
    WHERE co.is_active AND p.is_active AND p.name_en ILIKE '%mubadala%' ORDER BY co.id LIMIT 1;
  SELECT co.id INTO v_c2 FROM contract co JOIN party p ON p.id = co.counterparty_id
    WHERE co.is_active AND p.is_active AND p.name_en ILIKE '%DEWA%' ORDER BY co.id LIMIT 1;
  SELECT co.id INTO v_c3 FROM contract co JOIN party p ON p.id = co.counterparty_id
    WHERE co.is_active AND p.is_active AND p.name_en ILIKE '%IBM%' ORDER BY co.id LIMIT 1;
  SELECT co.id INTO v_c4 FROM contract co JOIN party p ON p.id = co.counterparty_id
    WHERE co.is_active AND p.is_active AND p.name_en ILIKE '%Crescent%' ORDER BY co.id LIMIT 1;
  SELECT co.id INTO v_c5 FROM contract co JOIN party p ON p.id = co.counterparty_id
    WHERE co.is_active AND p.is_active AND p.name_en ILIKE '%Fujairah%' ORDER BY co.id LIMIT 1;
  SELECT co.id INTO v_c6 FROM contract co JOIN party p ON p.id = co.counterparty_id
    WHERE co.is_active AND p.is_active AND p.name_en ILIKE '%Etisalat%' ORDER BY co.id LIMIT 1;

  -- Case 1: OPEN / HIGH — SLA breach on Mubadala
  IF v_c1 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'pari-seed-sla-mubadala') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c1, 'sla_breach', 'high',
              'Mubadala Investment Company — 2 SLA breaches in 180d',
              'Two consecutive milestone-slippage signals on the Investment Advisory contract. Initiate cure-notice draft and engage account manager.',
              'procurement_supplier_risk', 'open', 48, v_now + INTERVAL '2 days',
              'pari-seed-sla-mubadala', 'restricted', v_now - INTERVAL '4 hours', v_now - INTERVAL '4 hours', v_actor, v_actor, TRUE);
  END IF;

  -- Case 2: IN_REVIEW / CRITICAL — ICV missing on DEWA portfolio
  IF v_c2 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'pari-seed-icv-dewa') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c2, 'manual', 'critical',
              'DEWA — ICV certificates missing across 4 active contracts',
              'No In-Country Value certificates on file for any of DEWA''s 4 active contracts (AED 33.4M aggregate). Tier-1 audit window opens Q3.',
              'procurement_supplier_risk', 'in_review', 24, v_now + INTERVAL '1 day',
              'pari-seed-icv-dewa', 'restricted', v_now - INTERVAL '14 hours', v_now - INTERVAL '3 hours', v_actor, v_actor, TRUE);
  END IF;

  -- Case 3: OPEN / HIGH — financial distress signal on IBM
  IF v_c3 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'pari-seed-finhealth-ibm') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c3, 'correlation_alert', 'high',
              'IBM Middle East — credit bureau downgrade signal',
              'D&B downgrade flagged on IBM ME parent entity. Review payment terms and consider backup-supplier activation.',
              'procurement_supplier_risk', 'open', 72, v_now + INTERVAL '3 days',
              'pari-seed-finhealth-ibm', 'restricted', v_now - INTERVAL '1 day', v_now - INTERVAL '1 day', v_actor, v_actor, TRUE);
  END IF;

  -- Case 4: OPEN / MEDIUM — sanctions hit on Crescent
  IF v_c4 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'pari-seed-sanctions-crescent') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c4, 'correlation_alert', 'medium',
              'Crescent Petroleum — sub-tier supplier sanctions screen',
              'Tier-2 supplier in Crescent''s subcontractor chain matches OFAC SDN partial-name list. Escalate to compliance for confirmatory screen.',
              'procurement_supplier_risk', 'open', 168, v_now + INTERVAL '5 days',
              'pari-seed-sanctions-crescent', 'sensitive', v_now - INTERVAL '2 days', v_now - INTERVAL '2 days', v_actor, v_actor, TRUE);
  END IF;

  -- Case 5: IN_REVIEW / HIGH — concentration on Fujairah (AED 22B single counterparty)
  IF v_c5 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'pari-seed-concentration-fujairah') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c5, 'manual', 'high',
              'Fujairah Port Logistics — single-contract AED 22B exposure',
              'One contract represents 19% of total portfolio value. Diversification review + counterparty financial-strength reassessment overdue.',
              'procurement_supplier_risk', 'in_review', 96, v_now + INTERVAL '4 days',
              'pari-seed-concentration-fujairah', 'restricted', v_now - INTERVAL '18 hours', v_now - INTERVAL '6 hours', v_actor, v_actor, TRUE);
  END IF;

  -- Case 6: OPEN / MEDIUM — vendor onboarding stalled (Etisalat)
  IF v_c6 IS NOT NULL AND NOT EXISTS (SELECT 1 FROM risk_case WHERE dedupe_key = 'pari-seed-onboard-etisalat') THEN
    INSERT INTO risk_case (tenant_id, contract_id, case_type, priority, title, body, assigned_role, status, sla_hours, due_at, dedupe_key, data_classification, created_at, updated_at, created_by, updated_by, is_active)
      VALUES (v_tenant, v_c6, 'manual', 'medium',
              'Etisalat (e&) — supplier scorecard refresh stalled',
              'Quarterly scorecard refresh not received from supplier risk team for 60 days. Composite score remains at 0 until updated.',
              'procurement_supplier_risk', 'open', 120, v_now + INTERVAL '5 days',
              'pari-seed-onboard-etisalat', 'internal', v_now - INTERVAL '3 days', v_now - INTERVAL '3 days', v_actor, v_actor, TRUE);
  END IF;

END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (409, '409_pari_cluster8_risk_case_seed', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK:
-- DELETE FROM risk_case WHERE dedupe_key LIKE 'pari-seed-%';
-- DELETE FROM schema_migrations WHERE version = 409;
