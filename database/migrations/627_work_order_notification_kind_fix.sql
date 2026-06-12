-- Migration: 627_work_order_notification_kind_fix.sql
-- Module: Work Order Queue (M21) — notification dispatch hotfix
-- Date: 2026-06-11
--
-- mig 626 passed 'in_app' as p_notification_kind to fn_notification_dispatch,
-- but kinds must be one of {alert, advisory, approval_request,
-- signature_request, system, risk_case, report}. Channel is determined by
-- notification_rule_channel rows, not by the kind. This hotfix passes
-- 'system' which is the right bucket for work-order events.

BEGIN;

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

  v_counterparty_id := NULLIF(p_data->>'counterpartyId','')::bigint;
  v_prospect_name   := NULLIF(trim(p_data->>'counterpartyProspectName'),'');
  IF v_counterparty_id IS NULL AND v_prospect_name IS NULL THEN
    v_counterparty_id := v_source.counterparty_id;
  END IF;
  IF v_counterparty_id IS NOT NULL THEN
    SELECT name_en INTO v_counterparty_label FROM public.party WHERE id = v_counterparty_id;
  ELSE
    v_counterparty_label := v_prospect_name;
  END IF;
  v_instruction := NULLIF(trim(p_data->>'instructionNote'),'');
  v_value_aed   := NULLIF(p_data->>'valueAed','')::numeric;
  v_priority    := COALESCE(p_data->>'priority','medium');
  -- work_order CHECK accepts {low, normal, high, urgent}; the dispatcher accepts {low, medium, high, critical}.
  -- Keep the row's column on the work_order CHECK, send 'medium' as the dispatch priority.
  v_due_at := NULLIF(p_data->>'dueAt','')::timestamptz;

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
  ) VALUES (
    v_tenant_id, 'contract_draft_request', 'open',
    p_source_contract_id, NULL,
    v_counterparty_id, v_prospect_name,
    p_assigned_drafter_id, p_actor_id,
    v_payload, COALESCE(p_data->>'priority','normal'), v_due_at,
    p_actor_id, p_actor_id
  )
  RETURNING id INTO v_id;

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
      'assignedToName',       trim(concat(v_drafter.first_name,' ',v_drafter.last_name)),
      'assignedToUserEmail',  v_drafter.email,
      'notifyUserIds',        jsonb_build_array(p_assigned_drafter_id),
      'assignedByUserId',     p_actor_id,
      'assignedByName',       (SELECT trim(concat(first_name,' ',last_name)) FROM public."user" WHERE id = p_actor_id)
    ),
    'system',         -- p_notification_kind — was 'in_app' (a channel), which crashed fn_notification_send
    v_priority,
    p_actor_id,
    NULL
  );

  RETURN jsonb_build_object(
    'workOrderId',          v_id,
    'sourceContractId',     p_source_contract_id,
    'sourceContractNumber', v_source.contract_number,
    'counterpartyName',     v_counterparty_label,
    'assignedDrafter', jsonb_build_object(
      'id',   v_drafter.id,
      'name', trim(concat(v_drafter.first_name,' ',v_drafter.last_name))
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_create_draft_request(BIGINT, BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_create_draft_request(BIGINT, BIGINT, BIGINT, JSONB) TO neondb_owner;

-- Backfill the channel + recipient rows that the dispatcher reads (the
-- rule.channel + audience columns are legacy; only the v2 channel/recipient
-- tables are consulted at dispatch time).
INSERT INTO public.notification_rule_channel (rule_id, channel, template_slug, is_active, created_at, updated_at)
SELECT r.id, r.channel, t.template_id, TRUE, now(), now()
FROM public.notification_rule r
JOIN public.notification_template t ON t.template_id = r.template_id
WHERE r.event_type = 'work_order.assigned'
ON CONFLICT DO NOTHING;

INSERT INTO public.notification_rule_recipient (rule_id, recipient_type, recipient_value, is_active, created_at, updated_at)
SELECT r.id, 'context', 'notifyUserIds', TRUE, now(), now()
FROM public.notification_rule r
WHERE r.event_type = 'work_order.assigned'
ON CONFLICT DO NOTHING;

COMMIT;
