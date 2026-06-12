-- Migration: 636_fn_work_order_list_assigned_by_user.sql
-- Module: Assigned Work (M21 — executive scope)
-- Date: 2026-06-12
--
-- The drafter sees /app/work as "items assigned TO me" (mig 632 paginated
-- fn_work_order_list_for_user). The executive needs the inverse: items
-- "assigned BY me" so they can track everything they routed to their team.
--
-- This fn mirrors fn_work_order_list_for_user 1:1 — same envelope shape,
-- same pagination, same filters — with two differences:
--
--   1. WHERE wo.assigned_by_user_id = p_user_id (not assigned_to_user_id).
--   2. Row carries assignedToUserId + assignedToName (the owner) instead of
--      relying on assignedByName as the foreign actor.
--
-- A new optional p_owner_filter narrows by a single drafter so the exec can
-- isolate one person's queue. Same defensive clamps on page/limit.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_work_order_list_assigned_by_user(
  p_user_id        BIGINT,
  p_status_filter  TEXT[]  DEFAULT ARRAY['open','in_progress'],
  p_type_filter    TEXT[]  DEFAULT NULL,
  p_owner_filter   BIGINT  DEFAULT NULL,
  p_limit          INTEGER DEFAULT 20,
  p_page           INTEGER DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id   UUID;
  v_total       INTEGER;
  v_open        INTEGER;
  v_total_pages INTEGER;
  v_offset      INTEGER;
  v_safe_limit  INTEGER;
  v_safe_page   INTEGER;
  v_rows        JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  v_safe_limit := GREATEST(COALESCE(p_limit, 20), 1);
  IF v_safe_limit > 500 THEN
    v_safe_limit := 500;
  END IF;
  v_safe_page := GREATEST(COALESCE(p_page, 1), 1);
  v_offset    := (v_safe_page - 1) * v_safe_limit;

  SELECT count(*) INTO v_total
  FROM public.work_order wo
  WHERE wo.tenant_id = v_tenant_id
    AND wo.assigned_by_user_id = p_user_id
    AND wo.is_active = TRUE
    AND (p_status_filter IS NULL OR wo.status = ANY(p_status_filter))
    AND (p_type_filter   IS NULL OR wo.work_order_type = ANY(p_type_filter))
    AND (p_owner_filter  IS NULL OR wo.assigned_to_user_id = p_owner_filter);

  SELECT count(*) INTO v_open
  FROM public.work_order wo
  WHERE wo.tenant_id = v_tenant_id
    AND wo.assigned_by_user_id = p_user_id
    AND wo.is_active = TRUE
    AND wo.status IN ('open','in_progress');

  v_total_pages := GREATEST(1, CEIL(v_total::numeric / v_safe_limit)::integer);

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
      'assignedToUserId',    wo.assigned_to_user_id,
      'assignedToName',      CASE
        WHEN assignee.id IS NULL THEN NULL
        ELSE trim(concat(assignee.first_name,' ',assignee.last_name))
      END,
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
    LEFT JOIN public."user"   assignee ON assignee.id = wo.assigned_to_user_id
    WHERE wo.tenant_id = v_tenant_id
      AND wo.assigned_by_user_id = p_user_id
      AND wo.is_active = TRUE
      AND (p_status_filter IS NULL OR wo.status = ANY(p_status_filter))
      AND (p_type_filter   IS NULL OR wo.work_order_type = ANY(p_type_filter))
      AND (p_owner_filter  IS NULL OR wo.assigned_to_user_id = p_owner_filter)
    ORDER BY wo.created_at DESC
    LIMIT v_safe_limit
    OFFSET v_offset
  ) s;

  RETURN jsonb_build_object(
    'data',       v_rows,
    'totalCount', v_total,
    'openCount',  v_open,
    'page',       v_safe_page,
    'pageSize',   v_safe_limit,
    'totalPages', v_total_pages
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_list_assigned_by_user(BIGINT, TEXT[], TEXT[], BIGINT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_list_assigned_by_user(BIGINT, TEXT[], TEXT[], BIGINT, INTEGER, INTEGER) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_list_assigned_by_user(BIGINT, TEXT[], TEXT[], BIGINT, INTEGER, INTEGER) IS
  'M21 v5 (mig 636, 2026-06-12) — Lists work orders the user assigned to others. Mirror of fn_work_order_list_for_user with assigned_by scope; row carries assignedToUserId + assignedToName (the owner). Optional p_owner_filter narrows to one assignee. Same {data,totalCount,openCount,page,pageSize,totalPages} envelope so the FE pagination + filter UX is identical.';

COMMIT;
