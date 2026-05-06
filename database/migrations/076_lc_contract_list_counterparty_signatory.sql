-- Migration 076: R-LC6 — fn_contract_list adds Counterparty + Signatory.
--
-- Lovable's contracts list has Counterparty and Signatory columns we
-- don't expose. This migration extends fn_contract_list (21-param
-- variant from migration 069) to project:
--   - counterpartyName (party.name_en / name_ar based on locale handled FE-side)
--   - counterpartyNameEn / counterpartyNameAr (raw)
--   - signatoryFirstName / signatoryLastName (user.first_name resolved
--     from contract.drafted_by, fallback to created_by). Lovable surfaces
--     the "primary actor" on the contract — drafter is the most stable
--     fit for that mental model since approvers/signers may differ across
--     stages.
--
-- Body byte-for-byte identical to 069 except:
--   * Two extra LEFT JOINs (party, "user")
--   * Added camelCase fields in jsonb_build_object
--
-- 21-param signature unchanged so the controller doesn't need to update.

DROP FUNCTION IF EXISTS fn_contract_list(
  BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT,
  TEXT[], DATE, DATE, DATE, DATE, NUMERIC, NUMERIC,
  VARCHAR, INTEGER, INTEGER,
  BOOLEAN, VARCHAR,
  VARCHAR, VARCHAR, VARCHAR
);

CREATE FUNCTION fn_contract_list(
  p_actor_id                BIGINT,
  p_status                  VARCHAR       DEFAULT NULL,
  p_contract_type           VARCHAR       DEFAULT NULL,
  p_counterparty_id         BIGINT        DEFAULT NULL,
  p_drafted_by              BIGINT        DEFAULT NULL,
  p_approved_by             BIGINT        DEFAULT NULL,
  p_tags                    TEXT[]        DEFAULT NULL,
  p_start_date_from         DATE          DEFAULT NULL,
  p_start_date_to           DATE          DEFAULT NULL,
  p_end_date_from           DATE          DEFAULT NULL,
  p_end_date_to             DATE          DEFAULT NULL,
  p_value_aed_min           NUMERIC       DEFAULT NULL,
  p_value_aed_max           NUMERIC       DEFAULT NULL,
  p_search                  VARCHAR       DEFAULT NULL,
  p_page                    INTEGER       DEFAULT 1,
  p_limit                   INTEGER       DEFAULT 20,
  p_include_orphan_imports  BOOLEAN       DEFAULT TRUE,
  p_imported_only           VARCHAR       DEFAULT NULL,
  p_language                VARCHAR       DEFAULT NULL,
  p_governing_law           VARCHAR       DEFAULT NULL,
  p_sort                    VARCHAR       DEFAULT 'updated_at'
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id   BIGINT;
  v_role     TEXT;
  v_offset   INTEGER;
  v_total    BIGINT;
  v_data     JSONB;
  v_sort     TEXT;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'unauthorized' USING ERRCODE = '42501';
  END IF;
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'page:Page must be >= 1';
  END IF;
  IF p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'limit:Limit must be 1..100';
  END IF;
  v_offset := (p_page - 1) * p_limit;

  v_sort := COALESCE(p_sort, 'updated_at');
  IF v_sort NOT IN ('updated_at','created_at','end_date','value','alpha') THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'sort:invalid sort value';
  END IF;

  SELECT r.name INTO v_role
    FROM "user" u JOIN role r ON r.id = u.role_id
    WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

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
      AND (p_value_aed_min IS NULL   OR c.value_aed  >= p_value_aed_min)
      AND (p_value_aed_max IS NULL   OR c.value_aed  <= p_value_aed_max)
      AND (p_search IS NULL OR (
            lower(c.contract_number)            LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_en,''))      LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_ar,''))      LIKE '%' || lower(p_search) || '%'))
      AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
            (SELECT COUNT(*) FROM unnest(p_tags) tg
              WHERE EXISTS (
                SELECT 1 FROM contract_tag ct
                WHERE ct.contract_id = c.id
                  AND ct.tag = tg
                  AND ct.is_active = TRUE
              )) = array_length(p_tags, 1)
          ))
      AND (p_include_orphan_imports = TRUE OR c.import_batch_id IS NOT NULL OR c.import_batch_id IS NULL)
      AND (p_imported_only IS NULL OR (
            (p_imported_only = 'imports_only' AND c.import_batch_id IS NOT NULL)
            OR (p_imported_only = 'manual_only' AND c.import_batch_id IS NULL)
          ))
      AND (p_language IS NULL OR c.language = p_language)
      AND (p_governing_law IS NULL OR c.governing_law = p_governing_law);

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
        -- R-LC6 LC-D1 — counterparty name (resolved EN + AR).
        'counterpartyNameEn', cp.name_en,
        'counterpartyNameAr', cp.name_ar,
        -- R-LC6 LC-D2 — signatory = drafter (primary actor on the contract).
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
          AND (p_value_aed_min IS NULL   OR c.value_aed  >= p_value_aed_min)
          AND (p_value_aed_max IS NULL   OR c.value_aed  <= p_value_aed_max)
          AND (p_search IS NULL OR (
                lower(c.contract_number)            LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_en,''))      LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_ar,''))      LIKE '%' || lower(p_search) || '%'))
          AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
                (SELECT COUNT(*) FROM unnest(p_tags) tg
                  WHERE EXISTS (
                    SELECT 1 FROM contract_tag ct
                    WHERE ct.contract_id = c.id
                      AND ct.tag = tg
                      AND ct.is_active = TRUE
                  )) = array_length(p_tags, 1)
              ))
          AND (p_include_orphan_imports = TRUE OR c.import_batch_id IS NOT NULL OR c.import_batch_id IS NULL)
          AND (p_imported_only IS NULL OR (
                (p_imported_only = 'imports_only' AND c.import_batch_id IS NOT NULL)
                OR (p_imported_only = 'manual_only' AND c.import_batch_id IS NULL)
              ))
          AND (p_language IS NULL OR c.language = p_language)
          AND (p_governing_law IS NULL OR c.governing_law = p_governing_law)
        OFFSET v_offset
        LIMIT  p_limit
    ) AS sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'page', p_page,
      'limit', p_limit,
      'total', v_total,
      'totalPages', GREATEST(1, CEIL(v_total::NUMERIC / p_limit::NUMERIC)::INT)
    )
  );
END;
$fn$;

REVOKE ALL ON FUNCTION fn_contract_list(
  BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT,
  TEXT[], DATE, DATE, DATE, DATE, NUMERIC, NUMERIC,
  VARCHAR, INTEGER, INTEGER,
  BOOLEAN, VARCHAR,
  VARCHAR, VARCHAR, VARCHAR
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_list(
  BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT,
  TEXT[], DATE, DATE, DATE, DATE, NUMERIC, NUMERIC,
  VARCHAR, INTEGER, INTEGER,
  BOOLEAN, VARCHAR,
  VARCHAR, VARCHAR, VARCHAR
) TO neondb_owner;

-- ROLLBACK BEGIN
-- ROLLBACK END
