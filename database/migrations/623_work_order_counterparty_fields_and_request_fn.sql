-- Migration: 623_work_order_counterparty_fields_and_request_fn.sql
-- Module: Work Order Queue (M21) — architectural pivot
-- Date: 2026-06-11
--
-- V1 (mig 620/621) auto-created a duplicate contract at request time. The
-- correct flow: exec submits a request → ONLY a work_order row exists →
-- drafter composes from the source contract via the wizard → the new
-- contract is created only when the drafter submits for approval.
--
-- This migration:
--   1. Adds counterparty_id (existing party FK) + counterparty_prospect_name
--      (free-text new prospect) to work_order. Exec picks one at request time.
--   2. Drops fn_work_order_create_draft_from_contract (V1 auto-create logic).
--   3. Adds fn_work_order_create_draft_request — just creates the work_order
--      row; no contract.
--   4. Adds fn_work_order_link_target — called by compose-submit to attach
--      the newly-created contract to the work_order so the existing trigger
--      hook auto-completes it on first submit-for-approval.
--
-- Cleanup of the V1 dup row (contract 703 + work_order 1) is mig 625.

BEGIN;

-- ============================================================
-- 1. Schema changes
-- ============================================================
ALTER TABLE public.work_order
  ADD COLUMN IF NOT EXISTS counterparty_id BIGINT REFERENCES public.party(id),
  ADD COLUMN IF NOT EXISTS counterparty_prospect_name TEXT;

COMMENT ON COLUMN public.work_order.counterparty_id IS
  'Existing party the exec chose for the draft request, if any. Mutually inclusive with counterparty_prospect_name (one or the other).';
COMMENT ON COLUMN public.work_order.counterparty_prospect_name IS
  'Free-text prospect name when the exec is requesting a draft for a not-yet-onboarded party. Drafter creates the party in compose if needed.';

-- ============================================================
-- 2. Drop V1 fn
-- ============================================================
DROP FUNCTION IF EXISTS public.fn_work_order_create_draft_from_contract(BIGINT, BIGINT, BIGINT, JSONB);

