-- ============================================================================
-- 012_m1b_fix_export_xlsx_tags.sql — Fix operator-type-mismatch in fn_contract_export_xlsx
-- ============================================================================
-- Module:    M1b (patch on 011)
-- Depends:   011 (fn_contract_export_xlsx defined)
-- ----------------------------------------------------------------------------
-- Bug:
--   In 011, fn_contract_export_xlsx tag filter used:
--     p_tags <@ (SELECT COALESCE(array_agg(t.tag), ARRAY[]::TEXT[]) FROM contract_tag t WHERE ...)
--   p_tags is TEXT[] but contract_tag.tag is VARCHAR(64), so array_agg(t.tag) yields VARCHAR[].
--   PostgreSQL has no `text[] <@ varchar[]` operator resolution; the planner errors before the
--   `p_tags IS NULL OR ...` short-circuit can fire, so every invocation reaching the tag-filter
--   SELECT fails (the function deployed cleanly because CREATE OR REPLACE accepts the syntax).
--
-- Fix (Option B — mirror M1a's fn_contract_list pattern):
--   Replace the `<@` operator with the unnest(p_tags) tg / EXISTS pattern already validated in
--   005_m1a_contract_functions.sql + 007_m1a_fix_total_pages_zero.sql. Treats each requested tag
--   individually and uses the scalar `ct.tag = tg` comparison, which PostgreSQL resolves cleanly
--   across TEXT and VARCHAR via implicit cast. This is set-containment equivalent (count of
--   matched requested tags = array_length(p_tags, 1)) — same semantics as `p_tags <@ ...`.
--
-- Body verbatim from 011 EXCEPT for the two tag-filter clauses (count CTE + aggregate CTE).
-- All other attributes preserved: SECURITY INVOKER, STABLE, search_path = public,pg_temp,
-- and the comment from 011.
-- ----------------------------------------------------------------------------

BEGIN;

-- 5. fn_contract_export_xlsx (SECURITY INVOKER STABLE — no activity emit)
CREATE OR REPLACE FUNCTION fn_contract_export_xlsx(
  p_actor_id         BIGINT,
  p_actor_role       TEXT    DEFAULT NULL,
  p_status           TEXT    DEFAULT NULL,
  p_contract_type    TEXT    DEFAULT NULL,
  p_counterparty_id  BIGINT  DEFAULT NULL,
  p_drafted_by       BIGINT  DEFAULT NULL,
  p_approved_by      BIGINT  DEFAULT NULL,
  p_start_date_from  DATE    DEFAULT NULL,
  p_start_date_to    DATE    DEFAULT NULL,
  p_end_date_from    DATE    DEFAULT NULL,
  p_end_date_to      DATE    DEFAULT NULL,
  p_tags             TEXT[]  DEFAULT NULL,
  p_search           TEXT    DEFAULT NULL,
  p_max_rows         INTEGER DEFAULT 10000
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_max_rows  INTEGER;
  v_total     BIGINT;
  v_rows      JSONB;
  v_truncated BOOLEAN := FALSE;
BEGIN
  IF p_max_rows IS NULL OR p_max_rows < 1 OR p_max_rows > 50000 THEN
    RAISE EXCEPTION 'fn_contract_export_xlsx: %', 'maxRows:maxRows must be between 1 and 50000';
  END IF;
  v_max_rows := LEAST(GREATEST(p_max_rows, 1), 50000);

  -- Count for truncation flag (cheap because of M1a indexes; reuses same WHERE)
  WITH filtered AS (
    SELECT c.id FROM contract c
    WHERE c.is_active = TRUE
      AND (p_status         IS NULL OR c.status = p_status)
      AND (p_contract_type  IS NULL OR c.contract_type = p_contract_type)
      AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
      AND (p_drafted_by     IS NULL OR c.drafted_by = p_drafted_by)
      AND (p_approved_by    IS NULL OR c.approved_by = p_approved_by)
      AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
      AND (p_start_date_to   IS NULL OR c.start_date <= p_start_date_to)
      AND (p_end_date_from   IS NULL OR c.end_date   >= p_end_date_from)
      AND (p_end_date_to     IS NULL OR c.end_date   <= p_end_date_to)
      AND (p_search IS NULL OR lower(coalesce(c.contract_number,'') || ' ' || coalesce(c.title_en,'') || ' ' || coalesce(c.title_ar,''))
                                 LIKE '%' || lower(p_search) || '%')
      AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
            (SELECT COUNT(*) FROM unnest(p_tags) tg
              WHERE EXISTS (
                SELECT 1 FROM contract_tag ct
                  WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
              )) = array_length(p_tags, 1)))
  )
  SELECT COUNT(*)::BIGINT INTO v_total FROM filtered;

  IF v_total > v_max_rows THEN v_truncated := TRUE; END IF;

  -- Aggregate the row payload (capped by v_max_rows)
  WITH filtered AS (
    SELECT c.* FROM contract c
    WHERE c.is_active = TRUE
      AND (p_status         IS NULL OR c.status = p_status)
      AND (p_contract_type  IS NULL OR c.contract_type = p_contract_type)
      AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
      AND (p_drafted_by     IS NULL OR c.drafted_by = p_drafted_by)
      AND (p_approved_by    IS NULL OR c.approved_by = p_approved_by)
      AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
      AND (p_start_date_to   IS NULL OR c.start_date <= p_start_date_to)
      AND (p_end_date_from   IS NULL OR c.end_date   >= p_end_date_from)
      AND (p_end_date_to     IS NULL OR c.end_date   <= p_end_date_to)
      AND (p_search IS NULL OR lower(coalesce(c.contract_number,'') || ' ' || coalesce(c.title_en,'') || ' ' || coalesce(c.title_ar,''))
                                 LIKE '%' || lower(p_search) || '%')
      AND (p_tags IS NULL OR p_tags = '{}'::TEXT[] OR (
            (SELECT COUNT(*) FROM unnest(p_tags) tg
              WHERE EXISTS (
                SELECT 1 FROM contract_tag ct
                  WHERE ct.contract_id = c.id AND ct.tag = tg AND ct.is_active = TRUE
              )) = array_length(p_tags, 1)))
    ORDER BY c.created_at DESC, c.id DESC
    LIMIT v_max_rows
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', f.id, 'contractNumber', f.contract_number,
      'titleEn', f.title_en, 'titleAr', f.title_ar,
      'contractType', f.contract_type, 'status', f.status,
      'valueAed', f.value_aed, 'currency', f.currency,
      'startDate', f.start_date, 'endDate', f.end_date,
      'counterpartyId', f.counterparty_id, 'ourPartyId', f.our_party_id,
      'tagsCsv', (SELECT string_agg(t.tag, ', ' ORDER BY t.tag) FROM contract_tag t
                    WHERE t.contract_id = f.id AND t.is_active = TRUE),
      'currentVersion', f.current_version,
      'createdAt', f.created_at, 'updatedAt', f.updated_at
    ) ORDER BY f.created_at DESC, f.id DESC
  ), '[]'::JSONB) INTO v_rows
    FROM filtered f;

  RETURN jsonb_build_object(
    'rows',          v_rows,
    'totalRows',     LEAST(v_total, v_max_rows),
    'truncated',     v_truncated,
    'filterApplied', jsonb_build_object(
      'status', p_status, 'contractType', p_contract_type,
      'counterpartyId', p_counterparty_id, 'draftedBy', p_drafted_by, 'approvedBy', p_approved_by,
      'startDateFrom', p_start_date_from, 'startDateTo', p_start_date_to,
      'endDateFrom',   p_end_date_from,   'endDateTo',   p_end_date_to,
      'tags', to_jsonb(p_tags), 'search', p_search, 'maxRows', v_max_rows
    ),
    'generatedAt',   CURRENT_TIMESTAMP
  );
