-- Migration: 242_crij_fix_weather_fn_and_purge_perm.sql
-- Module: M17+M18 — CR-I + CR-J post-test defect fixes
-- Description:
--   DEFECT-CRJ-1 (HIGH): fn_demo_data_purge had super_admin_required guard blocking
--     platform_admin from calling fn_demo_reset (which delegates to purge). Widen guard
--     to ALSO accept the demo.reset application permission.
--   DEFECT-CRJ-2 (CRITICAL): fn_rule_evaluate_weather_fm_eligible referenced
--     contract.tenant_id which does not exist (contract uses RLS GUC + party FK for tenant
--     scoping, not a tenant_id column). Drop the predicate; RLS already enforces isolation.
-- Date: 2026-05-14

BEGIN;

-- =========================================================================
-- Fix 1: fn_rule_evaluate_weather_fm_eligible — drop contract.tenant_id predicate
-- =========================================================================
CREATE OR REPLACE FUNCTION fn_rule_evaluate_weather_fm_eligible(p_signal_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id       UUID;
  v_signal          RECORD;
  v_correlations    JSONB := '[]'::jsonb;
  v_inserted_count  INTEGER := 0;
  v_contract_id     BIGINT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  SELECT os.id, os.severity_v2, os.kind, os.geographies
  INTO v_signal
  FROM osint_signal os
  WHERE os.id = p_signal_id
    AND os.tenant_id = v_tenant_id
    AND os.kind = 'weather'
    AND os.severity_v2 IN ('high', 'critical')
    AND (
      os.geographies::text ILIKE '%persian_gulf%'
      OR os.geographies::text ILIKE '%gulf_of_oman%'
      OR os.geographies::text ILIKE '%gulf%'
    );

  IF NOT FOUND THEN
    RETURN jsonb_build_object('correlations', '[]'::jsonb);
  END IF;

  -- contract has no tenant_id column; RLS GUC enforces isolation.
  FOR v_contract_id IN
    SELECT DISTINCT c.id
    FROM contract c
    JOIN contract_clause_extracted cce ON cce.contract_id = c.id
    WHERE c.is_active = TRUE
      AND c.contract_type IN ('o_m', 'drilling', 'charter_party')
      AND cce.clause_type_v2 IN ('weather', 'force_majeure', 'excusable_delay')
      AND cce.is_active = TRUE
      AND cce.tenant_id = v_tenant_id
  LOOP
    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id,
      match_reason, confidence, status, is_active, created_at
    ) VALUES (
      v_tenant_id, p_signal_id, v_contract_id,
      'rule.weather.fm_eligible',
      'Weather event severity ' || v_signal.severity_v2 || ' in Gulf region matched FM-eligible contract',
      0.85,
      'active', TRUE, now()
    )
    ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING;

    IF FOUND THEN
      v_inserted_count := v_inserted_count + 1;
      v_correlations := v_correlations || jsonb_build_array(
        jsonb_build_object('contractId', v_contract_id, 'ruleId', 'rule.weather.fm_eligible')
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object('correlations', v_correlations, 'inserted', v_inserted_count);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_rule_evaluate_weather_fm_eligible: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
REVOKE EXECUTE ON FUNCTION fn_rule_evaluate_weather_fm_eligible(bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_rule_evaluate_weather_fm_eligible(bigint) TO neondb_owner;

-- =========================================================================
-- Fix 2: fn_demo_data_purge — widen guard to also accept demo.reset permission
-- =========================================================================
CREATE OR REPLACE FUNCTION fn_demo_data_purge(p_dry_run boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_uid             BIGINT;
  v_actor           BIGINT;
  v_now             TIMESTAMPTZ := CURRENT_TIMESTAMP;
  v_purge_order TEXT[] := ARRAY[
    'demo_scenario_run','demo_scenario','demo_seed_pack',
    'advisory_dispatch_log','advisory_draft','notification_dispatch_log',
    'risk_score',
    'correlation_evaluation_error','correlation',
    'contract_clause_extracted','ingestion_review_queue',
    'contract_obligation','contract_attachment',
    'signature_event','signature_invitation','signature_party_side',
    'signature_party','signer_qa_session',
    'approval_decision','approval_step','approval_chain','approval_matrix',
    'contract_comment','contract_watch','contract_activity',
    'contract_tag','contract_version',
    'payment_schedule',
    'impact_signal_contract','regulatory_impact','regulatory_update',
    'regulation','impact_category','regulator',
    'ai_insight','ai_request_log','ai_prompt',
    'import_batch',
    'notification_template',
    'contract','contract_clause','contract_template',
    'party_relationship','osint_signal','source_health','source_credential',
    'osint_source','internal_signal_kind','party'
  ];
  v_table          TEXT;
  v_count          BIGINT;
  v_total          BIGINT := 0;
  v_details        JSONB  := '{}'::jsonb;
  v_tables_purged  TEXT[] := ARRAY[]::TEXT[];
BEGIN
  v_uid := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'fn_demo_data_purge: unauthorized' USING ERRCODE = '42501';
  END IF;
  -- Widened guard: Super Admin OR demo.reset permission holder
  IF NOT EXISTS (
    SELECT 1 FROM "user" u
      JOIN role r ON r.id = u.role_id
      LEFT JOIN role_permission rp ON rp.role_id = u.role_id
      LEFT JOIN permission p ON p.id = rp.permission_id
     WHERE u.id = v_uid
       AND u.is_active = TRUE
       AND r.is_active = TRUE
       AND (r.name = 'Super Admin' OR p.code IN ('demo.reset','demo.purge'))
  ) THEN
    RAISE EXCEPTION 'fn_demo_data_purge: super_admin_or_demo_reset_required' USING ERRCODE = '42501';
  END IF;

  v_actor := v_uid;
  IF v_actor = 0 THEN v_actor := NULL; END IF;

  FOREACH v_table IN ARRAY v_purge_order LOOP
    BEGIN
      EXECUTE format('SELECT COUNT(*) FROM %I WHERE data_classification = ''demo''', v_table) INTO v_count;
    EXCEPTION WHEN undefined_column THEN
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

  IF NOT p_dry_run THEN
    REFRESH MATERIALIZED VIEW latest_risk_score;
  END IF;

  IF NOT p_dry_run AND v_total > 0 THEN
    PERFORM fn_audit_log_record_v2(
      '__demo_purge__', NULL, 'DELETE', NULL,
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
    'success', TRUE,
    'tablesPurged', to_jsonb(v_tables_purged),
    'rowsDeleted',  v_total,
    'details',      v_details,
    'dryRun',       p_dry_run
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'fn_demo_data_purge: demo_purge_fk_violation — %', SQLERRM USING ERRCODE = 'P0001';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_data_purge: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;
REVOKE EXECUTE ON FUNCTION fn_demo_data_purge(boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_data_purge(boolean) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (242, 'CR-I+J post-test defect fixes (CRJ-1 + CRJ-2)', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;
