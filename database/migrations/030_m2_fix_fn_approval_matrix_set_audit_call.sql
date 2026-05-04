-- ============================================================================
-- 030_m2_fix_fn_approval_matrix_set_audit_call.sql — Patch (Agent 6, M2)
-- ============================================================================
-- Module:    M2 (Approval Workflows) — patch on 025
-- Owner:     Agent 6 — DB Implementation (report-don't-fix protocol)
-- Depends:   025_m2_approval_functions.sql, 011_m1b_export_and_payment_functions.sql
-- ----------------------------------------------------------------------------
-- Bug discovered during DB Impl functional verification (test branch):
--
-- Migration 025 fn_approval_matrix_set body called fn_audit_log_record using
-- the signature implied by db-design.md Section 2:
--
--     PERFORM fn_audit_log_record(
--       p_actor_id,                              -- BIGINT
--       'APPROVAL_MATRIX_SET',                   -- TEXT (action)
--       jsonb_build_object(...)                  -- JSONB
--     );
--
-- However, the canonical M1b 011 signature is:
--
--     fn_audit_log_record(
--       p_table_name TEXT,
--       p_record_id  BIGINT,
--       p_action     TEXT,
--       p_new_values JSONB,
--       p_actor_id   BIGINT DEFAULT NULL
--     )
--
-- And p_action is constrained to {'INSERT','UPDATE','DELETE'} (the M0 audit_log
-- action CHECK enum); the EXPORT event used by M1b passes 'INSERT' with a
-- new_values discriminator field.
--
-- Without this patch, fn_approval_matrix_set fails at runtime with:
--   ERROR  42883  function fn_audit_log_record(bigint, unknown, jsonb) does not exist
--
-- This is a deviation from db-design.md Section 2 step 9 — surfaced via the
-- DB Impl functional probe per memory feedback_db_impl_report_dont_fix.md.
-- The deviation is reported in db-impl-summary.json.deviationsFromDesign.
--
-- Fix:
--   CREATE OR REPLACE fn_approval_matrix_set with the correct fn_audit_log_record
--   call. Use 'INSERT' as the action (preserving the M0 enum) with a new_values
--   discriminator { event: 'APPROVAL_MATRIX_SET', ... }. table_name = 'approval_matrix'.
--   record_id = first inserted rule id (or NULL if the array is empty — guarded by
--   the rules-non-empty check earlier in the function).
-- ----------------------------------------------------------------------------

BEGIN;

CREATE OR REPLACE FUNCTION fn_approval_matrix_set(
  p_actor_id      BIGINT,
  p_contract_type TEXT,
  p_min_value_aed NUMERIC,
  p_rules         JSONB,
  p_max_value_aed NUMERIC DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rule           JSONB;
  v_step_orders    INTEGER[] := ARRAY[]::INTEGER[];
  v_distinct_steps INTEGER[];
  v_expected       INTEGER[];
  v_rule_ids       BIGINT[]  := ARRAY[]::BIGINT[];
  v_id             BIGINT;
  v_role_name      TEXT;
  v_idx            INTEGER;
  v_step_order     INTEGER;
  v_parallel_group INTEGER;
  v_is_required    BOOLEAN;
  v_escalation_role TEXT;
  v_escalation_after_hours INTEGER;
  v_approver_role  TEXT;
BEGIN
  IF NOT fn_current_user_has_permission('approval.matrix.write') THEN
    RAISE EXCEPTION 'fn_approval_matrix_set: %', 'permission:approval.matrix.write required'
      USING ERRCODE = '42501';
  END IF;

  IF p_contract_type IS NULL OR p_contract_type = '' THEN
    RAISE EXCEPTION 'fn_approval_matrix_set: %', 'contractType:contractType is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_contract_type NOT IN ('employment','msa','sow','nda','vendor','partnership','consulting','other') THEN
    RAISE EXCEPTION 'fn_approval_matrix_set: %', 'contractType:Invalid contract type'
      USING ERRCODE = '23514';
  END IF;
  IF p_min_value_aed IS NULL OR p_min_value_aed < 0 THEN
    RAISE EXCEPTION 'fn_approval_matrix_set: %', 'minValueAed:minValueAed must be >= 0'
      USING ERRCODE = '22023';
  END IF;
  IF p_max_value_aed IS NOT NULL AND p_max_value_aed < p_min_value_aed THEN
    RAISE EXCEPTION 'fn_approval_matrix_set: %', 'maxValueAed:maxValueAed must be >= minValueAed'
      USING ERRCODE = '22023';
  END IF;
  IF p_rules IS NULL OR jsonb_typeof(p_rules) <> 'array' OR jsonb_array_length(p_rules) = 0 THEN
    RAISE EXCEPTION 'fn_approval_matrix_set: %', 'rules:rules array must not be empty'
      USING ERRCODE = '22023';
  END IF;

  v_idx := 0;
  FOR v_rule IN SELECT * FROM jsonb_array_elements(p_rules)
  LOOP
    v_step_order     := (v_rule->>'stepOrder')::INTEGER;
    v_parallel_group := NULLIF(v_rule->>'parallelGroup','')::INTEGER;
    v_approver_role  := v_rule->>'approverRole';
    v_is_required    := COALESCE((v_rule->>'isRequired')::BOOLEAN, TRUE);
    v_escalation_role := v_rule->>'escalationRole';
    v_escalation_after_hours := NULLIF(v_rule->>'escalationAfterHours','')::INTEGER;

    IF v_step_order IS NULL OR v_step_order < 1 THEN
      RAISE EXCEPTION 'fn_approval_matrix_set: %',
        format('rules[%s].stepOrder:stepOrder must be >= 1', v_idx)
        USING ERRCODE = '22023';
    END IF;
    IF v_parallel_group IS NOT NULL AND v_parallel_group <> v_step_order THEN
      RAISE EXCEPTION 'fn_approval_matrix_set: %',
        format('rules[%s].parallelGroup:parallelGroup must equal stepOrder', v_idx)
        USING ERRCODE = '23514';
    END IF;
    IF v_approver_role IS NULL OR v_approver_role = '' THEN
      RAISE EXCEPTION 'fn_approval_matrix_set: %',
        format('rules[%s].approverRole:approverRole is required', v_idx)
        USING ERRCODE = '22023';
    END IF;
    SELECT r.name INTO v_role_name FROM role r WHERE r.name = v_approver_role;
    IF v_role_name IS NULL THEN
      RAISE EXCEPTION 'fn_approval_matrix_set: %',
        format('rules[%s].approverRole:Role does not exist', v_idx)
        USING ERRCODE = 'P0002';
    END IF;
    IF v_escalation_role IS NOT NULL THEN
      SELECT r.name INTO v_role_name FROM role r WHERE r.name = v_escalation_role;
      IF v_role_name IS NULL THEN
        RAISE EXCEPTION 'fn_approval_matrix_set: %',
          format('rules[%s].escalationRole:Escalation role does not exist', v_idx)
          USING ERRCODE = 'P0002';
      END IF;
    END IF;
    IF v_escalation_after_hours IS NOT NULL AND v_escalation_after_hours <= 0 THEN
      RAISE EXCEPTION 'fn_approval_matrix_set: %',
        format('rules[%s].escalationAfterHours:escalationAfterHours must be > 0', v_idx)
        USING ERRCODE = '22023';
    END IF;

    v_step_orders := v_step_orders || v_step_order;
    v_idx := v_idx + 1;
  END LOOP;

  SELECT ARRAY(SELECT DISTINCT unnest(v_step_orders) ORDER BY 1) INTO v_distinct_steps;
  SELECT ARRAY(SELECT generate_series(1, COALESCE(array_length(v_distinct_steps, 1), 0))) INTO v_expected;
  IF v_distinct_steps IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'fn_approval_matrix_set: %',
      'rules:step_order has gaps; expected sequence 1..N'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext(p_contract_type || ':' || p_min_value_aed::text || ':' || COALESCE(p_max_value_aed::text, ''))
  );

  UPDATE approval_matrix
    SET is_active  = FALSE,
        updated_by = p_actor_id,
        updated_at = CURRENT_TIMESTAMP
    WHERE contract_type = p_contract_type
      AND min_value_aed = p_min_value_aed
      AND COALESCE(max_value_aed, -1) = COALESCE(p_max_value_aed, -1)
      AND is_active = TRUE;

  v_idx := 0;
  FOR v_rule IN SELECT * FROM jsonb_array_elements(p_rules)
  LOOP
    INSERT INTO approval_matrix (
      contract_type, min_value_aed, max_value_aed,
      step_order, parallel_group, approver_role,
      is_required, escalation_role, escalation_after_hours,
      created_by, updated_by, is_active
    ) VALUES (
      p_contract_type, p_min_value_aed, p_max_value_aed,
      (v_rule->>'stepOrder')::INTEGER,
      NULLIF(v_rule->>'parallelGroup','')::INTEGER,
      v_rule->>'approverRole',
      COALESCE((v_rule->>'isRequired')::BOOLEAN, TRUE),
      v_rule->>'escalationRole',
      NULLIF(v_rule->>'escalationAfterHours','')::INTEGER,
      p_actor_id, p_actor_id, TRUE
    ) RETURNING id INTO v_id;
    v_rule_ids := v_rule_ids || v_id;
    v_idx := v_idx + 1;
  END LOOP;

  -- AC-S5-08 — high-level audit log (PATCH 030: correct fn_audit_log_record signature)
  -- M1b 011 signature: (p_table_name TEXT, p_record_id BIGINT, p_action TEXT, p_new_values JSONB, p_actor_id BIGINT DEFAULT NULL)
  -- p_action constrained to {INSERT,UPDATE,DELETE}; we use 'INSERT' with new_values.event discriminator.
  PERFORM fn_audit_log_record(
    'approval_matrix',
    v_rule_ids[1],
    'INSERT',
    jsonb_build_object(
      'event',        'APPROVAL_MATRIX_SET',
      'contractType', p_contract_type,
      'minValueAed',  p_min_value_aed,
      'maxValueAed',  p_max_value_aed,
      'ruleCount',    array_length(v_rule_ids, 1),
      'ruleIds',      v_rule_ids
    ),
    p_actor_id
  );

  RETURN jsonb_build_object(
    'contractType', p_contract_type,
    'minValueAed',  p_min_value_aed,
    'maxValueAed',  p_max_value_aed,
    'ruleCount',    array_length(v_rule_ids, 1),
    'ruleIds',      v_rule_ids
  );
END;
$$;

COMMENT ON FUNCTION fn_approval_matrix_set(BIGINT, TEXT, NUMERIC, JSONB, NUMERIC) IS
  'M2 S5 — write, INVOKER. Permission gate: approval.matrix.write. Atomic replace-all-or-nothing for the (contract_type, min, max) range. PATCH 030: fn_audit_log_record signature corrected to M1b 011 canonical (TEXT,BIGINT,TEXT,JSONB,BIGINT) with event discriminator.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (30, 'm2_fix_fn_approval_matrix_set_audit_call', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
-- No-op rollback: 030 only changes the audit-log call signature; rolling back
-- restores the broken-at-runtime version. We instead suggest rolling back 025+
-- if a true revert is needed. Recording this as a marker so the runner's
-- --down command at this version reports cleanly.
DELETE FROM schema_migrations WHERE version = 30;
COMMIT;
-- ROLLBACK END
