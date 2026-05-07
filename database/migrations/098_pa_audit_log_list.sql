-- ============================================================================
-- 098_pa_audit_log_list.sql
-- ============================================================================
-- Module:    R-PA5 (Platform Admin parity — /admin/audit polish)
-- Owner:     Lovable Modernization Agent — Platform Admin parity
-- Depends:   001 (audit_log table), 094 (platform_admin grants), permission
--            'audit.read' seeded in M0 003.
-- ----------------------------------------------------------------------------
-- Adds fn_audit_log_list — paginated viewer for the audit_log table with
-- 5 filters wired to the FE:
--   * p_table_name TEXT     — exact table name (nullable).
--   * p_action     TEXT     — INSERT / UPDATE / DELETE (nullable).
--   * p_changed_by BIGINT   — actor user id (nullable).
--   * p_date_from  TIMESTAMPTZ  — inclusive lower bound (nullable).
--   * p_date_to    TIMESTAMPTZ  — exclusive upper bound (nullable).
-- Plus pagination via p_page (1-indexed) + p_limit (1..200).
--
-- Returns:
--   {
--     "data": [
--       { "id", "tableName", "recordId", "action", "changedBy",
--         "changedByName", "changedAt", "oldValues", "newValues" }
--     ],
--     "pagination": { "page", "limit", "total", "totalPages" }
--   }
--
-- Permission gate: settings-style (audit.read).
--
-- Stage 2 standards: REVOKE PUBLIC + GRANT neondb_owner.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION fn_audit_log_list(
  p_page       INTEGER DEFAULT 1,
  p_limit      INTEGER DEFAULT 50,
  p_table_name TEXT DEFAULT NULL,
  p_action     TEXT DEFAULT NULL,
  p_changed_by BIGINT DEFAULT NULL,
  p_date_from  TIMESTAMPTZ DEFAULT NULL,
  p_date_to    TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id   BIGINT;
  v_page      INTEGER := COALESCE(p_page, 1);
  v_limit     INTEGER := COALESCE(p_limit, 50);
  v_offset    INTEGER;
  v_total     BIGINT;
  v_data      JSONB;
BEGIN
  IF v_page < 1 THEN
    RAISE EXCEPTION 'fn_audit_log_list: page must be >= 1' USING ERRCODE = '22023';
  END IF;
  IF v_limit < 1 OR v_limit > 200 THEN
    RAISE EXCEPTION 'fn_audit_log_list: limit must be 1..200' USING ERRCODE = '22023';
  END IF;
  IF p_action IS NOT NULL AND p_action NOT IN ('INSERT', 'UPDATE', 'DELETE') THEN
    RAISE EXCEPTION 'fn_audit_log_list: action must be INSERT, UPDATE or DELETE' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_audit_log_list: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('audit.read') THEN
    RAISE EXCEPTION 'fn_audit_log_list: forbidden — audit.read required' USING ERRCODE = '42501';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  SELECT COUNT(*) INTO v_total
  FROM audit_log al
  WHERE (p_table_name IS NULL OR al.table_name = p_table_name)
    AND (p_action     IS NULL OR al.action = p_action)
    AND (p_changed_by IS NULL OR al.changed_by = p_changed_by)
    AND (p_date_from  IS NULL OR al.changed_at >= p_date_from)
    AND (p_date_to    IS NULL OR al.changed_at <  p_date_to);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',            al.id,
      'tableName',     al.table_name,
      'recordId',      al.record_id,
      'action',        al.action,
      'changedBy',     al.changed_by,
      'changedByName', COALESCE(u.first_name || ' ' || u.last_name, NULL),
      'changedByEmail', u.email,
      'changedAt',     al.changed_at,
      'oldValues',     al.old_values,
      'newValues',     al.new_values
    ) ORDER BY al.changed_at DESC, al.id DESC
  ), '[]'::jsonb)
    INTO v_data
  FROM (
    SELECT al.*
    FROM audit_log al
    WHERE (p_table_name IS NULL OR al.table_name = p_table_name)
      AND (p_action     IS NULL OR al.action = p_action)
      AND (p_changed_by IS NULL OR al.changed_by = p_changed_by)
      AND (p_date_from  IS NULL OR al.changed_at >= p_date_from)
      AND (p_date_to    IS NULL OR al.changed_at <  p_date_to)
    ORDER BY al.changed_at DESC, al.id DESC
    LIMIT v_limit OFFSET v_offset
  ) al
  LEFT JOIN "user" u ON u.id = al.changed_by;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'page',       v_page,
      'limit',      v_limit,
      'total',      v_total,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_limit)::INTEGER END
    )
  );
END;
$fn$;

REVOKE ALL ON FUNCTION fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ) TO neondb_owner;
COMMENT ON FUNCTION fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ) IS
  'R-PA5: paginated audit_log list with 5 filters. Permission gate: audit.read. CSV export uses the same fn at limit=200, page-iterated by the controller.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (98, 'pa_audit_log_list', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- DROP FUNCTION IF EXISTS fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ);
-- DELETE FROM schema_migrations WHERE version = 98;
-- ROLLBACK END
