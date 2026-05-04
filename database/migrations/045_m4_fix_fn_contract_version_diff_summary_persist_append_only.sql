-- ============================================================================
-- 045_m4_fix_fn_contract_version_diff_summary_persist_append_only.sql
-- ============================================================================
-- Module:    M4 (AI Features) — DEFECT-1 production-blocker patch
-- Owner:     Agent 6 — DB Implementation
-- Depends:   043 (defines fn_contract_version_diff_summary_persist).
-- ----------------------------------------------------------------------------
-- DEFECT-1: Migration 043 body of fn_contract_version_diff_summary_persist
-- contains an UPDATE that sets `updated_at` and `updated_by` on contract_version.
-- Per migration 003 (M1a), contract_version is APPEND-ONLY and has NEITHER
-- column. The function compiled at migration time because plpgsql lazy-compiles
-- bodies; first invocation in production throws SQLSTATE 42703
-- ("column \"updated_at\" does not exist"), making S6
-- (POST /api/v1/ai/version-diff-summary) a guaranteed 500.
--
-- FIX (Option A — match the table schema; preferred per
-- feedback_db_impl_report_dont_fix.md semantics):
--   - Drop `updated_at = CURRENT_TIMESTAMP` from SET list.
--   - Drop `updated_by = p_actor_user_id` from SET list.
--   - Drop `RETURNING updated_at INTO v_new_at`.
--   - Materialise v_new_at locally with CURRENT_TIMESTAMP at function entry
--     (the JSONB return shape `updatedAt` is preserved for callers).
--   - All other body lines byte-for-byte identical to 043's definition
--     (S2-19 fn-to-fn signature preservation:
--      fn_contract_activity_create 6-arg call unchanged).
--
-- Function signature (BIGINT, BIGINT, TEXT) RETURNS JSONB unchanged — no
-- DROP/CREATE needed; CREATE OR REPLACE is sufficient.
--
-- S2 mandatory checks honoured:
--   S2-16 DTO-to-fn-body: parameters {p_contract_version_id, p_actor_user_id,
--                          p_diff_summary} unchanged.
--   S2-17 concurrency-primitive preservation: SELECT FOR UPDATE retained.
--   S2-18 NULL-safe equality: not applicable (PK lookup, no NULLable join key).
--   S2-19 fn-to-fn signature verification: fn_contract_activity_create 6-arg
--                          (BIGINT, TEXT, BIGINT, TEXT, TEXT, JSONB) call
--                          preserved byte-for-byte from 043.
--   S2-20 system-event actor sentinel: not applicable (this fn requires
--                          an authenticated actor; not a system/cron path).
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. CREATE OR REPLACE fn_contract_version_diff_summary_persist (fixed body)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_contract_version_diff_summary_persist(
  p_contract_version_id BIGINT,
  p_actor_user_id       BIGINT,
  p_diff_summary        TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row     RECORD;
  v_new_at  TIMESTAMPTZ := CURRENT_TIMESTAMP;   -- materialised locally; contract_version has no updated_at column (M1a 003 — append-only)
  v_allowed BOOLEAN;
BEGIN
  -- 1. Permission gate (defence-in-depth; controller already validated).
  v_allowed := fn_current_user_has_permission('contract.read.all')
            OR fn_current_user_has_permission('contract.read.department')
            OR fn_current_user_has_permission('contract.read.own')
            OR fn_current_user_has_permission('contract.edit');
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'fn_contract_version_diff_summary_persist: %', 'forbidden'
      USING ERRCODE = '42501';
  END IF;

  -- 2. SELECT FOR UPDATE the version row (S2-17 lock).
  SELECT cv.id, cv.contract_id
    INTO v_row
    FROM contract_version cv
    WHERE cv.id = p_contract_version_id AND cv.is_active = TRUE
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_version_diff_summary_persist: %', 'contractVersionId:Contract version not found'
      USING ERRCODE = 'P0001';
  END IF;

  -- 3. UPDATE diff_summary (M1a-reserved column on otherwise-append-only table).
  --    DEFINER carve-out documented in DN-3.
  --    DEFECT-1 FIX: contract_version has NO updated_at / updated_by columns
  --    (M1a 003 — table is append-only). Set diff_summary only; v_new_at
  --    is materialised at function entry (CURRENT_TIMESTAMP) for the JSONB
  --    return shape, preserving the API contract.
  UPDATE contract_version
    SET diff_summary = p_diff_summary
    WHERE id = p_contract_version_id;

  -- 4. Emit contract_activity (parent contract scope). S2-19 6-arg signature.
  PERFORM fn_contract_activity_create(
    v_row.contract_id,
    'ai_diff_summary_generated',
    p_actor_user_id,
    NULL,
    NULL,
    jsonb_build_object('contractVersionId', p_contract_version_id)
  );

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'contractVersionId', p_contract_version_id,
      'diffSummary',       p_diff_summary,
      'updatedAt',         v_new_at
    )
  );
