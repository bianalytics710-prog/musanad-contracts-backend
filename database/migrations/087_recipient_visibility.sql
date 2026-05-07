-- ================================================================
-- Migration 087 — R-RC0: extend fn_contract_list row-level visibility
-- to cover the contract_recipient role.
-- ================================================================
-- Up: BEGIN
-- Recipients (role = 'contract_recipient') are external counterparty
-- signers. They are NOT in `v_role_can_see_all` because they should
-- see ONLY the contracts they are linked to as a signature party
-- — never the full org register.
--
-- The existing row-level OR clause checks
--   c.drafted_by | reviewed_by | approved_by | created_by = p_actor_id
-- which never matches a recipient. Result: /app/contracts shows 0
-- rows for them, even though the dashboard finds the same set via a
-- different join (fn_dashboard_recipient uses signer_email match).
--
-- Fix: append a single `OR EXISTS (...)` arm to the row-level OR
-- clause that joins via signature_party.signer_user_id. We restrict
-- to is_active = TRUE so cancelled / soft-deleted signature parties
-- don't leak access (S2-22 column-existence check passes — confirmed
-- by `information_schema.columns` query).
--
-- Body otherwise byte-for-byte identical to migration 084. Same
-- 21-arg signature; same role gate (5 roles). Same projection.
-- Same indexes + filters (Counterparty / Signatory / Hijri etc.
-- preserved from R-LC6).
-- ================================================================

DO $$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT p.oid::regprocedure::TEXT AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.proname = 'fn_contract_list' AND n.nspname = 'public'
  LOOP
    EXECUTE 'DROP FUNCTION ' || rec.sig;
  END LOOP;
END$$;

CREATE FUNCTION fn_contract_list(
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
  p_import_confidence_max   INTEGER       DEFAULT NULL,
  p_language                TEXT          DEFAULT NULL,
  p_governing_law           TEXT          DEFAULT NULL,
  p_sort                    TEXT          DEFAULT NULL
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
  v_sort      TEXT;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'page:Page must be >= 1';
  END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'limit:Limit must be between 1 and 100';
  END IF;
  v_sort := COALESCE(p_sort, 'updated_at');
  IF v_sort NOT IN ('updated_at','created_at','end_date','value','alpha') THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'sort:Invalid sort field';
  END IF;

  v_offset := (p_page - 1) * p_limit;

  v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive', 'contract_approver', 'Super Admin');

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
      AND (p_import_batch_id        IS NULL OR c.import_batch_id    = p_import_batch_id)
      AND (p_import_confidence_min  IS NULL OR c.import_confidence >= p_import_confidence_min)
      AND (p_import_confidence_max  IS NULL OR c.import_confidence <= p_import_confidence_max)
      AND (p_language               IS NULL OR c.language          = p_language)
      AND (p_governing_law          IS NULL OR c.governing_law     = p_governing_law)
      AND (v_role_can_see_all OR (
            c.drafted_by  = p_actor_id
         OR c.reviewed_by = p_actor_id
         OR c.approved_by = p_actor_id
         OR c.created_by  = p_actor_id
         -- R-RC0: recipient row-level visibility — actor is a signature party.
         OR EXISTS (
              SELECT 1 FROM signature_party sp
              WHERE sp.contract_id = c.id
                AND sp.signer_user_id = p_actor_id
                AND sp.is_active = TRUE
            )));

  SELECT COALESCE(jsonb_agg(row_to_payload ORDER BY ord_key1, ord_key2, ord_key3), '[]'::JSONB) INTO v_data
    FROM (
      SELECT jsonb_build_object(
        'id', c.id,
        'contractNumber', c.contract_number,
        'titleEn', c.title_en,
        'titleAr', c.title_ar,
        'contractType', c.contract_type,
        'status', c.status,
        'language', c.language,
        'governingLaw', c.governing_law,
        'valueAed', c.value_aed,
        'currency', c.currency,
        'startDate', c.start_date,
        'endDate', c.end_date,
        'counterpartyId', c.counterparty_id,
        'ourPartyId', c.our_party_id,
        'counterpartyNameEn', cp.name_en,
        'counterpartyNameAr', cp.name_ar,
        'signatoryFirstName', du.first_name,
        'signatoryLastName',  du.last_name,
        'tags', COALESCE((SELECT jsonb_agg(ct.tag ORDER BY ct.tag)
                           FROM contract_tag ct
                           WHERE ct.contract_id = c.id AND ct.is_active = TRUE), '[]'::JSONB),
        'currentVersion', c.current_version,
        'createdAt', c.created_at,
        'updatedAt', c.updated_at,
        'importBatchId',    c.import_batch_id,
        'importConfidence', c.import_confidence,
        'importWarnings',   c.import_warnings
      ) AS row_to_payload,
      CASE v_sort
        WHEN 'updated_at' THEN EXTRACT(EPOCH FROM c.updated_at)::NUMERIC * -1
        WHEN 'created_at' THEN EXTRACT(EPOCH FROM c.created_at)::NUMERIC * -1
        WHEN 'end_date'   THEN COALESCE(EXTRACT(EPOCH FROM c.end_date)::NUMERIC, 'infinity'::NUMERIC)
        WHEN 'value'      THEN COALESCE(c.value_aed, 0) * -1
        ELSE                  NULL
      END AS ord_key1,
      CASE v_sort
        WHEN 'alpha' THEN lower(coalesce(c.title_en, c.contract_number, ''))
        ELSE              NULL
      END AS ord_key2,
      c.id::NUMERIC AS ord_key3
        FROM contract c
        LEFT JOIN party cp ON cp.id = c.counterparty_id
        LEFT JOIN "user" du ON du.id = COALESCE(c.drafted_by, c.created_by)
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
          AND (p_language               IS NULL OR c.language          = p_language)
          AND (p_governing_law          IS NULL OR c.governing_law     = p_governing_law)
          AND (v_role_can_see_all OR (
                c.drafted_by  = p_actor_id
             OR c.reviewed_by = p_actor_id
             OR c.approved_by = p_actor_id
             OR c.created_by  = p_actor_id
             -- R-RC0: recipient row-level visibility — actor is a signature party.
             OR EXISTS (
                  SELECT 1 FROM signature_party sp
                  WHERE sp.contract_id = c.id
                    AND sp.signer_user_id = p_actor_id
                    AND sp.is_active = TRUE
                )))
        LIMIT p_limit OFFSET v_offset
    ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', v_total,
      'page', p_page,
      'limit', p_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0
                         ELSE CEIL(v_total::NUMERIC / p_limit)::INT END
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_list(
  INTEGER, INTEGER, TEXT, TEXT, BIGINT, BIGINT, BIGINT,
  DATE, DATE, DATE, DATE, TEXT[], TEXT, BIGINT, TEXT,
  BIGINT, INTEGER, INTEGER, TEXT, TEXT, TEXT
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION fn_contract_list(
  INTEGER, INTEGER, TEXT, TEXT, BIGINT, BIGINT, BIGINT,
  DATE, DATE, DATE, DATE, TEXT[], TEXT, BIGINT, TEXT,
  BIGINT, INTEGER, INTEGER, TEXT, TEXT, TEXT
) TO neondb_owner;

-- ================================================================
-- Up: END
-- Down: BEGIN
-- (Replay 084 to revert to the recipient-blind visibility model.)
-- ================================================================
-- Down: END
