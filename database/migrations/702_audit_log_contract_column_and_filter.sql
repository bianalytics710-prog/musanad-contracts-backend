-- ============================================================================
-- Migration 702 — Admin audit log: Contract column + filter-by-contract
-- ============================================================================
-- The /admin/audit viewer captures every INSERT/UPDATE/DELETE but cannot be
-- scoped to a single contract: a contract's footprint is spread across many
-- table names (contract, contract_version, contract_obligation,
-- contract_attachment, contract_comment, contract_tag, approval_chain/step/
-- decision, signature_event/invitation, risk_case) and there is no record-id
-- filter.
--
-- This migration adds:
--   1. fn_audit_contract_resolve(table, record_id) → contract_id
--        DEFINER lookup mapping any contract-related audit row back to its
--        contract (NULL for non-contract tables). Used for the display column.
--   2. fn_audit_contract_record_keys(contract_id) → TABLE(t_name, r_id)
--        DEFINER set of every (table_name, record_id) pair belonging to one
--        contract. Used for the contract filter (membership test against the
--        existing idx_audit_log_table_record index — efficient).
--   3. fn_audit_log_list — new 8-arg signature adding p_contract_id, and
--        emitting contractId + contractNumber per row. The old 7-arg function
--        is dropped (the 8-arg DEFAULT NULL keeps 7-arg call-sites working and
--        avoids overload ambiguity).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Resolver — single audit row → contract_id (for the display column).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_audit_contract_resolve(p_table TEXT, p_record_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE p_table
    WHEN 'contract'             THEN (SELECT id          FROM contract             WHERE id = p_record_id)
    WHEN 'contract_version'     THEN (SELECT contract_id FROM contract_version     WHERE id = p_record_id)
    WHEN 'contract_obligation'  THEN (SELECT contract_id FROM contract_obligation  WHERE id = p_record_id)
    WHEN 'contract_attachment'  THEN (SELECT contract_id FROM contract_attachment  WHERE id = p_record_id)
    WHEN 'contract_comment'     THEN (SELECT contract_id FROM contract_comment     WHERE id = p_record_id)
    WHEN 'contract_tag'         THEN (SELECT contract_id FROM contract_tag         WHERE id = p_record_id)
    WHEN 'approval_chain'       THEN (SELECT contract_id FROM approval_chain       WHERE id = p_record_id)
    WHEN 'approval_step'        THEN (SELECT ach.contract_id
                                        FROM approval_step ast
                                        JOIN approval_chain ach ON ach.id = ast.approval_chain_id
                                       WHERE ast.id = p_record_id)
    WHEN 'approval_decision'    THEN (SELECT ach.contract_id
                                        FROM approval_decision ad
                                        JOIN approval_step ast ON ast.id = ad.approval_step_id
                                        JOIN approval_chain ach ON ach.id = ast.approval_chain_id
                                       WHERE ad.id = p_record_id)
    WHEN 'signature_event'      THEN (SELECT contract_id FROM signature_event      WHERE id = p_record_id)
    WHEN 'signature_invitation' THEN (SELECT contract_id FROM signature_invitation WHERE id = p_record_id)
    WHEN 'risk_case'            THEN (SELECT contract_id FROM risk_case            WHERE id = p_record_id)
    ELSE NULL
  END
$$;

REVOKE ALL ON FUNCTION fn_audit_contract_resolve(TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_audit_contract_resolve(TEXT, BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_audit_contract_resolve(TEXT, BIGINT) IS
  '702: maps a single audit_log (table_name, record_id) to its owning contract_id, or NULL for non-contract tables. DEFINER so it resolves regardless of caller RLS. Used by fn_audit_log_list for the Contract display column.';

-- ----------------------------------------------------------------------------
-- 2. Key-set — all (table_name, record_id) pairs owned by one contract
--    (for the contract filter). DEFINER so the filter is RLS-independent.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_audit_contract_record_keys(p_contract_id BIGINT)
RETURNS TABLE(t_name TEXT, r_id BIGINT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
            SELECT 'contract'::text,            id FROM contract             WHERE id = p_contract_id
  UNION ALL SELECT 'contract_version',          id FROM contract_version     WHERE contract_id = p_contract_id
  UNION ALL SELECT 'contract_obligation',       id FROM contract_obligation  WHERE contract_id = p_contract_id
  UNION ALL SELECT 'contract_attachment',       id FROM contract_attachment  WHERE contract_id = p_contract_id
  UNION ALL SELECT 'contract_comment',          id FROM contract_comment     WHERE contract_id = p_contract_id
  UNION ALL SELECT 'contract_tag',              id FROM contract_tag         WHERE contract_id = p_contract_id
  UNION ALL SELECT 'approval_chain',            id FROM approval_chain       WHERE contract_id = p_contract_id
  UNION ALL SELECT 'approval_step',         ast.id FROM approval_step ast
                                                   JOIN approval_chain ach ON ach.id = ast.approval_chain_id
                                                  WHERE ach.contract_id = p_contract_id
  UNION ALL SELECT 'approval_decision',      ad.id FROM approval_decision ad
                                                   JOIN approval_step ast ON ast.id = ad.approval_step_id
                                                   JOIN approval_chain ach ON ach.id = ast.approval_chain_id
                                                  WHERE ach.contract_id = p_contract_id
  UNION ALL SELECT 'signature_event',           id FROM signature_event      WHERE contract_id = p_contract_id
  UNION ALL SELECT 'signature_invitation',      id FROM signature_invitation WHERE contract_id = p_contract_id
  UNION ALL SELECT 'risk_case',                 id FROM risk_case            WHERE contract_id = p_contract_id
$$;

REVOKE ALL ON FUNCTION fn_audit_contract_record_keys(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_audit_contract_record_keys(BIGINT) TO neondb_owner;
COMMENT ON FUNCTION fn_audit_contract_record_keys(BIGINT) IS
  '702: every (table_name, record_id) pair belonging to a contract, across all contract-related tables. DEFINER. Used by fn_audit_log_list to filter audit rows to one contract.';

-- ----------------------------------------------------------------------------
-- 3. fn_audit_log_list — drop 7-arg, recreate 8-arg with p_contract_id +
--    contractId / contractNumber output.
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ);

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
COMMENT ON FUNCTION fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT) IS
  '702: paginated audit_log list. Adds p_contract_id (filter to one contract across all contract-related tables) + contractId/contractNumber per row. Permission gate: audit.read.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (702, 'audit_log_contract_column_and_filter', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_audit_log_list(INTEGER, INTEGER, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT);
-- DROP FUNCTION IF EXISTS fn_audit_contract_record_keys(BIGINT);
-- DROP FUNCTION IF EXISTS fn_audit_contract_resolve(TEXT, BIGINT);
-- -- (Re-create the 7-arg fn_audit_log_list from migration 098 if needed.)
-- DELETE FROM schema_migrations WHERE version = 702;
-- COMMIT;
-- ROLLBACK END
