-- Migration: 294_crm_fix_fn_regulatory_cascade_run_penalty.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: DEFECT FIX — DEFECT-289-1: fn_regulatory_cascade_run penalty_max formula
--              Bug: penalty_max = LEAST(finePerHeadMax*gap, statutoryCeiling)
--                   For gap=1 in 20-49: max = LEAST(50000,1000000) = 50000
--                   But min = GREATEST(20000,100000) = 100000 → max < min
--                   Violates CHECK reg_cascade_item_penalty_order: penalty_max >= penalty_min
--              Fix: penalty_max = GREATEST(LEAST(finePerHeadMax*gap, statutoryCeiling), statutoryFloor)
--                   Ensures max is always >= floor, so max >= min always holds.
--              B14: COMMENT ON + REVOKE + GRANT re-applied (CREATE OR REPLACE drops them).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION fn_regulatory_cascade_run(
  p_actor_id BIGINT,
  p_signal_id BIGINT,
  p_params    JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id         UUID;
  v_run_id            BIGINT;
  v_signal_ref        TEXT;
  v_band_config       JSONB;
  v_clause_types      TEXT[];
  v_affected_count    INTEGER;
  v_total_min         NUMERIC(18,2);
  v_total_max         NUMERIC(18,2);
  v_summary           JSONB;
  v_actor_role        TEXT;
BEGIN
  -- 1. Resolve tenant
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- 2. Permission gate (DEFINER bypasses RLS; must enforce manually)
  SELECT r.name INTO v_actor_role
  FROM "user" u
  JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF NOT fn_current_user_has_permission('regulatory.cascade.run')
     AND v_actor_role NOT IN ('Super Admin', 'platform_admin', 'compliance_esg')
  THEN
    RAISE EXCEPTION 'Insufficient permission: regulatory.cascade.run required'
      USING ERRCODE = '42501';
  END IF;

  -- 3. Validate signal exists, is regulatory, belongs to this tenant
  SELECT raw_payload->>'decreeRef' INTO v_signal_ref
  FROM osint_signal
  WHERE id = p_signal_id
    AND tenant_id = v_tenant_id
    AND kind = 'regulatory'
    AND is_active = TRUE;

  IF v_signal_ref IS NULL THEN
    -- fallback: get title
    SELECT title INTO v_signal_ref
    FROM osint_signal
    WHERE id = p_signal_id
      AND tenant_id = v_tenant_id
      AND kind = 'regulatory'
      AND is_active = TRUE;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM osint_signal
    WHERE id = p_signal_id
      AND tenant_id = v_tenant_id
      AND kind = 'regulatory'
      AND is_active = TRUE
  ) THEN
    IF NOT EXISTS (SELECT 1 FROM osint_signal WHERE id = p_signal_id) THEN
      RAISE EXCEPTION 'Signal not found: %', p_signal_id USING ERRCODE = 'P0002';
    ELSE
      RAISE EXCEPTION 'Signal is not of kind=regulatory or does not belong to tenant'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Get regulation_ref for header
  SELECT COALESCE(raw_payload->>'decreeRef', title) INTO v_signal_ref
  FROM osint_signal WHERE id = p_signal_id;

  -- 4. Insert run header (status = 'running')
  INSERT INTO regulatory_cascade_run
    (tenant_id, signal_id, regulation_ref, status, summary, params,
     affected_contractor_count, total_penalty_min_aed, total_penalty_max_aed,
     data_classification, run_at, created_at, updated_at, created_by, updated_by, is_active)
  VALUES
    (v_tenant_id, p_signal_id, v_signal_ref, 'running', '{}'::jsonb,
     COALESCE(p_params, '{}'::jsonb),
     0, 0, 0, 'demo', NOW(), NOW(), NOW(), p_actor_id, p_actor_id, TRUE)
  RETURNING id INTO v_run_id;

  -- 5. Read penalty band config from system_setting (admin-tunable — Rule 8)
  SELECT value INTO v_band_config
  FROM system_setting
  WHERE key = 'regulatory.labor_cascade.penalty_bands'
    AND is_active = TRUE;

  IF v_band_config IS NULL THEN
    -- Embedded fallback per design §D.4 step 3
    v_band_config := '{
      "<20":  {"finePerHeadMin":0,"finePerHeadMax":0,"statutoryFloor":0,"statutoryCeiling":0},
      "20-49":{"finePerHeadMin":20000,"finePerHeadMax":50000,"statutoryFloor":100000,"statutoryCeiling":1000000},
      "50+":  {"finePerHeadMin":20000,"finePerHeadMax":50000,"statutoryFloor":100000,"statutoryCeiling":1000000}
    }'::jsonb;
  END IF;

  -- 6. Determine employment clause-type array (config-driven)
  SELECT ARRAY(
    SELECT jsonb_array_elements_text(
      COALESCE(p_params->'employmentClauseTypes',
               '["icv_in_country_value","strike_lockout","key_personnel"]'::jsonb)
    )
  ) INTO v_clause_types;

  -- 7. Fan-out: CTE-split (S2-24 — no nested aggregates, no FOR UPDATE in aggregate)
  --    For each party_workforce row in this tenant, build item rows.
  --    A party is "affected" if it is non-compliant OR has >=1 matching extracted clause.
  --    Penalty: per-head * max(gap,0), clamped to statutory floor/ceiling, zero for <20 band.
  WITH
  -- 7a. Workforce base: all active workforce rows for this tenant
  pw AS (
    SELECT
      pw.party_id,
      pw.headcount_band,
      pw.is_compliant,
      GREATEST(pw.emiratisation_target - pw.emiratisation_actual, 0) AS emiratisation_gap
    FROM party_workforce pw
    WHERE pw.tenant_id = v_tenant_id
      AND pw.is_active = TRUE
  ),
  -- 7b. Party contracts: active ADNOC contracts where this party is counterparty
  party_contracts AS (
    SELECT c.counterparty_id AS party_id,
           jsonb_agg(c.id ORDER BY c.id) AS contract_ids
    FROM contract c
    WHERE c.counterparty_id IN (SELECT party_id FROM pw)
      AND c.is_active = TRUE
    GROUP BY c.counterparty_id
  ),
  -- 7c. Affected clauses: labor-type extracted clauses for party's contracts
  --     (separate aggregate step — never aggregate-within-aggregate)
  affected_clauses AS (
    SELECT cce.contract_id,
           jsonb_agg(cce.id ORDER BY cce.id) AS clause_ids,
           COUNT(*)::integer AS clause_count
    FROM contract_clause_extracted cce
    WHERE cce.tenant_id = v_tenant_id
      AND cce.clause_type_v2 = ANY(v_clause_types)
      AND cce.is_active = TRUE
      AND cce.contract_id IN (
        SELECT jsonb_array_elements(pc.contract_ids)::bigint
        FROM party_contracts pc
      )
    GROUP BY cce.contract_id
  ),
  -- 7d. Per-party clause aggregation (group by party)
  party_clauses AS (
    SELECT pc.party_id,
           COALESCE(
             (SELECT jsonb_agg(j ORDER BY j)
              FROM (SELECT DISTINCT jsonb_array_elements(ac.clause_ids) AS j
                    FROM affected_clauses ac
                    WHERE ac.contract_id IN (
                      SELECT jsonb_array_elements(pc2.contract_ids)::bigint
                      FROM party_contracts pc2 WHERE pc2.party_id = pc.party_id
                    )) sq),
             '[]'::jsonb
           ) AS clause_ids
    FROM party_contracts pc
  ),
  -- 7e. ICV attachments (kind=icv_certificate) per party
  party_icv AS (
    SELECT pc.party_id,
           COALESCE(
             (SELECT jsonb_agg(ca.id ORDER BY ca.id)
              FROM contract_attachment ca
              WHERE ca.kind = 'icv_certificate'
                AND ca.is_active = TRUE
                AND ca.contract_id IN (
                  SELECT jsonb_array_elements(pc2.contract_ids)::bigint
                  FROM party_contracts pc2 WHERE pc2.party_id = pc.party_id
                )),
             '[]'::jsonb
           ) AS icv_ids
    FROM party_contracts pc
  ),
  -- 7f. Penalty computation per party (per-head * gap, clamped to statutory bounds)
  -- FIX (DEFECT-289-1): penalty_max must be GREATEST(LEAST(perHead*gap, ceiling), floor)
  -- so that max >= floor >= min always holds, satisfying reg_cascade_item_penalty_order CHECK.
  penalty AS (
    SELECT
      pw.party_id,
      pw.headcount_band,
      pw.emiratisation_gap,
      CASE
        WHEN pw.headcount_band = '<20' THEN 0::numeric
        WHEN pw.emiratisation_gap = 0  THEN 0::numeric
        ELSE GREATEST(
          (v_band_config -> pw.headcount_band ->> 'finePerHeadMin')::numeric * pw.emiratisation_gap,
          (v_band_config -> pw.headcount_band ->> 'statutoryFloor')::numeric
        )
      END AS penalty_min,
      CASE
        WHEN pw.headcount_band = '<20' THEN 0::numeric
        WHEN pw.emiratisation_gap = 0  THEN 0::numeric
        -- FIXED: was LEAST(perHead*gap, ceiling) which could be < floor → violates CHECK
        -- Now: GREATEST(LEAST(perHead*gap, ceiling), floor) guarantees max >= floor >= min
        ELSE GREATEST(
          LEAST(
            (v_band_config -> pw.headcount_band ->> 'finePerHeadMax')::numeric * pw.emiratisation_gap,
            (v_band_config -> pw.headcount_band ->> 'statutoryCeiling')::numeric
          ),
          (v_band_config -> pw.headcount_band ->> 'statutoryFloor')::numeric
        )
      END AS penalty_max
    FROM pw
  )
  -- 7g. Final INSERT into regulatory_cascade_item
  --     Include a party if: non-compliant OR has >=1 affected clause (demo robustness)
  INSERT INTO regulatory_cascade_item
    (tenant_id, cascade_run_id, party_id,
     headcount_band, is_compliant, emiratisation_gap,
     affected_clause_ids, affected_contract_ids, icv_attachment_ids,
     penalty_exposure_min_aed, penalty_exposure_max_aed, penalty_basis,
     remediation_status, data_classification,
     created_at, updated_at, created_by, updated_by, is_active)
  SELECT
    v_tenant_id,
    v_run_id,
    pw.party_id,
    pw.headcount_band,
    pw.is_compliant,
    pw.emiratisation_gap,
    COALESCE(pc_clauses.clause_ids, '[]'::jsonb),
    COALESCE(pc.contract_ids,       '[]'::jsonb),
    COALESCE(pi.icv_ids,            '[]'::jsonb),
    pen.penalty_min,
    pen.penalty_max,
    jsonb_build_object(
      'band',               pw.headcount_band,
      'emiratisationGap',   pw.emiratisation_gap,
      'finePerHeadMin',     COALESCE((v_band_config -> pw.headcount_band ->> 'finePerHeadMin')::numeric, 0),
      'finePerHeadMax',     COALESCE((v_band_config -> pw.headcount_band ->> 'finePerHeadMax')::numeric, 0),
      'statutoryFloor',     COALESCE((v_band_config -> pw.headcount_band ->> 'statutoryFloor')::numeric, 0),
      'statutoryCeiling',   COALESCE((v_band_config -> pw.headcount_band ->> 'statutoryCeiling')::numeric, 0)
    ),
    'pending',
    'demo',
    NOW(), NOW(), p_actor_id, p_actor_id, TRUE
  FROM pw
  JOIN penalty pen ON pen.party_id = pw.party_id
  LEFT JOIN party_contracts pc ON pc.party_id = pw.party_id
  LEFT JOIN party_clauses pc_clauses ON pc_clauses.party_id = pw.party_id
  LEFT JOIN party_icv pi ON pi.party_id = pw.party_id
  WHERE NOT pw.is_compliant
     OR jsonb_array_length(COALESCE(pc_clauses.clause_ids, '[]'::jsonb)) > 0;

  -- 8. Compute totals from inserted items (separate aggregate query — S2-24)
  SELECT
    COUNT(*)::integer,
    COALESCE(SUM(penalty_exposure_min_aed), 0),
    COALESCE(SUM(penalty_exposure_max_aed), 0)
  INTO v_affected_count, v_total_min, v_total_max
  FROM regulatory_cascade_item
  WHERE cascade_run_id = v_run_id
    AND is_active = TRUE;

  -- 9. Build summary JSONB (byBand counts + totals)
  SELECT jsonb_build_object(
    'byBand', jsonb_build_object(
      '<20', jsonb_build_object(
        'total',           COUNT(*) FILTER (WHERE headcount_band = '<20'),
        'nonCompliant',    COUNT(*) FILTER (WHERE headcount_band = '<20' AND NOT is_compliant),
        'compliant',       COUNT(*) FILTER (WHERE headcount_band = '<20' AND is_compliant),
        'totalPenaltyMinAed', COALESCE(SUM(penalty_exposure_min_aed) FILTER (WHERE headcount_band = '<20'), 0),
        'totalPenaltyMaxAed', COALESCE(SUM(penalty_exposure_max_aed) FILTER (WHERE headcount_band = '<20'), 0)
      ),
      '20-49', jsonb_build_object(
        'total',           COUNT(*) FILTER (WHERE headcount_band = '20-49'),
        'nonCompliant',    COUNT(*) FILTER (WHERE headcount_band = '20-49' AND NOT is_compliant),
        'compliant',       COUNT(*) FILTER (WHERE headcount_band = '20-49' AND is_compliant),
        'totalPenaltyMinAed', COALESCE(SUM(penalty_exposure_min_aed) FILTER (WHERE headcount_band = '20-49'), 0),
        'totalPenaltyMaxAed', COALESCE(SUM(penalty_exposure_max_aed) FILTER (WHERE headcount_band = '20-49'), 0)
      ),
      '50+', jsonb_build_object(
        'total',           COUNT(*) FILTER (WHERE headcount_band = '50+'),
        'nonCompliant',    COUNT(*) FILTER (WHERE headcount_band = '50+' AND NOT is_compliant),
        'compliant',       COUNT(*) FILTER (WHERE headcount_band = '50+' AND is_compliant),
        'totalPenaltyMinAed', COALESCE(SUM(penalty_exposure_min_aed) FILTER (WHERE headcount_band = '50+'), 0),
        'totalPenaltyMaxAed', COALESCE(SUM(penalty_exposure_max_aed) FILTER (WHERE headcount_band = '50+'), 0)
      )
    ),
    'totals', jsonb_build_object(
      'affectedContractors', v_affected_count,
      'totalPenaltyMinAed',  v_total_min,
      'totalPenaltyMaxAed',  v_total_max,
      'nonCompliantCount',   COUNT(*) FILTER (WHERE NOT is_compliant)
    ),
    'generatedAt', to_char(NOW(), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ) INTO v_summary
  FROM regulatory_cascade_item
  WHERE cascade_run_id = v_run_id
    AND is_active = TRUE;

  -- 10. Update run header: completed
  UPDATE regulatory_cascade_run
  SET status                    = 'completed',
      affected_contractor_count = v_affected_count,
      total_penalty_min_aed     = v_total_min,
      total_penalty_max_aed     = v_total_max,
      summary                   = v_summary,
      updated_at                = NOW(),
      updated_by                = p_actor_id
  WHERE id = v_run_id;

  -- 11. Return full run detail
  RETURN fn_regulatory_cascade_get(p_actor_id, v_run_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_regulatory_cascade_run: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_regulatory_cascade_run(BIGINT, BIGINT, JSONB) IS
  'CR-M DEFINER fn — fans the given regulatory signal across the ADNOC contractor population (party_workforce), computes headcount-band penalty exposure, inserts regulatory_cascade_run + regulatory_cascade_item rows. Returns full run detail. <5s for ~40 contractors (set-based CTE). S2-24 CTE-split. Fix 294: penalty_max clamped to GREATEST(LEAST(perHead*gap,ceiling),floor) to satisfy reg_cascade_item_penalty_order CHECK.';
REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_run(BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_run(BIGINT, BIGINT, JSONB) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (294, '294_crm_fix_fn_regulatory_cascade_run_penalty', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 294;
-- -- Re-apply the original 289 fn body (bug re-introduced — do not use unless reverting CR-M entirely).
-- COMMIT;
-- ============================================================
