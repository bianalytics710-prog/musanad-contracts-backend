-- ============================================================================
-- Migration 670 — Contract Notices view + Resend
-- ============================================================================
--   1. fn_contract_advisory_list(p_contract_id) — returns all advisory
--      drafts for a contract (any status, including dispatched). Powers
--      the new "Notices" tab on Contract Detail so Layla can see every
--      notice ever drafted for this contract + its current state.
--      Per-row dispatch_count comes from advisory_dispatch_log so the UI
--      can show "Sent 2 times".
--
--   2. fn_advisory_draft_resend(actor, id, recipient, name) — thin wrapper
--      that delegates to fn_advisory_draft_send_directly with p_is_resend
--      = TRUE so the dispatch_log accumulates resend history without
--      duplicating the approval flow.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_contract_advisory_list(
  p_actor_id    BIGINT,
  p_contract_id BIGINT
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
  IF p_actor_id IS NULL OR p_contract_id IS NULL THEN
    RAISE EXCEPTION 'actorId + contractId required' USING ERRCODE = '22023';
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
              'createdAt',         ad.created_at,
              'createdBy',         ad.created_by,
              'createdByName',     TRIM(CONCAT_WS(' ', cb.first_name, cb.last_name)),
              'approvedAt',        ad.approved_at,
              'approvedBy',        ad.approved_by,
              'approvedByName',    TRIM(CONCAT_WS(' ', ab.first_name, ab.last_name)),
              'dispatchedAt',      ad.dispatched_at,
              'dispatchChannel',   ad.dispatch_channel,
              'dispatchRecipients', ad.dispatch_recipients,
              'dispatchCount',     (
                SELECT COUNT(*)::int FROM advisory_dispatch_log dl
                 WHERE dl.advisory_draft_id = ad.id AND dl.is_active = TRUE
              ),
              'lastDispatchAt',    (
                SELECT MAX(dl.delivery_attempted_at) FROM advisory_dispatch_log dl
                 WHERE dl.advisory_draft_id = ad.id AND dl.is_active = TRUE
              ),
              'generatedTextEn',   ad.generated_text_en,
              'generatedTextAr',   ad.generated_text_ar,
              'finalTextEn',       ad.final_text_en,
              'finalTextAr',       ad.final_text_ar
            ) ORDER BY ad.created_at DESC)
       FROM advisory_draft ad
       JOIN advisory_template at ON at.id = ad.template_id
       LEFT JOIN "user" cb       ON cb.id = ad.created_by
       LEFT JOIN "user" ab       ON ab.id = ad.approved_by
      WHERE ad.tenant_id = v_tenant_id
        AND ad.contract_id = p_contract_id
        AND ad.is_active = TRUE),
    '[]'::jsonb
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_contract_advisory_list(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_contract_advisory_list(BIGINT, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_contract_advisory_list(BIGINT, BIGINT) IS
  'mig 670 — Powers the Contract Detail Notices tab. Returns every advisory '
  'draft on the contract (any status incl. dispatched) with dispatch_count + '
  'last_dispatch_at so the UI can render "Sent N times".';

-- ─── Resend wrapper ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_advisory_draft_resend(
  p_actor_id          BIGINT,
  p_advisory_draft_id BIGINT,
  p_recipient_address TEXT,
  p_recipient_name    TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN fn_advisory_draft_send_directly(
    p_actor_id, p_advisory_draft_id, p_recipient_address, p_recipient_name, TRUE
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_resend(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_resend(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_advisory_draft_resend(BIGINT, BIGINT, TEXT, TEXT) IS
  'mig 670 — Resend a previously-dispatched advisory. Thin wrapper over '
  'fn_advisory_draft_send_directly(..., p_is_resend=TRUE). Adds a new '
  'advisory_dispatch_log row without re-running the approval flow.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (670, 'fn_contract_advisory_list_and_resend', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
