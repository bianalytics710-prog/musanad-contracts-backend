-- ============================================================================
-- Migration 704 — Admin audit log: per-row change details ("what changed")
-- ============================================================================
-- The /admin/audit viewer only showed table + record id + INSERT/UPDATE/DELETE,
-- which doesn't tell a reader WHAT happened. audit_log already stores full
-- old_values / new_values JSONB snapshots, so we derive a clean field-level
-- diff and expose it per row.
--
-- Helpers:
--   fn_audit_fmt(value)              — null-safe display string, truncated to
--                                      160 chars (long bodies / AI summaries).
--   fn_audit_changes(old,new,action) — [{field, from, to}] array:
--       * UPDATE/DELETE → only genuinely-changed fields, excluding the
--         created_at/updated_at/created_by/updated_by audit plumbing (already
--         conveyed by the When/Actor columns) and tsvector/search columns.
--       * INSERT → a curated identity set (contract_number, title, status,
--         decision, …) so it reads "Created …" instead of a 41-field dump.
--
-- fn_audit_log_list (8-arg, same signature) now emits `changes` per row. The
-- FE renders a one-line summary + an expandable full diff; CSV export adds a
-- readable changes column.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Value formatter — null-safe, unquoted strings, truncated.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_audit_fmt(p_val jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_val IS NULL OR jsonb_typeof(p_val) = 'null' THEN NULL
    WHEN jsonb_typeof(p_val) = 'string' THEN left(p_val #>> '{}', 160)
    ELSE left(p_val::text, 160)
  END
$$;

REVOKE ALL ON FUNCTION fn_audit_fmt(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_audit_fmt(jsonb) TO neondb_owner;

-- ----------------------------------------------------------------------------
-- 2. Field-level diff between old/new snapshots.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_audit_changes(p_old jsonb, p_new jsonb, p_action text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  WITH ks AS (
    SELECT DISTINCT k
    FROM (
      SELECT jsonb_object_keys(COALESCE(p_new, '{}'::jsonb)) AS k
      UNION
      SELECT jsonb_object_keys(COALESCE(p_old, '{}'::jsonb))
    ) s
    WHERE k NOT IN ('created_at', 'updated_at', 'created_by', 'updated_by')
      AND k NOT LIKE '%tsv%'
      AND k NOT LIKE '%search_vector%'
  ),
  sel AS (
    SELECT k FROM ks
    WHERE CASE
      WHEN p_action = 'INSERT' THEN
        k IN ('contract_number','title_en','title','name','code','status','decision',
              'event_type','activity_type','kind','risk_type','severity','priority',
              'value_aed','amount','version_number','decision_note','tag','obligation_type')
        AND (p_new -> k) IS NOT NULL
        AND jsonb_typeof(p_new -> k) <> 'null'
      ELSE
        (p_old -> k) IS DISTINCT FROM (p_new -> k)
    END
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'field', k,
        'from',  fn_audit_fmt(p_old -> k),
        'to',    fn_audit_fmt(p_new -> k)
      ) ORDER BY k
    ), '[]'::jsonb)
  FROM sel
$$;

REVOKE ALL ON FUNCTION fn_audit_changes(jsonb, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_audit_changes(jsonb, jsonb, text) TO neondb_owner;

-- ----------------------------------------------------------------------------
-- 3. fn_audit_log_list — same 8-arg signature, now emits `changes` per row.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_audit_log_list(
  p_page        INTEGER DEFAULT 1,
  p_limit       INTEGER DEFAULT 50,
  p_table_name  TEXT DEFAULT NULL,
  p_action      TEXT DEFAULT NULL,
  p_changed_by  BIGINT DEFAULT NULL,
  p_date_from   TIMESTAMPTZ DEFAULT NULL,
  p_date_to     TIMESTAMPTZ DEFAULT NULL,
  p_contract_id BIGINT DEFAULT NULL
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
    AND (p_date_to    IS NULL OR al.changed_at <  p_date_to)
    AND (p_contract_id IS NULL OR (al.table_name, al.record_id) IN (
          SELECT t_name, r_id FROM fn_audit_contract_record_keys(p_contract_id)));

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',             al.id,
      'tableName',      al.table_name,
      'recordId',       al.record_id,
      'action',         al.action,
      'changedBy',      al.changed_by,
      'changedByName',  COALESCE(u.first_name || ' ' || u.last_name, NULL),
      'changedByEmail', u.email,
      'changedAt',      al.changed_at,
      'contractId',     cl.contract_id,
      'contractNumber', cl.contract_number,
      'changes',        fn_audit_changes(al.old_values, al.new_values, al.action),
      'oldValues',      al.old_values,
      'newValues',      al.new_values
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
      AND (p_contract_id IS NULL OR (al.table_name, al.record_id) IN (
            SELECT t_name, r_id FROM fn_audit_contract_record_keys(p_contract_id)))
    ORDER BY al.changed_at DESC, al.id DESC
    LIMIT v_limit OFFSET v_offset
  ) al
  LEFT JOIN "user" u ON u.id = al.changed_by
  LEFT JOIN LATERAL (
    SELECT rc.cid AS contract_id, c.contract_number
    FROM (SELECT fn_audit_contract_resolve(al.table_name, al.record_id) AS cid) rc
    LEFT JOIN contract c ON c.id = rc.cid
  ) cl ON TRUE;

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

REVOKE ALL ON FUNCTION fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (704, 'audit_log_change_details', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- BEGIN;
-- (re-create fn_audit_log_list from migration 702 without the `changes` key)
-- DROP FUNCTION IF EXISTS fn_audit_changes(jsonb, jsonb, text);
-- DROP FUNCTION IF EXISTS fn_audit_fmt(jsonb);
-- DELETE FROM schema_migrations WHERE version = 704;
-- COMMIT;
-- ROLLBACK END
