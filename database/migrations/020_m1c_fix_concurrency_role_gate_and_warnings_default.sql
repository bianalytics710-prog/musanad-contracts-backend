-- ============================================================================
-- 020_m1c_fix_concurrency_role_gate_and_warnings_default.sql
--   M1c bug-fix cycle 2: restore Codex BE-001 concurrency lock in
--   fn_contract_create, change importWarnings missing-key default to NULL,
--   add 'Super Admin' to fn_contract_list role-can-see-all gate.
-- ============================================================================
-- Module:    M1c (Bulk & Manual Import) — bug-fix cycle 2
-- Owner:     DB Implementation Agent (Agent 6, bug-fix mode)
-- Depends:   001..019 (M0 + M1a + M1b + M1c base + M1c cycle-1 forward fix).
--            Specifically supersedes 019_m1c_extend_fn_contract_create.sql
--            for fn_contract_create and 017_m1c_import_functions.sql for
--            fn_contract_list (signatures unchanged for both).
-- ----------------------------------------------------------------------------
-- Why this migration exists (cycle-1 follow-up):
--
-- (1) Codex-BE-001 concurrency regression (CRITICAL, 2 failing tests):
--     Migration 008 (M1a Codex hardening) introduced a SELECT FOR UPDATE on
--     the parent_contract_id existence check inside fn_contract_create. That
--     lock is what serialises a concurrent fn_contract_delete(parent) against
--     a child INSERT, ensuring no orphan child rows under a soft-deleted
--     parent (Codex-BE-001-a / -d invariant).
--
--     Migration 019's CREATE OR REPLACE of fn_contract_create faithfully
--     copied most of the M1a body but reverted that single line:
--         PERFORM 1 FROM contract WHERE id = v_parent_id AND is_active = TRUE;
--     instead of the 008 pattern:
--         PERFORM 1 FROM contract WHERE id = v_parent_id AND is_active = TRUE FOR UPDATE;
--     The hardening was lost. M1a concurrency tests started failing again.
--
--     This migration restores the FOR UPDATE clause verbatim from 008 lines
--     126-130. Comment block kept inline so future read-throughs see the WHY.
--
-- (2) NEW concurrency lock for import_batch_id (defense-in-depth):
--     M1c added a forward-FK fk_contract_import_batch_id (migration 016) with
--     ON DELETE SET NULL. The batch row itself can be soft-deleted via
--     UPDATE (RLS RESTRICTIVE policy import_batch_deny_direct_is_active_update
--     blocks direct flips, but fn_-mediated soft-deletes via a future fn_
--     could still happen). To preserve the same Codex-style invariant for the
--     new import_batch_id reference — that a child contract cannot be created
--     pointing at an import_batch that is being concurrently deactivated — we
--     add a parallel SELECT FOR UPDATE check when v_import_batch_id IS NOT
--     NULL. The lock holds for the rest of the txn; concurrent deactivation
--     blocks until commit. Pattern is identical to the parent_contract_id
--     lock in (1).
--
-- (3) AC-S6-08-NoImport: importWarnings missing-key must default to NULL,
--     not '[]'::JSONB:
--     Migration 019 wrote v_import_warnings := '[]'::JSONB whenever the key
--     was missing OR null. The integration test that asserts "non-imported
--     M1a contracts have NULL import_warnings" failed because the column
--     became empty-array for any contract that did not pass the key.
--
--     Distinguishing logic via the JSONB key-exists operator (?):
--       • Key entirely absent  → store NULL  (preserves M1a/M1b semantics)
--       • Key explicitly []    → store '[]'::JSONB
--       • Key explicitly null  → store NULL  (matches "absent" intent)
--       • Key explicitly ['x'] → store ['x']
--
-- (4) AC-S4-05 / AC-S6-01: 'Super Admin' missing from fn_contract_list
--     role gate:
--     migration 005 (M1a) defined fn_contract_list with
--         v_role_can_see_all := p_actor_role IN
--             ('platform_admin', 'legal_counsel', 'executive');
--     Migration 017 (M1c) rewrote the signature to 18 params but copied this
--     gate verbatim, so the role list still excludes 'Super Admin'.
--     fn_import_batch_list (017 line 432) already includes 'Super Admin' —
--     the symmetry exposes the gap. Adding 'Super Admin' to the list (parity
--     with fn_import_batch_list) closes both AC-S4-05 and AC-S6-01.
--
--     Note: this is technically a pre-existing M1a/M1c role-name-space gap
--     that surfaced in M1c (first cross-role list test: drafter creates,
--     admin lists). It is fixed here as a single-line additive change
--     because migration 020 already has fn_contract_list open for an
--     unrelated reason — actually, fn_contract_list is unchanged in (1)/(2)/
--     (3); we touch it solely for this fix. Documented separately in the
--     db-impl-summary.json patches[] entry.
-- ----------------------------------------------------------------------------
-- Method:
--   CREATE OR REPLACE FUNCTION on both fn_contract_create and fn_contract_list.
--   Signatures unchanged for both — atomic, no DROP needed.
--   All other M1a/M1b/M1c behaviors preserved verbatim.
-- ============================================================================

