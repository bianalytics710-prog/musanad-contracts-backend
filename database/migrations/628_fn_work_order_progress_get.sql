-- Migration: 628_fn_work_order_progress_get.sql
-- Module: My Work redesign (M21) — sidecar progress fn
-- Date: 2026-06-12
--
-- Adds fn_work_order_progress_get(p_user_id BIGINT) returning per-work-order
-- progress enrichment that the existing fn_work_order_list_for_user doesn't
-- carry (specifically the current approver name(s) when the linked target
-- contract is awaiting approval). The existing fn already returns
-- targetContractStatus + counterpartyName + source/target numbers — those
-- are enough to derive the Stage label client-side. This sidecar exists
-- ONLY to surface the human "Awaiting Layla Al Marri" detail.
--
-- Sidecar pattern (precedent: mig 560 high-risk, mig 488 expiring value_aed)
-- — keeps the canonical fn_work_order_list_for_user untouched so the
-- existing /work-orders endpoint + sidebar badge are bit-for-bit unchanged.
--
-- Permission reuses work.read.assigned — anyone who can read their queue
-- can read the matching progress data.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_work_order_progress_get(
  p_user_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_result    JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- For every work_order assigned to p_user_id with a target contract that
  -- has an in-progress approval chain, gather the role names + user display
  -- names of the currently-pending step(s). Parallel-group approvers are
  -- aggregated into an array so the FE can render "Awaiting Layla + Khalid".
  --
  -- We deliberately scope to is_active = TRUE on all tables. Cancelled or
  -- soft-deleted rows would otherwise produce stale "Awaiting X" labels.
  WITH wo AS (
    SELECT id AS work_order_id, target_contract_id
      FROM public.work_order
     WHERE assigned_to_user_id = p_user_id
       AND tenant_id           = v_tenant_id
       AND is_active           = TRUE
       AND target_contract_id IS NOT NULL
  ),
  chain AS (
    SELECT wo.work_order_id,
           ac.id                 AS chain_id,
           ac.current_step_order AS step_order
      FROM wo
      JOIN public.approval_chain ac
        ON ac.contract_id = wo.target_contract_id
       AND ac.status      = 'in_progress'
       AND ac.is_active   = TRUE
  ),
  step AS (
    SELECT c.work_order_id,
           ast.approver_role,
           ast.approver_user_id
      FROM chain c
      JOIN public.approval_step ast
        ON ast.approval_chain_id = c.chain_id
       AND ast.step_order        = c.step_order
       AND ast.status            = 'pending'
       AND ast.is_active         = TRUE
  ),
  named AS (
    SELECT s.work_order_id,
           -- Prefer the explicitly-assigned approver's name; fall back to a
           -- human-readable role label so the FE can show
           -- "Awaiting Legal Counsel" when the role has no specific user yet.
           COALESCE(
             NULLIF(trim(concat_ws(' ', u.first_name, u.last_name)), ''),
             initcap(replace(s.approver_role, '_', ' '))
           ) AS approver_name
      FROM step s
      LEFT JOIN public."user" u
        ON u.id = s.approver_user_id
       AND u.is_active = TRUE
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'workOrderId',          n.work_order_id,
    'currentApproverNames', n.names
  )), '[]'::jsonb)
    INTO v_result
    FROM (
      SELECT work_order_id,
             jsonb_agg(DISTINCT approver_name ORDER BY approver_name) AS names
        FROM named
       GROUP BY work_order_id
    ) n;

  RETURN jsonb_build_object('items', v_result);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_progress_get(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_progress_get(BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_progress_get(BIGINT) IS
  'M21 My Work table — sidecar: returns currentApproverNames per work order so the FE Stage column can render "Awaiting <name>" when the target contract is in_approval. Existing fn_work_order_list_for_user is intentionally untouched.';

COMMIT;
