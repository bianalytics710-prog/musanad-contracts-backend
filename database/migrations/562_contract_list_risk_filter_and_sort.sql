-- MIGRATION: 562_contract_list_risk_filter_and_sort.sql
-- Date: 2026-06-05
-- Description:
--   Extends fn_contract_list with:
--     1. A new p_risk_bucket parameter ('high' / 'medium' / 'low' /
--        'flagged' / NULL) that filters on contract.ai_risk_score:
--          high     → ai_risk_score >= 70
--          medium   → ai_risk_score BETWEEN 40 AND 69
--          low      → ai_risk_score BETWEEN 1 AND 39
--          flagged  → ai_risk_score IS NOT NULL AND > 0
--          NULL     → no filter
--     2. A new 'risk' sort key: ORDER BY ai_risk_score DESC NULLS LAST.
--     3. An aiRiskScore field on every row payload so the FE can render
--        the inline Risk N badge inside the Title cell when score >= 70.
--
--   Rationale: the executive dashboard's "View all flagged contracts →"
--   link previously dumped the user into /app/contracts unfiltered. With
--   ?risk=high&sort=risk wired up, the same click lands them on a
--   pre-filtered, pre-sorted view of contracts with score >= 70.
--
--   Body byte-for-byte identical to migration 507 except:
--     - Added p_risk_bucket parameter (last position, defaults NULL).
--     - Extended v_sort validation to accept 'risk'.
--     - Added aiRiskScore to the row payload.
--     - Added the bucket filter to the TOTAL COUNT, STATUS COUNTS, and
--       DATA PAGE WHERE clauses.
--     - Added 'risk' branch to the ORDER BY (sorted by -ai_risk_score
--       so DESC NULLS LAST falls out naturally with NULLS LAST).

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_contract_list(
  p_page integer DEFAULT 1,
  p_limit integer DEFAULT 20,
  p_status text DEFAULT NULL,
  p_contract_type text DEFAULT NULL,
  p_counterparty_id bigint DEFAULT NULL,
  p_drafted_by bigint DEFAULT NULL,
  p_approved_by bigint DEFAULT NULL,
  p_start_date_from date DEFAULT NULL,
  p_start_date_to date DEFAULT NULL,
  p_end_date_from date DEFAULT NULL,
  p_end_date_to date DEFAULT NULL,
  p_tags text[] DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_actor_id bigint DEFAULT NULL,
  p_actor_role text DEFAULT NULL,
  p_import_batch_id bigint DEFAULT NULL,
  p_import_confidence_min integer DEFAULT NULL,
  p_import_confidence_max integer DEFAULT NULL,
  p_language text DEFAULT NULL,
  p_governing_law text DEFAULT NULL,
  p_sort text DEFAULT NULL,
  p_risk_bucket text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_offset       INTEGER;
  v_total        BIGINT;
  v_data         JSONB;
  v_role_can_see_all BOOLEAN;
  v_sort         TEXT;
  v_bucket       TEXT;
  v_active       BIGINT;
  v_in_approval  BIGINT;
  v_expiring     BIGINT;
BEGIN
  IF p_page < 1 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'page:Page must be >= 1';
  END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'limit:Limit must be between 1 and 100';
  END IF;
  v_sort := COALESCE(p_sort, 'updated_at');
  IF v_sort NOT IN ('updated_at','created_at','end_date','value','alpha','risk') THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'sort:Invalid sort field';
  END IF;
  v_bucket := NULLIF(LOWER(COALESCE(p_risk_bucket, '')), '');
  IF v_bucket IS NOT NULL AND v_bucket NOT IN ('high','medium','low','flagged') THEN
    RAISE EXCEPTION 'fn_contract_list: %', 'riskBucket:Must be one of high|medium|low|flagged';
  END IF;

  v_offset := (p_page - 1) * p_limit;

  v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive', 'contract_approver', 'operations', 'Super Admin');

  -- ── TOTAL COUNT ───────────────────────────────────────────────────────────
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
      AND (v_bucket IS NULL OR (
              (v_bucket = 'high'    AND c.ai_risk_score >= 70)
           OR (v_bucket = 'medium'  AND c.ai_risk_score BETWEEN 40 AND 69)
           OR (v_bucket = 'low'     AND c.ai_risk_score BETWEEN 1 AND 39)
           OR (v_bucket = 'flagged' AND c.ai_risk_score IS NOT NULL AND c.ai_risk_score > 0)))
      AND (v_role_can_see_all OR (
            c.drafted_by  = p_actor_id
         OR c.reviewed_by = p_actor_id
         OR c.approved_by = p_actor_id
         OR c.created_by  = p_actor_id
         OR EXISTS (
              SELECT 1 FROM signature_party sp
              WHERE sp.contract_id = c.id
                AND sp.signer_user_id = p_actor_id
                AND sp.is_active = TRUE
            )));

  -- ── STATUS COUNTS (scope, ignores p_status) ───────────────────────────────
  SELECT
    COUNT(*) FILTER (WHERE c.status IN ('active','fully_signed')),
    COUNT(*) FILTER (WHERE c.status = 'in_approval'),
    COUNT(*) FILTER (WHERE c.status = 'expiring_soon')
  INTO v_active, v_in_approval, v_expiring
    FROM contract c
    WHERE c.is_active = TRUE
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
      AND (v_bucket IS NULL OR (
              (v_bucket = 'high'    AND c.ai_risk_score >= 70)
           OR (v_bucket = 'medium'  AND c.ai_risk_score BETWEEN 40 AND 69)
           OR (v_bucket = 'low'     AND c.ai_risk_score BETWEEN 1 AND 39)
           OR (v_bucket = 'flagged' AND c.ai_risk_score IS NOT NULL AND c.ai_risk_score > 0)))
      AND (v_role_can_see_all OR (
            c.drafted_by  = p_actor_id
         OR c.reviewed_by = p_actor_id
         OR c.approved_by = p_actor_id
         OR c.created_by  = p_actor_id
         OR EXISTS (
              SELECT 1 FROM signature_party sp
              WHERE sp.contract_id = c.id
                AND sp.signer_user_id = p_actor_id
                AND sp.is_active = TRUE
            )));

  -- ── DATA PAGE ─────────────────────────────────────────────────────────────
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
        'aiRiskScore',    c.ai_risk_score,
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
        WHEN 'risk'       THEN COALESCE(c.ai_risk_score, 0) * -1
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
          AND (v_bucket IS NULL OR (
                  (v_bucket = 'high'    AND c.ai_risk_score >= 70)
               OR (v_bucket = 'medium'  AND c.ai_risk_score BETWEEN 40 AND 69)
               OR (v_bucket = 'low'     AND c.ai_risk_score BETWEEN 1 AND 39)
               OR (v_bucket = 'flagged' AND c.ai_risk_score IS NOT NULL AND c.ai_risk_score > 0)))
          AND (v_role_can_see_all OR (
                c.drafted_by  = p_actor_id
             OR c.reviewed_by = p_actor_id
             OR c.approved_by = p_actor_id
             OR c.created_by  = p_actor_id
             OR EXISTS (
                  SELECT 1 FROM signature_party sp
                  WHERE sp.contract_id = c.id
                    AND sp.signer_user_id = p_actor_id
                    AND sp.is_active = TRUE
                )))
        ORDER BY
          CASE v_sort
            WHEN 'updated_at' THEN EXTRACT(EPOCH FROM c.updated_at)::NUMERIC * -1
            WHEN 'created_at' THEN EXTRACT(EPOCH FROM c.created_at)::NUMERIC * -1
            WHEN 'end_date'   THEN COALESCE(EXTRACT(EPOCH FROM c.end_date)::NUMERIC, 'infinity'::NUMERIC)
            WHEN 'value'      THEN COALESCE(c.value_aed, 0) * -1
            WHEN 'risk'       THEN COALESCE(c.ai_risk_score, 0) * -1
            ELSE                  NULL
          END NULLS LAST,
          CASE v_sort
            WHEN 'alpha' THEN lower(coalesce(c.title_en, c.contract_number, ''))
            ELSE              NULL
          END NULLS LAST,
          c.id::NUMERIC
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
    ),
    'statusCounts', jsonb_build_object(
      'active',       v_active,
      'inApproval',   v_in_approval,
      'expiringSoon', v_expiring
    )
  );
END;
$function$;

COMMIT;
