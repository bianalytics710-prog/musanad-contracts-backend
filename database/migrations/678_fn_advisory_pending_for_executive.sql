-- ============================================================================
-- Migration 678 — fn_advisory_draft_pending_for_executive
-- ============================================================================
-- Powers the new "Pending Advisories" sidebar entry on the executive
-- surface. Returns drafts where:
--   - approval_status = 'unapproved'
--   - template_context.currentReviewer = 'executive'
--   - not dispatched yet (covered by status filter; defensive WHERE here)
--
-- Per-row shape: id, draftType, templateDisplayEn, contractId,
-- contractNumber, contractTitle, counterpartyName, linkedRiskCaseId,
-- createdAt, createdByName, generatedTextEn/Ar so the Modify dialog can
-- prefill the textarea without a second fetch.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_advisory_draft_pending_for_executive(
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_tenant_id UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'actorId required' USING ERRCODE = '22023';
  END IF;

  RETURN COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
              'id',                ad.id,
              'draftType',         ad.draft_type,
              'templateId',        at.template_id,
              'templateDisplayEn', at.display_name_en,
              'templateDisplayAr', at.display_name_ar,
              'approvalStatus',    ad.approval_status,
              'reviewPath',        ad.template_context->>'reviewPath',
              'currentReviewer',   ad.template_context->>'currentReviewer',
              'linkedRiskCaseId',  ad.template_context->>'linkedRiskCaseId',
              'contractId',        ad.contract_id,
              'contractNumber',    c.contract_number,
              'contractTitle',     COALESCE(c.title_en, c.title_ar),
              'counterpartyName',  cp.name_en,
              'createdAt',         ad.created_at,
              'createdBy',         ad.created_by,
              'createdByName',     TRIM(CONCAT_WS(' ', cb.first_name, cb.last_name)),
              'routedAt',          (ad.template_context->>'routedAt')::timestamptz,
              'generatedTextEn',   ad.generated_text_en,
              'generatedTextAr',   ad.generated_text_ar,
              'finalTextEn',       ad.final_text_en,
              'finalTextAr',       ad.final_text_ar
            ) ORDER BY (ad.template_context->>'routedAt') DESC NULLS LAST, ad.created_at DESC)
       FROM advisory_draft ad
       JOIN advisory_template at ON at.id = ad.template_id
       JOIN contract c            ON c.id  = ad.contract_id
       LEFT JOIN party cp         ON cp.id = c.counterparty_id
       LEFT JOIN "user" cb        ON cb.id = ad.created_by
      WHERE ad.tenant_id = v_tenant_id
        AND ad.is_active = TRUE
        AND ad.approval_status = 'unapproved'
        AND ad.dispatched_at IS NULL
        AND (ad.template_context->>'currentReviewer') = 'executive'),
    '[]'::jsonb
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_pending_for_executive(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_pending_for_executive(BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_advisory_draft_pending_for_executive(BIGINT) IS
  'mig 678 — drafts awaiting executive review (currentReviewer=executive, '
  'unapproved, not dispatched). Powers /app/exec/pending-advisories.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (678, 'fn_advisory_draft_pending_for_executive', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
