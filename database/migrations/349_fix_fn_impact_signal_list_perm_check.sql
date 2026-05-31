-- Migration: 349_fix_fn_impact_signal_list_perm_check.sql
-- Unit: QA Phase 3 autonomous run 2026-05-31 — BUG-008 fix
-- Description: fn_impact_signal_list permission check accepted only
--              contract.read.department OR contract.edit. Executive role has
--              contract.read.all (broader scope) but lacked the narrower codes,
--              causing 4 retried 403s per /app/regulations page load. Extend the
--              perm check to also accept contract.read.all and the persona-level
--              insights.* read perms that govern "who can see Impact Watch".
-- Rollback: See ROLLBACK section below

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
  -- BUG-008 fix: accept contract.read.all (executive) + insights.executive +
  -- insights.compliance_esg (CR-G personas) in addition to the original two
  -- codes. All these roles legitimately see Impact Watch per ROLE_MODULES.
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
    'sourceUrl',         s.source_url,
    'publishedAt',       to_char(s.published_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'firstSeenAt',       to_char(s.first_seen_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'isActive',          s.is_active,
    'reviewedAt',        to_char(s.reviewed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'reviewedBy',        s.reviewed_by,
    'createdAt',         to_char(s.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'updatedAt',         to_char(s.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'createdBy',         s.created_by,
    'updatedBy',         s.updated_by,
    'matchedContractCount',
      (SELECT COUNT(*) FROM impact_signal_contract isc WHERE isc.signal_id = s.id)
  ) ORDER BY s.published_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT s.*
      FROM impact_signal s
     WHERE s.is_active = TRUE
       AND (p_category IS NULL OR s.category = p_category)
       AND (p_severity IS NULL OR s.severity = p_severity)
       AND (p_search IS NULL OR s.title_en ILIKE '%' || p_search || '%' OR COALESCE(s.title_ar,'') ILIKE '%' || p_search || '%')
     ORDER BY s.published_at DESC
     LIMIT p_limit OFFSET p_offset
  ) s;

  RETURN jsonb_build_object(
    'data',  v_rows,
    'total', v_total,
    'limit', p_limit,
    'offset', p_offset
  );
END;
$$;

COMMENT ON FUNCTION fn_impact_signal_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER) IS
  'R-LC7 — Impact Watch list. INVOKER. STABLE. Permission gate accepts contract.read.department OR contract.read.all OR contract.edit OR insights.executive OR insights.compliance_esg (BUG-008 fix 349). Returns paginated impact_signal rows + total count.';

REVOKE EXECUTE ON FUNCTION fn_impact_signal_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_impact_signal_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (349, 'BUG-008 fix fn_impact_signal_list perm check accept contract.read.all + insights.*', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- CREATE OR REPLACE FUNCTION fn_impact_signal_list(...) -- restore original 2-perm check
-- DELETE FROM schema_migrations WHERE version = 349;
