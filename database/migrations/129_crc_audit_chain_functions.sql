-- ============================================================
-- Migration 129 — CRC audit_chain_functions
-- ============================================================
-- Module:      M10 — CR-C
-- Description: Three new fn_'s that read or operate on the hash-chained audit_log:
--              - fn_audit_chain_verify(p_start_seq, p_end_seq) — INVOKER STABLE.
--              - fn_data_classification_summary()              — INVOKER STABLE
--                (per-table per-classification counts via dynamic format() loop;
--                 S2-24 safe — no nested aggregates).
--              - fn_demo_data_purge(p_dry_run BOOLEAN)         — DEFINER VOLATILE
--                (Super Admin role check inside body, NOT just demo.purge perm;
--                 children-first DELETE across 38 ordered tables; emits sentinel
--                 __demo_purge__ audit row via fn_audit_log_record_v2).
-- ============================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────
-- 1. fn_audit_chain_verify(p_start_seq BIGINT, p_end_seq BIGINT)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_audit_chain_verify(
  p_start_seq BIGINT DEFAULT NULL,
  p_end_seq   BIGINT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_uid           BIGINT;
  v_start         BIGINT;
  v_end           BIGINT;
  v_min_id        BIGINT;
  v_t0            TIMESTAMPTZ;
  v_rows          INTEGER := 0;
  v_expected_prev TEXT;
  v_canonical     TEXT;
  v_recomputed    TEXT;
  r               RECORD;
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_audit_chain_verify: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT fn_current_user_has_permission('audit.verify') THEN
    RAISE EXCEPTION 'fn_audit_chain_verify: forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_start_seq IS NOT NULL AND p_end_seq IS NOT NULL AND p_start_seq > p_end_seq THEN
    RAISE EXCEPTION 'fn_audit_chain_verify: invalid_range (start > end)' USING ERRCODE = '22023';
  END IF;

  v_t0 := clock_timestamp();
  SELECT MIN(id) INTO v_min_id FROM audit_log;
  IF v_min_id IS NULL THEN
    -- Empty audit_log → trivially verified
    RETURN jsonb_build_object(
      'verified',    TRUE,
      'brokenAtSeq', NULL,
      'error',       NULL,
      'rowsWalked',  0,
      'elapsedMs',   0
    );
  END IF;

  v_start := COALESCE(p_start_seq, v_min_id);
  v_end   := COALESCE(p_end_seq,   (SELECT MAX(id) FROM audit_log));

  -- Determine expected prev_hash for the first row in the range
  IF v_start = v_min_id THEN
    v_expected_prev := repeat('0', 64);   -- genesis
  ELSE
    SELECT this_hash INTO v_expected_prev
      FROM audit_log
     WHERE id < v_start
     ORDER BY id DESC
     LIMIT 1;
    IF v_expected_prev IS NULL THEN
      RETURN jsonb_build_object(
        'verified',    FALSE,
        'brokenAtSeq', v_start,
        'error',       'prev_hash_chain_break',
        'rowsWalked',  0,
        'elapsedMs',   GREATEST(0, EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::INTEGER
      );
    END IF;
  END IF;

  FOR r IN
    SELECT id, table_name, record_id, action, old_values, new_values,
           changed_by, changed_at, prev_hash, this_hash
      FROM audit_log
     WHERE id BETWEEN v_start AND v_end
     ORDER BY id ASC
  LOOP
    v_rows := v_rows + 1;

    IF r.prev_hash IS DISTINCT FROM v_expected_prev THEN
      RETURN jsonb_build_object(
        'verified',    FALSE,
        'brokenAtSeq', r.id,
        'error',       'prev_hash_chain_break',
        'rowsWalked',  v_rows,
        'elapsedMs',   GREATEST(0, EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::INTEGER
      );
    END IF;

    v_canonical := fn_audit_log_canonicalize(jsonb_build_object(
      'action',     r.action,
      'changedAt',  to_char(r.changed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'changedBy',  r.changed_by,
      'newValues',  COALESCE(r.new_values, 'null'::jsonb),
      'oldValues',  COALESCE(r.old_values, 'null'::jsonb),
      'recordId',   r.record_id,
      'tableName',  r.table_name
    ));
    v_recomputed := encode(digest(r.prev_hash || v_canonical, 'sha256'), 'hex');

    IF v_recomputed <> r.this_hash THEN
      RETURN jsonb_build_object(
        'verified',    FALSE,
        'brokenAtSeq', r.id,
        'error',       'hash_mismatch',
        'rowsWalked',  v_rows,
        'elapsedMs',   GREATEST(0, EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::INTEGER
      );
    END IF;

    v_expected_prev := r.this_hash;
  END LOOP;

  RETURN jsonb_build_object(
    'verified',    TRUE,
    'brokenAtSeq', NULL,
    'error',       NULL,
    'rowsWalked',  v_rows,
    'elapsedMs',   GREATEST(0, EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::INTEGER
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_audit_chain_verify: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_audit_chain_verify(BIGINT, BIGINT) IS
  'CR-C audit chain integrity verifier. INVOKER STABLE. Walks audit_log id ASC; recomputes each this_hash from prev_hash + canonical_row_payload. Returns first mismatch (broken_at_seq + error in {hash_mismatch, prev_hash_chain_break}) or success. NFR < 30s @ 100k rows.';
REVOKE EXECUTE ON FUNCTION fn_audit_chain_verify(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_chain_verify(BIGINT, BIGINT) TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 2. fn_data_classification_summary()
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_data_classification_summary()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_uid       BIGINT;
  v_tables    TEXT[] := ARRAY[
    'contract','contract_attachment','contract_clause','contract_obligation',
    'contract_template','contract_comment','contract_watch','contract_activity',
    'contract_tag','contract_version','party','payment_schedule',
    'signature_party','signature_party_side','signature_event','signature_invitation',
    'signature_method','signer_qa_session',
    'approval_chain','approval_step','approval_decision','approval_matrix',
    'regulation','regulator','regulatory_update','regulatory_impact','impact_category',
    'impact_signal_contract',
    'ai_insight','ai_prompt','ai_request_log',
    'import_batch',
    'osint_source','osint_signal','source_credential','source_health',
    'internal_signal_kind','party_relationship',
    'notification_template'
  ];
  v_t           TEXT;
  v_per_table   JSONB := '[]'::jsonb;
  v_d           BIGINT;
  v_p           BIGINT;
  v_pr          BIGINT;
  v_t_total     BIGINT;
  v_total_d     BIGINT := 0;
  v_total_p     BIGINT := 0;
  v_total_pr    BIGINT := 0;
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_data_classification_summary: unauthorized' USING ERRCODE = '42501';
  END IF;

  IF NOT (
    fn_current_user_has_permission('audit.verify')
    OR fn_current_user_has_permission('demo.purge')
    OR EXISTS (
      SELECT 1 FROM "user" u
        JOIN role r ON r.id = u.role_id
       WHERE u.id = v_uid
         AND r.name = 'Super Admin'
         AND u.is_active = TRUE
         AND r.is_active = TRUE
    )
  ) THEN
    RAISE EXCEPTION 'fn_data_classification_summary: forbidden' USING ERRCODE = '42501';
  END IF;

  FOREACH v_t IN ARRAY v_tables LOOP
    EXECUTE format(
      'SELECT COUNT(*) FILTER (WHERE data_classification = ''demo''),
              COUNT(*) FILTER (WHERE data_classification = ''pilot''),
              COUNT(*) FILTER (WHERE data_classification = ''production''),
              COUNT(*)
         FROM %I',
      v_t
    )
    INTO v_d, v_p, v_pr, v_t_total;

    v_per_table := v_per_table || jsonb_build_array(jsonb_build_object(
      'tableName',  v_t,
      'demo',       v_d,
      'pilot',      v_p,
      'production', v_pr,
      'total',      v_t_total
    ));
    v_total_d  := v_total_d  + COALESCE(v_d,  0);
    v_total_p  := v_total_p  + COALESCE(v_p,  0);
    v_total_pr := v_total_pr + COALESCE(v_pr, 0);
  END LOOP;

  RETURN jsonb_build_object(
    'summary', v_per_table,
    'totals',  jsonb_build_object(
      'demo',       v_total_d,
      'pilot',      v_total_p,
      'production', v_total_pr,
      'total',      v_total_d + v_total_p + v_total_pr
    )
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_data_classification_summary: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_data_classification_summary() IS
  'CR-C per-table per-classification record counts. INVOKER STABLE. Permission gate: audit.verify OR demo.purge OR Super Admin role. Iterates 39 content tables via dynamic format() loop with FILTER aggregates — avoids S2-24 nested-aggregate trap.';
REVOKE EXECUTE ON FUNCTION fn_data_classification_summary() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_data_classification_summary() TO neondb_owner;

-- ─────────────────────────────────────────────────────────────
-- 3. fn_demo_data_purge(p_dry_run BOOLEAN)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_demo_data_purge(p_dry_run BOOLEAN DEFAULT FALSE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid             BIGINT;
  v_actor           BIGINT;
  v_now             TIMESTAMPTZ := CURRENT_TIMESTAMP;
  -- Children-first DELETE order per A17 / db-design.md §2.3 (38 entries)
  v_purge_order TEXT[] := ARRAY[
    'contract_obligation', 'contract_attachment',
    'signature_event', 'signature_invitation', 'signature_party_side',
    'signature_party', 'signer_qa_session',
    'approval_decision', 'approval_step', 'approval_chain', 'approval_matrix',
    'contract_comment', 'contract_watch', 'contract_activity',
    'contract_tag', 'contract_version',
    'payment_schedule',
    'impact_signal_contract', 'regulatory_impact', 'regulatory_update',
    'regulation', 'impact_category', 'regulator',
    'ai_insight', 'ai_request_log', 'ai_prompt',
    'import_batch',
    'notification_template',
    'contract', 'contract_clause', 'contract_template',
    'party_relationship', 'osint_signal', 'source_health', 'source_credential',
    'osint_source', 'internal_signal_kind', 'party'
  ];
  v_table          TEXT;
  v_count          BIGINT;
  v_total          BIGINT := 0;
  v_details        JSONB  := '{}'::jsonb;
  v_tables_purged  TEXT[] := ARRAY[]::TEXT[];
BEGIN
  -- Compound permission gate — Super Admin role check inside body (NOT just demo.purge)
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_demo_data_purge: unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM "user" u
      JOIN role r ON r.id = u.role_id
     WHERE u.id = v_uid
       AND r.name = 'Super Admin'
       AND u.is_active = TRUE
       AND r.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'fn_demo_data_purge: super_admin_required' USING ERRCODE = '42501';
  END IF;

  v_actor := v_uid;
  IF v_actor = 0 THEN v_actor := NULL; END IF;

  FOREACH v_table IN ARRAY v_purge_order LOOP
    EXECUTE format('SELECT COUNT(*) FROM %I WHERE data_classification = ''demo''', v_table) INTO v_count;
    IF NOT p_dry_run AND v_count > 0 THEN
      EXECUTE format('DELETE FROM %I WHERE data_classification = ''demo''', v_table);
    END IF;
    v_details := v_details || jsonb_build_object(v_table, v_count);
    v_total   := v_total + COALESCE(v_count, 0);
    IF v_count > 0 THEN
      v_tables_purged := array_append(v_tables_purged, v_table);
    END IF;
  END LOOP;

  -- Sentinel audit row — captures purge summary (chain remains valid post-purge per AC-S6-07).
  IF NOT p_dry_run AND v_total > 0 THEN
    PERFORM fn_audit_log_record_v2(
      '__demo_purge__',
      NULL,
      'DELETE',
      NULL,
      jsonb_build_object(
        'rowsDeleted',  v_total,
        'details',      v_details,
        'purgedBy',     v_actor,
        'purgedAt',     to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'tablesPurged', to_jsonb(v_tables_purged)
      ),
      v_actor
    );
  END IF;

  RETURN jsonb_build_object(
    'success',       TRUE,
    'tablesPurged',  to_jsonb(v_tables_purged),
    'rowsDeleted',   v_total,
    'details',       v_details,
    'dryRun',        p_dry_run
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'fn_demo_data_purge: demo_purge_fk_violation — %', SQLERRM
      USING ERRCODE = 'P0001';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_data_purge: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

COMMENT ON FUNCTION fn_demo_data_purge(BOOLEAN) IS
  'CR-C demo data purge utility. Super Admin role check inside body (NOT just demo.purge permission). DELETEs children-first across 38 ordered table operations. Idempotent. Emits sentinel __demo_purge__ audit row via fn_audit_log_record_v2 — chain remains valid post-purge (AC-S6-07). p_dry_run=TRUE returns the same shape with no DELETE.';
REVOKE EXECUTE ON FUNCTION fn_demo_data_purge(BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_data_purge(BOOLEAN) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (129, 'crc_audit_chain_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_demo_data_purge(BOOLEAN);
-- DROP FUNCTION IF EXISTS fn_data_classification_summary();
-- DROP FUNCTION IF EXISTS fn_audit_chain_verify(BIGINT, BIGINT);
-- DELETE FROM schema_migrations WHERE version = 129;
-- COMMIT;
-- ROLLBACK END
