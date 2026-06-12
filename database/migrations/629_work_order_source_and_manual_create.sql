-- Migration: 629_work_order_source_and_manual_create.sql
-- Module: My Work (M21) — manual work-order creation
-- Date: 2026-06-12
--
-- Adds a work_order.source column ('system' default | 'manual') so we can
-- distinguish drafter-self-created entries from system-generated ones. Old
-- rows default to 'system' which preserves their meaning.
--
-- Adds fn_work_order_create_manual(p_data, p_actor_id) — a new, focused fn
-- for the drafter "Add to my queue" flow. Existing fn_work_order_create is
-- intentionally untouched. We get a dedicated input contract + dedicated
-- audit trail, and the existing system-create path keeps its bit-for-bit
-- behaviour for every other caller.
--
-- Constraints: work_order_type fixed to 'contract_draft_request' (the only
-- type the FE add-modal supports today), assigned_to/by both default to the
-- actor (self-assigned), source set to 'manual'. Sidecar progress fn and
-- fn_work_order_list_for_user pick this up automatically because they read
-- the same row shape — no downstream change needed for the table to render
-- a manual row.

BEGIN;

-- ─── Column: work_order.source ──────────────────────────────────────────────

ALTER TABLE public.work_order
  ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'system'
    CHECK (source IN ('system', 'manual'));

COMMENT ON COLUMN public.work_order.source IS
  'M21 2026-06-12 — origin of the row. system = created by upstream trigger / exec request; manual = drafter self-added via the "Add to my queue" modal. Defaults to system so pre-existing rows keep their meaning.';

-- ─── fn_work_order_create_manual ───────────────────────────────────────────

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
  v_tenant_id            UUID;
  v_counterparty_id      BIGINT;
  v_counterparty_name    TEXT;
  v_prospect_name        TEXT;
  v_instruction          TEXT;
  v_source_contract_id   BIGINT;
  v_priority             TEXT;
  v_due_at               TIMESTAMPTZ;
  v_payload              JSONB;
  v_id                   BIGINT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- Parse + validate input.
  v_counterparty_id    := NULLIF(p_data->>'counterpartyId', '')::bigint;
  v_prospect_name      := NULLIF(trim(p_data->>'counterpartyProspectName'), '');
  v_instruction        := NULLIF(trim(p_data->>'instructionNote'), '');
  v_source_contract_id := NULLIF(p_data->>'sourceContractId', '')::bigint;
  v_priority           := COALESCE(p_data->>'priority', 'normal');
  v_due_at             := NULLIF(p_data->>'dueAt', '')::timestamptz;

  IF v_instruction IS NULL OR length(v_instruction) = 0 THEN
    RAISE EXCEPTION 'instructionNote:Instruction is required for manual entries'
      USING ERRCODE = '22023';
  END IF;
  IF v_counterparty_id IS NULL AND v_prospect_name IS NULL THEN
    RAISE EXCEPTION 'counterparty:Either counterpartyId or counterpartyProspectName is required'
      USING ERRCODE = '22023';
  END IF;

  -- Resolve counterparty display name. Prefer the catalog party's name when
  -- an id was supplied; otherwise use the typed prospect string.
  IF v_counterparty_id IS NOT NULL THEN
    SELECT name_en INTO v_counterparty_name FROM public.party WHERE id = v_counterparty_id;
    IF v_counterparty_name IS NULL THEN
      RAISE EXCEPTION 'counterpartyId:Party % not found in catalog', v_counterparty_id
        USING ERRCODE = 'P0002';
    END IF;
  ELSE
    v_counterparty_name := v_prospect_name;
  END IF;

  -- Sanity-check the optional source contract belongs to this tenant (RLS
  -- will already filter, but the explicit check gives a clean 404 instead
  -- of an opaque NULL-id reference).
  IF v_source_contract_id IS NOT NULL THEN
    PERFORM 1 FROM public.contract
      WHERE id = v_source_contract_id
        AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'sourceContractId:Source contract % not found',
        v_source_contract_id USING ERRCODE = 'P0002';
    END IF;
  END IF;

  -- Build payload mirroring system-generated draft_request rows so the FE
  -- table renders both identically (counterpartyName + instructionNote).
  v_payload := jsonb_build_object(
    'counterpartyName',  v_counterparty_name,
    'instructionNote',   v_instruction,
    'origin',            'manual'
  );

  INSERT INTO public.work_order (
    tenant_id, work_order_type, status, source,
    source_contract_id, target_contract_id,
    counterparty_id, counterparty_prospect_name,
    assigned_to_user_id, assigned_by_user_id,
    payload, priority, due_at,
    created_by, updated_by
  ) VALUES (
    v_tenant_id, 'contract_draft_request', 'open', 'manual',
    v_source_contract_id, NULL,
    v_counterparty_id, v_prospect_name,
    p_actor_id, p_actor_id,                       -- self-assigned both sides
    v_payload, v_priority, v_due_at,
    p_actor_id, p_actor_id
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'workOrderId',     v_id,
    'counterpartyName', v_counterparty_name,
    'sourceContractId', v_source_contract_id,
    'source',          'manual'
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_create_manual(JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_create_manual(JSONB, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_create_manual(JSONB, BIGINT) IS
  'M21 manual add-to-queue — drafter self-assigns a draft request that originated outside the system (email, chat, etc.). Sets source=manual. Existing fn_work_order_create intentionally untouched.';

COMMIT;
