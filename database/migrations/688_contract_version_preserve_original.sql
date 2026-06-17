-- ============================================================================
-- Migration 688 — Preserve the original contract body in version history
-- ============================================================================
-- BUG: editing a contract overwrote contract.body_en/ar with the new text and
-- only THEN inserted a contract_version row capturing the NEW body as v1. The
-- pre-edit (original) body was never snapshotted, so after one edit the
-- Versions tab showed a single v1 == the current body and the original was
-- lost. There was also no version created at draft time.
--
-- FIX (two parts, both additive — every other behaviour preserved verbatim):
--
--   1. fn_contract_create — when the new contract has a body, snapshot it as
--      v1 ("Initial draft") immediately. New contracts therefore always have
--      an original version, and the first edit becomes v2.
--
--   2. fn_contract_update — for LEGACY contracts created before (1) (i.e. no
--      contract_version rows yet), lazily seed the PRE-EDIT body as v1
--      ("Original draft", stamped with the original creation time) before
--      recording the new version. So an original→edit produces v1 = original,
--      v2 = edit, with current_version pointing at v2 (== the live body, the
--      invariant other features like ingestion / "View this version" rely on).
--
-- A separate one-off script restores the already-lost original for the
-- specific demo contract CT-2026-000025 from audit_log (dev-only, not here).
-- ============================================================================

BEGIN;