BEGIN;

-- ============================================================
-- 1. fn_contract_create — restore FOR UPDATE locks + fix importWarnings default
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
    -- Codex BE-001 FIX (restored from migration 008 lines 126-130):
    -- Lock the parent row for the duration of this transaction so a concurrent
    -- fn_contract_delete cannot soft-delete it between this check and the
    -- child INSERT below. Concurrent delete will block on this row, then
    -- re-evaluate its child-active count and reject with
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

  -- ============================================================
  -- M1c additions: read & validate the 4 new import-trace fields
  -- ============================================================
  -- importBatchId — BIGINT. FK fk_contract_import_batch_id (added in 016)
  -- enforces validity at INSERT; bad IDs raise SQLSTATE 23503 which the outer
  -- EXCEPTION block re-raises as 'fn_contract_create: %' and the BE
  -- translates to 400 per AC-S9-04.
  --
  -- NEW in 020 (parallel to Codex BE-001 hardening on parent_contract_id):
  -- When import_batch_id is non-NULL, lock the batch row for the duration of
  -- this txn so a concurrent batch-deactivation (future fn_) cannot
  -- soft-delete the batch between this check and the child INSERT. Same
  -- pattern, same invariant — defense-in-depth ahead of any future
  -- fn_import_batch_delete or RLS-bypassing soft-delete path.
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

  -- importFilename — TEXT. Empty string normalised to NULL.
  v_import_filename := NULLIF(p_data->>'importFilename','');

  -- importConfidence — INTEGER (per 003 line 65, NOT NUMERIC).
  -- Range 0..100. Column has CHECK; we also validate here so the error is a
  -- structured 'fn_contract_create:' message rather than a raw check_violation.
  v_import_conf := NULLIF(p_data->>'importConfidence','')::INTEGER;
  IF v_import_conf IS NOT NULL AND (v_import_conf < 0 OR v_import_conf > 100) THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'importConfidence:Confidence must be between 0 and 100';
  END IF;

  -- importWarnings — JSONB.
  --
  -- AC-S6-08-NoImport FIX (cycle-1 regression):
  -- Distinguish missing-key vs explicit-empty-array vs explicit-null:
  --   • Key absent              → NULL (preserves M1a/M1b "no import payload" semantics)
  --   • Key present and 'null'  → NULL
  --   • Key present and array   → pass-through (e.g. [], ['warning1', ...])
  -- Use jsonb '->' (not '->>') so we keep the JSON typing.
  IF p_data ? 'importWarnings'
     AND p_data->'importWarnings' IS NOT NULL
     AND jsonb_typeof(p_data->'importWarnings') <> 'null' THEN
    v_import_warnings := p_data->'importWarnings';
  ELSE
    v_import_warnings := NULL;  -- changed from '[]'::JSONB in 019
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
  'importFilename, importConfidence, importWarnings; cycle-2 patch (020) '
  'restored Codex BE-001 SELECT FOR UPDATE on parent existence check, added '
  'parallel FOR UPDATE on importBatchId existence check, and changed '
  'importWarnings missing-key default from ''[]''::jsonb to NULL (so M1a/M1b '
  'callers that omit the key keep NULL semantics). SECURITY INVOKER. '
  'Validates inputs, auto-generates CT-YYYY-NNNNNN contract_number with up '
  'to 3 retries on UNIQUE collision, INSERTs contract row, INSERTs '
  'contract_tag rows, returns the full row via fn_contract_get_by_id. '
  'Activity ''created'' is emitted by the AFTER INSERT trigger '
  'trg_contract_activity_emit_iu.';

-- ============================================================
-- 2. fn_contract_list — add 'Super Admin' to v_role_can_see_all (parity with
--                       fn_import_batch_list per AC-S4-05 / AC-S6-01)
-- ============================================================

