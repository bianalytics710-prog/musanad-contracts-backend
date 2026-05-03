-- ============================================================================
-- 008_m1a_concurrency_fixes.sql
--   Codex BE-001 / BE-002 / BE-003 — concurrency hardening for M1a fn_'s.
-- ============================================================================
-- Module:    M1a (Contracts: Core CRUD & Lifecycle) — concurrency patch
-- Owner:     DB Implementation Agent (Codex adversarial review follow-up)
-- Depends:   005_m1a_contract_functions.sql, 007_m1a_fix_total_pages_zero.sql
-- ----------------------------------------------------------------------------
-- Why:
--   Codex review (2026-05-03) identified three race-condition / transaction-
--   scope defects:
--     BE-001 (CRITICAL) — fn_contract_create + fn_contract_update validate
--       parent_contract_id without locking the parent row. A concurrent
--       fn_contract_delete can soft-delete the parent between the
--       validation read and the child INSERT/UPDATE, leaving an active
--       child pointing at a soft-deleted parent (violates AC-S5-04).
--     BE-002 (HIGH) — fn_contract_update reads v_existing without
--       FOR UPDATE, then UPDATEs and INSERTs a contract_version row using
--       v_existing.body_* for fields the caller did not supply. A
--       concurrent UPDATE between the read and the version INSERT can
--       produce a version snapshot that does not reflect the final
--       committed body for the unchanged fields.
--     BE-003 (HIGH) — fn_contract_set_tags reads v_current_tags without
--       locking. Concurrent replacements each compute add/remove diffs
--       from the same stale set; the result can merge additions from
--       both callers and lose removals from either, violating last-write-
--       wins.
--
-- Fix:
--   BE-001: Replace the unlocked parent active-row check in
--           fn_contract_create + fn_contract_update with
--           SELECT 1 FROM contract WHERE id = ... AND is_active = TRUE FOR UPDATE.
--           The lock holds for the rest of the txn; concurrent
--           fn_contract_delete blocks until commit, then sees the new
--           child and raises children-block-delete (existing 409 path).
--   BE-002: Promote the v_existing read in fn_contract_update to
--           SELECT * FROM contract WHERE id = p_id AND is_active = TRUE FOR UPDATE.
--           Lock-then-read-then-merge-then-UPDATE-then-version is the
--           correct sequence — the FOR UPDATE on the head row also
--           covers the contract_version INSERT path that previously had
--           a redundant PERFORM ... FOR UPDATE later in the function
--           (kept harmlessly as a no-op).
--   BE-003: Add SELECT 1 FROM contract WHERE id = p_id AND is_active = TRUE FOR UPDATE
--           in fn_contract_set_tags before reading v_current_tags. This
--           serialises tag-set replacement per contract id; the second
--           caller waits, then re-evaluates the diff against the
--           first caller's committed result.
--
-- Method:
--   CREATE OR REPLACE FUNCTION on each of fn_contract_create,
--   fn_contract_update, fn_contract_set_tags. Bodies copied verbatim
--   from migration 005, with only the FOR UPDATE additions.
--   SECURITY mode and search_path preserved per original.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- 1. fn_contract_create — BE-001 fix (parent FOR UPDATE)
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
    -- BE-001 FIX: lock the parent row for the duration of this transaction
    -- so a concurrent fn_contract_delete cannot soft-delete it between this
    -- check and the child INSERT below. Concurrent delete will block on
    -- this row, then re-evaluate its child-active count and reject with
    -- 'children:Cannot delete contract with active child contracts'.
    PERFORM 1
      FROM contract
      WHERE id = v_parent_id
        AND is_active = TRUE
      FOR UPDATE;
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

COMMENT ON FUNCTION fn_contract_create(JSONB, BIGINT) IS
  'M1a write. SECURITY INVOKER. Codex BE-001 hardening: parent_contract_id existence check now uses SELECT FOR UPDATE so concurrent fn_contract_delete on the parent serialises against this txn. Validates inputs, auto-generates CT-YYYY-NNNNNN contract_number with up to 3 retries on UNIQUE collision, INSERTs contract row, INSERTs contract_tag rows, returns the full row via fn_contract_get_by_id. Activity ''created'' is emitted by the AFTER INSERT trigger trg_contract_activity_emit_iu.';

