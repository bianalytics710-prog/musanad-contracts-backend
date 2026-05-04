-- ============================================================================
-- 019_m1c_extend_fn_contract_create.sql
--   M1c forward-fix: extend fn_contract_create to read M1c import-trace fields
--   from p_data JSONB so the BE controller pass-through actually persists them.
-- ============================================================================
-- Module:    M1c (Bulk & Manual Import) — bug-fix cycle 1
-- Owner:     DB Implementation Agent (Agent 6, bug-fix mode)
-- Depends:   001..018 (M0 + M1a + M1b + M1c base; uses contract.import_batch_id /
--            import_filename / import_confidence / import_warnings columns
--            declared in 003 as forward references, FK on import_batch_id closed
--            in 016, fn_contract_create body originally written in 005).
-- ----------------------------------------------------------------------------
-- Why this migration exists:
--   The Testing Agent's M1c integration suite caught that POST /api/v1/contracts
--   with importBatchId / importFilename / importConfidence / importWarnings in
--   the body silently dropped those values:
--     • Zod schema (src/schemas/contracts.schemas.ts:168-177) accepts them.
--     • TypeScript types (src/types/contracts.types.ts:343-349) declare them.
--     • The BE controller passes the raw body to fn_contract_create unchanged.
--     • But fn_contract_create (M1a 005, §7) reads keys explicitly via
--       p_data->>'<key>' and never references the 4 new keys, so the JSONB
--       pass-through silently dropped them.
--
--   This is exactly the case the DB Impl 'report don't fix' protocol exists for:
--   Agent 4's M1c design extended Zod and types but did NOT call for amending
--   fn_contract_create. The integration test caught the gap. Forward-fix here.
--
-- Why DB layer, not BE controller-side UPDATE:
--   • Single source of truth — also benefits M1a/M1b call sites if ever they
--     pass these fields.
--   • Atomic — no INSERT-then-UPDATE pattern observable mid-flight.
--   • Audit log shows ONE 'created' event per contract (the AFTER INSERT
--     trigger trg_contract_activity_emit_iu fires once), not two.
--   • No race risk if a user reads between INSERT and UPDATE.
--   • Backward-compatible — existing M1a/M1b callers that don't pass these
--     fields are unaffected (NULL by default for all 4).
--
-- Signature:
--   M1a 005 fn_contract_create signature is (p_data JSONB, p_actor_id BIGINT).
--   This migration does NOT change the signature — same 2 args. Therefore we
--   use CREATE OR REPLACE FUNCTION (atomic, no DROP needed). Verified via
--   pg_get_function_identity_arguments before authoring this file.
-- ----------------------------------------------------------------------------
-- Backward-compat invariants preserved verbatim from M1a 005 §7:
--   • All existing input validations (titleEn / contractType / valueAed /
--     dates / language / governingLaw / relationshipType / parentContractId).
--   • Contract-number generator loop (CT-YYYY-NNNNNN with 3-retry on UNIQUE).
--   • Tag whitelist (1..64 chars, ON CONFLICT DO NOTHING).
--   • Tag insertion path.
--   • Final RETURN fn_contract_get_by_id(v_id, p_actor_id, NULL).
--   • Outer EXCEPTION WHEN OTHERS preserves the 'fn_contract_create: %' prefix.
--
-- New behavior (additive):
--   • importBatchId       → import_batch_id (BIGINT). FK validity is enforced
--                           by fk_contract_import_batch_id (added in 016) —
--                           bad ID raises SQLSTATE 23503; BE translates to 400
--                           per AC-S9-04. No in-fn existence check needed.
--   • importFilename      → import_filename (TEXT). NULLIF empty-string only.
--   • importConfidence    → import_confidence (INTEGER, 0..100). The column
--                           CHECK in 003 already enforces the range; we ALSO
--                           validate in-fn so the error is a clean
--                           'fn_contract_create: %' message rather than a raw
--                           PG check_violation. Note column type is INTEGER
--                           (per 003 line 65), NOT NUMERIC(5,2).
--   • importWarnings      → import_warnings (JSONB). Defaults to '[]'::jsonb
--                           when missing or NULL so the column is always a
--                           valid JSON array. Pass-through otherwise.
-- ============================================================================

BEGIN;

