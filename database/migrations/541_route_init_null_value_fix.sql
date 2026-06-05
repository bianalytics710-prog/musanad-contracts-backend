-- MIGRATION: 541_route_init_null_value_fix.sql
-- Date: 2026-06-04
-- Description:
--   fn_approval_route_init's matrix lookup uses
--   `v_contract.value_aed BETWEEN m.min_value_aed AND COALESCE(m.max_value_aed, ...)`.
--   When value_aed is NULL (common for NDAs, MSAs, framework agreements that
--   carry no monetary value at signing), BETWEEN returns NULL → no match →
--   the fn raises "No approval rule configured for contract type … at value ".
--   Result: those contracts can never be routed through the approval matrix.
--
--   Fix: coalesce a NULL value_aed to 0 for the matrix lookup. The matrix
--   already has entries with min_value_aed=0 for NDA/MSA — they now match.
--   No change to the matrix data itself; the semantics are "if no value is
--   given, treat it as the lowest band so the cheapest approval path applies."

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_approval_route_init(p_contract_id bigint, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_contract       contract%ROWTYPE;
  v_existing_chain bigint;
  v_chain_id       bigint;
  v_snapshot       jsonb;
  v_total_steps    integer;
  v_rule           approval_matrix%ROWTYPE;
  v_value_match    numeric;
BEGIN
  -- Lock the contract row + verify it exists and is draftable.
  SELECT * INTO v_contract
    FROM contract
    WHERE id = p_contract_id AND is_active = TRUE
    FOR UPDATE;
  IF v_contract.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_route_init: %', 'id:Contract not found'
      USING ERRCODE = 'P0002';
  END IF;
  IF v_contract.status NOT IN ('draft', 'resubmission_requested') THEN
    RAISE EXCEPTION 'fn_approval_route_init: %',
      format('status:Contract status %s does not allow re-routing', v_contract.status)
      USING ERRCODE = 'P0001';
  END IF;

  -- Reject if an in-progress chain already exists for this contract.
  SELECT id INTO v_existing_chain
    FROM approval_chain
    WHERE contract_id = p_contract_id
      AND is_active = TRUE
      AND status = 'in_progress'
    FOR UPDATE;
  IF v_existing_chain IS NOT NULL THEN
    RAISE EXCEPTION 'fn_approval_route_init: %', 'id:Contract already has an in-progress approval chain'
      USING ERRCODE = 'P0001';
  END IF;

  -- Coalesce NULL value_aed → 0 so NDAs / MSAs / framework agreements with no
  -- monetary value still match the lowest matrix band (where min_value_aed=0).
  v_value_match := COALESCE(v_contract.value_aed, 0);

  -- Build matrix_snapshot from current rules.
  SELECT
    COALESCE(jsonb_agg(
      jsonb_build_object(
        'stepOrder',     m.step_order,
        'parallelGroup', m.parallel_group,
        'approverRole',  m.approver_role,
        'isRequired',    m.is_required,
        'escalationRole', m.escalation_role,
        'escalationAfterHours', m.escalation_after_hours
      )
      ORDER BY m.step_order ASC, m.parallel_group NULLS FIRST
    ), '[]'::jsonb),
    COUNT(*)
    INTO v_snapshot, v_total_steps
    FROM approval_matrix m
    WHERE m.contract_type = v_contract.contract_type
      AND v_value_match BETWEEN m.min_value_aed AND COALESCE(m.max_value_aed, 999999999999.99)
      AND m.is_active = TRUE;

  IF v_total_steps = 0 THEN
    RAISE EXCEPTION 'fn_approval_route_init: %',
      format('contractType:No approval rule configured for contract type %s at value %s',
             v_contract.contract_type, v_value_match)
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO approval_chain (
    contract_id, matrix_snapshot, status, current_step_order,
    initiated_by, initiated_at, created_by, updated_by, is_active
  ) VALUES (
    p_contract_id, v_snapshot, 'in_progress', 1,
    p_actor_id, CURRENT_TIMESTAMP, p_actor_id, p_actor_id, TRUE
  ) RETURNING id INTO v_chain_id;

  FOR v_rule IN
    SELECT m.*
      FROM approval_matrix m
      WHERE m.contract_type = v_contract.contract_type
        AND v_value_match BETWEEN m.min_value_aed AND COALESCE(m.max_value_aed, 999999999999.99)
        AND m.is_active = TRUE
      ORDER BY m.step_order ASC, m.parallel_group NULLS FIRST
  LOOP
    INSERT INTO approval_step (
      approval_chain_id, step_order, parallel_group,
      approver_user_id, approver_role,
      is_required, escalation_role, escalation_after_hours,
      status, created_by, updated_by, is_active
    ) VALUES (
      v_chain_id, v_rule.step_order, v_rule.parallel_group,
      NULL, v_rule.approver_role,
      v_rule.is_required, v_rule.escalation_role, v_rule.escalation_after_hours,
      'pending', p_actor_id, p_actor_id, TRUE
    );
  END LOOP;

  -- Flip contract status to in_approval.
  UPDATE contract
     SET status = 'in_approval',
         updated_at = CURRENT_TIMESTAMP,
         updated_by = p_actor_id
   WHERE id = p_contract_id;

  RETURN jsonb_build_object(
    'chainId',       v_chain_id,
    'totalSteps',    v_total_steps,
    'matrixSnapshot', v_snapshot
  );
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (541, 'route_init_null_value_fix', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
