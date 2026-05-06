-- ============================================================================
-- 062_approver_parity_r0_fixes.sql
-- ============================================================================
-- Module:    M_parity (approver E2E sweep — Round 0 bug fixes)
-- Owner:     Direct work — no orchestrator pipeline
-- Depends:   060 (m_parity read-perm relax)
-- ----------------------------------------------------------------------------
-- Bug 9.1.1 from audit/approver/E2E-COVERAGE-V1.md:
--
-- An approver signed in to /app/contracts sees "Total 0" — no contracts at
-- all — even though they have a pending approval queue. fn_contract_list
-- gates visibility via:
--
--   v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel',
--                                           'executive');
--   ...
--   AND (v_role_can_see_all OR (
--         c.drafted_by  = p_actor_id
--      OR c.reviewed_by = p_actor_id
--      OR c.approved_by = p_actor_id
--      OR c.created_by  = p_actor_id));
--
-- The approver hasn't drafted, reviewed, or completed approval on the
-- contracts in their pending queue (approved_by is set ONLY after a final
-- approval lands), so the join filter excludes everything. Lovable's
-- approver sees the same contract pool as drafters.
--
-- Fix: add 'contract_approver' to the see-all allowlist. Approvers need
-- to research the document body, attachments, payment schedule, etc.
-- before deciding — so blanket read access is appropriate.
-- ----------------------------------------------------------------------------

BEGIN;

CREATE OR REPLACE FUNCTION fn_contract_list(
  p_page              INTEGER       DEFAULT 1,
  p_limit             INTEGER       DEFAULT 20,
  p_status            TEXT          DEFAULT NULL,
  p_contract_type     TEXT          DEFAULT NULL,
  p_counterparty_id   BIGINT        DEFAULT NULL,
  p_drafted_by        BIGINT        DEFAULT NULL,
  p_approved_by       BIGINT        DEFAULT NULL,
  p_start_date_from   DATE          DEFAULT NULL,
  p_start_date_to     DATE          DEFAULT NULL,
  p_end_date_from     DATE          DEFAULT NULL,
  p_end_date_to       DATE          DEFAULT NULL,
  p_tags              TEXT[]        DEFAULT NULL,
  p_search            TEXT          DEFAULT NULL,
  p_actor_id          BIGINT        DEFAULT NULL,
  p_actor_role        TEXT          DEFAULT NULL
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

  -- approver added to read-all allowlist (R0 audit bug 9.1.1).
  v_role_can_see_all := p_actor_role IN ('platform_admin', 'legal_counsel', 'executive', 'contract_approver');

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
            lower(c.contract_number)    LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_en,'')) LIKE '%' || lower(p_search) || '%'
         OR lower(coalesce(c.title_ar,'')) LIKE '%' || lower(p_search) || '%'))
      AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
            (SELECT COUNT(*) FROM unnest(p_tags) tg
              WHERE EXISTS (
                SELECT 1 FROM contract_tag ct
                  WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
              )) = array_length(p_tags, 1)))
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
        'updatedAt', c.updated_at
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
                lower(c.contract_number)    LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_en,'')) LIKE '%' || lower(p_search) || '%'
             OR lower(coalesce(c.title_ar,'')) LIKE '%' || lower(p_search) || '%'))
          AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
                (SELECT COUNT(*) FROM unnest(p_tags) tg
                  WHERE EXISTS (
                    SELECT 1 FROM contract_tag ct
                      WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
                  )) = array_length(p_tags, 1)))
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
      'totalPages', GREATEST(1, CAST(CEIL(v_total::NUMERIC / p_limit) AS INTEGER))
    )
  );
END;
$$;

COMMENT ON FUNCTION fn_contract_list(
  INTEGER, INTEGER, TEXT, TEXT, BIGINT, BIGINT, BIGINT,
  DATE, DATE, DATE, DATE, TEXT[], TEXT, BIGINT, TEXT
) IS
  'M_parity R0 bug 9.1.1: contract_approver added to v_role_can_see_all alongside platform_admin / legal_counsel / executive. Approvers need blanket read access to research contracts before deciding.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (62, 'M_parity R0: add contract_approver to fn_contract_list see-all allowlist', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
