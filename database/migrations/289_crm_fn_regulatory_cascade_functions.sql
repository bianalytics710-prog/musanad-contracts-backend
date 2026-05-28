-- Migration: 289_crm_fn_regulatory_cascade_functions.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: All 5 regulatory cascade fn_'s:
--              fn_regulatory_cascade_run      (DEFINER VOLATILE — workhorse; CTE fan-out)
--              fn_regulatory_cascade_list     (INVOKER STABLE — paginated list)
--              fn_regulatory_cascade_get      (INVOKER STABLE — full run + items)
--              fn_regulatory_cascade_item_set_status (INVOKER VOLATILE — status advance)
--              fn_regulatory_cascade_item_link_draft (INVOKER VOLATILE — link advisory draft)
--              Mandatory dedicated fn migration (agent rule).
--              Each fn: COMMENT ON + REVOKE EXECUTE FROM PUBLIC + GRANT TO neondb_owner (B14/S2-21/S2-27).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- D.4 fn_regulatory_cascade_run
-- VOLATILE, SECURITY DEFINER (must INSERT across write-deny-RLS context)
-- SET search_path for DEFINER safety
-- Gating: regulatory.cascade.run (or Super Admin / platform_admin / compliance_esg)
-- CTE-split fan-out (S2-24 — no nested jsonb_agg)
-- ============================================================

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
        ELSE LEAST(
          (v_band_config -> pw.headcount_band ->> 'finePerHeadMax')::numeric * pw.emiratisation_gap,
          (v_band_config -> pw.headcount_band ->> 'statutoryCeiling')::numeric
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
  'CR-M DEFINER fn — fans the given regulatory signal across the ADNOC contractor population (party_workforce), computes headcount-band penalty exposure, inserts regulatory_cascade_run + regulatory_cascade_item rows. Returns full run detail. <5s for ~40 contractors (set-based CTE). S2-24 CTE-split.';
REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_run(BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_run(BIGINT, BIGINT, JSONB) TO neondb_owner;

-- ============================================================
-- D.5 fn_regulatory_cascade_list
-- STABLE, SECURITY INVOKER
-- Gating: regulatory.cascade.read
-- ============================================================

CREATE OR REPLACE FUNCTION fn_regulatory_cascade_list(
  p_actor_id  BIGINT,
  p_signal_id BIGINT  DEFAULT NULL,
  p_limit     INTEGER DEFAULT 50,
  p_offset    INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_total     INTEGER;
  v_data      JSONB;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF NOT fn_current_user_has_permission('regulatory.cascade.read') THEN
    RAISE EXCEPTION 'Insufficient permission: regulatory.cascade.read required'
      USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*)::integer INTO v_total
  FROM regulatory_cascade_run r
  WHERE r.tenant_id = v_tenant_id
    AND r.is_active = TRUE
    AND (p_signal_id IS NULL OR r.signal_id = p_signal_id);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',                     r.id,
      'signalId',               r.signal_id,
      'regulationRef',          r.regulation_ref,
      'status',                 r.status,
      'runAt',                  to_char(r.run_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'affectedContractorCount', r.affected_contractor_count,
      'totalPenaltyMinAed',     r.total_penalty_min_aed,
      'totalPenaltyMaxAed',     r.total_penalty_max_aed,
      'summary',                r.summary,
      'createdByName',          concat_ws(' ', u.first_name, u.last_name)
    ) ORDER BY r.run_at DESC
  ), '[]'::jsonb) INTO v_data
  FROM regulatory_cascade_run r
  LEFT JOIN "user" u ON u.id = r.created_by
  WHERE r.tenant_id = v_tenant_id
    AND r.is_active = TRUE
    AND (p_signal_id IS NULL OR r.signal_id = p_signal_id)
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',  v_total,
      'limit',  p_limit,
      'offset', p_offset
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_regulatory_cascade_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_regulatory_cascade_list(BIGINT, BIGINT, INTEGER, INTEGER) IS
  'CR-M — paginated list of regulatory cascade runs (ordered run_at DESC). Gated: regulatory.cascade.read.';
REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_list(BIGINT, BIGINT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_list(BIGINT, BIGINT, INTEGER, INTEGER) TO neondb_owner;

-- ============================================================
-- D.6 fn_regulatory_cascade_get
-- STABLE, SECURITY INVOKER
-- Gating: regulatory.cascade.read
-- Returns run header + items array (N+1 prevented by CTE jsonb_agg)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_regulatory_cascade_get(
  p_actor_id BIGINT,
  p_run_id   BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_run       JSONB;
  v_items     JSONB;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF NOT fn_current_user_has_permission('regulatory.cascade.read') THEN
    RAISE EXCEPTION 'Insufficient permission: regulatory.cascade.read required'
      USING ERRCODE = '42501';
  END IF;

  -- Check run exists
  IF NOT EXISTS (
    SELECT 1 FROM regulatory_cascade_run
    WHERE id = p_run_id AND tenant_id = v_tenant_id AND is_active = TRUE
  ) THEN
    RETURN NULL;
  END IF;

  -- Build items array (one query — N+1 prevented)
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',                     i.id,
      'partyId',                i.party_id,
      'contractorNameEn',       p.name_en,
      'contractorNameAr',       p.name_ar,
      'emirate',                p.emirate,
      'headcountBand',          i.headcount_band,
      'isCompliant',            i.is_compliant,
      'emiratisationGap',       i.emiratisation_gap,
      'affectedClauseCount',    jsonb_array_length(i.affected_clause_ids),
      'affectedClauseIds',      i.affected_clause_ids,
      'affectedContractIds',    i.affected_contract_ids,
      'icvAttachmentIds',       i.icv_attachment_ids,
      'icvAttachmentCount',     jsonb_array_length(i.icv_attachment_ids),
      'penaltyExposureMinAed',  i.penalty_exposure_min_aed,
      'penaltyExposureMaxAed',  i.penalty_exposure_max_aed,
      'penaltyBasis',           i.penalty_basis,
      'remediationStatus',      i.remediation_status,
      'advisoryDraftId',        i.advisory_draft_id,
      'advisoryDraftStatus',    ad.approval_status
    ) ORDER BY i.id
  ), '[]'::jsonb) INTO v_items
  FROM regulatory_cascade_item i
  JOIN party p ON p.id = i.party_id
  LEFT JOIN advisory_draft ad ON ad.id = i.advisory_draft_id
  WHERE i.cascade_run_id = p_run_id
    AND i.tenant_id = v_tenant_id
    AND i.is_active = TRUE;

  -- Build run header
  SELECT jsonb_build_object(
    'id',                     r.id,
    'tenantId',               r.tenant_id,
    'signalId',               r.signal_id,
    'regulationRef',          r.regulation_ref,
    'status',                 r.status,
    'summary',                r.summary,
    'params',                 r.params,
    'affectedContractorCount', r.affected_contractor_count,
    'totalPenaltyMinAed',     r.total_penalty_min_aed,
    'totalPenaltyMaxAed',     r.total_penalty_max_aed,
    'dataClassification',     r.data_classification,
    'runAt',                  to_char(r.run_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'createdAt',              to_char(r.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'createdByName',          concat_ws(' ', u.first_name, u.last_name),
    'items',                  v_items
  ) INTO v_run
  FROM regulatory_cascade_run r
  LEFT JOIN "user" u ON u.id = r.created_by
  WHERE r.id = p_run_id
    AND r.tenant_id = v_tenant_id
    AND r.is_active = TRUE;

  RETURN v_run;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_regulatory_cascade_get: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_regulatory_cascade_get(BIGINT, BIGINT) IS
  'CR-M — full cascade run detail with per-contractor items array. N+1 prevented by single jsonb_agg CTE. Returns NULL if run not found. Gated: regulatory.cascade.read.';
REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_get(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_get(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- D.7 fn_regulatory_cascade_item_set_status
-- VOLATILE, SECURITY INVOKER
-- Gating: regulatory.cascade.read (Q6 decision — read-capable personas can advance)
-- SELECT FOR UPDATE row lock (S2-17)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_regulatory_cascade_item_set_status(
  p_actor_id BIGINT,
  p_item_id  BIGINT,
  p_status   TEXT,
  p_note     TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_item      regulatory_cascade_item%ROWTYPE;
  v_run_id    BIGINT;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF NOT fn_current_user_has_permission('regulatory.cascade.read') THEN
    RAISE EXCEPTION 'Insufficient permission: regulatory.cascade.read required'
      USING ERRCODE = '42501';
  END IF;

  -- Validate status enum
  IF p_status NOT IN ('pending','in_progress','amended','dismissed','resolved') THEN
    RAISE EXCEPTION 'Invalid remediation_status: %. Must be one of pending/in_progress/amended/dismissed/resolved', p_status
      USING ERRCODE = '22023';
  END IF;

  -- Row lock (S2-17)
  SELECT * INTO v_item
  FROM regulatory_cascade_item
  WHERE id = p_item_id
    AND tenant_id = v_tenant_id
    AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cascade item not found: %', p_item_id USING ERRCODE = 'P0002';
  END IF;

  UPDATE regulatory_cascade_item
  SET remediation_status = p_status,
      remediation_note   = p_note,
      updated_by         = p_actor_id,
      updated_at         = NOW()
  WHERE id = p_item_id;

  -- Return item JSONB via get (re-use the run get logic; build item directly here for efficiency)
  RETURN (
    SELECT jsonb_build_object(
      'id',                     i.id,
      'partyId',                i.party_id,
      'contractorNameEn',       p.name_en,
      'contractorNameAr',       p.name_ar,
      'emirate',                p.emirate,
      'headcountBand',          i.headcount_band,
      'isCompliant',            i.is_compliant,
      'emiratisationGap',       i.emiratisation_gap,
      'affectedClauseCount',    jsonb_array_length(i.affected_clause_ids),
      'affectedClauseIds',      i.affected_clause_ids,
      'affectedContractIds',    i.affected_contract_ids,
      'icvAttachmentIds',       i.icv_attachment_ids,
      'icvAttachmentCount',     jsonb_array_length(i.icv_attachment_ids),
      'penaltyExposureMinAed',  i.penalty_exposure_min_aed,
      'penaltyExposureMaxAed',  i.penalty_exposure_max_aed,
      'penaltyBasis',           i.penalty_basis,
      'remediationStatus',      i.remediation_status,
      'advisoryDraftId',        i.advisory_draft_id,
      'advisoryDraftStatus',    ad.approval_status
    )
    FROM regulatory_cascade_item i
    JOIN party p ON p.id = i.party_id
    LEFT JOIN advisory_draft ad ON ad.id = i.advisory_draft_id
    WHERE i.id = p_item_id
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_regulatory_cascade_item_set_status: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_regulatory_cascade_item_set_status(BIGINT, BIGINT, TEXT, TEXT) IS
  'CR-M — advance remediation_status on a cascade item (FOR UPDATE row lock). Gated: regulatory.cascade.read.';
REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_item_set_status(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_item_set_status(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

-- ============================================================
-- D.8 fn_regulatory_cascade_item_link_draft
-- VOLATILE, SECURITY INVOKER
-- Gating: advisory.draft.review OR regulatory.cascade.run
-- Called by BE service AFTER fn_advisory_draft_generate returns draftId (S2-19 seam)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_regulatory_cascade_item_link_draft(
  p_actor_id          BIGINT,
  p_item_id           BIGINT,
  p_advisory_draft_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_item      regulatory_cascade_item%ROWTYPE;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- Permission gate: advisory.draft.review OR regulatory.cascade.run
  IF NOT fn_current_user_has_permission('advisory.draft.review')
     AND NOT fn_current_user_has_permission('regulatory.cascade.run') THEN
    RAISE EXCEPTION 'Insufficient permission: advisory.draft.review or regulatory.cascade.run required'
      USING ERRCODE = '42501';
  END IF;

  -- Validate item exists
  SELECT * INTO v_item
  FROM regulatory_cascade_item
  WHERE id = p_item_id
    AND tenant_id = v_tenant_id
    AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cascade item not found: %', p_item_id USING ERRCODE = 'P0002';
  END IF;

  -- Validate draft exists in tenant
  IF NOT EXISTS (
    SELECT 1 FROM advisory_draft
    WHERE id = p_advisory_draft_id
      AND tenant_id = v_tenant_id
      AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Advisory draft not found: %', p_advisory_draft_id USING ERRCODE = 'P0002';
  END IF;

  -- Link draft + advance status to 'amended' if currently pending/in_progress
  UPDATE regulatory_cascade_item
  SET advisory_draft_id  = p_advisory_draft_id,
      remediation_status = CASE
        WHEN remediation_status IN ('pending','in_progress') THEN 'amended'
        ELSE remediation_status
      END,
      updated_by         = p_actor_id,
      updated_at         = NOW()
  WHERE id = p_item_id;

  -- Return item JSONB
  RETURN (
    SELECT jsonb_build_object(
      'id',                     i.id,
      'partyId',                i.party_id,
      'contractorNameEn',       p.name_en,
      'contractorNameAr',       p.name_ar,
      'emirate',                p.emirate,
      'headcountBand',          i.headcount_band,
      'isCompliant',            i.is_compliant,
      'emiratisationGap',       i.emiratisation_gap,
      'affectedClauseCount',    jsonb_array_length(i.affected_clause_ids),
      'affectedClauseIds',      i.affected_clause_ids,
      'affectedContractIds',    i.affected_contract_ids,
      'icvAttachmentIds',       i.icv_attachment_ids,
      'icvAttachmentCount',     jsonb_array_length(i.icv_attachment_ids),
      'penaltyExposureMinAed',  i.penalty_exposure_min_aed,
      'penaltyExposureMaxAed',  i.penalty_exposure_max_aed,
      'penaltyBasis',           i.penalty_basis,
      'remediationStatus',      i.remediation_status,
      'advisoryDraftId',        i.advisory_draft_id,
      'advisoryDraftStatus',    ad.approval_status
    )
    FROM regulatory_cascade_item i
    JOIN party p ON p.id = i.party_id
    LEFT JOIN advisory_draft ad ON ad.id = i.advisory_draft_id
    WHERE i.id = p_item_id
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_regulatory_cascade_item_link_draft: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_regulatory_cascade_item_link_draft(BIGINT, BIGINT, BIGINT) IS
  'CR-M — links advisory_draft_id to a cascade item and advances remediation_status to amended. Called by BE service AFTER fn_advisory_draft_generate (S2-19 seam). Gated: advisory.draft.review OR regulatory.cascade.run.';
REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_item_link_draft(BIGINT, BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_item_link_draft(BIGINT, BIGINT, BIGINT) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (289, '289_crm_fn_regulatory_cascade_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 289;
-- DROP FUNCTION IF EXISTS fn_regulatory_cascade_run(BIGINT, BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_regulatory_cascade_list(BIGINT, BIGINT, INTEGER, INTEGER);
-- DROP FUNCTION IF EXISTS fn_regulatory_cascade_get(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_regulatory_cascade_item_set_status(BIGINT, BIGINT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_regulatory_cascade_item_link_draft(BIGINT, BIGINT, BIGINT);
-- COMMIT;
-- ============================================================
