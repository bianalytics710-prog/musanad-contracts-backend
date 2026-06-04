-- MIGRATION: 522_report_data_drafter_approver_fns_v2.sql
-- Date: 2026-06-03
-- Description:
--   Fix mig 521 fns. Two real schema mismatches:
--   - contract is single-tenant (no tenant_id column) — the tenant guard
--     stays but we drop the WHERE tenant_id = clause for contract queries.
--   - approval_step columns: actor is "approver_user_id" (not
--     assigned_to_user_id); contract is reached via approval_chain_id →
--     approval_chain.contract_id; status enum uses {'pending','approved',
--     'rejected','request_info','reassigned','delegated',...}.

BEGIN;

-- ============================================================
-- Drafter — Templates I have used (last 90 days)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_drafter_template_usage(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB;
  v_total INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*) INTO v_total FROM contract
   WHERE created_by = p_actor_id AND is_active = TRUE
     AND created_at >= v_now - INTERVAL '90 days';
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'templateId', template_id, 'templateName', template_name,
    'usageCount', usage_count, 'lastUsedAt', last_used_at
  ) ORDER BY usage_count DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT c.template_id AS template_id,
           COALESCE(t.name_en, '(no template)') AS template_name,
           COUNT(*) AS usage_count, MAX(c.created_at) AS last_used_at
    FROM contract c LEFT JOIN contract_template t ON t.id = c.template_id
    WHERE c.created_by = p_actor_id AND c.is_active = TRUE
      AND c.created_at >= v_now - INTERVAL '90 days'
    GROUP BY c.template_id, t.name_en
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('totalContracts', v_total, 'byTemplate', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','contract','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_drafter_template_usage: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_drafter_template_usage(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_drafter_template_usage(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- Drafter — Cycle time
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_drafter_cycle_time(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB; v_avg NUMERIC; v_n INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*), AVG(EXTRACT(EPOCH FROM (signed_at - created_at)) / 86400.0) INTO v_n, v_avg
    FROM contract WHERE created_by = p_actor_id AND is_active = TRUE
     AND signed_at IS NOT NULL AND created_at >= v_now - INTERVAL '180 days';
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractNumber', contract_number, 'titleEn', title_en,
    'createdAt', created_at, 'signedAt', signed_at, 'cycleDays', cycle_days
  ) ORDER BY cycle_days DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT contract_number, title_en, created_at, signed_at,
           ROUND(EXTRACT(EPOCH FROM (signed_at - created_at)) / 86400.0, 1) AS cycle_days
      FROM contract WHERE created_by = p_actor_id AND is_active = TRUE
       AND signed_at IS NOT NULL AND created_at >= v_now - INTERVAL '180 days'
     ORDER BY signed_at DESC LIMIT 50
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('contractCount', v_n, 'avgCycleDays', COALESCE(ROUND(v_avg, 1), 0), 'recentRuns', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','contract','count', v_n)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_drafter_cycle_time: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_drafter_cycle_time(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_drafter_cycle_time(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- Drafter — My pipeline
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_drafter_my_pipeline(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_by_status JSONB; v_recent JSONB; v_total INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*) INTO v_total FROM contract WHERE created_by = p_actor_id AND is_active = TRUE;
  SELECT COALESCE(jsonb_object_agg(status, cnt), '{}'::jsonb) INTO v_by_status FROM (
    SELECT status, COUNT(*) AS cnt FROM contract
     WHERE created_by = p_actor_id AND is_active = TRUE GROUP BY status
  ) s;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractNumber', contract_number, 'titleEn', title_en, 'status', status,
    'createdAt', created_at, 'updatedAt', updated_at
  ) ORDER BY updated_at DESC), '[]'::jsonb) INTO v_recent FROM (
    SELECT contract_number, title_en, status, created_at, updated_at
      FROM contract WHERE created_by = p_actor_id AND is_active = TRUE
     ORDER BY updated_at DESC LIMIT 25
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('totalContracts', v_total, 'byStatus', v_by_status, 'recent', v_recent),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','contract','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_drafter_my_pipeline: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_drafter_my_pipeline(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_drafter_my_pipeline(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- Approver — My decisions
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_approver_my_decisions(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_by_status JSONB; v_recent JSONB; v_total INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*) INTO v_total FROM approval_step
   WHERE approver_user_id = p_actor_id AND is_active = TRUE
     AND created_at >= v_now - INTERVAL '30 days';
  SELECT COALESCE(jsonb_object_agg(status, cnt), '{}'::jsonb) INTO v_by_status FROM (
    SELECT status, COUNT(*) AS cnt FROM approval_step
     WHERE approver_user_id = p_actor_id AND is_active = TRUE
       AND created_at >= v_now - INTERVAL '30 days' GROUP BY status
  ) s;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'stepId', step_id, 'contractNumber', contract_number, 'titleEn', title_en,
    'status', step_status, 'createdAt', step_created_at, 'decidedAt', step_decided_at
  ) ORDER BY step_created_at DESC), '[]'::jsonb) INTO v_recent FROM (
    SELECT a.id AS step_id, c.contract_number, c.title_en,
           a.status AS step_status, a.created_at AS step_created_at, a.decided_at AS step_decided_at
      FROM approval_step a
      JOIN approval_chain ac ON ac.id = a.approval_chain_id
      JOIN contract c ON c.id = ac.contract_id
     WHERE a.approver_user_id = p_actor_id AND a.is_active = TRUE
       AND a.created_at >= v_now - INTERVAL '30 days'
     ORDER BY a.created_at DESC LIMIT 100
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('totalSteps', v_total, 'byStatus', v_by_status, 'recent', v_recent),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','approval_step','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_approver_my_decisions: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_approver_my_decisions(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_approver_my_decisions(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- Approver — Cycle time by contract type
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_approver_cycle_time_by_type(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB; v_n INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*) INTO v_n FROM approval_step a
   WHERE a.approver_user_id = p_actor_id AND a.is_active = TRUE
     AND a.decided_at IS NOT NULL AND a.created_at >= v_now - INTERVAL '180 days';
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractType', contract_type, 'decisions', n_decisions,
    'avgCycleHours', avg_hours, 'p95CycleHours', p95_hours
  ) ORDER BY avg_hours DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT COALESCE(c.contract_type, '(unknown)') AS contract_type,
           COUNT(*) AS n_decisions,
           ROUND(AVG(EXTRACT(EPOCH FROM (a.decided_at - a.created_at)) / 3600.0)::numeric, 1) AS avg_hours,
           ROUND((percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (a.decided_at - a.created_at)) / 3600.0))::numeric, 1) AS p95_hours
      FROM approval_step a
      JOIN approval_chain ac ON ac.id = a.approval_chain_id
      JOIN contract c ON c.id = ac.contract_id
     WHERE a.approver_user_id = p_actor_id AND a.is_active = TRUE
       AND a.decided_at IS NOT NULL AND a.created_at >= v_now - INTERVAL '180 days'
     GROUP BY c.contract_type
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('decisionCount', v_n, 'byContractType', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','approval_step','count', v_n)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_approver_cycle_time_by_type: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_approver_cycle_time_by_type(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_approver_cycle_time_by_type(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- Approver — SLA breach summary
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_approver_sla_breach_summary(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB; v_total INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*) INTO v_total FROM approval_step
   WHERE approver_user_id = p_actor_id AND is_active = TRUE
     AND status = 'pending' AND created_at <= v_now - INTERVAL '72 hours';
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'stepId', step_id, 'contractNumber', contract_number, 'titleEn', title_en,
    'status', step_status, 'createdAt', step_created_at, 'hoursPending', hours_pending
  ) ORDER BY hours_pending DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT a.id AS step_id, c.contract_number, c.title_en, a.status AS step_status,
           a.created_at AS step_created_at,
           ROUND(EXTRACT(EPOCH FROM (v_now - a.created_at)) / 3600.0, 1) AS hours_pending
      FROM approval_step a
      JOIN approval_chain ac ON ac.id = a.approval_chain_id
      JOIN contract c ON c.id = ac.contract_id
     WHERE a.approver_user_id = p_actor_id AND a.is_active = TRUE
       AND a.status = 'pending' AND a.created_at <= v_now - INTERVAL '72 hours'
     ORDER BY a.created_at ASC LIMIT 100
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('breachCount', v_total, 'slaWindowHours', 72, 'breaches', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','approval_step','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_approver_sla_breach_summary: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_approver_sla_breach_summary(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_approver_sla_breach_summary(BIGINT, JSONB) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (522, 'report_data_drafter_approver_fns_v2', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
