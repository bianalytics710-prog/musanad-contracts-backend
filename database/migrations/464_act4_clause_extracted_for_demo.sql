-- Migration: 464_act4_clause_extracted_for_demo.sql
-- Module: ADNOC demo — Act 4 Risk-tab dim-score completeness
-- Date: 2026-06-02
--
-- Why: fn_risk_score_compute (mig 171) computes per-dimension impact
-- from contract_clause_extracted.parameters. When that table has 0 rows
-- for a contract, impacts default to 0 for legal/operational/compliance,
-- which collapses those dim scores to 0 regardless of correlation count
-- — exactly the Act-4 walkthrough finding ("Legal=0 with 5 correlations
-- contributing" undermines the explainability pitch).
--
-- Fix: seed clause_extracted rows for CRQ-GAS-005 (id 239 — the contract
-- the script pins Act 4 to) with realistic parameter flags so legal /
-- operational / compliance impacts compute > 0. After this + a recompute,
-- the contract surfaces the demo-worthy 60/50/70/68/73 → 53 (Medium)
-- profile the v3.0 script promises.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_tenant   UUID := '00000000-0000-0000-0000-000000000001';
  v_contract BIGINT := 239;
  v_version  BIGINT;
  v_now      TIMESTAMPTZ := now();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = v_contract AND is_active) THEN
    RAISE NOTICE 'Contract 239 not present — skipping clause-extracted seed';
    RETURN;
  END IF;

  -- Idempotency: only seed if no rows yet
  IF EXISTS (SELECT 1 FROM contract_clause_extracted WHERE contract_id = v_contract AND is_active) THEN
    RAISE NOTICE 'contract_clause_extracted already seeded for 239 — skipping';
    RETURN;
  END IF;

  -- Resolve a contract_version_id (latest non-soft-deleted)
  SELECT id INTO v_version
  FROM contract_version
  WHERE contract_id = v_contract AND is_active = TRUE
  ORDER BY version_number DESC NULLS LAST, id DESC
  LIMIT 1;
  IF v_version IS NULL THEN
    RAISE NOTICE 'No contract_version for 239 — skipping';
    RETURN;
  END IF;

  INSERT INTO contract_clause_extracted (
    tenant_id, contract_id, contract_version_id, clause_type_v2, parameters, text_excerpts,
    confidence, summary_en, review_status, data_classification,
    created_at, updated_at, is_active
  ) VALUES
    (v_tenant, v_contract, v_version, 'indemnity',
     jsonb_build_object('indemnity_scope', 'broad', 'liability_cap_value', 50000000),
     '["mutual indemnification — broad scope including third-party claims arising from Shah Gas Field operations"]'::jsonb,
     0.91, 'Broad mutual indemnity — Shah Gas SPA', 'reviewed', 'demo', v_now, v_now, TRUE),
    (v_tenant, v_contract, v_version, 'liability_cap',
     jsonb_build_object('liability_cap_value', 50000000, 'aggregate', TRUE),
     '["aggregate liability cap of AED 50M per contract year"]'::jsonb,
     0.94, 'Liability cap AED 50M aggregate', 'reviewed', 'demo', v_now, v_now, TRUE),
    (v_tenant, v_contract, v_version, 'critical_path',
     jsonb_build_object('critical_path_impact', TRUE),
     '["delivery of stabilised gas to Abu Dhabi Power — critical-path obligation"]'::jsonb,
     0.88, 'Critical path delivery obligation', 'reviewed', 'demo', v_now, v_now, TRUE),
    (v_tenant, v_contract, v_version, 'critical_path',
     jsonb_build_object('critical_path_impact', TRUE),
     '["scheduled maintenance windows — coordination requirement"]'::jsonb,
     0.84, 'Coordinated maintenance window obligation', 'reviewed', 'demo', v_now, v_now, TRUE),
    (v_tenant, v_contract, v_version, 'single_source',
     jsonb_build_object('single_source_dependency', TRUE),
     '["sole-source for stabilised gas supply to Abu Dhabi Power per SPA Schedule 2"]'::jsonb,
     0.92, 'Sole-source supply dependency', 'reviewed', 'demo', v_now, v_now, TRUE),
    (v_tenant, v_contract, v_version, 'public_visibility',
     jsonb_build_object('public_visibility', TRUE),
     '["state-owned counterparty (ADNOC Gas) — public-record contract"]'::jsonb,
     0.97, 'Public-record state contract', 'reviewed', 'demo', v_now, v_now, TRUE),
    (v_tenant, v_contract, v_version, 'regulatory_linkage',
     jsonb_build_object('regulatory_linkage', TRUE),
     '["UAE Federal Decree-Law 14/2023 — energy sector compliance"]'::jsonb,
     0.95, 'Federal energy-sector regulatory linkage', 'reviewed', 'demo', v_now, v_now, TRUE),
    (v_tenant, v_contract, v_version, 'regulatory_linkage',
     jsonb_build_object('regulatory_linkage', TRUE),
     '["ADNOC HSE Code — health/safety/environmental compliance"]'::jsonb,
     0.93, 'ADNOC HSE regulatory linkage', 'reviewed', 'demo', v_now, v_now, TRUE);
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (464, '464_act4_clause_extracted_for_demo', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 464;
-- DELETE FROM contract_clause_extracted WHERE contract_id = 239 AND data_classification = 'demo';
-- ============================================================
