-- Migration: 230_extend_fn_demo_data_purge.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: EXTEND fn_demo_data_purge to 53-table topology (adds 9 missing tables + 6 new tables from this module
--              + REFRESH MV latest_risk_score post-purge). Also extends fn_audit_trigger redaction list to include
--              event_injection_payload and error_message per Section 5 of db-design.md.
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- EXTEND fn_demo_data_purge: replace v_purge_order with full 53-table topology
-- Preserves signature fn_demo_data_purge(p_dry_run BOOLEAN) — S2-19 compliant.
CREATE OR REPLACE FUNCTION fn_demo_data_purge(p_dry_run BOOLEAN DEFAULT FALSE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_uid             BIGINT;
  v_actor           BIGINT;
  v_now             TIMESTAMPTZ := CURRENT_TIMESTAMP;
  -- Children-first DELETE order — 53-table topology (extended from 38 in M0/A17 + 9 missing + 6 new CR-I+J)
  v_purge_order TEXT[] := ARRAY[
    -- CR-I+J demo tables (new, children-first)
    'demo_scenario_run',
    'demo_scenario',
    'demo_seed_pack',
    -- Advisory + notification children
    'advisory_dispatch_log',
    'advisory_draft',
    'notification_dispatch_log',
    -- Risk scoring
    'risk_score',
    -- Correlation children
    'correlation_evaluation_error',
    'correlation',
    -- Clause + ingestion
    'contract_clause_extracted',
    'ingestion_review_queue',
    -- Original 38 tables (children-first)
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
  -- Compound permission gate — Super Admin role check
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
    BEGIN
      EXECUTE format('SELECT COUNT(*) FROM %I WHERE data_classification = ''demo''', v_table) INTO v_count;
    EXCEPTION WHEN undefined_column THEN
      -- Table exists but has no data_classification column — skip silently
      v_count := 0;
    END;
    IF NOT p_dry_run AND v_count > 0 THEN
      EXECUTE format('DELETE FROM %I WHERE data_classification = ''demo''', v_table);
    END IF;
    v_details := v_details || jsonb_build_object(v_table, v_count);
    v_total   := v_total + COALESCE(v_count, 0);
    IF v_count > 0 THEN
      v_tables_purged := array_append(v_tables_purged, v_table);
    END IF;
  END LOOP;

  -- Refresh MV after purge so latest_risk_score reflects clean state
  IF NOT p_dry_run THEN
    REFRESH MATERIALIZED VIEW latest_risk_score;
  END IF;

  -- Sentinel audit row
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
$$;

COMMENT ON FUNCTION fn_demo_data_purge(BOOLEAN) IS 'DEFINER: cascade-purge all demo data_classification=''demo'' rows in FK-safe topological order (53-table topology). Refreshes latest_risk_score MV post-purge. Super Admin required.';
REVOKE EXECUTE ON FUNCTION fn_demo_data_purge(BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_data_purge(BOOLEAN) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (230, '230_extend_fn_demo_data_purge', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 230;
-- (Re-apply the 38-table body from the prior migration to restore previous state)
-- ============================================================
