-- Migration: 350_fix_fn_impact_signal_list_body.sql
-- Unit: QA Phase 3 autonomous run 2026-05-31 — corrects mig 349's body which
--       used wrong column names (published_at vs published_date) + wrong return
--       shape (flat vs nested pagination). Restore exact original body, change
--       ONLY the permission check expansion (BUG-008 fix intent preserved).
-- Rollback: re-apply original fn from migration 079 + DELETE row.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_impact_signal_list(
  p_actor_id BIGINT,
  p_category VARCHAR DEFAULT NULL,
  p_severity VARCHAR DEFAULT NULL,
  p_search   VARCHAR DEFAULT NULL,
  p_limit    INTEGER DEFAULT 100,
  p_offset   INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_rows JSONB;
  v_total BIGINT;
BEGIN
  -- BUG-008 fix: original accepted only contract.read.department + contract.edit.
  -- Extended to also accept contract.read.all (executive), insights.executive
  -- (exec dashboard role), insights.compliance_esg (CR-G compliance persona).
  -- These all legitimately have Impact Watch in their sidebar per ROLE_MODULES.
  IF NOT fn_current_user_has_permission('contract.read.department')
     AND NOT fn_current_user_has_permission('contract.read.all')
     AND NOT fn_current_user_has_permission('contract.edit')
     AND NOT fn_current_user_has_permission('insights.executive')
     AND NOT fn_current_user_has_permission('insights.compliance_esg') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total FROM impact_signal s
    WHERE s.is_active = TRUE
      AND (p_category IS NULL OR s.category = p_category)
      AND (p_severity IS NULL OR s.severity = p_severity)
      AND (p_search IS NULL OR s.title_en ILIKE '%' || p_search || '%' OR COALESCE(s.title_ar,'') ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                s.id,
    'extId',             s.ext_id,
    'category',          s.category,
    'source',            s.source,
    'severity',          s.severity,
    'titleEn',           s.title_en,
    'titleAr',           s.title_ar,
    'descriptionEn',     s.description_en,
    'descriptionAr',     s.description_ar,
    'affectedClauseCategories', s.affected_clause_categories,
    'publishedDate',     s.published_date,
    'effectiveDate',     s.effective_date,
    'complianceDeadline', s.compliance_deadline,
    'impactedContractCount', (SELECT COUNT(*) FROM impact_signal_contract isc WHERE isc.signal_id = s.id AND isc.is_active = TRUE),
    'createdAt',         s.created_at
  ) ORDER BY s.published_date DESC, s.id DESC), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM impact_signal
    WHERE is_active = TRUE
      AND (p_category IS NULL OR category = p_category)
      AND (p_severity IS NULL OR severity = p_severity)
      AND (p_search IS NULL OR title_en ILIKE '%' || p_search || '%' OR COALESCE(title_ar,'') ILIKE '%' || p_search || '%')
    ORDER BY published_date DESC, id DESC
    LIMIT p_limit OFFSET p_offset
  ) s;

  RETURN jsonb_build_object('data', v_rows, 'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset));
END;
$$;

COMMENT ON FUNCTION fn_impact_signal_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER) IS
  'R-LC7 — Impact Watch list. INVOKER. STABLE. Permission gate accepts contract.read.department OR contract.read.all OR contract.edit OR insights.executive OR insights.compliance_esg (BUG-008 fix mig 350). Returns paginated impact_signal rows + total count.';

REVOKE EXECUTE ON FUNCTION fn_impact_signal_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_impact_signal_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (350, 'BUG-008 fix corrects mig 349 body to match original column shape + return envelope', NOW())
ON CONFLICT (version) DO NOTHING;
