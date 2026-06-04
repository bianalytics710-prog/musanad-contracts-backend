-- MIGRATION: 523_report_tailored_fns.sql
-- Date: 2026-06-03
-- Description:
--   Per-role report tailoring. Adds a section_key column to report_template
--   so the FE Reports library can group cards under section headers, and
--   creates 11 fn_report_data_* functions:
--   • 8 NEW functions (3 drafter + 3 approver + 2 executive)
--   • 3 FIXES for legal-counsel templates whose data_source pointed at
--     non-existent fns (advisory_approval_sla, cure_notice_audit,
--     dispatched_notifications_log).
--
--   Template-seed and assigned_roles changes are in mig 524.

BEGIN;

-- ============================================================
-- 1. Schema — section_key column
-- ============================================================
ALTER TABLE report_template
  ADD COLUMN IF NOT EXISTS section_key VARCHAR(60) NULL;
COMMENT ON COLUMN report_template.section_key IS
  'FE grouping key (e.g. board_brief, risk_exposure, my_work, productivity, advisory, regulatory_clause, my_queue, decisions). NULL = ungrouped.';

-- ============================================================
-- 2. EXECUTIVE — Counterparty Concentration (NEW)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_counterparty_concentration(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB; v_total_value NUMERIC; v_party_count INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COALESCE(SUM(value_aed), 0), COUNT(DISTINCT counterparty_id)
    INTO v_total_value, v_party_count
    FROM contract WHERE is_active = TRUE AND counterparty_id IS NOT NULL;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'counterpartyId', counterparty_id, 'counterpartyName', counterparty_name,
    'contractCount', contract_count, 'totalValueAed', total_value_aed,
    'sharePct', share_pct, 'avgRiskScore', avg_risk_score, 'maxRiskScore', max_risk_score
  ) ORDER BY total_value_aed DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT c.counterparty_id, p.name_en AS counterparty_name,
           COUNT(*) AS contract_count,
           ROUND(SUM(COALESCE(c.value_aed, 0))::numeric, 0) AS total_value_aed,
           ROUND((SUM(COALESCE(c.value_aed, 0)) / NULLIF(v_total_value, 0) * 100)::numeric, 2) AS share_pct,
           ROUND(AVG(COALESCE(c.ai_risk_score, 0))::numeric, 1) AS avg_risk_score,
           MAX(COALESCE(c.ai_risk_score, 0)) AS max_risk_score
      FROM contract c
      JOIN party p ON p.id = c.counterparty_id
     WHERE c.is_active = TRUE AND c.counterparty_id IS NOT NULL
     GROUP BY c.counterparty_id, p.name_en
     ORDER BY SUM(COALESCE(c.value_aed, 0)) DESC NULLS LAST
     LIMIT 20
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object(
      'totalPortfolioValueAed', ROUND(v_total_value::numeric, 0),
      'distinctCounterparties', v_party_count,
      'top20', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','contract','count', (SELECT COUNT(*) FROM contract WHERE is_active = TRUE))),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_counterparty_concentration: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_counterparty_concentration(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_counterparty_concentration(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- 3. EXECUTIVE — Recent Material Events (NEW)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_recent_material_events(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB; v_total INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*) INTO v_total FROM correlation co
   WHERE co.tenant_id = v_tenant AND co.is_active = TRUE AND co.status = 'active'
     AND co.created_at >= v_now - INTERVAL '30 days';
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'firedAt', fired_at, 'ruleName', rule_name, 'scenario', scenario,
    'contractNumber', contract_number, 'contractTitle', title_en,
    'counterpartyName', counterparty_name,
    'severity', severity, 'matchReason', match_reason
  ) ORDER BY fired_at DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT co.created_at AS fired_at, cr.name AS rule_name, cr.scenario AS scenario,
           c.contract_number, c.title_en,
           COALESCE(p.name_en, '—') AS counterparty_name,
           COALESCE(co.match_evidence->>'severity', 'medium') AS severity,
           COALESCE(co.match_reason, '') AS match_reason
      FROM correlation co
      JOIN correlation_rule cr ON cr.rule_id = co.rule_id AND cr.tenant_id = co.tenant_id
      LEFT JOIN contract c ON c.id = co.contract_id
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE co.tenant_id = v_tenant AND co.is_active = TRUE AND co.status = 'active'
       AND co.created_at >= v_now - INTERVAL '30 days'
     ORDER BY co.created_at DESC LIMIT 50
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('windowDays', 30, 'eventCount', v_total, 'events', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','correlation','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_recent_material_events: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_recent_material_events(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_recent_material_events(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- 4. DRAFTER — Drafts awaiting my input (NEW)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_drafter_drafts_awaiting_input(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB; v_total INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*) INTO v_total
    FROM contract c
   WHERE c.is_active = TRUE
     AND (c.drafted_by = p_actor_id OR c.created_by = p_actor_id)
     AND EXISTS (
       SELECT 1 FROM approval_chain ac
         JOIN approval_step ast ON ast.approval_chain_id = ac.id
        WHERE ac.contract_id = c.id AND ac.is_active = TRUE
          AND ast.is_active = TRUE AND ast.status = 'request_info'
     );
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractNumber', contract_number, 'titleEn', title_en, 'status', status,
    'requestedAt', requested_at, 'requesterRole', requester_role,
    'daysOpen', days_open
  ) ORDER BY requested_at ASC), '[]'::jsonb) INTO v_rows FROM (
    SELECT c.contract_number, c.title_en, c.status,
           MIN(ast.updated_at) AS requested_at,
           STRING_AGG(DISTINCT ast.approver_role, ', ') AS requester_role,
           ROUND(EXTRACT(EPOCH FROM (v_now - MIN(ast.updated_at))) / 86400.0, 1) AS days_open
      FROM contract c
      JOIN approval_chain ac ON ac.contract_id = c.id
      JOIN approval_step ast ON ast.approval_chain_id = ac.id
     WHERE c.is_active = TRUE AND ac.is_active = TRUE AND ast.is_active = TRUE
       AND ast.status = 'request_info'
       AND (c.drafted_by = p_actor_id OR c.created_by = p_actor_id)
     GROUP BY c.contract_number, c.title_en, c.status
     ORDER BY MIN(ast.updated_at) ASC LIMIT 50
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('awaitingInputCount', v_total, 'drafts', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','contract','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_drafter_drafts_awaiting_input: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_drafter_drafts_awaiting_input(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_drafter_drafts_awaiting_input(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- 5. DRAFTER — My contracts in approval (NEW)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_drafter_contracts_in_approval(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB; v_total INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(DISTINCT c.id) INTO v_total
    FROM contract c
    JOIN approval_chain ac ON ac.contract_id = c.id
    JOIN approval_step ast ON ast.approval_chain_id = ac.id
   WHERE c.is_active = TRUE AND ac.is_active = TRUE AND ast.is_active = TRUE
     AND ast.status IN ('pending', 'in_review')
     AND (c.drafted_by = p_actor_id OR c.created_by = p_actor_id);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractNumber', contract_number, 'titleEn', title_en, 'status', status,
    'currentStage', current_stage, 'currentApproverRole', approver_role,
    'enteredQueueAt', entered_queue_at, 'daysInQueue', days_in_queue,
    'valueAed', value_aed
  ) ORDER BY days_in_queue DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT c.contract_number, c.title_en, c.status,
           ast.step_order AS current_stage,
           ast.approver_role,
           ast.created_at AS entered_queue_at,
           ROUND(EXTRACT(EPOCH FROM (v_now - ast.created_at)) / 86400.0, 1) AS days_in_queue,
           c.value_aed
      FROM contract c
      JOIN approval_chain ac ON ac.contract_id = c.id
      JOIN approval_step ast ON ast.approval_chain_id = ac.id
     WHERE c.is_active = TRUE AND ac.is_active = TRUE AND ast.is_active = TRUE
       AND ast.status IN ('pending', 'in_review')
       AND (c.drafted_by = p_actor_id OR c.created_by = p_actor_id)
     ORDER BY ast.created_at ASC LIMIT 50
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('inApprovalCount', v_total, 'contracts', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','approval_step','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_drafter_contracts_in_approval: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_drafter_contracts_in_approval(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_drafter_contracts_in_approval(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- 6. DRAFTER — Recently signed (NEW)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_drafter_recently_signed(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB; v_total INTEGER; v_avg_cycle NUMERIC; v_total_value NUMERIC;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*),
         AVG(EXTRACT(EPOCH FROM (signed_at - created_at)) / 86400.0),
         SUM(COALESCE(value_aed, 0))
    INTO v_total, v_avg_cycle, v_total_value
    FROM contract
   WHERE is_active = TRUE AND signed_at IS NOT NULL
     AND signed_at >= v_now - INTERVAL '30 days'
     AND (drafted_by = p_actor_id OR created_by = p_actor_id);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractNumber', contract_number, 'titleEn', title_en, 'contractType', contract_type,
    'counterpartyName', counterparty_name, 'signedAt', signed_at,
    'cycleDays', cycle_days, 'valueAed', value_aed
  ) ORDER BY signed_at DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT c.contract_number, c.title_en, c.contract_type,
           COALESCE(p.name_en, '—') AS counterparty_name,
           c.signed_at, c.value_aed,
           ROUND(EXTRACT(EPOCH FROM (c.signed_at - c.created_at)) / 86400.0, 1) AS cycle_days
      FROM contract c
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE c.is_active = TRUE AND c.signed_at IS NOT NULL
       AND c.signed_at >= v_now - INTERVAL '30 days'
       AND (c.drafted_by = p_actor_id OR c.created_by = p_actor_id)
     ORDER BY c.signed_at DESC LIMIT 50
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('signedCount', v_total,
      'avgCycleDays', COALESCE(ROUND(v_avg_cycle, 1), 0),
      'totalValueAed', ROUND(COALESCE(v_total_value, 0)::numeric, 0),
      'contracts', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','contract','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_drafter_recently_signed: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_drafter_recently_signed(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_drafter_recently_signed(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- 7. APPROVER — My pending approvals (NEW)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_approver_pending_approvals(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB; v_total INTEGER; v_total_value NUMERIC;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*), SUM(COALESCE(c.value_aed, 0))
    INTO v_total, v_total_value
    FROM approval_step a
    JOIN approval_chain ac ON ac.id = a.approval_chain_id
    JOIN contract c ON c.id = ac.contract_id
   WHERE a.is_active = TRUE AND a.approver_user_id = p_actor_id
     AND a.status IN ('pending', 'in_review');
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'stepId', step_id, 'contractNumber', contract_number, 'titleEn', title_en,
    'contractType', contract_type, 'stageOrder', stage_order, 'status', step_status,
    'enteredAt', entered_at, 'hoursPending', hours_pending,
    'valueAed', value_aed, 'counterpartyName', counterparty_name
  ) ORDER BY hours_pending DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT a.id AS step_id, c.contract_number, c.title_en, c.contract_type,
           a.step_order AS stage_order, a.status AS step_status,
           a.created_at AS entered_at,
           ROUND(EXTRACT(EPOCH FROM (v_now - a.created_at)) / 3600.0, 1) AS hours_pending,
           c.value_aed,
           COALESCE(p.name_en, '—') AS counterparty_name
      FROM approval_step a
      JOIN approval_chain ac ON ac.id = a.approval_chain_id
      JOIN contract c ON c.id = ac.contract_id
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE a.is_active = TRUE AND a.approver_user_id = p_actor_id
       AND a.status IN ('pending', 'in_review')
     ORDER BY a.created_at ASC LIMIT 100
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('pendingCount', v_total,
      'totalValueInQueueAed', ROUND(COALESCE(v_total_value, 0)::numeric, 0),
      'pendingSteps', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','approval_step','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_approver_pending_approvals: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_approver_pending_approvals(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_approver_pending_approvals(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- 8. APPROVER — High-value approvals in queue (NEW)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_approver_high_value_approvals(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_threshold NUMERIC := COALESCE((p_parameters->>'thresholdAed')::numeric, 1000000); -- AED 1M default
  v_rows JSONB; v_total INTEGER; v_total_value NUMERIC;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*), SUM(COALESCE(c.value_aed, 0))
    INTO v_total, v_total_value
    FROM approval_step a
    JOIN approval_chain ac ON ac.id = a.approval_chain_id
    JOIN contract c ON c.id = ac.contract_id
   WHERE a.is_active = TRUE AND a.approver_user_id = p_actor_id
     AND a.status IN ('pending', 'in_review')
     AND COALESCE(c.value_aed, 0) >= v_threshold;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'stepId', step_id, 'contractNumber', contract_number, 'titleEn', title_en,
    'contractType', contract_type, 'valueAed', value_aed,
    'counterpartyName', counterparty_name, 'hoursPending', hours_pending
  ) ORDER BY value_aed DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT a.id AS step_id, c.contract_number, c.title_en, c.contract_type, c.value_aed,
           COALESCE(p.name_en, '—') AS counterparty_name,
           ROUND(EXTRACT(EPOCH FROM (v_now - a.created_at)) / 3600.0, 1) AS hours_pending
      FROM approval_step a
      JOIN approval_chain ac ON ac.id = a.approval_chain_id
      JOIN contract c ON c.id = ac.contract_id
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE a.is_active = TRUE AND a.approver_user_id = p_actor_id
       AND a.status IN ('pending', 'in_review')
       AND COALESCE(c.value_aed, 0) >= v_threshold
     ORDER BY c.value_aed DESC NULLS LAST LIMIT 50
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('thresholdAed', v_threshold, 'matchCount', v_total,
      'totalValueAed', ROUND(COALESCE(v_total_value, 0)::numeric, 0),
      'highValueSteps', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','approval_step','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_approver_high_value_approvals: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_approver_high_value_approvals(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_approver_high_value_approvals(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- 9. APPROVER — Weekly activity (NEW)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_approver_weekly_activity(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_by_status JSONB; v_recent JSONB; v_total INTEGER; v_avg_cycle NUMERIC;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*), AVG(EXTRACT(EPOCH FROM (decided_at - created_at)) / 3600.0)
    INTO v_total, v_avg_cycle
    FROM approval_step
   WHERE is_active = TRUE AND approver_user_id = p_actor_id
     AND decided_at >= v_now - INTERVAL '7 days';
  SELECT COALESCE(jsonb_object_agg(status, cnt), '{}'::jsonb) INTO v_by_status FROM (
    SELECT status, COUNT(*) AS cnt FROM approval_step
     WHERE is_active = TRUE AND approver_user_id = p_actor_id
       AND decided_at >= v_now - INTERVAL '7 days' GROUP BY status
  ) s;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'contractNumber', contract_number, 'titleEn', title_en, 'decision', step_status,
    'decidedAt', decided_at, 'cycleHours', cycle_hours
  ) ORDER BY decided_at DESC), '[]'::jsonb) INTO v_recent FROM (
    SELECT c.contract_number, c.title_en, a.status AS step_status, a.decided_at,
           ROUND(EXTRACT(EPOCH FROM (a.decided_at - a.created_at)) / 3600.0, 1) AS cycle_hours
      FROM approval_step a
      JOIN approval_chain ac ON ac.id = a.approval_chain_id
      JOIN contract c ON c.id = ac.contract_id
     WHERE a.is_active = TRUE AND a.approver_user_id = p_actor_id
       AND a.decided_at >= v_now - INTERVAL '7 days'
     ORDER BY a.decided_at DESC LIMIT 50
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('windowDays', 7,
      'decisionCount', v_total,
      'avgCycleHours', COALESCE(ROUND(v_avg_cycle, 1), 0),
      'byDecisionStatus', v_by_status, 'decisions', v_recent),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','approval_step','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_approver_weekly_activity: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_approver_weekly_activity(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_approver_weekly_activity(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- 10. LEGAL COUNSEL — Advisory Approval SLA (FIX)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_advisory_approval_sla(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_by_status JSONB; v_by_type JSONB; v_total INTEGER; v_avg NUMERIC;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*),
         AVG(EXTRACT(EPOCH FROM (approved_at - created_at)) / 3600.0)
    INTO v_total, v_avg
    FROM advisory_draft
   WHERE tenant_id = v_tenant AND is_active = TRUE
     AND approved_at IS NOT NULL
     AND created_at >= v_now - INTERVAL '90 days';
  SELECT COALESCE(jsonb_object_agg(approval_status, cnt), '{}'::jsonb) INTO v_by_status FROM (
    SELECT approval_status, COUNT(*) AS cnt FROM advisory_draft
     WHERE tenant_id = v_tenant AND is_active = TRUE
       AND created_at >= v_now - INTERVAL '90 days'
     GROUP BY approval_status
  ) s;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'draftType', draft_type, 'approvedCount', n_approved,
    'avgApprovalHours', avg_hours, 'p95ApprovalHours', p95_hours
  ) ORDER BY avg_hours DESC), '[]'::jsonb) INTO v_by_type FROM (
    SELECT draft_type, COUNT(*) AS n_approved,
           ROUND(AVG(EXTRACT(EPOCH FROM (approved_at - created_at)) / 3600.0)::numeric, 1) AS avg_hours,
           ROUND((percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (approved_at - created_at)) / 3600.0))::numeric, 1) AS p95_hours
      FROM advisory_draft
     WHERE tenant_id = v_tenant AND is_active = TRUE
       AND approved_at IS NOT NULL AND created_at >= v_now - INTERVAL '90 days'
     GROUP BY draft_type
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('windowDays', 90, 'totalDrafts', v_total,
      'avgApprovalHours', COALESCE(ROUND(v_avg, 1), 0),
      'byApprovalStatus', v_by_status, 'byDraftType', v_by_type),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','advisory_draft','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_advisory_approval_sla: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_advisory_approval_sla(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_advisory_approval_sla(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- 11. LEGAL COUNSEL — Cure Notice Audit (FIX)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_cure_notice_audit(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB; v_total INTEGER; v_dispatched INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*) FILTER (WHERE TRUE),
         COUNT(*) FILTER (WHERE ad.dispatched_at IS NOT NULL)
    INTO v_total, v_dispatched
    FROM advisory_draft ad
   WHERE ad.tenant_id = v_tenant AND ad.is_active = TRUE
     AND ad.draft_type IN ('cure_notice', 'budget_cure_notice')
     AND ad.created_at >= v_now - INTERVAL '180 days';
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'draftId', draft_id, 'contractNumber', contract_number, 'titleEn', title_en,
    'counterpartyName', counterparty_name,
    'approvalStatus', approval_status, 'createdAt', created_at,
    'approvedAt', approved_at, 'dispatchedAt', dispatched_at,
    'dispatchChannel', dispatch_channel,
    'lastDispatchStatus', last_dispatch_status, 'lastDispatchError', last_dispatch_error
  ) ORDER BY created_at DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT ad.id AS draft_id, c.contract_number, c.title_en,
           COALESCE(p.name_en, '—') AS counterparty_name,
           ad.approval_status, ad.created_at, ad.approved_at,
           ad.dispatched_at, ad.dispatch_channel,
           (SELECT adl.status FROM advisory_dispatch_log adl
             WHERE adl.advisory_draft_id = ad.id ORDER BY adl.delivery_attempted_at DESC NULLS LAST LIMIT 1) AS last_dispatch_status,
           (SELECT adl.error_message FROM advisory_dispatch_log adl
             WHERE adl.advisory_draft_id = ad.id ORDER BY adl.delivery_attempted_at DESC NULLS LAST LIMIT 1) AS last_dispatch_error
      FROM advisory_draft ad
      LEFT JOIN contract c ON c.id = ad.contract_id
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE ad.tenant_id = v_tenant AND ad.is_active = TRUE
       AND ad.draft_type IN ('cure_notice', 'budget_cure_notice')
       AND ad.created_at >= v_now - INTERVAL '180 days'
     ORDER BY ad.created_at DESC LIMIT 100
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('windowDays', 180,
      'totalCureNotices', v_total, 'dispatchedCount', v_dispatched,
      'cureNotices', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','advisory_draft','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_cure_notice_audit: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_cure_notice_audit(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_cure_notice_audit(BIGINT, JSONB) TO neondb_owner;


-- ============================================================
-- 12. LEGAL COUNSEL — Dispatched Notifications Log (FIX)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_report_data_dispatched_notifications_log(
  p_actor_id BIGINT, p_parameters JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := NOW();
  v_rows JSONB; v_total INTEGER; v_failed INTEGER;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;
  SELECT COUNT(*),
         COUNT(*) FILTER (WHERE status IN ('failed', 'final_failed'))
    INTO v_total, v_failed
    FROM advisory_dispatch_log
   WHERE tenant_id = v_tenant AND is_active = TRUE
     AND delivery_attempted_at >= v_now - INTERVAL '30 days';
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'logId', log_id, 'draftType', draft_type,
    'contractNumber', contract_number, 'counterpartyName', counterparty_name,
    'channel', channel, 'recipient', recipient_address, 'status', status,
    'attemptedAt', delivery_attempted_at, 'completedAt', delivery_completed_at,
    'retryCount', retry_count, 'errorMessage', error_message
  ) ORDER BY delivery_attempted_at DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT adl.id AS log_id, ad.draft_type, c.contract_number,
           COALESCE(p.name_en, '—') AS counterparty_name,
           adl.channel, adl.recipient_address, adl.status,
           adl.delivery_attempted_at, adl.delivery_completed_at,
           adl.retry_count, adl.error_message
      FROM advisory_dispatch_log adl
      JOIN advisory_draft ad ON ad.id = adl.advisory_draft_id
      LEFT JOIN contract c ON c.id = ad.contract_id
      LEFT JOIN party p ON p.id = c.counterparty_id
     WHERE adl.tenant_id = v_tenant AND adl.is_active = TRUE
       AND adl.delivery_attempted_at >= v_now - INTERVAL '30 days'
     ORDER BY adl.delivery_attempted_at DESC LIMIT 200
  ) s;
  RETURN jsonb_build_object(
    'payload', jsonb_build_object('windowDays', 30, 'totalAttempts', v_total,
      'failedCount', v_failed, 'dispatches', v_rows),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now,
      'sourceTraceability', jsonb_build_array(jsonb_build_object('tableName','advisory_dispatch_log','count', v_total)),
      'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_dispatched_notifications_log: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $fn$;
REVOKE EXECUTE ON FUNCTION fn_report_data_dispatched_notifications_log(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_dispatched_notifications_log(BIGINT, JSONB) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (523, 'report_tailored_fns', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
