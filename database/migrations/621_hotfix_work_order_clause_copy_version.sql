-- Migration: 621_hotfix_work_order_clause_copy_version.sql
-- Module: Work Order Queue (M21) — hotfix
-- Date: 2026-06-11
--
-- Mig 620 copies contract_clause_extracted rows from source → new draft
-- but failed to set contract_version_id, which is NOT NULL on that table.
-- Result: ERROR P0001 / NOT NULL violation, fn rolled back, work order
-- never persisted.
--
-- Fix: look up the new contract's initial version (created by
-- fn_contract_create's insert chain) and stamp that on every copied row.

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
  v_new_version_id         BIGINT;
  v_clauses_copied         INTEGER;
  v_work_order_payload     JSONB;
  v_work_order             JSONB;
  v_work_order_id          BIGINT;
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

  SELECT u.id, u.first_name, u.last_name, r.name AS role_name
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

  v_counterparty_id := COALESCE(NULLIF(p_data->>'counterpartyId','')::bigint, v_source.counterparty_id);
  IF v_counterparty_id IS NOT NULL THEN
    SELECT name_en INTO v_counterparty_name FROM public.party WHERE id = v_counterparty_id;
  END IF;
  v_instruction := NULLIF(trim(p_data->>'instructionNote'), '');
  v_value_aed   := COALESCE(NULLIF(p_data->>'valueAed','')::numeric, v_source.value_aed);

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

  v_new_contract := public.fn_contract_create(v_new_contract_payload, p_actor_id);
  v_new_contract_id     := (v_new_contract->>'id')::bigint;
  v_new_contract_number := v_new_contract->>'contractNumber';

  -- Pick up the initial contract_version row created by fn_contract_create
  -- (auto-snapshot of body_en/body_ar -> contract_version). Required for
  -- contract_clause_extracted.contract_version_id NOT NULL constraint.
  SELECT id INTO v_new_version_id
  FROM public.contract_version
  WHERE contract_id = v_new_contract_id
  ORDER BY version_number DESC, id DESC
  LIMIT 1;

  -- Copy clause extractions across, scoped to the new contract's first
  -- version. Skipped silently if the source had none.
  IF v_new_version_id IS NOT NULL THEN
    INSERT INTO public.contract_clause_extracted (
      tenant_id, contract_id, contract_version_id,
      clause_type_v2, parameters, text_excerpts,
      confidence, summary_en, summary_ar, review_status,
      extraction_model_version, extraction_prompt_hash,
      data_classification, created_at, created_by, updated_at, updated_by, is_active
    )
    SELECT
      tenant_id, v_new_contract_id, v_new_version_id,
      clause_type_v2, parameters, text_excerpts,
      confidence, summary_en, summary_ar, 'inherited',
      extraction_model_version, extraction_prompt_hash,
      data_classification, now(), p_actor_id, now(), p_actor_id, TRUE
    FROM public.contract_clause_extracted
    WHERE contract_id = p_source_contract_id
      AND is_active = TRUE;
    GET DIAGNOSTICS v_clauses_copied = ROW_COUNT;
  ELSE
    v_clauses_copied := 0;
  END IF;

  v_work_order_payload := jsonb_build_object(
    'sourceContractNumber', v_source.contract_number,
    'sourceTitleEn',        v_source.title_en,
    'counterpartyName',     v_counterparty_name,
    'instructionNote',      v_instruction,
    'valueAed',             v_value_aed,
    'clausesInherited',     v_clauses_copied
  );

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

COMMIT;
