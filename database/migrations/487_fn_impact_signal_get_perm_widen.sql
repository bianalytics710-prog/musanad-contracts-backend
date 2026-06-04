-- Migration: 487_fn_impact_signal_get_perm_widen.sql
-- Module: Impact Watch — Executive demo polish (E-rev round E follow-up)
-- Date: 2026-06-02
--
-- Background: mig 349 widened fn_impact_signal_list's perm gate so executive
-- and compliance_esg could see Impact Watch (BUG-008). fn_impact_signal_get
-- was never patched — it still rejects unless the caller holds
-- contract.read.department OR contract.edit. So the executive sees commodity
-- signals in the LIST (correct: 5 impacted contracts) but gets 403 the
-- moment they click into the detail (impactedContracts empty + Explain with
-- AI fails because the controller fetches the signal via fn_impact_signal_get
-- first).
--
-- Fix: mirror mig 349's broadened perm check inside fn_impact_signal_get.
-- Same code list, same OR semantics. Body otherwise byte-for-byte identical
-- to migration 079.

CREATE OR REPLACE FUNCTION fn_impact_signal_get(
  p_actor_id BIGINT,
  p_signal_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_row JSONB;
  v_contracts JSONB;
BEGIN
  -- E-rev-E (2026-06-02): accept the same broad code set as fn_impact_signal_list
  -- (mig 349). Executive + compliance_esg need to see signal detail so the
  -- "5 impacted contracts" count from the list actually opens into a table.
  IF NOT fn_current_user_has_permission('contract.read.department')
     AND NOT fn_current_user_has_permission('contract.read.all')
     AND NOT fn_current_user_has_permission('contract.edit')
     AND NOT fn_current_user_has_permission('insights.executive')
     AND NOT fn_current_user_has_permission('insights.compliance_esg') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',                s.id,
    'extId',             s.ext_id,
    'category',          s.category,
    'source',            s.source,
    'severity',          s.severity,
    'titleEn',           s.title_en,
    'titleAr',           s.title_ar,
    'descriptionEn',     s.description_en,
    'descriptionAr',     s.description_ar,
    'affectedClauseCategories', s.affected_clause_categories,
    'publishedDate',     s.published_date,
    'effectiveDate',     s.effective_date,
    'complianceDeadline', s.compliance_deadline,
    'createdAt',         s.created_at,
    'updatedAt',         s.updated_at
  ) INTO v_row
  FROM impact_signal s WHERE s.id = p_signal_id AND s.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'impact_signal_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             isc.id,
    'contractId',     c.id,
    'contractNumber', c.contract_number,
    'titleEn',        c.title_en,
    'impactScore',    isc.impact_score,
    'status',         isc.status,
    'reviewedAt',     isc.reviewed_at
  ) ORDER BY isc.impact_score DESC, c.contract_number), '[]'::jsonb) INTO v_contracts
  FROM impact_signal_contract isc
  JOIN contract c ON c.id = isc.contract_id
  WHERE isc.signal_id = p_signal_id AND isc.is_active = TRUE AND c.is_active = TRUE;

  RETURN v_row || jsonb_build_object('impactedContracts', v_contracts);
END;
$$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (487, '487_fn_impact_signal_get_perm_widen', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;
