-- ============================================================================
-- Migration 713 — Redline approver tag: group work orders + bell notification
-- ============================================================================
-- Feedback:
--  • Tagging an approver on N redlines created N work orders (N My-Work line
--    items). Group them: ONE work order per (assigner → approver, contract).
--    A different assigner for the same contract still gets its own line item.
--  • The tagged approver should also get an in-app BELL notification (with a
--    real description), not just a My-Work entry.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION fn_contract_redline_change_assign(
  p_actor_id    BIGINT,
  p_change_id   BIGINT,
  p_assignee_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_contract_id     BIGINT;
  v_heading         TEXT;
  v_contract_number TEXT;
  v_assignee_name   TEXT;
  v_assigner_name   TEXT;
  v_wo              BIGINT;
BEGIN
  IF NOT (fn_current_user_has_permission('contract.edit')
       OR fn_current_user_has_permission('contract.draft')) THEN
    RAISE EXCEPTION 'forbidden: contract.edit or contract.draft required' USING ERRCODE = '42501';
  END IF;

  SELECT ri.contract_id, rc.clause_heading, c.contract_number
    INTO v_contract_id, v_heading, v_contract_number
  FROM contract_redline_change rc
  JOIN contract_redline_import ri ON ri.id = rc.import_id
  JOIN contract c ON c.id = ri.contract_id
  WHERE rc.id = p_change_id AND rc.is_active = TRUE;
  IF v_contract_id IS NULL THEN
    RAISE EXCEPTION 'Change not found' USING ERRCODE = '22023';
  END IF;

  SELECT NULLIF(trim(concat_ws(' ', first_name, last_name)), '') INTO v_assignee_name
  FROM "user" WHERE id = p_assignee_id AND is_active = TRUE;
  IF v_assignee_name IS NULL THEN
    RAISE EXCEPTION 'Assignee not found' USING ERRCODE = '22023';
  END IF;
  SELECT NULLIF(trim(concat_ws(' ', first_name, last_name)), '') INTO v_assigner_name
  FROM "user" WHERE id = p_actor_id;

  UPDATE contract_redline_change
     SET assigned_to = p_assignee_id, assigned_by = p_actor_id, assigned_at = now(), updated_at = now()
   WHERE id = p_change_id;

  -- GUCs for the work-order + notification helpers.
  PERFORM set_config('app.current_tenant_id',
    COALESCE(NULLIF(current_setting('app.current_tenant_id', true), ''),
             '00000000-0000-0000-0000-000000000001'), true);
  PERFORM set_config('app.current_user_id', p_actor_id::text, true);

  -- Group: reuse an open work order for this (assigner → approver, contract).
  SELECT id INTO v_wo
  FROM work_order
  WHERE work_order_type = 'redline_approver_tag'
    AND target_contract_id = v_contract_id
    AND assigned_to_user_id = p_assignee_id
    AND assigned_by_user_id = p_actor_id
    AND status IN ('open', 'in_progress')
    AND is_active = TRUE
  LIMIT 1;

  IF v_wo IS NULL THEN
    -- First tag of this assigner → approver on this contract: one work order…
    BEGIN
      PERFORM fn_work_order_auto_insert(
        'redline_approver_tag', v_contract_id, v_contract_id,
        p_assignee_id, p_actor_id, NULL, NULL,
        jsonb_build_object('kind', 'redline_review', 'contractNumber', v_contract_number),
        FALSE
      );
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    -- …and one in-app bell notification (priority high clears the default
    -- subscription floor; NULL template → subject/body are used literally).
    BEGIN
      PERFORM fn_notification_send(
        p_actor_id,
        NULL::BIGINT,
        'approval_request',
        'in_app',
        'high',
        p_assignee_id,
        NULL::TEXT,
        jsonb_build_object(
          'subject', 'Redline review assigned — ' || COALESCE(v_contract_number, 'contract'),
          'bodyRendered',
            COALESCE(v_assigner_name, 'A reviewer')
            || ' has asked you to review counterparty redline changes on '
            || COALESCE(v_contract_number, 'a contract')
            || '. Open the contract''s Redline tab to accept or reject the changes.',
          'contractId', v_contract_id,
          'contractNumber', v_contract_number,
          'clauseHeading', v_heading,
          'source', 'redline.approver_assigned'
        ),
        NULL::BIGINT
      );
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END IF;

  RETURN jsonb_build_object('changeId', p_change_id, 'assignedTo', p_assignee_id, 'assigneeName', v_assignee_name);
END;
$fn$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (713, 'redline_assign_group_and_notify', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- (restore the mig-711 body of fn_contract_redline_change_assign)
-- DELETE FROM schema_migrations WHERE version = 713;
-- ROLLBACK END
-- ============================================================================
