-- Migration: 355_eman_seed_diverse_risk_scores.sql
-- Unit: Eman Executive QA Phase 3.3 (2026-05-31)
-- Fix:
--   E4 — AVaR breakdown shows only 1 bar in Business unit / Geography /
--        Counterparty subtabs because risk_score only exists for 36 of 327
--        contracts AND all populated rows are services × dubai. Seed
--        ~120 additional risk_score rows spread across contract_type
--        (services/epc/concession/gas_spa) × emirate (abu_dhabi/dubai/
--        sharjah/fujairah/ajman) × multiple counterparties so the AVaR
--        breakdown bar charts show plausible diversity.
--
--        Range of MAR values keeps the demo story credible: a couple of
--        contracts in each (type, emirate) bucket get sizeable MAR (AED
--        20M..150M) with a mix of weather / sanctions / esg / epc_sla
--        contributing rule categories. Lower-importance contracts get
--        zero or small MAR.
--
--        After INSERT we REFRESH MATERIALIZED VIEW latest_risk_score so
--        fn_avar_aggregate (which reads from the MV) reflects the seed.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
  v_now    TIMESTAMPTZ := NOW();
  v_admin  BIGINT := 1;
  v_contract_id BIGINT;
  v_counter INT := 0;
  v_mar NUMERIC;
  v_health INT;
  v_correlations JSONB;
  v_dim_legal INT;
  v_dim_financial INT;
  v_dim_operational INT;
  v_contract_count INT;