-- ============================================================
-- 3. fn_work_order_create_draft_request — no contract creation
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_work_order_create_draft_request(
  p_source_contract_id  BIGINT,
  p_assigned_drafter_id BIGINT,
  p_actor_id            BIGINT,
  p_data                JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id            UUID;
  v_source               public.contract%ROWTYPE;
  v_drafter              RECORD;
  v_counterparty_id      BIGINT;
  v_counterparty_label   TEXT;
  v_prospect_name        TEXT;
  v_instruction          TEXT;
  v_value_aed            NUMERIC;
  v_priority             TEXT;
  v_due_at               TIMESTAMPTZ;
  v_payload              JSONB;
  v_id                   BIGINT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;
  IF p_source_contract_id IS NULL OR p_assigned_drafter_id IS NULL OR p_actor_id IS NULL THEN
    RAISE EXCEPTION 'sourceContractId, assignedDrafterId, actorId all required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_source FROM public.contract WHERE id = p_source_contract_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source contract % not found', p_source_contract_id USING ERRCODE = 'P0002';
  END IF;

  SELECT u.id, u.first_name, u.last_name, u.email, r.name AS role_name
  INTO v_drafter
  FROM public."user" u JOIN public.role r ON r.id = u.role_id
  WHERE u.id = p_assigned_drafter_id AND u.is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assigned drafter % not found / inactive', p_assigned_drafter_id USING ERRCODE = 'P0002';
  END IF;
  IF v_drafter.role_name <> 'contract_drafter' THEN
    RAISE EXCEPTION 'User % is not a contract_drafter (role=%)', p_assigned_drafter_id, v_drafter.role_name
      USING ERRCODE = '22023';
  END IF;

  -- Counterparty resolution: prefer explicit existing-party choice; else
  -- accept free-text prospect name; else inherit from the source contract.
  v_counterparty_id := NULLIF(p_data->>'counterpartyId','')::bigint;
  v_prospect_name   := NULLIF(trim(p_data->>'counterpartyProspectName'),'');

  IF v_counterparty_id IS NULL AND v_prospect_name IS NULL THEN
    -- Soft fallback: inherit source counterparty so we always have a label
    v_counterparty_id := v_source.counterparty_id;
  END IF;

  IF v_counterparty_id IS NOT NULL THEN
    SELECT name_en INTO v_counterparty_label FROM public.party WHERE id = v_counterparty_id;
  ELSE
    v_counterparty_label := v_prospect_name;
  END IF;

  v_instruction := NULLIF(trim(p_data->>'instructionNote'), '');
  v_value_aed   := NULLIF(p_data->>'valueAed','')::numeric;
  v_priority    := COALESCE(p_data->>'priority','normal');
  v_due_at      := NULLIF(p_data->>'dueAt','')::timestamptz;

  v_payload := jsonb_build_object(
    'sourceContractNumber', v_source.contract_number,
    'sourceTitleEn',        v_source.title_en,
    'sourceContractType',   v_source.contract_type,
    'counterpartyName',     v_counterparty_label,
    'instructionNote',      v_instruction,
    'valueAed',             v_value_aed
  );

  INSERT INTO public.work_order (
    tenant_id, work_order_type, status,
    source_contract_id, target_contract_id,
    counterparty_id, counterparty_prospect_name,
    assigned_to_user_id, assigned_by_user_id,
    payload, priority, due_at,
    created_by, updated_by
  )
  VALUES (
    v_tenant_id, 'contract_draft_request', 'open',
    p_source_contract_id, NULL,
    v_counterparty_id, v_prospect_name,
    p_assigned_drafter_id, p_actor_id,
    v_payload, v_priority, v_due_at,
    p_actor_id, p_actor_id
  )
  RETURNING id INTO v_id;

  -- Notification fan-out — dispatcher reads the work_order.assigned event
  -- type + the role-targeted audience defined in the rule (mig 626).
  PERFORM public.fn_notification_dispatch(
    p_actor_id,
    'work_order.assigned',
    jsonb_build_object(
      'workOrderId',          v_id,
      'sourceContractNumber', v_source.contract_number,
      'sourceTitleEn',        v_source.title_en,
      'counterpartyName',     v_counterparty_label,
      'instructionNote',      v_instruction,
      'assignedToUserId',     p_assigned_drafter_id,
      'assignedToUserEmail',  v_drafter.email,
      'assignedToName',       trim(concat(v_drafter.first_name,' ',v_drafter.last_name)),
      'assignedByUserId',     p_actor_id
    ),
    'in_app',
    v_priority,
    p_actor_id,
    NULL
  );

  RETURN jsonb_build_object(
    'workOrderId',     v_id,
    'sourceContractId', p_source_contract_id,
    'sourceContractNumber', v_source.contract_number,
    'counterpartyName', v_counterparty_label,
    'assignedDrafter', jsonb_build_object(
      'id',   v_drafter.id,
      'name', trim(concat(v_drafter.first_name,' ',v_drafter.last_name))
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_create_draft_request(BIGINT, BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_create_draft_request(BIGINT, BIGINT, BIGINT, JSONB) TO neondb_owner;

-- ============================================================
-- 4. fn_work_order_link_target — set target_contract_id post-compose
-- ============================================================
-- Called by the BE compose-submit handler immediately after the new
-- contract is created. Stamps target_contract_id + marks status
-- 'in_progress'. Once the drafter submits the contract for approval, the
-- existing trg_work_order_on_contract_status trigger (mig 619) auto-
-- completes the work_order on the draft → in_approval transition.
CREATE OR REPLACE FUNCTION public.fn_work_order_link_target(
  p_work_order_id BIGINT,
  p_contract_id   BIGINT,
  p_actor_id      BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_row       public.work_order%ROWTYPE;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  SELECT * INTO v_row FROM public.work_order
   WHERE id = p_work_order_id AND tenant_id = v_tenant_id AND is_active = TRUE
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work order % not found', p_work_order_id USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.work_order
     SET target_contract_id = p_contract_id,
         status             = CASE WHEN status = 'open' THEN 'in_progress' ELSE status END,
         updated_at         = now(),
         updated_by         = p_actor_id
   WHERE id = p_work_order_id;

  RETURN jsonb_build_object(
    'id', p_work_order_id,
    'targetContractId', p_contract_id,
    'status', 'in_progress'
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_link_target(BIGINT, BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_link_target(BIGINT, BIGINT, BIGINT) TO neondb_owner;

COMMIT;