END;
$$;

-- Re-grant per existing policy (idempotent; preserves 043 GRANT matrix).
REVOKE ALL ON FUNCTION fn_contract_version_diff_summary_persist(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_version_diff_summary_persist(BIGINT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION fn_contract_version_diff_summary_persist(BIGINT, BIGINT, TEXT) IS
  'M4 (043; patched 045) — DEFINER carve-out. contract_version is append-only at table level; this fn is the ONLY allowed UPDATE path on diff_summary column (M1a-reserved). Future modules MUST NOT add additional UPDATE-via-DEFINER carve-outs without explicit invariant review (DN-3). 045 fix: removed nonexistent updated_at/updated_by column references (DEFECT-1).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (45, 'm4_fix_fn_contract_version_diff_summary_persist_append_only', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- Restores migration 043's body verbatim. The 043 body is broken (references
-- updated_at/updated_by columns that do not exist on contract_version), so
-- this rollback is strictly to undo 045 if 045 itself causes a regression
-- worse than the original DEFECT-1. After rollback, fn invocation will again
-- raise SQLSTATE 42703.
-- ============================================================================
BEGIN;
CREATE OR REPLACE FUNCTION fn_contract_version_diff_summary_persist(
  p_contract_version_id BIGINT,
  p_actor_user_id       BIGINT,
  p_diff_summary        TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row     RECORD;
  v_new_at  TIMESTAMPTZ;
  v_allowed BOOLEAN;
BEGIN
  -- 1. Permission gate (defence-in-depth; controller already validated).
  v_allowed := fn_current_user_has_permission('contract.read.all')
            OR fn_current_user_has_permission('contract.read.department')
            OR fn_current_user_has_permission('contract.read.own')
            OR fn_current_user_has_permission('contract.edit');
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'fn_contract_version_diff_summary_persist: %', 'forbidden'
      USING ERRCODE = '42501';
  END IF;

  -- 2. SELECT FOR UPDATE the version row (S2-17 lock).
  SELECT cv.id, cv.contract_id
    INTO v_row
    FROM contract_version cv
    WHERE cv.id = p_contract_version_id AND cv.is_active = TRUE
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_contract_version_diff_summary_persist: %', 'contractVersionId:Contract version not found'
      USING ERRCODE = 'P0001';
  END IF;

  -- 3. UPDATE diff_summary (M1a-reserved column on otherwise-append-only table).
  --    DEFINER carve-out documented in DN-3.
  UPDATE contract_version
    SET diff_summary = p_diff_summary,
        updated_at   = CURRENT_TIMESTAMP,
        updated_by   = p_actor_user_id
    WHERE id = p_contract_version_id
    RETURNING updated_at INTO v_new_at;

  -- 4. Emit contract_activity (parent contract scope).
  PERFORM fn_contract_activity_create(
    v_row.contract_id,
    'ai_diff_summary_generated',
    p_actor_user_id,
    NULL,
    NULL,
    jsonb_build_object('contractVersionId', p_contract_version_id)
  );

  RETURN jsonb_build_object(
    'data', jsonb_build_object(
      'contractVersionId', p_contract_version_id,
      'diffSummary',       p_diff_summary,
      'updatedAt',         v_new_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_contract_version_diff_summary_persist(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_contract_version_diff_summary_persist(BIGINT, BIGINT, TEXT) TO neondb_owner;

DELETE FROM schema_migrations WHERE version = 45;
COMMIT;
-- ROLLBACK END