CREATE OR REPLACE FUNCTION fn_contract_list(
  p_page                    INTEGER       DEFAULT 1,
  p_limit                   INTEGER       DEFAULT 20,
  p_status                  TEXT          DEFAULT NULL,
  p_contract_type           TEXT          DEFAULT NULL,
  p_counterparty_id         BIGINT        DEFAULT NULL,
  p_drafted_by              BIGINT        DEFAULT NULL,
  p_approved_by             BIGINT        DEFAULT NULL,
  p_start_date_from         DATE          DEFAULT NULL,
  p_start_date_to           DATE          DEFAULT NULL,
  p_end_date_from           DATE          DEFAULT NULL,
  p_end_date_to             DATE          DEFAULT NULL,
  p_tags                    TEXT[]        DEFAULT NULL,
  p_search                  TEXT          DEFAULT NULL,
  p_actor_id                BIGINT        DEFAULT NULL,
  p_actor_role              TEXT          DEFAULT NULL,
  p_import_batch_id         BIGINT        DEFAULT NULL,
  p_import_confidence_min   INTEGER       DEFAULT NULL,
  p_import_confidence_max   INTEGER       DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset    INTEGER;
  v_total     BIGINT;
  v_data      JSONB;
  v_role_can_see_all BOOLEAN;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'page:Page must be >= 1';
  END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'limit:Limit must be between 1 and 100';
  END IF;

  v_offset := (p_page - 1) * p_limit;

  -- AC-S4-05 / AC-S6-01 FIX: add 'Super Admin' to the role-can-see-all set.
  -- Parity with fn_import_batch_list (017 line 432). The M0 role 'Super Admin'
  -- (with the literal space — role.name verbatim) is the admin role used by
  -- M1c integration tests' loginAdmin(); without this, admin's GET requests
  -- fall through to the user-narrowing predicate and miss drafter-created
  -- contracts. Pre-existing M1a/M1c gap; surfaced by first cross-role
  -- create+list test in M1c.
  v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive', 'Super Admin');

  SELECT COUNT(*) INTO v_total
    FROM contract c
    WHERE c.is_active = TRUE
      AND (p_status IS NULL          OR c.status = p_status)
      AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
      AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
      AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
      AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
      AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
      AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
      AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
      AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
      AND (p_search IS NULL OR (
            lower(c.contract_number)            LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_en,''))      LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_ar,''))      LIKE '%' || lower(p_search) || '%'))
      AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
            (SELECT COUNT(*) FROM unnest(p_tags) tg
              WHERE EXISTS (
                SELECT 1 FROM contract_tag ct
                  WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
              )) = array_length(p_tags, 1)))
      -- M1c additive filters (additive-only — NULL preserves M1a semantics)
      AND (p_import_batch_id        IS NULL OR c.import_batch_id    = p_import_batch_id)
      AND (p_import_confidence_min  IS NULL OR c.import_confidence >= p_import_confidence_min)
      AND (p_import_confidence_max  IS NULL OR c.import_confidence <= p_import_confidence_max)
      AND (v_role_can_see_all OR (
            c.drafted_by  = p_actor_id
         OR c.reviewed_by = p_actor_id
         OR c.approved_by = p_actor_id
         OR c.created_by  = p_actor_id));

  SELECT COALESCE(jsonb_agg(row_to_payload), '[]'::JSONB) INTO v_data
    FROM (
      SELECT jsonb_build_object(
        'id', c.id,
        'contractNumber', c.contract_number,
        'titleEn', c.title_en,
        'titleAr', c.title_ar,
        'contractType', c.contract_type,
        'status', c.status,
        'valueAed', c.value_aed,
        'currency', c.currency,
        'startDate', c.start_date,
        'endDate', c.end_date,
        'counterpartyId', c.counterparty_id,
        'ourPartyId', c.our_party_id,
        'tags', COALESCE((SELECT jsonb_agg(ct.tag ORDER BY ct.tag)
                           FROM contract_tag ct
                           WHERE ct.contract_id = c.id AND ct.is_active = TRUE), '[]'::JSONB),
        'currentVersion', c.current_version,
        'createdAt', c.created_at,
        'updatedAt', c.updated_at,
        -- M1c additive fields (always present; null when no import_batch attached)
        'importBatchId',    c.import_batch_id,
        'importConfidence', c.import_confidence,
        'importWarnings',   c.import_warnings
      ) AS row_to_payload
        FROM contract c
        WHERE c.is_active = TRUE
          AND (p_status IS NULL          OR c.status = p_status)
          AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
          AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
          AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
          AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
          AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
          AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
          AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
          AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
          AND (p_search IS NULL OR (
                lower(c.contract_number)            LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_en,''))      LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_ar,''))      LIKE '%' || lower(p_search) || '%'))
          AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
                (SELECT COUNT(*) FROM unnest(p_tags) tg
                  WHERE EXISTS (
                    SELECT 1 FROM contract_tag ct
                      WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
                  )) = array_length(p_tags, 1)))
          AND (p_import_batch_id        IS NULL OR c.import_batch_id    = p_import_batch_id)
          AND (p_import_confidence_min  IS NULL OR c.import_confidence >= p_import_confidence_min)
          AND (p_import_confidence_max  IS NULL OR c.import_confidence <= p_import_confidence_max)
          AND (v_role_can_see_all OR (
                c.drafted_by  = p_actor_id
             OR c.reviewed_by = p_actor_id
             OR c.approved_by = p_actor_id
             OR c.created_by  = p_actor_id))
        ORDER BY c.created_at DESC, c.end_date ASC NULLS LAST
        LIMIT p_limit OFFSET v_offset
    ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', v_total,
      'page', p_page,
      'limit', p_limit,
      'totalPages', CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER)
    )
  );