END;
$$;
COMMENT ON FUNCTION fn_contract_export_xlsx IS
  'M1b read. SECURITY INVOKER STABLE. Returns flat list payload for BE exceljs streaming. Filter semantics IDENTICAL to M1a fn_contract_list (M1b duplicates the WHERE rather than refactoring; if a third copy emerges, refactor then). Hard cap p_max_rows ∈ [1,50000]; sets truncated=true when filter yields more rows. NO activity emission — list-level audit is the BE controller''s responsibility via fn_audit_log_record. (012 fix) tag filter uses unnest(p_tags)/EXISTS (M1a fn_contract_list pattern) instead of `<@` to avoid `text[] <@ varchar[]` operator-resolution failure caused by contract_tag.tag being VARCHAR(64).';

-- Record migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (12, 'm1b_fix_export_xlsx_tags', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 012_m1b_fix_export_xlsx_tags.sql
-- ============================================================================
-- Restores the broken pre-012 body verbatim from 011 (CREATE OR REPLACE is idempotent;
-- this brings the function back to the bugged state for the rollback assertion).
-- ROLLBACK BEGIN
BEGIN;
  CREATE OR REPLACE FUNCTION fn_contract_export_xlsx(
    p_actor_id         BIGINT,
    p_actor_role       TEXT    DEFAULT NULL,
    p_status           TEXT    DEFAULT NULL,
    p_contract_type    TEXT    DEFAULT NULL,
    p_counterparty_id  BIGINT  DEFAULT NULL,
    p_drafted_by       BIGINT  DEFAULT NULL,
    p_approved_by      BIGINT  DEFAULT NULL,
    p_start_date_from  DATE    DEFAULT NULL,
    p_start_date_to    DATE    DEFAULT NULL,
    p_end_date_from    DATE    DEFAULT NULL,
    p_end_date_to      DATE    DEFAULT NULL,
    p_tags             TEXT[]  DEFAULT NULL,
    p_search           TEXT    DEFAULT NULL,
    p_max_rows         INTEGER DEFAULT 10000
  ) RETURNS JSONB
  LANGUAGE plpgsql
  SECURITY INVOKER
  STABLE
  SET search_path = public, pg_temp
  AS $$
  DECLARE
    v_max_rows  INTEGER;
    v_total     BIGINT;
    v_rows      JSONB;
    v_truncated BOOLEAN := FALSE;
  BEGIN
    IF p_max_rows IS NULL OR p_max_rows < 1 OR p_max_rows > 50000 THEN
      RAISE EXCEPTION 'fn_contract_export_xlsx: %', 'maxRows:maxRows must be between 1 and 50000';
    END IF;
    v_max_rows := LEAST(GREATEST(p_max_rows, 1), 50000);
    WITH filtered AS (
      SELECT c.id FROM contract c
      WHERE c.is_active = TRUE
        AND (p_status         IS NULL OR c.status = p_status)
        AND (p_contract_type  IS NULL OR c.contract_type = p_contract_type)
        AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
        AND (p_drafted_by     IS NULL OR c.drafted_by = p_drafted_by)
        AND (p_approved_by    IS NULL OR c.approved_by = p_approved_by)
        AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
        AND (p_start_date_to   IS NULL OR c.start_date <= p_start_date_to)
        AND (p_end_date_from   IS NULL OR c.end_date   >= p_end_date_from)
        AND (p_end_date_to     IS NULL OR c.end_date   <= p_end_date_to)
        AND (p_search IS NULL OR lower(coalesce(c.contract_number,'') || ' ' || coalesce(c.title_en,'') || ' ' || coalesce(c.title_ar,''))
                                   LIKE '%' || lower(p_search) || '%')
        AND (p_tags IS NULL OR p_tags <@ (
          SELECT COALESCE(array_agg(t.tag), ARRAY[]::TEXT[])
            FROM contract_tag t WHERE t.contract_id = c.id AND t.is_active = TRUE
        ))
    )
    SELECT COUNT(*)::BIGINT INTO v_total FROM filtered;
    IF v_total > v_max_rows THEN v_truncated := TRUE; END IF;
    WITH filtered AS (
      SELECT c.* FROM contract c
      WHERE c.is_active = TRUE
        AND (p_status         IS NULL OR c.status = p_status)
        AND (p_contract_type  IS NULL OR c.contract_type = p_contract_type)
        AND (p_counterparty_id IS NULL OR c.counterparty_id = p_counterparty_id)
        AND (p_drafted_by     IS NULL OR c.drafted_by = p_drafted_by)
        AND (p_approved_by    IS NULL OR c.approved_by = p_approved_by)
        AND (p_start_date_from IS NULL OR c.start_date >= p_start_date_from)
        AND (p_start_date_to   IS NULL OR c.start_date <= p_start_date_to)
        AND (p_end_date_from   IS NULL OR c.end_date   >= p_end_date_from)
        AND (p_end_date_to     IS NULL OR c.end_date   <= p_end_date_to)
        AND (p_search IS NULL OR lower(coalesce(c.contract_number,'') || ' ' || coalesce(c.title_en,'') || ' ' || coalesce(c.title_ar,''))
                                   LIKE '%' || lower(p_search) || '%')
        AND (p_tags IS NULL OR p_tags <@ (
          SELECT COALESCE(array_agg(t.tag), ARRAY[]::TEXT[])
            FROM contract_tag t WHERE t.contract_id = c.id AND t.is_active = TRUE
        ))
      ORDER BY c.created_at DESC, c.id DESC
      LIMIT v_max_rows
    )
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'id', f.id, 'contractNumber', f.contract_number,
        'titleEn', f.title_en, 'titleAr', f.title_ar,
        'contractType', f.contract_type, 'status', f.status,
        'valueAed', f.value_aed, 'currency', f.currency,
        'startDate', f.start_date, 'endDate', f.end_date,
        'counterpartyId', f.counterparty_id, 'ourPartyId', f.our_party_id,
        'tagsCsv', (SELECT string_agg(t.tag, ', ' ORDER BY t.tag) FROM contract_tag t
                      WHERE t.contract_id = f.id AND t.is_active = TRUE),
        'currentVersion', f.current_version,
        'createdAt', f.created_at, 'updatedAt', f.updated_at
      ) ORDER BY f.created_at DESC, f.id DESC
    ), '[]'::JSONB) INTO v_rows
      FROM filtered f;
    RETURN jsonb_build_object(
      'rows',          v_rows,
      'totalRows',     LEAST(v_total, v_max_rows),
      'truncated',     v_truncated,
      'filterApplied', jsonb_build_object(
        'status', p_status, 'contractType', p_contract_type,
        'counterpartyId', p_counterparty_id, 'draftedBy', p_drafted_by, 'approvedBy', p_approved_by,
        'startDateFrom', p_start_date_from, 'startDateTo', p_start_date_to,
        'endDateFrom',   p_end_date_from,   'endDateTo',   p_end_date_to,
        'tags', to_jsonb(p_tags), 'search', p_search, 'maxRows', v_max_rows
      ),
      'generatedAt',   CURRENT_TIMESTAMP
    );
  END;
  $$;
  DELETE FROM schema_migrations WHERE version = 12;
COMMIT;
-- ROLLBACK END
