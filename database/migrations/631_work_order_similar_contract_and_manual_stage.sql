-- Migration: 631_work_order_similar_contract_and_manual_stage.sql
-- Module: My Work (M21)
-- Date: 2026-06-12
--
-- Two enhancements, both surfaced on the drafter's "Add to my queue" modal
-- and on the My Work table.
--
-- A) Similar contract on manual add:
--    The drafter can optionally name an existing contract to replicate when
--    request type = contract_draft_request. If they confirm a match, that
--    contract id is stored in work_order.source_contract_id, which the
--    existing Compose wizard already keys off (?fromWorkOrder=N → fetch wo
--    → extract-from-source on wo.sourceContractId). Without a similar
--    contract, source_contract_id stays NULL and the wizard falls back to
--    the regular template-picker entry point.
--
-- B) Drafter-editable Stage column:
--    The Stage column on My Work currently derives a single label from
--    (wo.status, target_contract.status). When the drafter wants to override
--    that derivation — e.g. the contract is genuinely in approval but the
--    drafter is treating it as completed in their own workflow, or a manual
--    row needs to move from "Not started" → "Drafting" without yet having a
--    contract — they pick a value from a small dropdown. We persist it in
--    work_order.manual_stage; the FE uses (manual_stage ?? derivedStage) so
--    the override is the single effective value across filters + sorting.
--
-- Architecture notes:
--   - We extend fn_work_order_create_manual (already rewritten today in
--     mig 630) to accept p_data.sourceContractId. Sidecar wrapper would be
--     more "untouched", but the insert needs to know about the FK at write
--     time, so a CREATE OR REPLACE is cleaner. The signature stays the same.
--   - fn_work_order_contract_lookup is a true sidecar: read-only, takes a
--     contract number, returns the lookup row or empty. RLS-scoped through
--     the app.current_tenant_id GUC, same pattern as every other fn.
--   - fn_work_order_stage_set is RBAC-gated: only the assigned drafter can
--     change their own row's stage. RAISE if anyone else tries.

BEGIN;

-- ============================================================
-- 1. Schema: work_order.manual_stage
-- ============================================================
ALTER TABLE public.work_order
  ADD COLUMN IF NOT EXISTS manual_stage TEXT
    CHECK (manual_stage IS NULL OR manual_stage IN (
      'not_started',
      'draft_in_progress',
      'awaiting_approval',
      'returned',
      'completed'
    ));

COMMENT ON COLUMN public.work_order.manual_stage IS
  'M21 2026-06-12 (mig 631) — drafter-set override for the Stage column on My Work. When NULL, FE derives the stage from (work_order.status, target_contract.status). When set, FE uses this value as the effective stage. Only the assigned drafter can set it via fn_work_order_stage_set.';

