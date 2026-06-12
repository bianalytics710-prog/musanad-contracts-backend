-- Migration: 632_fn_work_order_list_for_user_paginate.sql
-- Module: My Work (M21)
-- Date: 2026-06-12
--
-- Adds proper page/offset pagination to fn_work_order_list_for_user. The fn
-- already returned totalCount but had no way to ask for a specific page —
-- the FE was just rendering the first p_limit rows. With the queue
-- expected to grow well beyond 20 rows per drafter, we need the same
-- Prev/Next/"page N of M" pattern the Contracts list uses.
--
-- Signature change:
--   v2 (mig 618): (BIGINT, TEXT[], TEXT[], INTEGER)
--   v3 (mig 631): same args + manualStage in row shape
--   v4 (this mig): adds optional p_page INTEGER DEFAULT 1
--
-- The new arg goes at the end with a default, so every existing call site
-- (BE controller + any tests) keeps working unchanged — they'll get page 1.
-- The response envelope now includes totalPages alongside totalCount +
-- openCount.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_work_order_list_for_user(
  p_user_id        BIGINT,
  p_status_filter  TEXT[] DEFAULT ARRAY['open','in_progress'],
  p_type_filter    TEXT[] DEFAULT NULL,
  p_limit          INTEGER DEFAULT 100,
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

  -- Defensive coercions: clamp page ≥ 1, limit ≥ 1 + cap at 500.
  v_safe_limit := GREATEST(COALESCE(p_limit, 100), 1);
  IF v_safe_limit > 500 THEN
    v_safe_limit := 500;
  END IF;
  v_safe_page  := GREATEST(COALESCE(p_page, 1), 1);
  v_offset     := (v_safe_page - 1) * v_safe_limit;

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

REVOKE EXECUTE ON FUNCTION public.fn_work_order_list_for_user(BIGINT, TEXT[], TEXT[], INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_list_for_user(BIGINT, TEXT[], TEXT[], INTEGER, INTEGER) TO neondb_owner;

-- Drop the v3 4-arg overload from mig 631 so PostgreSQL doesn't have two
-- competing signatures. Existing BE callers don't supply p_page so they
-- naturally bind to the new 5-arg with default page=1.
DROP FUNCTION IF EXISTS public.fn_work_order_list_for_user(BIGINT, TEXT[], TEXT[], INTEGER);

COMMENT ON FUNCTION public.fn_work_order_list_for_user(BIGINT, TEXT[], TEXT[], INTEGER, INTEGER) IS
  'M21 v4 (mig 632, 2026-06-12) — Lists work orders for a user with proper page/offset pagination. Returns {data, totalCount, openCount, page, pageSize, totalPages} so the FE can render the standard Prev/"page N of M"/Next footer. Defaults p_page=1 + safely clamps inputs.';

COMMIT;
