-- Migration: 607_drafter_contracts_scope_and_recent_drafts_type.sql
-- Module: Drafter contracts scope tighten + dashboard Recent drafts type column
-- Date: 2026-06-09
--
-- Two related changes for the drafter persona:
--
-- 1. fn_contract_list — tighten the contract_drafter scope.
--
--    Before: contract_drafter is NOT in v_role_can_see_all, so the OR
--    fallback grants visibility on contracts where the drafter is ANY of
--    drafted_by / reviewed_by / approved_by / created_by / a signing
--    party. For Hala that yielded 174 visible contracts vs only 121 on
--    fn_dashboard_drafter (which filters drafted_by = me). The 53-gap
--    confused the demo — list said 174 in scope, donut said 121 total.
--
--    After: when p_actor_role = 'contract_drafter', restrict visibility
--    strictly to drafted_by = p_actor_id. Other roles untouched: legal
--    counsel / executive / approver / operations / platform_admin still
--    see-all; recipient still routes via signature_party.
--
-- 2. fn_dashboard_drafter — add contractType to the myDrafts5 payload.
--
--    The FE is replacing the cramped 5-column ContractRowList on the
--    Recent drafts widget with a table modelled on Legal Counsel's
--    approval queue (Contract / Type / Value / Updated / Open →). That
--    table renders a Type chip per row, so the fn output needs a
--    contractType field — additive, doesn't break any current reader.
--    awaitingMyAction5 is left untouched (different shape).

BEGIN;

-- ──────────────────────────────────────────────────────────────────────
-- (1) fn_contract_list — drafter scope tighten
-- ──────────────────────────────────────────────────────────────────────
-- Body byte-for-byte from migration 562 except for THREE places where
-- the OR-fallback is wrapped to apply the drafter-only carve-out.
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
  v_drafter_only BOOLEAN;
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
  -- NEW: drafter-only carve-out. When the actor is a drafter, narrow
  -- the OR-fallback to drafted_by = me. Reviewer / approver / creator /
  -- signing-party fallbacks are intentionally dropped — the drafter
  -- persona view is "my drafts" only, mirroring fn_dashboard_drafter.
  v_drafter_only := p_actor_role = 'contract_drafter';

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
      AND (
            v_role_can_see_all
            OR (v_drafter_only AND c.drafted_by = p_actor_id)
            OR (NOT v_drafter_only AND (
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
          );

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
      AND (
            v_role_can_see_all
            OR (v_drafter_only AND c.drafted_by = p_actor_id)
            OR (NOT v_drafter_only AND (
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
          );

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
          AND (
                v_role_can_see_all
                OR (v_drafter_only AND c.drafted_by = p_actor_id)
                OR (NOT v_drafter_only AND (
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
              )
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

-- ──────────────────────────────────────────────────────────────────────
-- (2) fn_dashboard_drafter — add contractType to myDrafts5
-- ──────────────────────────────────────────────────────────────────────
-- Body byte-for-byte from migration 605 except for the additional
-- 'contractType' field inside myDrafts5.
CREATE OR REPLACE FUNCTION public.fn_dashboard_drafter(p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_user_id BIGINT;
  v_role    TEXT;
  v_window  INTEGER;
  v_kpis    JSONB;
  v_lists   JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: unauthorized' USING ERRCODE = '42501';
  END IF;
  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;
  IF v_role IS NULL OR v_role NOT IN ('contract_drafter', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: forbidden — drafter dashboard restricted to contract_drafter, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'myDraftsCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id AND status = 'draft' AND is_active = TRUE),
    'inProgressCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('draft','in_approval','resubmission_requested',
                         'awaiting_signature_employer','awaiting_signature_counterparty')
          AND is_active = TRUE),
    'awaitingMyActionCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('draft','resubmission_requested')
          AND is_active = TRUE),
    'readyToSendCount',
      (SELECT COUNT(*) FROM contract c
        WHERE c.drafted_by = v_user_id
          AND c.status IN ('awaiting_signature_employer','awaiting_signature_counterparty')
          AND c.is_active = TRUE),
    'myRecentlyApprovedCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('fully_signed','active')
          AND updated_at >= fn_demo_now() - (v_window || ' days')::INTERVAL
          AND is_active = TRUE),
    -- NEW (v607): all-time signed count — feeds the "My contracts by
    -- stage" donut so the donut total reconciles with the Contracts
    -- list (drafter-scope total). myRecentlyApprovedCount is the
    -- 30-day-window KPI; mySignedAllTimeCount is the donut input.
    'mySignedAllTimeCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('fully_signed','active','expired','terminated','amended')
          AND is_active = TRUE)
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    -- NEW (v607): contractType added so the FE Recent drafts table can
    -- render a Type chip per row, mirroring Legal Counsel's approval
    -- queue. Field is additive — backward compatible.
    'myDrafts5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'contractType', c.contract_type,
          'status', c.status,
          'valueAed', c.value_aed,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id AND status = 'draft' AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb),
    'awaitingMyAction5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'status', c.status,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id
            AND status IN ('draft','resubmission_requested')
            AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists);
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (607, '607_drafter_contracts_scope_and_recent_drafts_type', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
