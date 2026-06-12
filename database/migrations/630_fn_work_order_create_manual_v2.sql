-- Migration: 630_fn_work_order_create_manual_v2.sql
-- Module: My Work (M21) — manual create v2 with new field shape
-- Date: 2026-06-12
--
-- The user redesigned the "Add to my queue" modal to ask for exactly 4
-- fields, in this order:
--   1. Request Type     — work_order_type enum (draft_request / returned / comment)
--   2. Request Details  — free text (was instructionNote)
--   3. Requestor        — user_id of the person who asked for the work
--   4. Stage            — not_started (default) / in_progress / completed
--
-- This is a CREATE OR REPLACE on fn_work_order_create_manual (introduced in
-- mig 629), tightening the contract:
--   - assigned_by_user_id = p_data.requestorUserId (was self)
--   - assigned_to_user_id = p_actor_id (drafter, unchanged)
--   - work_order_type now driven by p_data.requestType (was hardcoded
--     'contract_draft_request')
--   - status mapped from p_data.initialStage:
--       not_started → 'open'
--       in_progress → 'in_progress'
--       completed   → 'completed' (+ completed_at = now, completed_by = actor)
--   - counterparty fields no longer required (the FE dropped them)
--
-- Existing fn_work_order_create + fn_work_order_create_draft_request are
-- still untouched. This is the only call path the FE modal hits.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_work_order_create_manual(
  p_data       JSONB,
  p_actor_id   BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id        UUID;
  v_request_type     TEXT;
  v_requestor_id     BIGINT;
  v_instruction      TEXT;
  v_initial_stage    TEXT;
  v_status           TEXT;
  v_completed_at     TIMESTAMPTZ;
  v_completed_by     BIGINT;
  v_payload          JSONB;
  v_id               BIGINT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- Parse + validate input.
  v_request_type   := p_data->>'requestType';
  v_requestor_id   := NULLIF(p_data->>'requestorUserId', '')::bigint;
  v_instruction    := NULLIF(trim(p_data->>'instructionNote'), '');
  v_initial_stage  := COALESCE(p_data->>'initialStage', 'not_started');

  IF v_request_type NOT IN ('contract_draft_request', 'contract_returned', 'comment_response') THEN
    RAISE EXCEPTION 'requestType:Invalid request type %', v_request_type
      USING ERRCODE = '22023';
  END IF;
  IF v_requestor_id IS NULL THEN
    RAISE EXCEPTION 'requestorUserId:Requestor is required' USING ERRCODE = '22023';
  END IF;
  IF v_instruction IS NULL THEN
    RAISE EXCEPTION 'instructionNote:Request details are required'
      USING ERRCODE = '22023';
  END IF;
  IF v_initial_stage NOT IN ('not_started', 'in_progress', 'completed') THEN
    RAISE EXCEPTION 'initialStage:Invalid stage %', v_initial_stage
      USING ERRCODE = '22023';
  END IF;

  -- Sanity-check the requestor exists + is active in this tenant.
  PERFORM 1 FROM public."user"
    WHERE id = v_requestor_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'requestorUserId:Requestor % not found or inactive', v_requestor_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Map stage → status + completion stamps.
  CASE v_initial_stage
    WHEN 'not_started' THEN
      v_status := 'open';
    WHEN 'in_progress' THEN
      v_status := 'in_progress';
    WHEN 'completed' THEN
      v_status       := 'completed';
      v_completed_at := CURRENT_TIMESTAMP;
      v_completed_by := p_actor_id;
  END CASE;

  -- Payload mirrors what the system-generated rows carry so the table
  -- renders both consistently (the FE reads payload.instructionNote).
  v_payload := jsonb_build_object(
    'instructionNote', v_instruction,
    'origin',          'manual'
  );

  INSERT INTO public.work_order (
    tenant_id, work_order_type, status, source,
    source_contract_id, target_contract_id,
    counterparty_id, counterparty_prospect_name,
    assigned_to_user_id, assigned_by_user_id,
    payload, priority, due_at,
    completed_at, completed_by_user_id,
    created_by, updated_by
  ) VALUES (
    v_tenant_id, v_request_type, v_status, 'manual',
    NULL, NULL,
    NULL, NULL,
    p_actor_id, v_requestor_id,                  -- requestor IS the assigned_by
    v_payload, 'normal', NULL,
    v_completed_at, v_completed_by,
    p_actor_id, p_actor_id
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'workOrderId',    v_id,
    'requestType',    v_request_type,
    'requestorUserId', v_requestor_id,
    'initialStage',   v_initial_stage,
    'source',         'manual'
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_create_manual(JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_create_manual(JSONB, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_create_manual(JSONB, BIGINT) IS
  'M21 v2 (mig 630, 2026-06-12) — manual add-to-queue with 4 fields: requestType, instructionNote, requestorUserId, initialStage. Drafter is assigned_to; requestor is assigned_by. Mig 629 superseded by this rewrite.';

-- ─── Sidecar fn: list requestor candidates for the FE dropdown ─────────────

CREATE OR REPLACE FUNCTION public.fn_work_order_requestor_options(
  p_actor_id BIGINT
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
  PERFORM p_actor_id; -- silence unused warning; reserved for future scoping

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',        u.id,
    'firstName', u.first_name,
    'lastName',  u.last_name,
    'email',     u.email,
    'roleName',  r.name
  ) ORDER BY u.first_name, u.last_name), '[]'::jsonb)
    INTO v_result
    FROM public."user" u
    JOIN public.role r ON r.id = u.role_id
   WHERE u.is_active = TRUE;

  RETURN jsonb_build_object('items', v_result);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_requestor_options(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_requestor_options(BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_requestor_options(BIGINT) IS
  'M21 — populates the FE "Requestor" dropdown for the Add to my queue modal. Returns active tenant users with role for context.';

COMMIT;
