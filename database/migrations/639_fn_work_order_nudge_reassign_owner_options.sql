-- Migration: 637_fn_work_order_nudge_reassign_owner_options.sql
-- Module: Assigned Work (M21 — executive scope)
-- Date: 2026-06-12
--
-- Three new fns powering the executive's row-action menu on the Assigned
-- Work table:
--
--   1. fn_work_order_nudge(work_order_id, actor_id, message?)
--      → fires a work_order.nudge in-app notification to the assignee
--      → 6-hour idempotency window: a second nudge from the same actor on
--        the same work_order within 6h is a no-op (returns {throttled:true}).
--   2. fn_work_order_reassign(work_order_id, new_assignee_id, actor_id, reason?)
--      → updates assigned_to_user_id, fires work_order.assigned on the new
--        owner. Old owner does NOT receive a notification (intentional —
--        the assumption is they were unable to action it). Audit trigger
--        captures the change.
--   3. fn_work_order_owner_options(actor_id)
--      → list of {id,label} for the OWNER dropdown on the executive's table.
--        Returns every distinct assignee the actor has ever sent work to —
--        keeps the dropdown short and meaningful (vs the full user list).
--
-- A new notification_event_type + notification_template + notification_rule
-- (plus the v2 channel + recipient rows) for work_order.nudge are seeded so
-- the in-app payload renders correctly. Pattern mirrors mig 625 + 627.

BEGIN;