-- ============================================================
-- 1. fn_contract_create — snapshot the initial body as v1
--    (verbatim from migration 020 + the v1 snapshot before RETURN)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_contract_create(
  p_data     JSONB,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id              BIGINT;
  v_contract_number VARCHAR(50);
  v_year            INTEGER := EXTRACT(YEAR FROM CURRENT_TIMESTAMP)::INTEGER;
  v_seq             INTEGER;
  v_attempt         INTEGER := 0;
  v_inserted        BOOLEAN := FALSE;
  v_tag             TEXT;
  v_parent_id       BIGINT;
  v_value           NUMERIC;
  v_start           DATE;
  v_end             DATE;
  v_lang            TEXT;
  v_law             TEXT;
  v_rel             TEXT;
  v_import_batch_id BIGINT;
  v_import_filename TEXT;
  v_import_conf     INTEGER;
  v_import_warnings JSONB;
  -- 688
  v_body_en_new     TEXT;
  v_body_ar_new     TEXT;
BEGIN
  IF NULLIF(TRIM(p_data->>'titleEn'), '') IS NULL THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'titleEn:Title (English) is required';
  END IF;
  IF NULLIF(TRIM(p_data->>'contractType'), '') IS NULL THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'contractType:Contract type is required';
  END IF;

  v_value := NULLIF(p_data->>'valueAed','')::NUMERIC;
  IF v_value IS NOT NULL AND v_value < 0 THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'valueAed:Value must be greater than or equal to zero';
  END IF;

  v_start := NULLIF(p_data->>'startDate','')::DATE;
  v_end   := NULLIF(p_data->>'endDate','')::DATE;
  IF v_start IS NOT NULL AND v_end IS NOT NULL AND v_end < v_start THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'endDate:End date must be on or after start date';
  END IF;

  v_lang := COALESCE(NULLIF(p_data->>'language',''), 'en');
  IF v_lang NOT IN ('en','ar','bilingual') THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'language:Invalid language';
  END IF;

  v_law := NULLIF(p_data->>'governingLaw','');
  IF v_law IS NOT NULL AND v_law NOT IN ('uae_federal','dubai','abu_dhabi','sharjah','difc','adgm','english','other') THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'governingLaw:Invalid governing law';
  END IF;

  v_rel := NULLIF(p_data->>'relationshipType','');
  IF v_rel IS NOT NULL AND v_rel NOT IN ('amendment','renewal','extension','superseded','sow_under_msa') THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'relationshipType:Invalid relationship type';
  END IF;

  v_parent_id := NULLIF(p_data->>'parentContractId','')::BIGINT;
  IF v_parent_id IS NOT NULL THEN
    -- Codex BE-001: lock parent for the txn (orphan-prevention invariant).
    PERFORM 1
      FROM contract
      WHERE id = v_parent_id
        AND is_active = TRUE
      FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'fn_contract_create: %', 'parentContractId:Parent contract not found';
    END IF;
  END IF;

  v_import_batch_id := NULLIF(p_data->>'importBatchId','')::BIGINT;
  IF v_import_batch_id IS NOT NULL THEN
    PERFORM 1
      FROM import_batch
      WHERE id = v_import_batch_id
        AND is_active = TRUE
      FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'fn_contract_create: %', 'importBatchId:Import batch not found';
    END IF;
  END IF;

  v_import_filename := NULLIF(p_data->>'importFilename','');

  v_import_conf := NULLIF(p_data->>'importConfidence','')::INTEGER;
  IF v_import_conf IS NOT NULL AND (v_import_conf < 0 OR v_import_conf > 100) THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'importConfidence:Confidence must be between 0 and 100';
  END IF;

  IF p_data ? 'importWarnings'
     AND p_data->'importWarnings' IS NOT NULL
     AND jsonb_typeof(p_data->'importWarnings') <> 'null' THEN
    v_import_warnings := p_data->'importWarnings';
  ELSE
    v_import_warnings := NULL;
  END IF;

  -- 688 — normalise the body once for both the contract INSERT and the v1 snapshot.
  v_body_en_new := NULLIF(p_data->>'bodyEn','');
  v_body_ar_new := NULLIF(p_data->>'bodyAr','');

  LOOP
    v_attempt := v_attempt + 1;
    SELECT COALESCE(MAX(CAST(SUBSTRING(contract_number FROM 'CT-' || v_year || '-(\d+)$') AS INTEGER)), 0) + 1
      INTO v_seq
      FROM contract
      WHERE contract_number LIKE 'CT-' || v_year || '-%';
    v_contract_number := 'CT-' || v_year || '-' || LPAD(v_seq::TEXT, 6, '0');

    BEGIN
      INSERT INTO contract (
        contract_number, title_en, title_ar, contract_type, template_id, status,
        language, our_party_id, counterparty_id, value_aed, currency,
        start_date, end_date, signed_at, expiry_notice_days,
        emirate, governing_law, jurisdiction_court,
        parent_contract_id, relationship_type, body_en, body_ar,
        current_version, drafted_by, reviewed_by, approved_by,
        import_batch_id, import_filename, import_confidence, import_warnings,
        created_by, updated_by
      ) VALUES (
        v_contract_number,
        p_data->>'titleEn',
        NULLIF(p_data->>'titleAr',''),
        p_data->>'contractType',
        NULLIF(p_data->>'templateId','')::BIGINT,
        'draft',
        v_lang,
        NULLIF(p_data->>'ourPartyId','')::BIGINT,
        NULLIF(p_data->>'counterpartyId','')::BIGINT,
        v_value,
        COALESCE(NULLIF(p_data->>'currency',''), 'AED'),
        v_start,
        v_end,
        NULLIF(p_data->>'signedAt','')::TIMESTAMPTZ,
        COALESCE(NULLIF(p_data->>'expiryNoticeDays','')::INTEGER, 30),
        NULLIF(p_data->>'emirate',''),
        v_law,
        NULLIF(p_data->>'jurisdictionCourt',''),
        v_parent_id,
        v_rel,
        v_body_en_new,
        v_body_ar_new,
        1,
        COALESCE(NULLIF(p_data->>'draftedBy','')::BIGINT, p_actor_id),
        NULLIF(p_data->>'reviewedBy','')::BIGINT,
        NULLIF(p_data->>'approvedBy','')::BIGINT,
        v_import_batch_id,
        v_import_filename,
        v_import_conf,
        v_import_warnings,
        p_actor_id,
        p_actor_id
      ) RETURNING id INTO v_id;
      v_inserted := TRUE;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF v_attempt >= 3 THEN
        RAISE EXCEPTION 'fn_contract_create: %', 'contractNumber:Contract number already exists';
      END IF;
    END;
  END LOOP;

  IF p_data ? 'tags' AND jsonb_typeof(p_data->'tags') = 'array' THEN
    FOR v_tag IN SELECT TRIM(value::TEXT, '"') FROM jsonb_array_elements_text(p_data->'tags')
    LOOP
      IF char_length(v_tag) BETWEEN 1 AND 64 THEN
        INSERT INTO contract_tag (contract_id, tag, created_by)
        VALUES (v_id, v_tag, p_actor_id)
        ON CONFLICT DO NOTHING;
      ELSE
        RAISE EXCEPTION 'fn_contract_create: %', 'tags:Each tag must be 1 to 64 characters';
      END IF;
    END LOOP;
  END IF;

  -- 688 — snapshot the initial body as v1 so version history always has an
  -- "original" entry, even before any edit. Only when a body exists; current_version
  -- was already set to 1 on the contract row above, so this is consistent.
  IF v_body_en_new IS NOT NULL OR v_body_ar_new IS NOT NULL THEN
    INSERT INTO contract_version (
      contract_id, version_number, body_en, body_ar, diff_summary, change_note, changed_by, created_by
    ) VALUES (
      v_id, 1, v_body_en_new, v_body_ar_new, NULL, 'Initial draft', p_actor_id, p_actor_id
    );
  END IF;

  RETURN fn_contract_get_by_id(v_id, p_actor_id, NULL);
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_create: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_create: %', SQLERRM;
    END IF;
END;
$$;

-- ============================================================
-- 2. fn_contract_update — lazily seed the pre-edit body as v1 for legacy
--    contracts (verbatim from migration 616 + the seed block)
-- ============================================================
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
    -- v616 — derive a human change_note when the caller did not supply one.
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

    -- 688 — legacy contracts (created before creation-time snapshotting) have
    -- no version rows; their pre-edit (original) body would otherwise be lost
    -- when we record the new version below. Seed it as v1 first, stamped with
    -- the original creation time + author so the timeline reads correctly.
    IF NOT EXISTS (SELECT 1 FROM contract_version WHERE contract_id = p_id) THEN
      INSERT INTO contract_version (
        contract_id, version_number, body_en, body_ar, diff_summary, change_note,
        changed_by, created_at, created_by
      ) VALUES (
        p_id, 1, v_existing.body_en, v_existing.body_ar, NULL, 'Original draft',
        COALESCE(v_existing.created_by, p_actor_id), v_existing.created_at, p_actor_id
      );
    END IF;

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
VALUES (688, 'contract_version preserve original body (create snapshot + update lazy-seed)', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
