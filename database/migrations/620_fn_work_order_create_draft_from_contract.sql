-- Migration: 620_fn_work_order_create_draft_from_contract.sql
-- Module: Work Order Queue (M21)
-- Date: 2026-06-11
--
-- The exec-facing "Request similar contract" flow's core fn. Takes a
-- source (signed/approved) contract + a chosen drafter + an optional
-- counterparty override + optional instruction note, and produces:
--
--   1. A NEW draft contract seeded with the source's body_en/body_ar,
--      contract_type, currency, language, emirate, governing_law, our_party,
--      value (overridable). Inherits source title; drafter can rename in
--      Compose Step 1.
--
--   2. Copies linked clause-extractions from contract_clause_extracted
--      so the drafter's Step 3 drag-and-drop panel pre-populates.
--
--   3. A work_order(type='contract_draft_request', source=source,
--      target=new_draft, assigned=drafter, assigned_by=actor, payload=
--      { instructionNote, sourceContractNumber, counterpartyName }).
--
-- Returns { workOrderId, contractId, contractNumber, targetContractId }.
-- Caller (POST /contracts/:id/request-similar) just relays this to FE.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_work_order_create_draft_from_contract(
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
  v_tenant_id              UUID;
  v_source                 public.contract%ROWTYPE;
  v_drafter                RECORD;
  v_counterparty_id        BIGINT;
  v_counterparty_name      TEXT;
  v_instruction            TEXT;
  v_value_aed              NUMERIC;
  v_new_contract_payload   JSONB;
  v_new_contract           JSONB;
  v_new_contract_id        BIGINT;
  v_new_contract_number    TEXT;
  v_clauses_copied         INTEGER;
  v_work_order_payload     JSONB;
  v_work_order             JSONB;
  v_work_order_id          BIGINT;
BEGIN
  -- ---------- Guards ----------
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;
  IF p_source_contract_id IS NULL OR p_assigned_drafter_id IS NULL OR p_actor_id IS NULL THEN
    RAISE EXCEPTION 'sourceContractId, assignedDrafterId, actorId all required' USING ERRCODE = '22023';
  END IF;

  -- ---------- Source ----------
  SELECT * INTO v_source FROM public.contract WHERE id = p_source_contract_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source contract % not found', p_source_contract_id USING ERRCODE = 'P0002';
  END IF;

  -- ---------- Drafter sanity ----------
  SELECT u.id, u.first_name, u.last_name, r.name AS role_name
  INTO v_drafter
  FROM public."user" u
  JOIN public.role r ON r.id = u.role_id
  WHERE u.id = p_assigned_drafter_id AND u.is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assigned drafter % not found / inactive', p_assigned_drafter_id USING ERRCODE = 'P0002';
  END IF;
  IF v_drafter.role_name <> 'contract_drafter' THEN
    RAISE EXCEPTION 'User % is not a contract_drafter (role=%)', p_assigned_drafter_id, v_drafter.role_name
      USING ERRCODE = '22023';
  END IF;

  -- ---------- Resolve counterparty (override or inherit) ----------
  v_counterparty_id := COALESCE(NULLIF(p_data->>'counterpartyId','')::bigint, v_source.counterparty_id);
  IF v_counterparty_id IS NOT NULL THEN
    SELECT name_en INTO v_counterparty_name FROM public.party WHERE id = v_counterparty_id;
  END IF;

  v_instruction := NULLIF(trim(p_data->>'instructionNote'), '');
  v_value_aed   := NULLIF(p_data->>'valueAed','')::numeric;
  v_value_aed   := COALESCE(v_value_aed, v_source.value_aed);

  -- ---------- Build payload for fn_contract_create ----------
  v_new_contract_payload := jsonb_build_object(
    'titleEn',         v_source.title_en,
    'titleAr',         v_source.title_ar,
    'contractType',    v_source.contract_type,
    'status',          'draft',
    'language',        v_source.language,
    'ourPartyId',      v_source.our_party_id,
    'counterpartyId',  v_counterparty_id,
    'valueAed',        v_value_aed,
    'currency',        v_source.currency,
    'startDate',       NULL,
    'endDate',         NULL,
    'emirate',         v_source.emirate,
    'governingLaw',    v_source.governing_law,
    'bodyEn',          v_source.body_en,
    'bodyAr',          v_source.body_ar,
    'draftedBy',       p_assigned_drafter_id,
    'parentContractId', NULL,
    'tags',            jsonb_build_array('seeded_from_' || v_source.contract_number)
  );

  -- ---------- Create the seeded draft ----------
  -- Use the exec as actor so audit log captures who initiated; drafted_by
  -- is set explicitly in payload to the chosen drafter.
  v_new_contract := public.fn_contract_create(v_new_contract_payload, p_actor_id);
  v_new_contract_id     := (v_new_contract->>'id')::bigint;
  v_new_contract_number := v_new_contract->>'contractNumber';

  -- ---------- Copy clause extractions ----------
  -- Replicates the drag-and-drop clause panel in Step 3 of Compose.
  INSERT INTO public.contract_clause_extracted (
    tenant_id, contract_id, clause_type_v2, parameters, text_excerpts,
    confidence, summary_en, summary_ar, review_status,
    extraction_model_version, extraction_prompt_hash,
    data_classification, created_at, created_by, updated_at, updated_by, is_active
  )
  SELECT
    tenant_id, v_new_contract_id, clause_type_v2, parameters, text_excerpts,
    confidence, summary_en, summary_ar, 'inherited',
    extraction_model_version, extraction_prompt_hash,
    data_classification, now(), p_actor_id, now(), p_actor_id, TRUE
  FROM public.contract_clause_extracted
  WHERE contract_id = p_source_contract_id
    AND is_active = TRUE;

  GET DIAGNOSTICS v_clauses_copied = ROW_COUNT;

  -- ---------- Build the work_order payload ----------
  v_work_order_payload := jsonb_build_object(
    'sourceContractNumber', v_source.contract_number,
    'sourceTitleEn',        v_source.title_en,
    'counterpartyName',     v_counterparty_name,
    'instructionNote',      v_instruction,
    'valueAed',             v_value_aed,
    'clausesInherited',     v_clauses_copied
  );

  -- ---------- Create the work_order ----------
  v_work_order := public.fn_work_order_create(
    jsonb_build_object(
      'workOrderType',     'contract_draft_request',
      'assignedToUserId',  p_assigned_drafter_id,
      'sourceContractId',  p_source_contract_id,
      'targetContractId',  v_new_contract_id,
      'priority',          COALESCE(p_data->>'priority','normal'),
      'dueAt',             NULLIF(p_data->>'dueAt','')::timestamptz,
      'payload',           v_work_order_payload
    ),
    p_actor_id
  );

  v_work_order_id := (v_work_order->>'id')::bigint;

  RETURN jsonb_build_object(
    'workOrderId',     v_work_order_id,
    'contractId',      v_new_contract_id,
    'contractNumber',  v_new_contract_number,
    'targetContractId', v_new_contract_id,
    'clausesInherited', v_clauses_copied,
    'assignedDrafter', jsonb_build_object(
      'id',   v_drafter.id,
      'name', trim(concat(v_drafter.first_name,' ',v_drafter.last_name))
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_create_draft_from_contract(BIGINT, BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_create_draft_from_contract(BIGINT, BIGINT, BIGINT, JSONB) TO neondb_owner;

-- ==================================================================
-- Companion: fn_work_order_assignable_drafters
--   Lists active contract_drafter users for the exec's dropdown,
--   each annotated with open work-order count (so the exec can pick
--   the least-loaded drafter).
-- ==================================================================
CREATE OR REPLACE FUNCTION public.fn_work_order_assignable_drafters(
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_rows      JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',              u.id,
    'email',           u.email,
    'firstName',       u.first_name,
    'lastName',        u.last_name,
    'fullName',        trim(concat(u.first_name,' ',u.last_name)),
    'openWorkOrders',  COALESCE(wo.cnt, 0)
  ) ORDER BY u.first_name, u.last_name), '[]'::jsonb)
  INTO v_rows
  FROM public."user" u
  JOIN public.role r ON r.id = u.role_id
  LEFT JOIN (
    SELECT assigned_to_user_id, count(*) AS cnt
    FROM public.work_order
    WHERE tenant_id = v_tenant_id
      AND status IN ('open','in_progress')
      AND is_active = TRUE
    GROUP BY assigned_to_user_id
  ) wo ON wo.assigned_to_user_id = u.id
  WHERE r.name = 'contract_drafter'
    AND u.is_active = TRUE;

  RETURN jsonb_build_object('data', v_rows);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_assignable_drafters(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_assignable_drafters(BIGINT) TO neondb_owner;

COMMIT;