BEGIN
  -- Test-branch guard: skip if not enough seed contracts
  SELECT COUNT(*) INTO v_contract_count FROM contract WHERE is_active = TRUE;
  IF v_contract_count < 50 THEN
    RAISE NOTICE 'Skipping diverse-risk-score seed — only % active contracts (need >=50 for diversity).', v_contract_count;
    RETURN;
  END IF;
  -- Pick the top 120 contracts by value_aed across diversified buckets that
  -- DON'T already have a non-zero MAR. We pick by (contract_type, emirate)
  -- combinations to maximise spread on the bar chart.
  FOR v_contract_id IN
    WITH ranked AS (
      SELECT c.id, c.value_aed, c.counterparty_id, c.contract_type, c.emirate,
             ROW_NUMBER() OVER (PARTITION BY c.contract_type, c.emirate ORDER BY c.value_aed DESC NULLS LAST) AS rn
      FROM contract c
      WHERE c.is_active = TRUE
        AND c.counterparty_id IS NOT NULL
        AND c.value_aed IS NOT NULL
        AND c.value_aed > 0
        AND c.contract_type IN ('services','epc','concession','gas_spa')
        AND c.emirate IN ('abu_dhabi','dubai','sharjah','fujairah','ajman')
    )
    SELECT id FROM ranked WHERE rn <= 15  -- up to 15 per type×emirate bucket
    ORDER BY (id % 17)                     -- pseudo-random ordering
    LIMIT 130
  LOOP
    v_counter := v_counter + 1;

    -- Cycle through 4 risk profiles so we get a varied spread of MAR values
    -- and rule categories contributing to AVaR breakdown by risk_kind.
    CASE (v_counter % 7)
      WHEN 0 THEN  -- Sanctions exposure — large MAR
        v_mar := 80000000 + (v_counter % 13) * 7500000;
        v_health := 30 + (v_counter % 20);
        v_dim_legal := 75; v_dim_financial := 55; v_dim_operational := 45;
        v_correlations := jsonb_build_array(jsonb_build_object(
          'ruleId', 'rule.sanctions.ofac_hit',
          'correlationId', 100000 + v_counter,
          'severity', 'critical',
          'matchedAt', (v_now - INTERVAL '5 days')::text
        ));
      WHEN 1 THEN  -- Hormuz / weather force majeure — medium-large MAR
        v_mar := 35000000 + (v_counter % 11) * 4000000;
        v_health := 45 + (v_counter % 15);
        v_dim_legal := 60; v_dim_financial := 50; v_dim_operational := 70;
        v_correlations := jsonb_build_array(jsonb_build_object(
          'ruleId', 'rule.hormuz.fm_eligible',
          'correlationId', 200000 + v_counter,
          'severity', 'high',
          'matchedAt', (v_now - INTERVAL '3 days')::text
        ));
      WHEN 2 THEN  -- Brent / Murban / Dubai crude price band breach
        v_mar := 18000000 + (v_counter % 9) * 2500000;
        v_health := 60 + (v_counter % 12);
        v_dim_legal := 50; v_dim_financial := 75; v_dim_operational := 55;
        v_correlations := jsonb_build_array(jsonb_build_object(
          'ruleId', 'rule.brent.band_breach',
          'correlationId', 300000 + v_counter,
          'severity', 'medium',
          'matchedAt', (v_now - INTERVAL '7 days')::text
        ));
      WHEN 3 THEN  -- ESG / water stress / emission
        v_mar := 12000000 + (v_counter % 7) * 1800000;
        v_health := 55 + (v_counter % 15);
        v_dim_legal := 55; v_dim_financial := 60; v_dim_operational := 65;
        v_correlations := jsonb_build_array(jsonb_build_object(
          'ruleId', 'rule.esg.high_water_stress',
          'correlationId', 400000 + v_counter,
          'severity', 'medium',
          'matchedAt', (v_now - INTERVAL '4 days')::text
        ));
      WHEN 4 THEN  -- EPC SLA risk
        v_mar := 22000000 + (v_counter % 6) * 3000000;
        v_health := 50 + (v_counter % 18);
        v_dim_legal := 65; v_dim_financial := 50; v_dim_operational := 75;
        v_correlations := jsonb_build_array(jsonb_build_object(
          'ruleId', 'rule.epc_sla.penalty_window',
          'correlationId', 500000 + v_counter,
          'severity', 'medium',
          'matchedAt', (v_now - INTERVAL '6 days')::text
        ));
      WHEN 5 THEN  -- Regulatory / labor cascade
        v_mar := 8000000 + (v_counter % 5) * 1200000;
        v_health := 70 + (v_counter % 10);
        v_dim_legal := 70; v_dim_financial := 45; v_dim_operational := 50;
        v_correlations := jsonb_build_array(jsonb_build_object(
          'ruleId', 'rule.regulatory.labor_cascade',
          'correlationId', 600000 + v_counter,
          'severity', 'low',
          'matchedAt', (v_now - INTERVAL '8 days')::text
        ));
      ELSE  -- Low / healthy
        v_mar := 0;
        v_health := 85 + (v_counter % 10);
        v_dim_legal := 80; v_dim_financial := 75; v_dim_operational := 80;
        v_correlations := '[]'::jsonb;
    END CASE;

    -- Insert a fresh snapshot. Skip if a non-zero snapshot already exists.
    IF NOT EXISTS (
      SELECT 1 FROM risk_score rs
      WHERE rs.contract_id = v_contract_id
        AND rs.tenant_id   = v_tenant
        AND rs.mar_value   > 0
    ) THEN
      INSERT INTO risk_score (
        tenant_id, contract_id, health_score,
        dim_legal, dim_financial, dim_operational,
        dim_compliance, dim_reputational,
        mar_value, mar_currency, contributing_correlations,
        triggered_by, weights_version,
        calculated_at, created_by
      ) VALUES (
        v_tenant, v_contract_id, v_health,
        v_dim_legal, v_dim_financial, v_dim_operational,
        65 + (v_counter % 20), 60 + (v_counter % 15),
        v_mar, 'AED', v_correlations,
        'manual', 'v1.0',
        v_now - (v_counter * INTERVAL '17 minutes'),  -- spread over recent past
        v_admin
      );
    END IF;
  END LOOP;

  -- Refresh the MV that fn_avar_aggregate reads.
  REFRESH MATERIALIZED VIEW latest_risk_score;
END $$;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Data-seed migration. To roll back:
--   DELETE FROM risk_score WHERE (contributing_correlations->0->>'correlationId')::int >= 100000
--     AND (contributing_correlations->0->>'correlationId')::int < 700000;
--   REFRESH MATERIALIZED VIEW latest_risk_score;
-- ============================================================