-- ==================================================================
-- 1. fn_work_order_nudge
-- ==================================================================
CREATE OR REPLACE FUNCTION public.fn_work_order_nudge(
  p_id        BIGINT,
  p_actor_id  BIGINT,
  p_message   TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id      UUID;
  v_row            public.work_order%ROWTYPE;
  v_assignee       RECORD;
  v_last_nudge_at  TIMESTAMPTZ;
  v_source_number  TEXT;
  v_source_title   TEXT;
  v_actor_name     TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM public.work_order
   WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work order % not found', p_id USING ERRCODE = 'P0002';
  END IF;
  IF v_row.status IN ('cancelled','completed') THEN
    RAISE EXCEPTION 'Work order % is % — nothing to nudge', p_id, v_row.status
      USING ERRCODE = '22023';
  END IF;
  IF v_row.assigned_by_user_id <> p_actor_id THEN
    RAISE EXCEPTION 'Only the original requestor can nudge'
      USING ERRCODE = '42501';
  END IF;

  -- 6-hour idempotency: skip if this actor already nudged this work_order
  -- within the last 6 hours. The payload tracks last_nudged_at + per-actor.
  v_last_nudge_at := NULLIF(v_row.payload->>'lastNudgedAt','')::timestamptz;
  IF v_last_nudge_at IS NOT NULL
     AND v_last_nudge_at > (now() - INTERVAL '6 hours')
     AND NULLIF(v_row.payload->>'lastNudgedBy','')::bigint = p_actor_id THEN
    RETURN jsonb_build_object(
      'workOrderId',    p_id,
      'throttled',      TRUE,
      'lastNudgedAt',   v_last_nudge_at,
      'nextEligibleAt', v_last_nudge_at + INTERVAL '6 hours'
    );
  END IF;

  SELECT u.id, u.first_name, u.last_name, u.email
    INTO v_assignee
    FROM public."user" u
   WHERE u.id = v_row.assigned_to_user_id AND u.is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assignee % no longer active', v_row.assigned_to_user_id
      USING ERRCODE = 'P0002';
  END IF;

  SELECT trim(concat(first_name,' ',last_name))
    INTO v_actor_name
    FROM public."user" WHERE id = p_actor_id;

  IF v_row.source_contract_id IS NOT NULL THEN
    SELECT contract_number, title_en INTO v_source_number, v_source_title
      FROM public.contract WHERE id = v_row.source_contract_id;
  END IF;

  -- Stamp the work_order so the next nudge inside 6h is throttled.
  UPDATE public.work_order
     SET payload    = COALESCE(payload,'{}'::jsonb)
                      || jsonb_build_object(
                           'lastNudgedAt',     now(),
                           'lastNudgedBy',     p_actor_id,
                           'lastNudgeMessage', NULLIF(trim(p_message),'')
                         ),
         updated_at = now(),
         updated_by = p_actor_id
   WHERE id = p_id;

  -- Fire the in-app notification. Kind = 'system' (channel is determined by
  -- notification_rule_channel rows; mig 625/627 pattern).
  PERFORM public.fn_notification_dispatch(
    p_actor_id,
    'work_order.nudge',
    jsonb_build_object(
      'workOrderId',          p_id,
      'sourceContractNumber', v_source_number,
      'sourceTitleEn',        v_source_title,
      'counterpartyName',     v_row.payload->>'counterpartyName',
      'instructionNote',      v_row.payload->>'instructionNote',
      'nudgeMessage',         NULLIF(trim(p_message),''),
      'assignedToUserId',     v_assignee.id,
      'assignedToName',       trim(concat(v_assignee.first_name,' ',v_assignee.last_name)),
      'assignedToUserEmail',  v_assignee.email,
      'notifyUserIds',        jsonb_build_array(v_assignee.id),
      'assignedByUserId',     p_actor_id,
      'assignedByName',       v_actor_name
    ),
    'system',
    'medium',
    p_actor_id,
    NULL
  );

  RETURN jsonb_build_object(
    'workOrderId',  p_id,
    'throttled',    FALSE,
    'nudgedAt',     now(),
    'assigneeName', trim(concat(v_assignee.first_name,' ',v_assignee.last_name))
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_nudge(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_nudge(BIGINT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_nudge(BIGINT, BIGINT, TEXT) IS
  'M21 (mig 637, 2026-06-12) — Executive sends an in-app reminder to the work-order assignee. 6-hour idempotency window on (work_order_id, actor_id) prevents spam. Only the original requestor (assigned_by_user_id) may nudge.';


-- ==================================================================
-- 2. fn_work_order_reassign
-- ==================================================================
CREATE OR REPLACE FUNCTION public.fn_work_order_reassign(
  p_id              BIGINT,
  p_new_assignee_id BIGINT,
  p_actor_id        BIGINT,
  p_reason          TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id     UUID;
  v_row           public.work_order%ROWTYPE;
  v_new_assignee  RECORD;
  v_old_assignee  RECORD;
  v_source_number TEXT;
  v_source_title  TEXT;
  v_counterparty  TEXT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context not set' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM public.work_order
   WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Work order % not found', p_id USING ERRCODE = 'P0002';
  END IF;
  IF v_row.status IN ('cancelled','completed') THEN
    RAISE EXCEPTION 'Work order % is % — cannot reassign', p_id, v_row.status
      USING ERRCODE = '22023';
  END IF;
  IF v_row.assigned_by_user_id <> p_actor_id THEN
    RAISE EXCEPTION 'Only the original requestor can reassign'
      USING ERRCODE = '42501';
  END IF;
  IF v_row.assigned_to_user_id = p_new_assignee_id THEN
    RETURN jsonb_build_object('workOrderId', p_id, 'message','no_op');
  END IF;

  SELECT u.id, u.first_name, u.last_name, u.email
    INTO v_new_assignee
    FROM public."user" u
   WHERE u.id = p_new_assignee_id AND u.is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'New assignee % not found or inactive', p_new_assignee_id
      USING ERRCODE = 'P0002';
  END IF;

  SELECT u.id, u.first_name, u.last_name
    INTO v_old_assignee
    FROM public."user" u
   WHERE u.id = v_row.assigned_to_user_id;

  IF v_row.source_contract_id IS NOT NULL THEN
    SELECT contract_number, title_en INTO v_source_number, v_source_title
      FROM public.contract WHERE id = v_row.source_contract_id;
  END IF;
  v_counterparty := v_row.payload->>'counterpartyName';

  UPDATE public.work_order
     SET assigned_to_user_id = p_new_assignee_id,
         payload             = COALESCE(payload,'{}'::jsonb)
                               || jsonb_build_object(
                                    'reassignedAt',         now(),
                                    'reassignedBy',         p_actor_id,
                                    'previousAssigneeId',   v_row.assigned_to_user_id,
                                    'previousAssigneeName',
                                      trim(concat(v_old_assignee.first_name,' ',v_old_assignee.last_name)),
                                    'reassignReason',       NULLIF(trim(p_reason),'')
                                  ),
         updated_at          = now(),
         updated_by          = p_actor_id
   WHERE id = p_id;

  -- Notify the new owner (reuses the existing work_order.assigned rule).
  PERFORM public.fn_notification_dispatch(
    p_actor_id,
    'work_order.assigned',
    jsonb_build_object(
      'workOrderId',          p_id,
      'sourceContractNumber', v_source_number,
      'sourceTitleEn',        v_source_title,
      'counterpartyName',     v_counterparty,
      'instructionNote',      v_row.payload->>'instructionNote',
      'assignedToUserId',     v_new_assignee.id,
      'assignedToName',       trim(concat(v_new_assignee.first_name,' ',v_new_assignee.last_name)),
      'assignedToUserEmail',  v_new_assignee.email,
      'notifyUserIds',        jsonb_build_array(v_new_assignee.id),
      'assignedByUserId',     p_actor_id,
      'assignedByName',       (SELECT trim(concat(first_name,' ',last_name)) FROM public."user" WHERE id = p_actor_id),
      'reassigned',           TRUE
    ),
    'system',
    'medium',
    p_actor_id,
    NULL
  );

  RETURN jsonb_build_object(
    'workOrderId', p_id,
    'newAssignee', jsonb_build_object(
      'id',   v_new_assignee.id,
      'name', trim(concat(v_new_assignee.first_name,' ',v_new_assignee.last_name))
    ),
    'previousAssigneeId', v_row.assigned_to_user_id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_reassign(BIGINT, BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_reassign(BIGINT, BIGINT, BIGINT, TEXT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_reassign(BIGINT, BIGINT, BIGINT, TEXT) IS
  'M21 (mig 637, 2026-06-12) — Executive moves an open work order from one assignee to another. New owner gets the standard work_order.assigned notification; previous owner is silent.';


-- ==================================================================
-- 3. fn_work_order_owner_options
-- ==================================================================
CREATE OR REPLACE FUNCTION public.fn_work_order_owner_options(
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

  SELECT COALESCE(jsonb_agg(o ORDER BY o->>'label'), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT DISTINCT ON (u.id)
      jsonb_build_object(
        'id',       u.id,
        'label',    trim(concat(u.first_name,' ',u.last_name)),
        'email',    u.email,
        'roleName', r.name
      ) AS o
    FROM public.work_order wo
    JOIN public."user" u ON u.id = wo.assigned_to_user_id
    JOIN public.role   r ON r.id = u.role_id
    WHERE wo.tenant_id = v_tenant_id
      AND wo.assigned_by_user_id = p_actor_id
      AND wo.is_active = TRUE
    ORDER BY u.id, wo.created_at DESC
  ) s;

  RETURN jsonb_build_object('options', v_rows);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_work_order_owner_options(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_work_order_owner_options(BIGINT) TO neondb_owner;

COMMENT ON FUNCTION public.fn_work_order_owner_options(BIGINT) IS
  'M21 (mig 637, 2026-06-12) — Dropdown source for the Assigned Work OWNER filter. Returns only people the actor has actually routed work to.';


-- ==================================================================
-- 4. Notification event_type + template + rule for work_order.nudge
-- ==================================================================
INSERT INTO public.notification_event_type
  (code, display_name, description, category, sort_order, is_active, created_at, updated_at)
VALUES
  ('work_order.nudge',
   'Work order nudge',
   'Executive sends a reminder to the drafter who owns an open draft request.',
   'contract', 105, TRUE, now(), now())
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.notification_template (
  tenant_id, template_id, channel, subject_en, subject_ar, body_en, body_ar,
  parameter_schema, data_classification, is_active, created_at, updated_at
)
VALUES
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'work_order.nudge.in_app',
   'in_app',
   NULL, NULL,
   '{{assignedByName}} is asking about your draft for {{counterpartyName}}{{#nudgeMessage}} — "{{nudgeMessage}}"{{/nudgeMessage}}',
   'يسأل {{assignedByName}} عن مسودتك لـ {{counterpartyName}}{{#nudgeMessage}} — "{{nudgeMessage}}"{{/nudgeMessage}}',
   '{"assignedByName":"string","counterpartyName":"string","nudgeMessage":"string"}'::jsonb,
   'production', TRUE, now(), now())
ON CONFLICT DO NOTHING;

INSERT INTO public.notification_rule (
  tenant_id, event_type, template_id, channel, is_enabled,
  audience, condition, priority, cooldown_minutes, description,
  is_active, created_at, updated_at, module, name, ordering
)
VALUES
  ('00000000-0000-0000-0000-000000000001'::uuid,
   'work_order.nudge',
   'work_order.nudge.in_app',
   'in_app',
   TRUE,
   jsonb_build_object('users', jsonb_build_array(jsonb_build_object('source','payload','path','assignedToUserId'))),
   NULL,
   'medium', 0,
   'In-app reminder fires when the executive nudges the drafter on an open draft request.',
   TRUE, now(), now(),
   'work_order',
   'Work order nudge (in_app)',
   120)
ON CONFLICT DO NOTHING;

-- v2 channel + recipient rows so fn_notification_dispatch actually delivers.
INSERT INTO public.notification_rule_channel (rule_id, channel, template_slug, is_active, created_at, updated_at)
SELECT r.id, r.channel, t.template_id, TRUE, now(), now()
FROM public.notification_rule r
JOIN public.notification_template t ON t.template_id = r.template_id
WHERE r.event_type = 'work_order.nudge'
ON CONFLICT DO NOTHING;

INSERT INTO public.notification_rule_recipient (rule_id, recipient_type, recipient_value, is_active, created_at, updated_at)
SELECT r.id, 'context', 'notifyUserIds', TRUE, now(), now()
FROM public.notification_rule r
WHERE r.event_type = 'work_order.nudge'
ON CONFLICT DO NOTHING;

COMMIT;
