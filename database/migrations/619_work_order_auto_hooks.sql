-- Migration: 619_work_order_auto_hooks.sql
-- Module: Work Order Queue (M21)
-- Date: 2026-06-11
--
-- Auto-populate work_order from existing domain events. Triggers rather
-- than fn-body extensions keep the existing fn_approval_decide / fn_
-- contract_comment_create / fn_contract_status_update_* unchanged.
--
-- Triggers added:
--
--   1. trg_work_order_on_contract_status — AFTER UPDATE ON contract
--      a) status moves TO 'resubmission_requested'
--         → INSERT work_order(type='contract_returned', assigned=drafter)
--      b) status moves OUT of {draft, resubmission_requested} TO
--         {in_approval, approved, fully_signed, active}
--         → mark every open work_order whose target is this contract
--           as 'completed' (the drafter handed it off; their queue clears)
--
--   2. trg_work_order_on_comment — AFTER INSERT ON contract_comment
--      Comment by anyone OTHER than the drafter, and contract has a
--      drafter set → INSERT work_order(type='comment_response',
--      assigned=drafter). Idempotency: no per-comment dedup needed since
--      each comment is its own discrete item.

BEGIN;

-- ==================================================================
-- 1. Helper: insert a work_order if no equivalent open one exists.
--    Idempotency guard for status transitions. Comment events skip this
--    (one work_order per comment is desired).
-- ==================================================================
CREATE OR REPLACE FUNCTION public.fn_work_order_auto_insert(
  p_type             TEXT,
  p_target_contract  BIGINT,
  p_source_contract  BIGINT,
  p_assigned_to      BIGINT,
  p_assigned_by      BIGINT,
  p_related_step_id  BIGINT,
  p_related_comment  BIGINT,
  p_payload          JSONB,
  p_dedup            BOOLEAN DEFAULT TRUE
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant UUID;
  v_id     BIGINT;
BEGIN
  v_tenant := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant IS NULL OR p_assigned_to IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_dedup THEN
    SELECT id INTO v_id
    FROM public.work_order
    WHERE tenant_id = v_tenant
      AND work_order_type = p_type
      AND target_contract_id IS NOT DISTINCT FROM p_target_contract
      AND assigned_to_user_id = p_assigned_to
      AND status IN ('open','in_progress')
      AND is_active = TRUE
    LIMIT 1;
    IF v_id IS NOT NULL THEN
      RETURN v_id;
    END IF;
  END IF;

  INSERT INTO public.work_order (
    tenant_id, work_order_type, status,
    source_contract_id, target_contract_id,
    assigned_to_user_id, assigned_by_user_id,
    related_comment_id, related_approval_step_id,
    payload, priority,
    created_by, updated_by
  ) VALUES (
    v_tenant, p_type, 'open',
    p_source_contract, p_target_contract,
    p_assigned_to, p_assigned_by,
    p_related_comment, p_related_step_id,
    COALESCE(p_payload, '{}'::jsonb),
    CASE WHEN p_type = 'contract_returned' THEN 'high' ELSE 'normal' END,
    p_assigned_by, p_assigned_by
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_auto_insert(TEXT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, JSONB, BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_auto_insert(TEXT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, JSONB, BOOLEAN) TO neondb_owner;

-- ==================================================================
-- 2. Trigger fn: on contract status change
-- ==================================================================
CREATE OR REPLACE FUNCTION public.fn_trg_work_order_on_contract_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_step       RECORD;
  v_payload    JSONB;
  v_actor      BIGINT;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- Resolve actor — current user GUC if set, else updated_by, else NULL
  BEGIN
    v_actor := NULLIF(current_setting('app.current_user_id', true),'')::bigint;
  EXCEPTION WHEN OTHERS THEN
    v_actor := NULL;
  END;
  v_actor := COALESCE(v_actor, NEW.updated_by);

  -- (a) Status → resubmission_requested : create contract_returned work order
  IF NEW.status = 'resubmission_requested' AND NEW.drafted_by IS NOT NULL THEN
    -- Find the most recent rejected step (if any) for context
    SELECT ast.id AS step_id,
           ast.decision_note,
           u.id AS approver_id,
           trim(concat(u.first_name,' ',u.last_name)) AS approver_name
    INTO v_step
    FROM public.approval_step ast
    JOIN public.approval_chain ac ON ac.id = ast.chain_id
    LEFT JOIN public."user" u ON u.id = ast.decided_by_user_id
    WHERE ac.contract_id = NEW.id
      AND ast.decision IN ('reject','resubmission_requested')
      AND ast.decided_at IS NOT NULL
    ORDER BY ast.decided_at DESC
    LIMIT 1;

    v_payload := jsonb_build_object(
      'sourceContractNumber', NEW.contract_number,
      'fromApproverName',     v_step.approver_name,
      'decisionNote',         v_step.decision_note
    );

    PERFORM public.fn_work_order_auto_insert(
      'contract_returned',
      NEW.id,                -- target = same contract
      NEW.id,                -- source = same contract
      NEW.drafted_by,        -- assignee = drafter
      COALESCE(v_step.approver_id, v_actor),
      v_step.step_id,
      NULL,
      v_payload,
      TRUE                   -- dedup: one open returned wo per contract
    );
  END IF;

  -- (b) Status moves OUT of work-in-progress → auto-complete open work
  --     orders whose target is this contract. The drafter handed it off.
  IF OLD.status IN ('draft','resubmission_requested')
     AND NEW.status NOT IN ('draft','resubmission_requested')
  THEN
    UPDATE public.work_order
       SET status               = 'completed',
           completed_at         = now(),
           completed_by_user_id = v_actor,
           updated_at           = now(),
           updated_by           = v_actor
     WHERE tenant_id = current_setting('app.current_tenant_id', true)::uuid
       AND target_contract_id = NEW.id
       AND status IN ('open','in_progress')
       AND is_active = TRUE
       AND work_order_type IN ('contract_draft_request','contract_returned','comment_response');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_work_order_on_contract_status ON public.contract;
CREATE TRIGGER trg_work_order_on_contract_status
  AFTER UPDATE OF status ON public.contract
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_trg_work_order_on_contract_status();

-- ==================================================================
-- 3. Trigger fn: on contract_comment insert
-- ==================================================================
CREATE OR REPLACE FUNCTION public.fn_trg_work_order_on_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contract    public.contract%ROWTYPE;
  v_author_name TEXT;
  v_payload     JSONB;
  v_excerpt     TEXT;
BEGIN
  -- Skip soft-deleted / inactive
  IF NEW.is_active = FALSE THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_contract FROM public.contract WHERE id = NEW.contract_id;
  IF NOT FOUND OR v_contract.drafted_by IS NULL THEN
    RETURN NEW;
  END IF;

  -- Skip when commenter IS the drafter (the existing fan-out then targets
  -- the next approver via Approvals module — work_order not needed).
  IF NEW.created_by = v_contract.drafted_by THEN
    RETURN NEW;
  END IF;

  -- Skip when contract is not in an active workflow status (no point asking
  -- the drafter to respond to a comment on a fully-signed contract).
  IF v_contract.status NOT IN ('draft','in_approval','resubmission_requested') THEN
    RETURN NEW;
  END IF;

  SELECT trim(concat(u.first_name,' ',u.last_name))
    INTO v_author_name
  FROM public."user" u WHERE u.id = NEW.created_by;

  v_excerpt := left(COALESCE(NEW.body, ''), 240);

  v_payload := jsonb_build_object(
    'commentExcerpt',  v_excerpt,
    'authorName',      v_author_name,
    'sourceContractNumber', v_contract.contract_number
  );

  PERFORM public.fn_work_order_auto_insert(
    'comment_response',
    NEW.contract_id,    -- target = contract the comment lives on
    NEW.contract_id,    -- source = same
    v_contract.drafted_by,
    NEW.created_by,
    NULL,
    NEW.id,
    v_payload,
    FALSE               -- no dedup: each comment is its own item
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_work_order_on_comment ON public.contract_comment;
CREATE TRIGGER trg_work_order_on_comment
  AFTER INSERT ON public.contract_comment
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_trg_work_order_on_comment();

COMMIT;
