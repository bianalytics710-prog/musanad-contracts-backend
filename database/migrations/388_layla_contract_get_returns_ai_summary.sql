-- Migration: 388_layla_contract_get_returns_ai_summary.sql
-- Unit: Layla Counsel QA Phase 3.7 (2026-05-31) — L42/L43 grounded summary
--
-- fn_contract_get_by_id previously omitted ai_summary_en / ai_summary_ar.
-- Without these, the FE relies purely on streaming LLM output, which fabricates
-- financial values that contradict metadata. Returning the metadata-grounded
-- ai_summary_* lets the FE render a "Grounded summary" card alongside the
-- streaming panel.

CREATE OR REPLACE FUNCTION public.fn_contract_get_by_id(p_id bigint, p_actor_id bigint, p_actor_role text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row              contract%ROWTYPE;
  v_drafter          JSONB;
  v_reviewer         JSONB;
  v_approver         JSONB;
  v_tags             JSONB;
  v_attachment_count INTEGER := 0;
  v_comment_count    INTEGER := 0;
BEGIN
  SELECT * INTO v_row FROM contract WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_drafter
    FROM "user" u WHERE u.id = v_row.drafted_by;
  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_reviewer
    FROM "user" u WHERE u.id = v_row.reviewed_by;
  SELECT jsonb_build_object('id', u.id, 'firstName', u.first_name, 'lastName', u.last_name)
    INTO v_approver
    FROM "user" u WHERE u.id = v_row.approved_by;

  SELECT COALESCE(jsonb_agg(tag ORDER BY tag), '[]'::JSONB) INTO v_tags
    FROM contract_tag
    WHERE contract_id = p_id AND is_active = TRUE;

  IF to_regclass('public.contract_attachment') IS NOT NULL THEN
    EXECUTE 'SELECT COUNT(*)::INT FROM public.contract_attachment WHERE contract_id = $1 AND is_active = TRUE'
      INTO v_attachment_count
      USING p_id;
  END IF;
  IF to_regclass('public.contract_comment') IS NOT NULL THEN
    EXECUTE 'SELECT COUNT(*)::INT FROM public.contract_comment WHERE contract_id = $1 AND is_active = TRUE'
      INTO v_comment_count
      USING p_id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'contractNumber', v_row.contract_number,
    'titleEn', v_row.title_en,
    'titleAr', v_row.title_ar,
    'contractType', v_row.contract_type,
    'templateId', v_row.template_id,
    'status', v_row.status,
    'language', v_row.language,
    'ourPartyId', v_row.our_party_id,
    'counterpartyId', v_row.counterparty_id,
    'valueAed', v_row.value_aed,
    'currency', v_row.currency,
    'startDate', v_row.start_date,
    'endDate', v_row.end_date,
    'signedAt', v_row.signed_at,
    'expiryNoticeDays', v_row.expiry_notice_days,
    'emirate', v_row.emirate,
    'governingLaw', v_row.governing_law,
    'jurisdictionCourt', v_row.jurisdiction_court,
    'parentContractId', v_row.parent_contract_id,
    'relationshipType', v_row.relationship_type,
    'bodyEn', v_row.body_en,
    'bodyAr', v_row.body_ar,
    -- L42/L43 — Surface metadata-grounded summary so FE can render a credible
    -- summary card alongside (or instead of) the streaming AI panel
    'aiSummaryEn', v_row.ai_summary_en,
    'aiSummaryAr', v_row.ai_summary_ar,
    'aiRiskScore', v_row.ai_risk_score,
    'currentVersion', v_row.current_version,
    'draftedBy', v_drafter,
    'reviewedBy', v_reviewer,
    'approvedBy', v_approver,
    'tags', v_tags,
    'attachmentCount', v_attachment_count,
    'commentCount', v_comment_count,
    'importBatchId',    v_row.import_batch_id,
    'importFilename',   v_row.import_filename,
    'importConfidence', v_row.import_confidence,
    'importWarnings',   v_row.import_warnings,
    'createdAt', v_row.created_at,
    'updatedAt', v_row.updated_at
  );
END;
$function$;