END;
$$;

COMMENT ON FUNCTION fn_contract_list IS
  'M1a list extended by M1c (AE-1, migration 017); cycle-2 patch (020) added '
  '''Super Admin'' to v_role_can_see_all (parity with fn_import_batch_list). '
  '18-param signature; 19-field ContractListItem. M1c added 3 optional params '
  '(p_import_batch_id, p_import_confidence_min, p_import_confidence_max) and '
  '3 row fields (importBatchId, importConfidence, importWarnings). M1a '
  'behaviour preserved verbatim when new params are NULL.';

-- ============================================================
-- 3. Record migration
-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (20, 'm1c_fix_concurrency_role_gate_and_warnings_default', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 020_m1c_fix_concurrency_role_gate_and_warnings_default.sql
-- ============================================================================
-- Restores the v19 fn_contract_create (without parent FOR UPDATE, without
-- import_batch FOR UPDATE, with importWarnings default '[]') and the v17
-- fn_contract_list (without 'Super Admin' in v_role_can_see_all). Run this
-- manually if 020 must be reversed; the cycle-1 regressions and AC-S4-05/01
-- gap will reappear afterwards.
-- ROLLBACK BEGIN
BEGIN;

-- Restore v19 fn_contract_create body (verbatim from 019 forward section).
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
  v_import_batch_id := NULLIF(p_data->>'importBatchId','')::BIGINT;
  v_import_filename := NULLIF(p_data->>'importFilename','');
  v_import_conf := NULLIF(p_data->>'importConfidence','')::INTEGER;
  IF v_import_conf IS NOT NULL AND (v_import_conf < 0 OR v_import_conf > 100) THEN
    RAISE EXCEPTION 'fn_contract_create: %', 'importConfidence:Confidence must be between 0 and 100';
  END IF;
  IF p_data ? 'importWarnings' AND p_data->'importWarnings' IS NOT NULL AND jsonb_typeof(p_data->'importWarnings') <> 'null' THEN
    v_import_warnings := p_data->'importWarnings';
  ELSE
    v_import_warnings := '[]'::JSONB;
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
        import_batch_id, import_filename, import_confidence, import_warnings,
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
        v_import_batch_id, v_import_filename, v_import_conf, v_import_warnings,
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

-- Restore v17 fn_contract_list (without 'Super Admin' in v_role_can_see_all).
CREATE OR REPLACE FUNCTION fn_contract_list(
  p_page                    INTEGER       DEFAULT 1,
  p_limit                   INTEGER       DEFAULT 20,
  p_status                  TEXT          DEFAULT NULL,
  p_contract_type           TEXT          DEFAULT NULL,
  p_counterparty_id         BIGINT        DEFAULT NULL,
  p_drafted_by              BIGINT        DEFAULT NULL,
  p_approved_by             BIGINT        DEFAULT NULL,
  p_start_date_from         DATE          DEFAULT NULL,
  p_start_date_to           DATE          DEFAULT NULL,
  p_end_date_from           DATE          DEFAULT NULL,
  p_end_date_to             DATE          DEFAULT NULL,
  p_tags                    TEXT[]        DEFAULT NULL,
  p_search                  TEXT          DEFAULT NULL,
  p_actor_id                BIGINT        DEFAULT NULL,
  p_actor_role              TEXT          DEFAULT NULL,
  p_import_batch_id         BIGINT        DEFAULT NULL,
  p_import_confidence_min   INTEGER       DEFAULT NULL,
  p_import_confidence_max   INTEGER       DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset    INTEGER;
  v_total     BIGINT;
  v_data      JSONB;
  v_role_can_see_all BOOLEAN;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'page:Page must be >= 1';
  END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'limit:Limit must be between 1 and 100';
  END IF;
  v_offset := (p_page - 1) * p_limit;
  v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive');
  SELECT COUNT(*) INTO v_total FROM contract c
    WHERE c.is_active = TRUE
      AND (p_status IS NULL          OR c.status = p_status)
      AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
      AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
      AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
      AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
      AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
      AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
      AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
      AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
      AND (p_search IS NULL OR (
            lower(c.contract_number) LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_en,'')) LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_ar,'')) LIKE '%' || lower(p_search) || '%'))
      AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
            (SELECT COUNT(*) FROM unnest(p_tags) tg
              WHERE EXISTS (
                SELECT 1 FROM contract_tag ct
                  WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
              )) = array_length(p_tags, 1)))
      AND (p_import_batch_id        IS NULL OR c.import_batch_id    = p_import_batch_id)
      AND (p_import_confidence_min  IS NULL OR c.import_confidence >= p_import_confidence_min)
      AND (p_import_confidence_max  IS NULL OR c.import_confidence <= p_import_confidence_max)
      AND (v_role_can_see_all OR (
            c.drafted_by  = p_actor_id
         OR c.reviewed_by = p_actor_id
         OR c.approved_by = p_actor_id
         OR c.created_by  = p_actor_id));
  SELECT COALESCE(jsonb_agg(row_to_payload), '[]'::JSONB) INTO v_data
    FROM (
      SELECT jsonb_build_object(
        'id', c.id, 'contractNumber', c.contract_number,
        'titleEn', c.title_en, 'titleAr', c.title_ar,
        'contractType', c.contract_type, 'status', c.status,
        'valueAed', c.value_aed, 'currency', c.currency,
        'startDate', c.start_date, 'endDate', c.end_date,
        'counterpartyId', c.counterparty_id, 'ourPartyId', c.our_party_id,
        'tags', COALESCE((SELECT jsonb_agg(ct.tag ORDER BY ct.tag)
                           FROM contract_tag ct
                           WHERE ct.contract_id = c.id AND ct.is_active = TRUE), '[]'::JSONB),
        'currentVersion', c.current_version,
        'createdAt', c.created_at, 'updatedAt', c.updated_at,
        'importBatchId', c.import_batch_id,
        'importConfidence', c.import_confidence,
        'importWarnings', c.import_warnings
      ) AS row_to_payload
        FROM contract c
        WHERE c.is_active = TRUE
          AND (p_status IS NULL          OR c.status = p_status)
          AND (p_contract_type IS NULL   OR c.contract_type = p_contract_type)
          AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
          AND (p_drafted_by IS NULL      OR c.drafted_by = p_drafted_by)
          AND (p_approved_by IS NULL     OR c.approved_by = p_approved_by)
          AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
          AND (p_start_date_to IS NULL   OR c.start_date <= p_start_date_to)
          AND (p_end_date_from IS NULL   OR c.end_date   >= p_end_date_from)
          AND (p_end_date_to IS NULL     OR c.end_date   <= p_end_date_to)
          AND (p_search IS NULL OR (
                lower(c.contract_number) LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_en,'')) LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_ar,'')) LIKE '%' || lower(p_search) || '%'))
          AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
                (SELECT COUNT(*) FROM unnest(p_tags) tg
                  WHERE EXISTS (
                    SELECT 1 FROM contract_tag ct
                      WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
                  )) = array_length(p_tags, 1)))
          AND (p_import_batch_id        IS NULL OR c.import_batch_id    = p_import_batch_id)
          AND (p_import_confidence_min  IS NULL OR c.import_confidence >= p_import_confidence_min)
          AND (p_import_confidence_max  IS NULL OR c.import_confidence <= p_import_confidence_max)
          AND (v_role_can_see_all OR (
                c.drafted_by  = p_actor_id
             OR c.reviewed_by = p_actor_id
             OR c.approved_by = p_actor_id
             OR c.created_by  = p_actor_id))
        ORDER BY c.created_at DESC, c.end_date ASC NULLS LAST
        LIMIT p_limit OFFSET v_offset
    ) sub;
  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', v_total, 'page', p_page, 'limit', p_limit,
      'totalPages', CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER)
    )
  );
END;
$$;

DELETE FROM schema_migrations WHERE version = 20;
COMMIT;
-- ROLLBACK END
