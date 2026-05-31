-- Migration: 377_khalid_cascade_get_add_ar_title.sql
-- Unit: Khalid Compliance QA Phase 3.6 (2026-05-31)
-- Fixes K20 (cascade detail H1 stays English in AR mode) by re-emitting
-- fn_regulatory_cascade_get with regulationRefAr in the return.

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

  IF NOT EXISTS (
    SELECT 1 FROM regulatory_cascade_run
    WHERE id = p_run_id AND tenant_id = v_tenant_id AND is_active = TRUE
  ) THEN
    RETURN NULL;
  END IF;

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

  SELECT jsonb_build_object(
    'id',                     r.id,
    'tenantId',               r.tenant_id,
    'signalId',               r.signal_id,
    'regulationRef',          r.regulation_ref,
    -- K20 fix — surface the Arabic title so the FE H1 can read it in AR mode.
    'regulationRefAr',        r.regulation_ref_ar,
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

REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_get(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_get(BIGINT, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_regulatory_cascade_get(BIGINT, BIGINT) IS
  'CR-M cascade run detail (K20 patch: includes regulationRefAr from mig 372 column).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (377, '377_khalid_cascade_get_add_ar_title', NOW())
ON CONFLICT (version) DO NOTHING;
