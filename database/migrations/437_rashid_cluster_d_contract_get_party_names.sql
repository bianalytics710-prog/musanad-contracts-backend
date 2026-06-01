-- Migration: 437_rashid_cluster_d_contract_get_party_names.sql
-- Unit: Rashid Recipient PM-grade audit fix pass (2026-06-01) — Cluster D
-- Defect addressed:
--   R17 — Contract detail Parties section shows OUR PARTY="—" / COUNTERPARTY="—"
--         for Recipient because the FE fetches party.read.all and Recipient
--         doesn't have that permission. Surface the party display names
--         alongside the contract row so the FE can render them WITHOUT a
--         separate gated party.get call. Recipient sees only the parties
--         on contracts he's already authorised to read (contract.read.own
--         is the gate).
-- Test-branch-safe: CREATE OR REPLACE.
-- Rollback: revert to mig 388 body.

BEGIN;

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
  v_our_party_name_en TEXT;
  v_our_party_name_ar TEXT;
  v_counterparty_name_en TEXT;
  v_counterparty_name_ar TEXT;
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

  -- R17 — fetch party display names inline so the FE renders them without
  -- a separate party.read.all-gated call.
  SELECT p.name_en, p.name_ar INTO v_our_party_name_en, v_our_party_name_ar
    FROM party p WHERE p.id = v_row.our_party_id;
  SELECT p.name_en, p.name_ar INTO v_counterparty_name_en, v_counterparty_name_ar
    FROM party p WHERE p.id = v_row.counterparty_id;

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
    -- R17 additive — direct party display names for FE fallback when
    -- party.read.all is not in the caller's perms.
    'ourPartyNameEn', v_our_party_name_en,
    'ourPartyNameAr', v_our_party_name_ar,
    'counterpartyNameEn', v_counterparty_name_en,
    'counterpartyNameAr', v_counterparty_name_ar,
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

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (437, 'R17 — fn_contract_get_by_id ships party display names inline', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- Re-run migration 388 body (the prior fn_contract_get_by_id version).
-- ROLLBACK END
