-- Migration: 197_rces_fn_contract_audit_rights_list.sql
-- Unit: Unit-3 (R-CES — Audit Rights Tracker per-contract drilldown)
-- Description: New fn_contract_audit_rights_list(p_actor_id, p_contract_id)
--              RETURNS jsonb. Per-contract audit-rights inventory: lists all
--              clause_type_v2='audit_rights' rows for the contract +
--              parameters + computed daysToExpiry + severity. Empty list when
--              no audit_rights clauses (NEVER errors on empty).
--
--              Permission gate: caller must have contract.read OR
--              insights.compliance_esg OR insights.executive. The contract is
--              not row-filtered separately; if the caller has contract.read
--              they can see contract data within RLS scope. SECURITY INVOKER
--              keeps RLS active (vs SECURITY DEFINER which would bypass).
--
--              S2-21: explicit REVOKE/GRANT for the new fn.
-- Reference: GAP-REPORT-COMPLIANCE-ESG H5, R-CES6 round.
-- Rollback: see ROLLBACK section.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_contract_audit_rights_list(p_actor_id bigint, p_contract_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY INVOKER
AS $function$
DECLARE
  v_result JSONB;
  v_rows JSONB;
  v_contract_exists BOOLEAN;
BEGIN
  -- Permission gate
  IF NOT (
    fn_current_user_has_permission('contract.read')
    OR fn_current_user_has_permission('insights.compliance_esg')
    OR fn_current_user_has_permission('insights.executive')
  ) THEN
    RAISE EXCEPTION 'permission_denied: contract.read or insights.compliance_esg required' USING ERRCODE='42501';
  END IF;

  -- Input validation
  IF p_actor_id IS NULL OR p_actor_id <= 0 THEN
    RAISE EXCEPTION 'invalid_actor_id' USING ERRCODE='22023';
  END IF;
  IF p_contract_id IS NULL OR p_contract_id <= 0 THEN
    RAISE EXCEPTION 'invalid_contract_id' USING ERRCODE='22023';
  END IF;

  -- Verify contract exists (RLS-scoped via SECURITY INVOKER)
  SELECT EXISTS (SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE)
  INTO v_contract_exists;

  IF NOT v_contract_exists THEN
    RAISE EXCEPTION 'contract_not_found: %', p_contract_id USING ERRCODE='P0002';
  END IF;

  -- Collect audit_rights clauses for the contract
  SELECT COALESCE(jsonb_agg(item ORDER BY days_to_expiry_sort ASC NULLS LAST), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      jsonb_build_object(
        'clauseId',     cce.id::text,
        'clauseType',   cce.clause_type_v2,
        'parameters',   cce.parameters,
        'pageNo',       cce.page_no,
        'confidence',   cce.confidence,
        'summaryEn',    cce.summary_en,
        'summaryAr',    cce.summary_ar,
        'reviewStatus', cce.review_status,
        'extractedAt',  cce.created_at,
        'daysToExpiry', CASE
          WHEN cce.parameters ? 'endDate' THEN
            ((cce.parameters->>'endDate')::date - CURRENT_DATE)::integer
          ELSE NULL
        END,
        'severity', CASE
          WHEN cce.parameters ? 'endDate' THEN
            CASE
              WHEN ((cce.parameters->>'endDate')::date - CURRENT_DATE) < 30 THEN 'high'
              WHEN ((cce.parameters->>'endDate')::date - CURRENT_DATE) < 90 THEN 'medium'
              ELSE 'low'
            END
          ELSE 'unknown'
        END
      ) AS item,
      CASE
        WHEN cce.parameters ? 'endDate' THEN
          ((cce.parameters->>'endDate')::date - CURRENT_DATE)::integer
        ELSE NULL
      END AS days_to_expiry_sort
    FROM contract_clause_extracted cce
    WHERE cce.contract_id = p_contract_id
      AND cce.is_active = TRUE
      AND cce.clause_type_v2 = 'audit_rights'
      AND cce.tenant_id = current_setting('app.current_tenant_id', true)::uuid
  ) sub;

  v_result := jsonb_build_object(
    'contractId',         p_contract_id::text,
    'auditRightsClauses', v_rows,
    'count',              jsonb_array_length(v_rows)
  );

  RETURN v_result;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_contract_audit_rights_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

-- S2-21 explicit guard for the new function.
REVOKE EXECUTE ON FUNCTION public.fn_contract_audit_rights_list(bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_contract_audit_rights_list(bigint, bigint) TO neondb_owner;
COMMENT ON FUNCTION public.fn_contract_audit_rights_list(bigint, bigint) IS
  'Per-contract audit-rights inventory: lists all contract_clause_extracted rows where clause_type_v2=audit_rights, with parameters + computed daysToExpiry + severity band. SECURITY INVOKER preserves RLS on contract scope. Empty list when no audit_rights clauses — never errors on empty.';

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (197, 'Unit-3 R-CES6: fn_contract_audit_rights_list — per-contract audit rights drilldown', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS public.fn_contract_audit_rights_list(bigint, bigint);
-- DELETE FROM schema_migrations WHERE version = 197;
