-- Migration: 618_work_order_table_and_fns.sql
-- Module: Work Order Queue (M21)
-- Date: 2026-06-11
--
-- New cross-cutting "things on your plate" inbox. Currently drafters get
-- emails when work needs doing and then trawl the app to find it. The
-- work_order table is the canonical record of assigned actions:
--
--   - contract_draft_request  → exec asks drafter to draft a similar contract
--   - contract_returned       → approver returned a draft; drafter must rework
--   - comment_response        → a comment fan-out targets the drafter
--
-- This migration creates:
--   1. work_order table (FORCE RLS, audit trigger, append-aware)
--   2. 5 fn_'s (create / list / get / complete / cancel)
--   3. 3 permissions (work.read.assigned, work.create, work.manage)
--   4. Role grants (drafter / executive / platform_admin / Super Admin)
--
-- Hooks that AUTO-create rows for the "returned" and "comment" events
-- live in migration 619.
-- The fn that creates a `contract_draft_request` plus its seeded draft
-- contract lives in migration 620.

BEGIN;

-- ==================================================================
-- 1. TABLE
-- ==================================================================
CREATE TABLE public.work_order (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES public.tenant(id) ON DELETE RESTRICT,

  work_order_type          TEXT NOT NULL
    CHECK (work_order_type IN ('contract_draft_request','contract_returned','comment_response')),

  status                   TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','in_progress','completed','cancelled')),

  -- The source/reference contract (always set for draft_request +
  -- returned + comment_response; nullable for future generic types).
  source_contract_id       BIGINT REFERENCES public.contract(id),

  -- The NEW seeded draft to act on (only set for contract_draft_request).
  -- For contract_returned, target == source (the same contract is being
  -- re-worked). For comment_response, target == the contract the comment
  -- lives on. Always the contract the drafter clicks INTO.
  target_contract_id       BIGINT REFERENCES public.contract(id),

  assigned_to_user_id      BIGINT NOT NULL REFERENCES public."user"(id),
  assigned_by_user_id      BIGINT REFERENCES public."user"(id),

  -- Optional related entities for context-restoration in UI.
  related_comment_id       BIGINT,
  related_approval_step_id BIGINT REFERENCES public.approval_step(id),

  -- Free-form payload — keyed differently per type. See type-specific
  -- documentation in each creator fn.
  payload                  JSONB NOT NULL DEFAULT '{}'::jsonb,

  priority                 TEXT NOT NULL DEFAULT 'normal'
    CHECK (priority IN ('low','normal','high','urgent')),
  due_at                   TIMESTAMPTZ,

  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by               BIGINT REFERENCES public."user"(id),
  updated_by               BIGINT REFERENCES public."user"(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,

  -- Set when status moves to completed/cancelled.
  completed_at             TIMESTAMPTZ,
  completed_by_user_id     BIGINT REFERENCES public."user"(id)
);

COMMENT ON TABLE  public.work_order IS
  'Cross-cutting work inbox. One row per assigned action (draft request, returned contract, comment response). Drafter''s landing surface; extensible to other roles.';
COMMENT ON COLUMN public.work_order.work_order_type IS
  'Discriminator. contract_draft_request | contract_returned | comment_response.';
COMMENT ON COLUMN public.work_order.target_contract_id IS
  'Contract the assignee clicks into. For draft_request: the new seeded draft. For returned: the source itself. For comment_response: the contract the comment lives on.';
COMMENT ON COLUMN public.work_order.payload IS
  'Type-specific JSONB. draft_request: { counterpartyId, instructionNote, sourceContractNumber }. returned: { decisionNote, fromApprover }. comment_response: { commentExcerpt, authorName }.';

-- Indexes
CREATE INDEX idx_work_order_assigned_open
  ON public.work_order (assigned_to_user_id, tenant_id)
  WHERE status = 'open' AND is_active = TRUE;

CREATE INDEX idx_work_order_assigned_all
  ON public.work_order (assigned_to_user_id, tenant_id, status);

CREATE INDEX idx_work_order_target
  ON public.work_order (target_contract_id)
  WHERE target_contract_id IS NOT NULL;

CREATE INDEX idx_work_order_source
  ON public.work_order (source_contract_id)
  WHERE source_contract_id IS NOT NULL;

CREATE INDEX idx_work_order_type_status
  ON public.work_order (tenant_id, work_order_type, status);

-- Audit trigger (updated_at maintained inline by fn_'s, per project convention).
DROP TRIGGER IF EXISTS audit_work_order_changes ON public.work_order;
CREATE TRIGGER audit_work_order_changes
  AFTER INSERT OR UPDATE OR DELETE ON public.work_order
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_trigger();

-- ==================================================================
-- 2. RLS
-- ==================================================================
ALTER TABLE public.work_order ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_order FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS work_order_tenant_isolation ON public.work_order;
CREATE POLICY work_order_tenant_isolation ON public.work_order
  FOR ALL
  USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

-- Block direct DELETE — only soft-delete via fn_work_order_cancel.
DROP POLICY IF EXISTS work_order_no_direct_delete ON public.work_order;
CREATE POLICY work_order_no_direct_delete ON public.work_order
  AS RESTRICTIVE
  FOR DELETE
  USING (FALSE);

-- ==================================================================
-- 3. PERMISSIONS
-- ==================================================================
INSERT INTO public.permission (code, module, action, description, created_at, is_active) VALUES
  ('work.read.assigned', 'work', 'read.assigned',
   'See work orders assigned to me', now(), TRUE),
  ('work.create',         'work', 'create',
   'Create work orders (assign work to others — exec / admin)', now(), TRUE),
  ('work.manage',         'work', 'manage',
   'Cancel / reassign / view any work order (admin)', now(), TRUE)
ON CONFLICT (code) DO NOTHING;

-- Grants
INSERT INTO public.role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, now(), TRUE
FROM public.role r, public.permission p
WHERE (r.name = 'contract_drafter' AND p.code IN ('work.read.assigned'))
   OR (r.name = 'executive'        AND p.code IN ('work.create','work.read.assigned'))
   OR (r.name = 'platform_admin'   AND p.code IN ('work.read.assigned','work.create','work.manage'))
   OR (r.name = 'Super Admin'      AND p.code IN ('work.read.assigned','work.create','work.manage'))
ON CONFLICT (role_id, permission_id) DO UPDATE SET is_active = TRUE;

-- ==================================================================
-- 4. fn_work_order_create
-- ==================================================================
-- Generic create. Used by:
--   - fn_work_order_create_draft_from_contract (mig 620)
--   - hooks in fn_approval_decide + fn_contract_comment_create (mig 619)
--   - the BE controller for POST /work-orders (admin / future generic)
CREATE OR REPLACE FUNCTION public.fn_work_order_create(
  p_data    JSONB,
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id              UUID;
  v_type                   TEXT;
  v_assigned_to            BIGINT;
  v_source_contract_id     BIGINT;
  v_target_contract_id     BIGINT;
  v_related_comment_id     BIGINT;
  v_related_step_id        BIGINT;
  v_priority               TEXT;
  v_due_at                 TIMESTAMPTZ;
  v_payload                JSONB;
  v_assignee_role          TEXT;
  v_id                     BIGINT;
  v_row                    public.work_order%ROWTYPE;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  v_type               := p_data->>'workOrderType';
  v_assigned_to        := (p_data->>'assignedToUserId')::bigint;
  v_source_contract_id := NULLIF(p_data->>'sourceContractId','')::bigint;
  v_target_contract_id := NULLIF(p_data->>'targetContractId','')::bigint;
  v_related_comment_id := NULLIF(p_data->>'relatedCommentId','')::bigint;
  v_related_step_id    := NULLIF(p_data->>'relatedApprovalStepId','')::bigint;
  v_priority           := COALESCE(p_data->>'priority','normal');
  v_due_at             := NULLIF(p_data->>'dueAt','')::timestamptz;
  v_payload            := COALESCE(p_data->'payload','{}'::jsonb);

  IF v_type IS NULL OR v_type NOT IN ('contract_draft_request','contract_returned','comment_response') THEN
    RAISE EXCEPTION 'Invalid workOrderType: %', v_type USING ERRCODE = '22023';
  END IF;
  IF v_assigned_to IS NULL THEN
    RAISE EXCEPTION 'assignedToUserId required' USING ERRCODE = '22023';
  END IF;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  -- Sanity: assignee must exist and be active in same tenant context.
  PERFORM 1 FROM public."user" WHERE id = v_assigned_to AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assignee user % not found or inactive', v_assigned_to USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.work_order (
    tenant_id, work_order_type, status,
    source_contract_id, target_contract_id,
    assigned_to_user_id, assigned_by_user_id,
    related_comment_id, related_approval_step_id,
    payload, priority, due_at,
    created_by, updated_by
  ) VALUES (
    v_tenant_id, v_type, 'open',
    v_source_contract_id, v_target_contract_id,
    v_assigned_to, p_actor_id,
    v_related_comment_id, v_related_step_id,
    v_payload, v_priority, v_due_at,
    p_actor_id, p_actor_id
  )
  RETURNING id INTO v_id;

  SELECT * INTO v_row FROM public.work_order WHERE id = v_id;

  RETURN jsonb_build_object(
    'id',                  v_row.id,
    'workOrderType',       v_row.work_order_type,
    'status',              v_row.status,
    'sourceContractId',    v_row.source_contract_id,
    'targetContractId',    v_row.target_contract_id,
    'assignedToUserId',    v_row.assigned_to_user_id,
    'assignedByUserId',    v_row.assigned_by_user_id,
    'priority',            v_row.priority,
    'dueAt',               v_row.due_at,
    'payload',             v_row.payload,
    'createdAt',           v_row.created_at
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_create(JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_create(JSONB, BIGINT) TO neondb_owner;

-- ==================================================================
-- 5. fn_work_order_list_for_user
-- ==================================================================
-- Returns enriched JSONB array of work orders for a user — joined with
-- source contract (number, title, counterparty name) + target contract
-- (number, status) + assignor name. UI renders directly from this.
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

  -- Single-tenant scope (RLS would block cross-tenant anyway, but be explicit)
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

-- ==================================================================
-- 6. fn_work_order_get
-- ==================================================================
CREATE OR REPLACE FUNCTION public.fn_work_order_get(
  p_id       BIGINT,
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id UUID;
  v_row       JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  SELECT jsonb_build_object(
    'id',                  wo.id,
    'workOrderType',       wo.work_order_type,
    'status',              wo.status,
    'priority',            wo.priority,
    'sourceContractId',    wo.source_contract_id,
    'sourceContractNumber', src.contract_number,
    'sourceContractTitleEn', src.title_en,
    'targetContractId',    wo.target_contract_id,
    'targetContractNumber', tgt.contract_number,
    'targetContractTitleEn', tgt.title_en,
    'targetContractStatus', tgt.status,
    'counterpartyName',    COALESCE(cp_tgt.legal_name_en, cp_src.legal_name_en),
    'assignedToUserId',    wo.assigned_to_user_id,
    'assignedByUserId',    wo.assigned_by_user_id,
    'assignedByName',      CASE
      WHEN assignor.id IS NULL THEN NULL
      ELSE trim(concat(assignor.first_name,' ',assignor.last_name))
    END,
    'payload',             wo.payload,
    'relatedCommentId',    wo.related_comment_id,
    'createdAt',           wo.created_at,
    'completedAt',         wo.completed_at,
    'dueAt',               wo.due_at
  )
  INTO v_row
  FROM public.work_order wo
  LEFT JOIN public.contract src    ON src.id = wo.source_contract_id
  LEFT JOIN public.contract tgt    ON tgt.id = wo.target_contract_id
  LEFT JOIN public.party    cp_src ON cp_src.id = src.counterparty_id
  LEFT JOIN public.party    cp_tgt ON cp_tgt.id = tgt.counterparty_id
  LEFT JOIN public."user"   assignor ON assignor.id = wo.assigned_by_user_id
  WHERE wo.id = p_id
    AND wo.tenant_id = v_tenant_id
    AND wo.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'Work order % not found', p_id USING ERRCODE = 'P0002';
  END IF;
  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_get(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_get(BIGINT, BIGINT) TO neondb_owner;

-- ==================================================================
-- 7. fn_work_order_complete
-- ==================================================================
-- Called manually OR auto-fired from mig 619 hooks when the target
-- contract progresses out of 'draft'. Idempotent for already-completed.
CREATE OR REPLACE FUNCTION public.fn_work_order_complete(
  p_id       BIGINT,
  p_actor_id BIGINT
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
   WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work order % not found', p_id USING ERRCODE = 'P0002';
  END IF;
  IF v_row.status = 'completed' THEN
    RETURN jsonb_build_object('id', v_row.id, 'status', 'completed', 'message', 'already_completed');
  END IF;
  IF v_row.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot complete a cancelled work order' USING ERRCODE = '22023';
  END IF;

  UPDATE public.work_order
     SET status               = 'completed',
         completed_at         = now(),
         completed_by_user_id = p_actor_id,
         updated_at           = now(),
         updated_by           = p_actor_id
   WHERE id = p_id;

  RETURN jsonb_build_object('id', p_id, 'status', 'completed');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_complete(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_complete(BIGINT, BIGINT) TO neondb_owner;

-- ==================================================================
-- 8. fn_work_order_cancel
-- ==================================================================
CREATE OR REPLACE FUNCTION public.fn_work_order_cancel(
  p_id       BIGINT,
  p_actor_id BIGINT,
  p_reason   TEXT DEFAULT NULL
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
   WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work order % not found', p_id USING ERRCODE = 'P0002';
  END IF;
  IF v_row.status IN ('cancelled','completed') THEN
    RETURN jsonb_build_object('id', v_row.id, 'status', v_row.status, 'message','no_op');
  END IF;

  UPDATE public.work_order
     SET status               = 'cancelled',
         completed_at         = now(),
         completed_by_user_id = p_actor_id,
         payload              = COALESCE(payload,'{}'::jsonb) ||
                                jsonb_build_object('cancelReason', p_reason),
         updated_at           = now(),
         updated_by           = p_actor_id
   WHERE id = p_id;

  RETURN jsonb_build_object('id', p_id, 'status', 'cancelled');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_cancel(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_cancel(BIGINT, BIGINT, TEXT) TO neondb_owner;

COMMIT;