-- ============================================================
-- 1. fn_contract_create — extended (M1c bug-fix forward-fix)
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
  -- M1c additions:
  v_import_batch_id BIGINT;
  v_import_filename TEXT;
  v_import_conf     INTEGER;
  v_import_warnings JSONB;
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
    PERFORM 1 FROM contract WHERE id = v_parent_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'fn_contract_create: %', 'parentContractId:Parent contract not found';
    END IF;
  END IF;

  -- ============================================================
  -- M1c additions: read & validate the 4 new import-trace fields
  -- ============================================================
  -- importBatchId — BIGINT. FK fk_contract_import_batch_id (added in 016)
  -- enforces validity at INSERT; bad IDs raise SQLSTATE 23503 which the
  -- outer EXCEPTION block re-raises as 'fn_contract_create: %' and the BE
  -- translates to 400 per AC-S9-04. No in-fn pre-check (matches M1a's
  -- counterparty/our_party pattern of trusting the FK).
  v_import_batch_id := NULLIF(p_data->>'importBatchId','')::BIGINT;

  -- importFilename — TEXT. Empty string normalised to NULL.
  v_import_filename := NULLIF(p_data->>'importFilename','');

  -- importConfidence — INTEGER (per 003 line 65, NOT NUMERIC).
  -- Range 0..100. Column has CHECK; we also validate here so the error is a
  -- structured 'fn_contract_create:' message rather than a raw check_violation.
  v_import_conf := NULLIF(p_data->>'importConfidence','')::INTEGER;
  IF v_import_conf IS NOT NULL AND (v_import_conf < 0 OR v_import_conf > 100) THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'importConfidence:Confidence must be between 0 and 100';
  END IF;

  -- importWarnings — JSONB. Default empty array when missing or NULL so the
  -- column is always a valid JSON array (consistent with the BE list output
  -- shape). Use jsonb '->' (not '->>') so we keep the JSON typing.
  IF p_data ? 'importWarnings' AND p_data->'importWarnings' IS NOT NULL AND jsonb_typeof(p_data->'importWarnings') <> 'null' THEN
    v_import_warnings := p_data->'importWarnings';
  ELSE
    v_import_warnings := '[]'::JSONB;
  END IF;

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
        -- M1c additions:
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
        NULLIF(p_data->>'bodyEn',''),
        NULLIF(p_data->>'bodyAr',''),
        1,
        COALESCE(NULLIF(p_data->>'draftedBy','')::BIGINT, p_actor_id),
        NULLIF(p_data->>'reviewedBy','')::BIGINT,
        NULLIF(p_data->>'approvedBy','')::BIGINT,
        -- M1c additions:
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

COMMENT ON FUNCTION fn_contract_create(JSONB, BIGINT) IS
  'M1a write, extended in M1c (migration 019) to persist importBatchId, '
  'importFilename, importConfidence, importWarnings from p_data. SECURITY '
  'INVOKER. Validates inputs, auto-generates CT-YYYY-NNNNNN contract_number '
  'with up to 3 retries on UNIQUE collision, INSERTs contract row, INSERTs '
  'contract_tag rows, returns the full row via fn_contract_get_by_id. '
  'Activity ''created'' is emitted by the AFTER INSERT trigger '
  'trg_contract_activity_emit_iu. Backward-compatible: callers that omit the '
  '4 import-trace fields get NULL/[] defaults — identical to pre-019 behavior.';

-- ============================================================
-- 2. Record migration
-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (19, 'm1c_extend_fn_contract_create', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 019_m1c_extend_fn_contract_create.sql
-- ============================================================================
-- Recreates the M1a-005 version of fn_contract_create (signature unchanged).
-- Run this manually if 019 must be reversed; downstream BE callers that send
-- import-trace fields will silently drop them again afterwards (the original
-- bug returns).
-- ROLLBACK BEGIN
BEGIN;

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
    PERFORM 1 FROM contract WHERE id = v_parent_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'fn_contract_create: %', 'parentContractId:Parent contract not found';
    END IF;
  END IF;

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
        NULLIF(p_data->>'bodyEn',''),
        NULLIF(p_data->>'bodyAr',''),
        1,
        COALESCE(NULLIF(p_data->>'draftedBy','')::BIGINT, p_actor_id),
        NULLIF(p_data->>'reviewedBy','')::BIGINT,
        NULLIF(p_data->>'approvedBy','')::BIGINT,
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

DELETE FROM schema_migrations WHERE version = 19;
COMMIT;
-- ROLLBACK END