-- ============================================================
-- 2. fn_work_order_create_manual — accept optional sourceContractId
-- ============================================================
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
  v_tenant_id          UUID;
  v_request_type       TEXT;
  v_requestor_id       BIGINT;
  v_instruction        TEXT;
  v_initial_stage      TEXT;
  v_source_contract_id BIGINT;
  v_status             TEXT;
  v_completed_at       TIMESTAMPTZ;
  v_completed_by       BIGINT;
  v_payload            JSONB;
  v_id                 BIGINT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- Parse + validate input.
  v_request_type       := p_data->>'requestType';
  v_requestor_id       := NULLIF(p_data->>'requestorUserId', '')::bigint;
  v_instruction        := NULLIF(trim(p_data->>'instructionNote'), '');
  v_initial_stage      := COALESCE(p_data->>'initialStage', 'not_started');
  v_source_contract_id := NULLIF(p_data->>'sourceContractId', '')::bigint;

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

  -- If sourceContractId is supplied, verify it exists in the tenant. RLS on
  -- contract enforces the tenant boundary, so a row visible here is one the
  -- caller can replicate.
  IF v_source_contract_id IS NOT NULL THEN
    PERFORM 1 FROM public.contract WHERE id = v_source_contract_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'sourceContractId:Contract % not found in this tenant', v_source_contract_id
        USING ERRCODE = 'P0002';
    END IF;
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
    v_source_contract_id, NULL,
    NULL, NULL,
    p_actor_id, v_requestor_id,
    v_payload, 'normal', NULL,
    v_completed_at, v_completed_by,
    p_actor_id, p_actor_id
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'workOrderId',     v_id,
    'requestType',     v_request_type,
    'requestorUserId', v_requestor_id,
    'initialStage',    v_initial_stage,
    'sourceContractId', v_source_contract_id,
    'source',          'manual'
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_create_manual(JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_create_manual(JSONB, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_create_manual(JSONB, BIGINT) IS
  'M21 v3 (mig 631, 2026-06-12) — manual add-to-queue with optional sourceContractId. When provided + visible in tenant, stored on work_order.source_contract_id so the Compose wizard can extract-from-source on Compose-draft. Supersedes mig 630.';

-- ============================================================
-- 3. fn_work_order_contract_lookup — sidecar for the modal
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_work_order_contract_lookup(
  p_actor_id        BIGINT,
  p_contract_number TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_normalised TEXT;
  v_row        JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;
  PERFORM p_actor_id;

  v_normalised := NULLIF(trim(upper(p_contract_number)), '');
  IF v_normalised IS NULL THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  SELECT jsonb_build_object(
    'found',           true,
    'id',              c.id,
    'contractNumber',  c.contract_number,
    'titleEn',         c.title_en,
    'titleAr',         c.title_ar,
    'contractType',    c.contract_type,
    'counterpartyName', cp.name_en
  )
    INTO v_row
    FROM public.contract c
    LEFT JOIN public.party cp ON cp.id = c.counterparty_id
   WHERE upper(c.contract_number) = v_normalised
   LIMIT 1;

  IF v_row IS NULL THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_contract_lookup(BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_contract_lookup(BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_contract_lookup(BIGINT, TEXT) IS
  'M21 (mig 631) — sidecar for "Add to my queue" Similar contract field. Looks up a contract by number within the actor''s tenant (RLS-scoped). Returns {found: true/false, id, contractNumber, titleEn, titleAr, contractType, counterpartyName} so the FE can render a confirmation card before storing the FK.';

-- ============================================================
-- 4. fn_work_order_stage_set — RBAC-gated stage override
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_work_order_stage_set(
  p_wo_id     BIGINT,
  p_stage     TEXT,       -- NULL or one of the 5 effective stage codes
  p_actor_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_assigned  BIGINT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  IF p_stage IS NOT NULL AND p_stage NOT IN (
    'not_started', 'draft_in_progress', 'awaiting_approval', 'returned', 'completed'
  ) THEN
    RAISE EXCEPTION 'stage:Invalid stage %', p_stage USING ERRCODE = '22023';
  END IF;

  SELECT assigned_to_user_id INTO v_assigned
    FROM public.work_order
   WHERE id = p_wo_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'workOrderId:Work order % not found', p_wo_id USING ERRCODE = 'P0002';
  END IF;
  IF v_assigned IS DISTINCT FROM p_actor_id THEN
    RAISE EXCEPTION 'forbidden:Only the assigned drafter can change stage'
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.work_order
     SET manual_stage = p_stage,
         updated_at   = CURRENT_TIMESTAMP,
         updated_by   = p_actor_id
   WHERE id = p_wo_id;

  RETURN jsonb_build_object(
    'workOrderId', p_wo_id,
    'manualStage', p_stage
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_stage_set(BIGINT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_stage_set(BIGINT, TEXT, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_stage_set(BIGINT, TEXT, BIGINT) IS
  'M21 (mig 631) — sets work_order.manual_stage override. RBAC: only the assigned drafter (assigned_to_user_id) can change their own row. Pass NULL to clear. The FE uses (manual_stage ?? derivedStage) as the effective Stage column value.';

-- ============================================================
-- 5. Extend fn_work_order_list_for_user to surface manual_stage
-- ============================================================
-- The existing fn (mig 618) returns a JSONB array. We re-create with
-- manualStage added to the row shape. Signature unchanged so all call sites
-- + tests are stable. Body is a near-verbatim copy of the mig-618 fn with
-- one new key.

CREATE OR REPLACE FUNCTION public.fn_work_order_list_for_user(
  p_user_id        BIGINT,
  p_status_filter  TEXT[] DEFAULT ARRAY['open','in_progress'],
  p_type_filter    TEXT[] DEFAULT NULL,
  p_limit          INTEGER DEFAULT 100
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_total     INTEGER;
  v_open      INTEGER;
  v_rows      JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  SELECT count(*) INTO v_total
  FROM public.work_order wo
  WHERE wo.tenant_id = v_tenant_id
    AND wo.assigned_to_user_id = p_user_id
    AND wo.is_active = TRUE
    AND (p_status_filter IS NULL OR wo.status = ANY(p_status_filter))
    AND (p_type_filter   IS NULL OR wo.work_order_type = ANY(p_type_filter));

  SELECT count(*) INTO v_open
  FROM public.work_order wo
  WHERE wo.tenant_id = v_tenant_id
    AND wo.assigned_to_user_id = p_user_id
    AND wo.is_active = TRUE
    AND wo.status IN ('open','in_progress');

  SELECT COALESCE(jsonb_agg(row_obj ORDER BY (row_obj->>'createdAt') DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'id',                  wo.id,
      'workOrderType',       wo.work_order_type,
      'status',              wo.status,
      'priority',            wo.priority,
      'sourceContractId',    wo.source_contract_id,
      'sourceContractNumber', src.contract_number,
      'sourceContractTitleEn', src.title_en,
      'sourceContractTitleAr', src.title_ar,
      'targetContractId',    wo.target_contract_id,
      'targetContractNumber', tgt.contract_number,
      'targetContractTitleEn', tgt.title_en,
      'targetContractTitleAr', tgt.title_ar,
      'targetContractStatus', tgt.status,
      'counterpartyName',    COALESCE(cp_tgt.name_en, cp_src.name_en),
      'assignedByUserId',    wo.assigned_by_user_id,
      'assignedByName',      CASE
        WHEN assignor.id IS NULL THEN NULL
        ELSE trim(concat(assignor.first_name,' ',assignor.last_name))
      END,
      'payload',             wo.payload,
      'relatedCommentId',    wo.related_comment_id,
      'manualStage',         wo.manual_stage,
      'createdAt',           wo.created_at,
      'completedAt',         wo.completed_at,
      'dueAt',               wo.due_at,
      'ageDays',             EXTRACT(EPOCH FROM (now() - wo.created_at))/86400.0
    ) AS row_obj
    FROM public.work_order wo
    LEFT JOIN public.contract src      ON src.id = wo.source_contract_id
    LEFT JOIN public.contract tgt      ON tgt.id = wo.target_contract_id
    LEFT JOIN public.party    cp_src   ON cp_src.id = src.counterparty_id
    LEFT JOIN public.party    cp_tgt   ON cp_tgt.id = tgt.counterparty_id
    LEFT JOIN public."user"   assignor ON assignor.id = wo.assigned_by_user_id
    WHERE wo.tenant_id = v_tenant_id
      AND wo.assigned_to_user_id = p_user_id
      AND wo.is_active = TRUE
      AND (p_status_filter IS NULL OR wo.status = ANY(p_status_filter))
      AND (p_type_filter   IS NULL OR wo.work_order_type = ANY(p_type_filter))
    ORDER BY wo.created_at DESC
    LIMIT p_limit
  ) s;

  RETURN jsonb_build_object(
    'data',       v_rows,
    'totalCount', v_total,
    'openCount',  v_open
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_list_for_user(BIGINT, TEXT[], TEXT[], INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_list_for_user(BIGINT, TEXT[], TEXT[], INTEGER) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_list_for_user(BIGINT, TEXT[], TEXT[], INTEGER) IS
  'M21 (mig 631 extends mig 618) — Lists work orders for a user. v2 adds manualStage to the row shape so the FE can apply (manualStage ?? derivedStage) as the effective Stage column value.';

COMMIT;
