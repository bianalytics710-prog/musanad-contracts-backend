-- Migration: 616_fn_contract_update_change_note.sql
-- Module: Versioning UX — auto-snapshot change_note default
-- Date: 2026-06-09
--
-- fn_contract_update already auto-snapshots a contract_version row when
-- body_en or body_ar changes (see migration 008/132 lineage). The default
-- change_note when the caller does not supply one is the literal string
-- "Body update via fn_contract_update" — that's an internal stack name
-- leaking into the version timeline.
--
-- This migration rewrites the default to something a drafter or reviewer
-- can actually read:
--   - If the most recent chain on the contract ended in
--     resubmission_requested → "Edits after resubmission request"
--   - Otherwise → "Drafter edit"
--
-- Behaviour for callers that DO supply changeNote is unchanged; they win.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_contract_update(p_id bigint, p_data jsonb, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_existing      contract%ROWTYPE;
  v_new_start     DATE;
  v_new_end       DATE;
  v_new_parent_id BIGINT;
  v_body_en_changed BOOLEAN := FALSE;
  v_body_ar_changed BOOLEAN := FALSE;
  v_body_en_new   TEXT;
  v_body_ar_new   TEXT;
  v_change_note   TEXT;
  v_new_version   INTEGER;
  v_lang          TEXT;
  v_law           TEXT;
  v_rel           TEXT;
  v_value         NUMERIC;
  v_cycle_count   INTEGER;
  v_last_chain_status TEXT;
BEGIN
  SELECT * INTO v_existing
    FROM contract
    WHERE id = p_id AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_update: %', 'id:Contract not found';
  END IF;

  IF p_data ? 'status' THEN
    RAISE EXCEPTION 'fn_contract_update: %', 'status:Use fn_contract_status_update to change status';
  END IF;

  IF p_data ? 'language' THEN
    v_lang := p_data->>'language';
    IF v_lang NOT IN ('en','ar','bilingual') THEN
      RAISE EXCEPTION 'fn_contract_update: %', 'language:Invalid language';
    END IF;
  END IF;
  IF p_data ? 'governingLaw' THEN
    v_law := NULLIF(p_data->>'governingLaw','');
    IF v_law IS NOT NULL AND v_law NOT IN ('uae_federal','dubai','abu_dhabi','sharjah','difc','adgm','english','other') THEN
      RAISE EXCEPTION 'fn_contract_update: %', 'governingLaw:Invalid governing law';
    END IF;
  END IF;
  IF p_data ? 'relationshipType' THEN
    v_rel := NULLIF(p_data->>'relationshipType','');
    IF v_rel IS NOT NULL AND v_rel NOT IN ('amendment','renewal','extension','superseded','sow_under_msa') THEN
      RAISE EXCEPTION 'fn_contract_update: %', 'relationshipType:Invalid relationship type';
    END IF;
  END IF;

  IF p_data ? 'valueAed' THEN
    v_value := NULLIF(p_data->>'valueAed','')::NUMERIC;
    IF v_value IS NOT NULL AND v_value < 0 THEN
      RAISE EXCEPTION 'fn_contract_update: %', 'valueAed:Value must be greater than or equal to zero';
    END IF;
  END IF;

  v_new_start := COALESCE(NULLIF(p_data->>'startDate','')::DATE, v_existing.start_date);
  v_new_end   := COALESCE(NULLIF(p_data->>'endDate','')::DATE,   v_existing.end_date);
  IF v_new_start IS NOT NULL AND v_new_end IS NOT NULL AND v_new_end < v_new_start THEN
    RAISE EXCEPTION 'fn_contract_update: %', 'endDate:End date must be on or after start date';
  END IF;

  IF p_data ? 'parentContractId' THEN
    v_new_parent_id := NULLIF(p_data->>'parentContractId','')::BIGINT;
    IF v_new_parent_id = p_id THEN
      RAISE EXCEPTION 'fn_contract_update: %', 'parentContractId:Contract cannot be its own parent';
    END IF;
    IF v_new_parent_id IS NOT NULL THEN
      PERFORM 1
        FROM contract
        WHERE id = v_new_parent_id
          AND is_active = TRUE
        FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_contract_update: %', 'parentContractId:Parent contract not found';
      END IF;
      WITH RECURSIVE ancestors(id, parent_contract_id, depth) AS (
        SELECT id, parent_contract_id, 1
          FROM contract
          WHERE id = v_new_parent_id
        UNION ALL
        SELECT c.id, c.parent_contract_id, a.depth + 1
          FROM contract c
          INNER JOIN ancestors a ON c.id = a.parent_contract_id
          WHERE a.depth < 20
      )
      SELECT COUNT(*) INTO v_cycle_count FROM ancestors WHERE id = p_id;
      IF v_cycle_count > 0 THEN
        RAISE EXCEPTION 'fn_contract_update: %', 'parentContractId:Cycle detected in contract tree';
      END IF;
    END IF;
  END IF;

  IF p_data ? 'bodyEn' THEN
    v_body_en_new := NULLIF(p_data->>'bodyEn','');
    v_body_en_changed := (v_body_en_new IS DISTINCT FROM v_existing.body_en);
  END IF;
  IF p_data ? 'bodyAr' THEN
    v_body_ar_new := NULLIF(p_data->>'bodyAr','');
    v_body_ar_changed := (v_body_ar_new IS DISTINCT FROM v_existing.body_ar);
  END IF;

  UPDATE contract SET
    title_en           = COALESCE(NULLIF(p_data->>'titleEn',''),               title_en),
    title_ar           = CASE WHEN p_data ? 'titleAr' THEN NULLIF(p_data->>'titleAr','') ELSE title_ar END,
    contract_type      = COALESCE(NULLIF(p_data->>'contractType',''),          contract_type),
    template_id        = CASE WHEN p_data ? 'templateId' THEN NULLIF(p_data->>'templateId','')::BIGINT ELSE template_id END,
    language           = COALESCE(v_lang,                                       language),
    our_party_id       = CASE WHEN p_data ? 'ourPartyId' THEN NULLIF(p_data->>'ourPartyId','')::BIGINT ELSE our_party_id END,
    counterparty_id    = CASE WHEN p_data ? 'counterpartyId' THEN NULLIF(p_data->>'counterpartyId','')::BIGINT ELSE counterparty_id END,
    value_aed          = CASE WHEN p_data ? 'valueAed' THEN v_value ELSE value_aed END,
    currency           = COALESCE(NULLIF(p_data->>'currency',''),               currency),
    start_date         = CASE WHEN p_data ? 'startDate' THEN v_new_start ELSE start_date END,
    end_date           = CASE WHEN p_data ? 'endDate'   THEN v_new_end   ELSE end_date END,
    signed_at          = CASE WHEN p_data ? 'signedAt'  THEN NULLIF(p_data->>'signedAt','')::TIMESTAMPTZ ELSE signed_at END,
    expiry_notice_days = COALESCE(NULLIF(p_data->>'expiryNoticeDays','')::INTEGER, expiry_notice_days),
    emirate            = CASE WHEN p_data ? 'emirate'           THEN NULLIF(p_data->>'emirate','') ELSE emirate END,
    governing_law      = CASE WHEN p_data ? 'governingLaw'      THEN v_law ELSE governing_law END,
    jurisdiction_court = CASE WHEN p_data ? 'jurisdictionCourt' THEN NULLIF(p_data->>'jurisdictionCourt','') ELSE jurisdiction_court END,
    parent_contract_id = CASE WHEN p_data ? 'parentContractId'  THEN v_new_parent_id ELSE parent_contract_id END,
    relationship_type  = CASE WHEN p_data ? 'relationshipType'  THEN v_rel ELSE relationship_type END,
    body_en            = CASE WHEN v_body_en_changed THEN v_body_en_new ELSE body_en END,
    body_ar            = CASE WHEN v_body_ar_changed THEN v_body_ar_new ELSE body_ar END,
    drafted_by         = CASE WHEN p_data ? 'draftedBy'  THEN NULLIF(p_data->>'draftedBy','')::BIGINT  ELSE drafted_by  END,
    reviewed_by        = CASE WHEN p_data ? 'reviewedBy' THEN NULLIF(p_data->>'reviewedBy','')::BIGINT ELSE reviewed_by END,
    approved_by        = CASE WHEN p_data ? 'approvedBy' THEN NULLIF(p_data->>'approvedBy','')::BIGINT ELSE approved_by END,
    updated_at         = CURRENT_TIMESTAMP,
    updated_by         = p_actor_id
  WHERE id = p_id;

  IF v_body_en_changed OR v_body_ar_changed THEN
    -- v616 — derive a human change_note when the caller did not supply
    -- one. Look at the most recent chain on this contract: if it ended
    -- in resubmission_requested, the drafter is editing in response to
    -- a return-to-draft, so surface that context.
    IF p_data ? 'changeNote' AND NULLIF(p_data->>'changeNote','') IS NOT NULL THEN
      v_change_note := NULLIF(p_data->>'changeNote','');
    ELSE
      SELECT status INTO v_last_chain_status
        FROM approval_chain
       WHERE contract_id = p_id
       ORDER BY created_at DESC
       LIMIT 1;

      IF v_last_chain_status = 'resubmission_requested' THEN
        v_change_note := 'Edits after resubmission request';
      ELSE
        v_change_note := 'Drafter edit';
      END IF;
    END IF;

    PERFORM 1 FROM contract WHERE id = p_id FOR UPDATE;

    SELECT COALESCE(MAX(version_number), 0) + 1 INTO v_new_version
      FROM contract_version
      WHERE contract_id = p_id;

    INSERT INTO contract_version (
      contract_id, version_number, body_en, body_ar, diff_summary, change_note, changed_by, created_by
    ) VALUES (
      p_id,
      v_new_version,
      COALESCE(v_body_en_new, v_existing.body_en),
      COALESCE(v_body_ar_new, v_existing.body_ar),
      NULL,
      v_change_note,
      p_actor_id,
      p_actor_id
    );

    UPDATE contract SET current_version = v_new_version WHERE id = p_id;
  END IF;

  RETURN fn_contract_get_by_id(p_id, p_actor_id, NULL);
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_update: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_update: %', SQLERRM;
    END IF;
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (616, '616_fn_contract_update_change_note', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
