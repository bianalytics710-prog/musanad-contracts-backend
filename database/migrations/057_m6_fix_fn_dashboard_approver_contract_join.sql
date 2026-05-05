-- ============================================================================
-- 057_m6_fix_fn_dashboard_approver_contract_join.sql
-- ============================================================================
-- Module:    M6 (Dashboards & Reporting) — runtime fix migration
-- Owner:     Agent 6 — DB Implementation
-- Depends:   056 (fn_dashboard_approver definition).
-- ----------------------------------------------------------------------------
-- DEFECT:    Original migration 056 fn_dashboard_approver pendingQueue5 SQL
--            joined contract via `step.contract_id`, but live approval_step
--            has NO contract_id column (it owns approval_chain_id; the
--            contract reference lives on approval_chain.contract_id).
--            Runtime probe surfaced 'column step.contract_id does not exist'
--            at first execution against the test branch (S2-22 escape from
--            design — Patch Round 1 missed this reference because earlier
--            patches focused on the approver_user_id / decided_by /
--            assigned_at column trio).
--
--            Live join path:
--              approval_step (chain_id) -> approval_chain (contract_id) -> contract (id)
--
-- FIX:       CREATE OR REPLACE FUNCTION fn_dashboard_approver(INTEGER) with
--            corrected pendingQueue5 SQL: join approval_chain on chain_id and
--            contract on chain.contract_id. Output JSONB shape unchanged
--            ('contractId' projects from the chain.contract_id, not from
--            a non-existent step.contract_id).
--
-- This is a CREATE OR REPLACE FUNCTION patch — additive, signature-preserving.
-- Mirrors M3 038/039 and M4 045 fix-migration precedent.
-- ----------------------------------------------------------------------------

BEGIN;

CREATE OR REPLACE FUNCTION fn_dashboard_approver(
  p_window_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id BIGINT;
  v_role    TEXT;
  v_window  INTEGER;
  v_kpis    JSONB;
  v_lists   JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_approver: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_approver: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('contract_approver', 'contract_approver_2', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_approver: forbidden — approver dashboard restricted to contract_approver, contract_approver_2, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'pendingMyApprovalCount',
      (SELECT COUNT(*) FROM approval_step
        WHERE COALESCE(delegated_to, reassigned_to, approver_user_id) IS NOT DISTINCT FROM v_user_id
          AND status = 'pending' AND is_active = TRUE),
    'decidedByMeCount',
      (SELECT COUNT(*) FROM approval_decision
        WHERE decided_by = v_user_id
          AND decided_at >= NOW() - (v_window || ' days')::INTERVAL
          AND is_active = TRUE),
    'averageDecisionHoursMine',
      (SELECT AVG(EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0)::NUMERIC(12,2)
       FROM approval_decision ad
       JOIN approval_step step ON step.id = ad.approval_step_id
       WHERE ad.decided_by = v_user_id
         AND ad.decided_at >= NOW() - (v_window || ' days')::INTERVAL
         AND ad.is_active = TRUE),
    'averageDecisionHoursTeam',
      (SELECT AVG(EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0)::NUMERIC(12,2)
       FROM approval_decision ad
       JOIN approval_step step ON step.id = ad.approval_step_id
       JOIN "user" u ON u.id = ad.decided_by
       JOIN role  r ON r.id = u.role_id
       WHERE ad.decided_by != v_user_id
         AND r.name = v_role
         AND ad.decided_at >= NOW() - (v_window || ' days')::INTERVAL
         AND ad.is_active = TRUE)
  ) INTO v_kpis;

  -- DEFECT-FIX: contract_id lives on approval_chain (NOT approval_step). Live
  -- chain: approval_step -> approval_chain -> contract.
  SELECT jsonb_build_object(
    'pendingQueue5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'stepId', q.step_id,
          'contractId', q.contract_id,
          'contractNumber', q.contract_number,
          'titleEn', q.title_en,
          'titleAr', q.title_ar,
          'valueAed', q.value_aed,
          'requestedAt', q.requested_at,
          'hoursWaiting', q.hours_waiting
        ) ORDER BY q.requested_at ASC)
        FROM (
          SELECT step.id AS step_id,
                 c.id AS contract_id,
                 c.contract_number,
                 c.title_en,
                 c.title_ar,
                 c.value_aed,
                 step.created_at AS requested_at,
                 ROUND((EXTRACT(EPOCH FROM (NOW() - step.created_at))/3600.0)::NUMERIC, 2) AS hours_waiting
          FROM approval_step step
          JOIN approval_chain ch ON ch.id = step.approval_chain_id AND ch.is_active = TRUE
          JOIN contract c        ON c.id  = ch.contract_id          AND c.is_active = TRUE
          WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
            AND step.status = 'pending'
            AND step.is_active = TRUE
          ORDER BY step.created_at ASC
          LIMIT 5
        ) q
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_approver: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_approver(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_approver(INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (57, 'm6_fix_fn_dashboard_approver_contract_join', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- This fix migration cannot be cleanly reverted to the broken-step.contract_id
-- form because that form fails on first execution. To roll back, apply the
-- 056 ROLLBACK (DROP FUNCTION fn_dashboard_approver) followed by re-applying
-- 056 minus the broken pendingQueue5 reference (or equivalent manual recovery).
BEGIN;
DELETE FROM schema_migrations WHERE version = 57;
COMMIT;
-- ROLLBACK END
