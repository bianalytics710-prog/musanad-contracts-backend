-- ============================================================
-- Migration 280: CR-FIX1 Issue 5 — audit chain
--   Part 1: fn_audit_log_record_v2 — add pg_advisory_xact_lock
--     as the first statement to serialize concurrent chain writers.
--   Part 2: Re-baseline the existing chain by walking audit_log
--     in id ASC order, recomputing prev_hash / this_hash using
--     the same canonicalization the verify fn uses.
--     Mirrors migration 128 backfill logic exactly.
-- ============================================================

-- ============================================================
-- Part 1: Replace fn_audit_log_record_v2 with advisory lock
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_audit_log_record_v2(p_table_name text, p_record_id bigint, p_action text, p_old_values jsonb, p_new_values jsonb, p_changed_by bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_actor       BIGINT;
  v_prev_id     BIGINT;
  v_prev_hash   TEXT;
  v_this_hash   TEXT;
  v_id          BIGINT;
  v_now         TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_canonical   TEXT;
BEGIN
  -- CR-FIX1 (280): serialize concurrent audit chain writers so each
  -- computes prev_hash from the true latest row and no two concurrent
  -- inserts can both read the same "prev" and fork the chain.
  -- Key 4815162342 is a fixed constant dedicated to the audit chain lock.
  PERFORM pg_advisory_xact_lock(4815162342);

  IF p_action NOT IN ('INSERT','UPDATE','DELETE') THEN
    RAISE EXCEPTION 'fn_audit_log_record_v2: invalid_action_value' USING ERRCODE = '22023';
  END IF;

  v_actor := COALESCE(
    p_changed_by,
    NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
  );
  IF v_actor = 0 THEN v_actor := NULL; END IF;  -- S2-20 system actor sentinel

  -- OPEN-DECISION-D: pessimistic concurrency lock on prev row.
  -- Throughput ceiling acceptable for demo+pilot load (largest single emit ~10 rows; A18).
  SELECT id, this_hash
    INTO v_prev_id, v_prev_hash
    FROM audit_log
   ORDER BY id DESC
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    v_prev_hash := repeat('0', 64);   -- genesis row
  ELSIF v_prev_hash IS NULL THEN
    -- Defensive: post-backfill no row should have NULL hash
    RAISE EXCEPTION 'fn_audit_log_record_v2: audit_chain_integrity_violation at prev id %', v_prev_id
      USING ERRCODE = 'P0001';
  END IF;

  -- Canonical payload built deterministically from input + computed timestamp
  v_canonical := fn_audit_log_canonicalize(jsonb_build_object(
    'action',     p_action,
    'changedAt',  to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'changedBy',  v_actor,
    'newValues',  COALESCE(p_new_values, 'null'::jsonb),
    'oldValues',  COALESCE(p_old_values, 'null'::jsonb),
    'recordId',   p_record_id,
    'tableName',  p_table_name
  ));
  v_this_hash := encode(digest(v_prev_hash || v_canonical, 'sha256'), 'hex');

  INSERT INTO audit_log (
    table_name, record_id, action, old_values, new_values,
    changed_by, changed_at, prev_hash, this_hash
  ) VALUES (
    p_table_name, p_record_id, p_action, p_old_values, p_new_values,
    v_actor, v_now, v_prev_hash, v_this_hash
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id',       v_id,
    'prevHash', v_prev_hash,
    'thisHash', v_this_hash
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_audit_log_record_v2: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

-- S2-21 trio
COMMENT ON FUNCTION public.fn_audit_log_record_v2(text, bigint, text, jsonb, jsonb, bigint) IS
  'CR-FIX1 (280): pg_advisory_xact_lock(4815162342) added as first statement to serialize concurrent chain writers and prevent hash-chain forks. CR-C single source of truth for audit_log writes. Computes hash chain with FOR UPDATE on prev row. Genesis prev_hash = ''0''x64. SECURITY DEFINER bypasses audit_log RLS deny-direct-INSERT. Canonical payload via fn_audit_log_canonicalize. v_actor=0 → NULL coercion (S2-20).';
REVOKE EXECUTE ON FUNCTION public.fn_audit_log_record_v2(text, bigint, text, jsonb, jsonb, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_audit_log_record_v2(text, bigint, text, jsonb, jsonb, bigint) TO neondb_owner;

-- ============================================================
-- Part 2: Re-baseline the existing audit chain.
-- Disables the no-update guard trigger, walks all rows in id ASC,
-- recomputes prev_hash / this_hash using fn_audit_log_canonicalize,
-- updates each row, then re-enables the trigger.
-- Mirrors migration 128 backfill logic exactly.
-- ============================================================

ALTER TABLE audit_log DISABLE TRIGGER audit_log_no_update;

DO $$
DECLARE
  r          RECORD;
  v_prev     TEXT := repeat('0', 64);
  v_canonical TEXT;
  v_this     TEXT;
BEGIN
  FOR r IN
    SELECT id, table_name, record_id, action, old_values, new_values, changed_by, changed_at
    FROM audit_log
    ORDER BY id ASC
  LOOP
    v_canonical := fn_audit_log_canonicalize(jsonb_build_object(
      'action',     r.action,
      'changedAt',  to_char(r.changed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'changedBy',  r.changed_by,
      'newValues',  COALESCE(r.new_values, 'null'::jsonb),
      'oldValues',  COALESCE(r.old_values, 'null'::jsonb),
      'recordId',   r.record_id,
      'tableName',  r.table_name
    ));
    v_this := encode(digest(v_prev || v_canonical, 'sha256'), 'hex');

    UPDATE audit_log
    SET prev_hash = v_prev,
        this_hash = v_this
    WHERE id = r.id;

    v_prev := v_this;
  END LOOP;
END;
$$;

ALTER TABLE audit_log ENABLE TRIGGER audit_log_no_update;

-- schema_migrations
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (280, 'crfix1_audit_chain_concurrency_and_rebaseline', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if needed):
-- To undo Part 1: restore fn_audit_log_record_v2 without
--   pg_advisory_xact_lock. Chain hashes remain valid post-backfill.
-- To undo Part 2: re-run the backfill from migration 128.
-- DELETE FROM schema_migrations WHERE version = 280;
-- ============================================================