-- ============================================================
-- 2. fn_contract_update — BE-001 + BE-002 fix
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_update(
  p_id       BIGINT,
  p_data     JSONB,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
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
BEGIN
  -- BE-002 FIX: lock the row before reading v_existing so the
  -- read-merge-UPDATE-version-INSERT sequence is serialised per contract id.
  -- A concurrent fn_contract_update will wait here; the contract_version
  -- snapshot inserted later in this function therefore reflects the final
  -- committed body for fields the caller did not supply.
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
      -- BE-001 FIX: lock the parent row so a concurrent fn_contract_delete
      -- on the parent serialises against this update. Concurrent delete
      -- will then re-evaluate child-active count post-commit and reject.
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
    v_change_note := COALESCE(NULLIF(p_data->>'changeNote',''), 'Body update via fn_contract_update');
    -- The row is already locked by the FOR UPDATE at the top of the function.
    -- This PERFORM is retained as a defensive no-op (already-held lock).
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
$$;

COMMENT ON FUNCTION fn_contract_update(BIGINT, JSONB, BIGINT) IS
  'M1a partial-update. SECURITY INVOKER. Codex BE-001 hardening: new parentContractId existence check uses SELECT FOR UPDATE. Codex BE-002 hardening: head-row read promoted to SELECT FOR UPDATE so the read-merge-UPDATE-version-INSERT sequence is serialised per contract id; the contract_version snapshot reflects the final committed body for fields the caller did not supply. Refuses status changes (use fn_contract_status_update). Cycle detection via recursive CTE capped at depth 20.';

-- ============================================================
-- 3. fn_contract_set_tags — BE-003 fix (head-row FOR UPDATE)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_set_tags(
  p_id       BIGINT,
  p_tags     TEXT[],
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tag_normalised TEXT;
  v_added          TEXT[] := ARRAY[]::TEXT[];
  v_removed        TEXT[] := ARRAY[]::TEXT[];
  v_current_tags   TEXT[];
  v_final_tags     TEXT[];
BEGIN
  -- BE-003 FIX: lock the contract head row before reading v_current_tags
  -- so concurrent fn_contract_set_tags calls on the same id are serialised.
  -- The second caller waits here, then reads v_current_tags reflecting the
  -- first caller's committed result and computes the correct diff.
  PERFORM 1
    FROM contract
    WHERE id = p_id
      AND is_active = TRUE
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_set_tags: %', 'id:Contract not found';
  END IF;

  IF p_tags IS NOT NULL THEN
    FOR v_tag_normalised IN SELECT TRIM(unnest) FROM unnest(p_tags) LOOP
      IF char_length(v_tag_normalised) NOT BETWEEN 1 AND 64 THEN
        RAISE EXCEPTION 'fn_contract_set_tags: %', 'tags:Each tag must be 1 to 64 characters';
      END IF;
      IF v_tag_normalised ~ '[\x00-\x1F\x7F]' THEN
        RAISE EXCEPTION 'fn_contract_set_tags: %', 'tags:Tag must not contain control characters';
      END IF;
    END LOOP;
  END IF;

  SELECT COALESCE(array_agg(tag), ARRAY[]::TEXT[])
    INTO v_current_tags
    FROM contract_tag
    WHERE contract_id = p_id AND is_active = TRUE;

  SELECT COALESCE(array_agg(DISTINCT TRIM(t)), ARRAY[]::TEXT[])
    INTO v_final_tags
    FROM unnest(COALESCE(p_tags, ARRAY[]::TEXT[])) t
    WHERE TRIM(t) <> '';

  v_added   := (SELECT COALESCE(array_agg(t), ARRAY[]::TEXT[]) FROM unnest(v_final_tags) t WHERE NOT (t = ANY(v_current_tags)));
  v_removed := (SELECT COALESCE(array_agg(t), ARRAY[]::TEXT[]) FROM unnest(v_current_tags) t WHERE NOT (t = ANY(v_final_tags)));

  IF array_length(v_removed, 1) > 0 THEN
    UPDATE contract_tag
      SET is_active = FALSE
      WHERE contract_id = p_id
        AND is_active = TRUE
        AND tag = ANY(v_removed);
  END IF;

  IF array_length(v_added, 1) > 0 THEN
    UPDATE contract_tag
      SET is_active = TRUE,
          created_at = CURRENT_TIMESTAMP,
          created_by = p_actor_id
      WHERE contract_id = p_id
        AND is_active = FALSE
        AND tag = ANY(v_added);
    INSERT INTO contract_tag (contract_id, tag, created_by)
      SELECT p_id, t, p_actor_id
        FROM unnest(v_added) t
        WHERE NOT EXISTS (
          SELECT 1 FROM contract_tag ct
            WHERE ct.contract_id = p_id AND ct.tag = t AND ct.is_active = TRUE
        );
  END IF;

  IF (array_length(v_added,1) > 0) OR (array_length(v_removed,1) > 0) THEN
    PERFORM fn_contract_activity_create(
      p_id,
      'tagged',
      p_actor_id,
      NULL,
      NULL,
      jsonb_build_object('added', to_jsonb(v_added), 'removed', to_jsonb(v_removed))
    );
  END IF;

  RETURN jsonb_build_object('id', p_id, 'tags', to_jsonb(v_final_tags));
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_set_tags: %' THEN
      RAISE;
    ELSE
      RAISE EXCEPTION 'fn_contract_set_tags: %', SQLERRM;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_contract_set_tags(BIGINT, TEXT[], BIGINT) IS
  'M1a tag-set replacement. SECURITY INVOKER. Codex BE-003 hardening: head-row SELECT FOR UPDATE serialises concurrent set_tags calls per contract id, eliminating the lost-removal / merged-addition hybrid result. Computes added/removed diff against current active set, soft-deletes removed and re-inserts (or reactivates) added, emits a single statement-level "tagged" activity with metadata={added, removed}.';

-- ============================================================
-- 4. Record migration
-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (8, 'm1a_concurrency_fixes', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 008_m1a_concurrency_fixes.sql
-- ============================================================================
-- Restores the pre-008 (migration 005) function bodies for the three
-- affected fn_'s. CREATE OR REPLACE FUNCTION with the verbatim 005 body
-- removes the FOR UPDATE additions cleanly; idempotent.
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
      INTO v_seq FROM contract WHERE contract_number LIKE 'CT-' || v_year || '-%';
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
        v_contract_number, p_data->>'titleEn', NULLIF(p_data->>'titleAr',''),
        p_data->>'contractType', NULLIF(p_data->>'templateId','')::BIGINT, 'draft',
        v_lang, NULLIF(p_data->>'ourPartyId','')::BIGINT, NULLIF(p_data->>'counterpartyId','')::BIGINT,
        v_value, COALESCE(NULLIF(p_data->>'currency',''), 'AED'),
        v_start, v_end, NULLIF(p_data->>'signedAt','')::TIMESTAMPTZ,
        COALESCE(NULLIF(p_data->>'expiryNoticeDays','')::INTEGER, 30),
        NULLIF(p_data->>'emirate',''), v_law, NULLIF(p_data->>'jurisdictionCourt',''),
        v_parent_id, v_rel, NULLIF(p_data->>'bodyEn',''), NULLIF(p_data->>'bodyAr',''),
        1, COALESCE(NULLIF(p_data->>'draftedBy','')::BIGINT, p_actor_id),
        NULLIF(p_data->>'reviewedBy','')::BIGINT, NULLIF(p_data->>'approvedBy','')::BIGINT,
        p_actor_id, p_actor_id
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
        INSERT INTO contract_tag (contract_id, tag, created_by) VALUES (v_id, v_tag, p_actor_id) ON CONFLICT DO NOTHING;
      ELSE
        RAISE EXCEPTION 'fn_contract_create: %', 'tags:Each tag must be 1 to 64 characters';
      END IF;
    END LOOP;
  END IF;
  RETURN fn_contract_get_by_id(v_id, p_actor_id, NULL);
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_create: %' THEN RAISE;
    ELSE RAISE EXCEPTION 'fn_contract_create: %', SQLERRM;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_contract_update(
  p_id       BIGINT,
  p_data     JSONB,
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
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
BEGIN
  SELECT * INTO v_existing FROM contract WHERE id = p_id AND is_active = TRUE;
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
      PERFORM 1 FROM contract WHERE id = v_new_parent_id AND is_active = TRUE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'fn_contract_update: %', 'parentContractId:Parent contract not found';
      END IF;
      WITH RECURSIVE ancestors(id, parent_contract_id, depth) AS (
        SELECT id, parent_contract_id, 1 FROM contract WHERE id = v_new_parent_id
        UNION ALL
        SELECT c.id, c.parent_contract_id, a.depth + 1 FROM contract c
          INNER JOIN ancestors a ON c.id = a.parent_contract_id WHERE a.depth < 20
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
    v_change_note := COALESCE(NULLIF(p_data->>'changeNote',''), 'Body update via fn_contract_update');
    PERFORM 1 FROM contract WHERE id = p_id FOR UPDATE;
    SELECT COALESCE(MAX(version_number), 0) + 1 INTO v_new_version FROM contract_version WHERE contract_id = p_id;
    INSERT INTO contract_version (
      contract_id, version_number, body_en, body_ar, diff_summary, change_note, changed_by, created_by
    ) VALUES (
      p_id, v_new_version,
      COALESCE(v_body_en_new, v_existing.body_en),
      COALESCE(v_body_ar_new, v_existing.body_ar),
      NULL, v_change_note, p_actor_id, p_actor_id
    );
    UPDATE contract SET current_version = v_new_version WHERE id = p_id;
  END IF;
  RETURN fn_contract_get_by_id(p_id, p_actor_id, NULL);
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_update: %' THEN RAISE;
    ELSE RAISE EXCEPTION 'fn_contract_update: %', SQLERRM;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_contract_set_tags(
  p_id       BIGINT,
  p_tags     TEXT[],
  p_actor_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tag_normalised TEXT;
  v_added          TEXT[] := ARRAY[]::TEXT[];
  v_removed        TEXT[] := ARRAY[]::TEXT[];
  v_current_tags   TEXT[];
  v_final_tags     TEXT[];
BEGIN
  PERFORM 1 FROM contract WHERE id = p_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_set_tags: %', 'id:Contract not found';
  END IF;
  IF p_tags IS NOT NULL THEN
    FOR v_tag_normalised IN SELECT TRIM(unnest) FROM unnest(p_tags) LOOP
      IF char_length(v_tag_normalised) NOT BETWEEN 1 AND 64 THEN
        RAISE EXCEPTION 'fn_contract_set_tags: %', 'tags:Each tag must be 1 to 64 characters';
      END IF;
      IF v_tag_normalised ~ '[\x00-\x1F\x7F]' THEN
        RAISE EXCEPTION 'fn_contract_set_tags: %', 'tags:Tag must not contain control characters';
      END IF;
    END LOOP;
  END IF;
  SELECT COALESCE(array_agg(tag), ARRAY[]::TEXT[]) INTO v_current_tags
    FROM contract_tag WHERE contract_id = p_id AND is_active = TRUE;
  SELECT COALESCE(array_agg(DISTINCT TRIM(t)), ARRAY[]::TEXT[]) INTO v_final_tags
    FROM unnest(COALESCE(p_tags, ARRAY[]::TEXT[])) t WHERE TRIM(t) <> '';
  v_added   := (SELECT COALESCE(array_agg(t), ARRAY[]::TEXT[]) FROM unnest(v_final_tags) t WHERE NOT (t = ANY(v_current_tags)));
  v_removed := (SELECT COALESCE(array_agg(t), ARRAY[]::TEXT[]) FROM unnest(v_current_tags) t WHERE NOT (t = ANY(v_final_tags)));
  IF array_length(v_removed, 1) > 0 THEN
    UPDATE contract_tag SET is_active = FALSE
      WHERE contract_id = p_id AND is_active = TRUE AND tag = ANY(v_removed);
  END IF;
  IF array_length(v_added, 1) > 0 THEN
    UPDATE contract_tag SET is_active = TRUE, created_at = CURRENT_TIMESTAMP, created_by = p_actor_id
      WHERE contract_id = p_id AND is_active = FALSE AND tag = ANY(v_added);
    INSERT INTO contract_tag (contract_id, tag, created_by)
      SELECT p_id, t, p_actor_id FROM unnest(v_added) t
        WHERE NOT EXISTS (
          SELECT 1 FROM contract_tag ct
            WHERE ct.contract_id = p_id AND ct.tag = t AND ct.is_active = TRUE
        );
  END IF;
  IF (array_length(v_added,1) > 0) OR (array_length(v_removed,1) > 0) THEN
    PERFORM fn_contract_activity_create(
      p_id, 'tagged', p_actor_id, NULL, NULL,
      jsonb_build_object('added', to_jsonb(v_added), 'removed', to_jsonb(v_removed)));
  END IF;
  RETURN jsonb_build_object('id', p_id, 'tags', to_jsonb(v_final_tags));
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'fn_contract_set_tags: %' THEN RAISE;
    ELSE RAISE EXCEPTION 'fn_contract_set_tags: %', SQLERRM;
    END IF;
END;
$$;

DELETE FROM schema_migrations WHERE version = 8;
COMMIT;
-- ROLLBACK END
