-- ============================================================================
-- 025_m2_approval_functions.sql — All 11 owned fn_approval_* functions
-- ============================================================================
-- Module:    M2 (Approval Workflows)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   023_m2_extend_contract_status_check.sql,
--            024_m2_approval_tables_rls_indexes.sql,
--            026 (fn_contract_status_update_internal — see note below)
-- ----------------------------------------------------------------------------
-- All 11 owned fn_'s for M2:
--   Read (5): fn_approval_my_pending, fn_approval_matrix_list,
--             fn_approval_route_init_preview, fn_approval_chain_get,
--             fn_approval_chain_list
--   Write (6): fn_approval_decide, fn_approval_delegate,
--              fn_approval_matrix_set, fn_approval_route_init,
--              fn_approval_reassign, fn_approval_escalate
--
-- Forward reference: fn_approval_decide PERFORMs fn_contract_status_update_internal
-- which is created in 026. To avoid 025-vs-026 ordering breakage, we use an
-- EXECUTE-by-name plpgsql call (resolved at runtime) — this is a Postgres
-- behaviour: PERFORM fn_x(...) inside a plpgsql body resolves names at *call*
-- time, not at function-creation time. So 025 can reference fn_contract_status_update_internal
-- before 026 creates it; the reference only needs to exist when fn_approval_decide
-- is actually invoked.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- 1. fn_approval_my_pending (S1 — read, INVOKER, STABLE)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approval_my_pending(
  p_actor_id BIGINT,
  p_page     INTEGER DEFAULT 1,
  p_limit    INTEGER DEFAULT 20,
  p_sort     TEXT    DEFAULT 'oldest'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset    INTEGER := GREATEST(p_page - 1, 0) * GREATEST(p_limit, 1);
  v_roles     TEXT[];
  v_total     INTEGER;
  v_data      JSONB;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_my_pending: %', 'actorId:Actor id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_sort IS NOT NULL AND p_sort NOT IN ('oldest','newest','highest_value') THEN
    RAISE EXCEPTION 'fn_approval_my_pending: %', 'sort:Invalid sort key'
      USING ERRCODE = '22023';
  END IF;

  SELECT ARRAY[r.name]
    INTO v_roles
    FROM "user" u
    INNER JOIN role r ON r.id = u.role_id
    WHERE u.id = p_actor_id
      AND u.is_active = TRUE;
  IF v_roles IS NULL THEN
    v_roles := ARRAY[]::TEXT[];
  END IF;

  SELECT COUNT(*)
    INTO v_total
    FROM approval_step s
    INNER JOIN approval_chain ch ON ch.id = s.approval_chain_id
    INNER JOIN contract c        ON c.id  = ch.contract_id
    WHERE s.is_active = TRUE
      AND s.status = 'pending'
      AND ch.is_active = TRUE
      AND ch.status = 'in_progress'
      AND c.is_active = TRUE
      AND (
        s.approver_user_id = p_actor_id
        OR (s.approver_user_id IS NULL AND s.approver_role = ANY(v_roles))
        OR s.delegated_to = p_actor_id
        OR s.reassigned_to = p_actor_id
      );

  SELECT COALESCE(jsonb_agg(row_data ORDER BY ord_key1, ord_key2, ord_key3), '[]'::jsonb)
    INTO v_data
    FROM (
      SELECT
        jsonb_build_object(
          'stepId',           s.id,
          'chainId',          ch.id,
          'contractId',       c.id,
          'contractNumber',   c.contract_number,
          'contractTitleEn',  c.title_en,
          'contractTitleAr',  c.title_ar,
          'valueAed',         c.value_aed,
          'requesterUserRef', fn_user_get_by_id(ch.initiated_by),
          'stepOrder',        s.step_order,
          'parallelGroup',    s.parallel_group,
          'isRequired',       s.is_required,
          'hoursPending',     ROUND(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - s.created_at)) / 3600.0, 2),
          'escalationRole',   s.escalation_role,
          'escalationAfterHours', s.escalation_after_hours
        ) AS row_data,
        CASE p_sort
          WHEN 'newest'        THEN EXTRACT(EPOCH FROM s.created_at) * -1
          WHEN 'highest_value' THEN COALESCE(c.value_aed, 0) * -1
          ELSE EXTRACT(EPOCH FROM s.created_at)
        END AS ord_key1,
        CASE p_sort WHEN 'highest_value' THEN EXTRACT(EPOCH FROM s.created_at) ELSE 0 END AS ord_key2,
        s.id::numeric AS ord_key3
      FROM approval_step s
      INNER JOIN approval_chain ch ON ch.id = s.approval_chain_id
      INNER JOIN contract c        ON c.id  = ch.contract_id
      WHERE s.is_active = TRUE
        AND s.status = 'pending'
        AND ch.is_active = TRUE
        AND ch.status = 'in_progress'
        AND c.is_active = TRUE
        AND (
          s.approver_user_id = p_actor_id
          OR (s.approver_user_id IS NULL AND s.approver_role = ANY(v_roles))
          OR s.delegated_to = p_actor_id
          OR s.reassigned_to = p_actor_id
        )
      ORDER BY ord_key1, ord_key2, ord_key3
      LIMIT GREATEST(p_limit, 1) OFFSET v_offset
    ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', v_total,
      'page',  p_page,
      'limit', p_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0
                         ELSE CEIL(v_total::numeric / GREATEST(p_limit, 1))::int END
    )
  );
END;
$$;

COMMENT ON FUNCTION fn_approval_my_pending(BIGINT, INTEGER, INTEGER, TEXT) IS
  'M2 S1 — read, STABLE, INVOKER. Returns paginated pending approval steps for the actor (4 OR-arms: direct user, role-based, delegated, reassigned).';

-- ============================================================
-- 2. fn_approval_matrix_list (S4 — read, INVOKER, STABLE)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approval_matrix_list(
  p_actor_id      BIGINT,
  p_page          INTEGER DEFAULT 1,
  p_limit         INTEGER DEFAULT 50,
  p_contract_type TEXT    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset INTEGER := GREATEST(p_page - 1, 0) * GREATEST(p_limit, 1);
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('approval.matrix.read') THEN
    RAISE EXCEPTION 'fn_approval_matrix_list: %', 'permission:approval.matrix.read required'
      USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*)
    INTO v_total
    FROM approval_matrix m
    WHERE m.is_active = TRUE
      AND (p_contract_type IS NULL OR m.contract_type = p_contract_type);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', m.id,
      'contractType', m.contract_type,
      'minValueAed',  m.min_value_aed,
      'maxValueAed',  m.max_value_aed,
      'stepOrder',    m.step_order,
      'parallelGroup', m.parallel_group,
      'approverRole', m.approver_role,
      'isRequired',   m.is_required,
      'escalationRole', m.escalation_role,
      'escalationAfterHours', m.escalation_after_hours,
      'createdAt',    m.created_at,
      'updatedAt',    m.updated_at
    )
    ORDER BY m.contract_type ASC, m.step_order ASC, m.parallel_group NULLS FIRST, m.approver_role ASC
  ), '[]'::jsonb) INTO v_data
  FROM (
    SELECT *
      FROM approval_matrix
      WHERE is_active = TRUE
        AND (p_contract_type IS NULL OR contract_type = p_contract_type)
      ORDER BY contract_type ASC, step_order ASC, parallel_group NULLS FIRST, approver_role ASC
      LIMIT GREATEST(p_limit, 1) OFFSET v_offset
  ) m;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', v_total,
      'page',  p_page,
      'limit', p_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0
                         ELSE CEIL(v_total::numeric / GREATEST(p_limit, 1))::int END
    )
  );
END;
$$;

COMMENT ON FUNCTION fn_approval_matrix_list(BIGINT, INTEGER, INTEGER, TEXT) IS
  'M2 S4 — read, STABLE, INVOKER. Permission gate: approval.matrix.read.';

-- ============================================================
-- 3. fn_approval_route_init_preview (S6 — read, INVOKER, STABLE)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approval_route_init_preview(
  p_actor_id      BIGINT,
  p_contract_type TEXT,
  p_value_aed     NUMERIC
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_steps JSONB;
  v_count INTEGER;
BEGIN
  IF p_contract_type IS NULL OR p_contract_type = '' THEN
    RAISE EXCEPTION 'fn_approval_route_init_preview: %', 'contractType:contractType is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_value_aed IS NULL OR p_value_aed < 0 THEN
    RAISE EXCEPTION 'fn_approval_route_init_preview: %', 'valueAed:valueAed must be >= 0'
      USING ERRCODE = '22023';
  END IF;

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
    INTO v_steps, v_count
    FROM approval_matrix m
    WHERE m.contract_type = p_contract_type
      AND p_value_aed BETWEEN m.min_value_aed AND COALESCE(m.max_value_aed, 999999999999.99)
      AND m.is_active = TRUE;

  RETURN jsonb_build_object(
    'contractType',     p_contract_type,
    'valueAed',         p_value_aed,
    'steps',            v_steps,
    'hasNoMatchingRule', (v_count = 0)
  );
END;
$$;

COMMENT ON FUNCTION fn_approval_route_init_preview(BIGINT, TEXT, NUMERIC) IS
  'M2 S6 — read, STABLE, INVOKER. Returns chain projection without persistence.';

-- ============================================================
-- 4. fn_approval_chain_get (S10 — read, INVOKER, STABLE)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approval_chain_get(
  p_actor_id    BIGINT,
  p_chain_id    BIGINT DEFAULT NULL,
  p_contract_id BIGINT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_chain RECORD;
  v_steps JSONB;
  v_can_see_inactive BOOLEAN := FALSE;
BEGIN
  IF p_chain_id IS NULL AND p_contract_id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_chain_get: %', 'id:chainId or contractId is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM "user" u INNER JOIN role r ON r.id = u.role_id
      WHERE u.id = p_actor_id AND r.name IN ('platform_admin','Super Admin','legal_counsel')
  ) INTO v_can_see_inactive;

  IF p_chain_id IS NOT NULL THEN
    SELECT ch.*
      INTO v_chain
      FROM approval_chain ch
      WHERE ch.id = p_chain_id
        AND (v_can_see_inactive OR ch.is_active = TRUE);
  ELSE
    SELECT ch.*
      INTO v_chain
      FROM approval_chain ch
      WHERE ch.contract_id = p_contract_id
        AND (v_can_see_inactive OR ch.is_active = TRUE)
      ORDER BY ch.initiated_at DESC
      LIMIT 1;
  END IF;

  IF v_chain.id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',                   s.id,
      'stepOrder',            s.step_order,
      'parallelGroup',        s.parallel_group,
      'approverRole',         s.approver_role,
      'approverUser',         CASE WHEN s.approver_user_id IS NULL THEN NULL ELSE fn_user_get_by_id(s.approver_user_id) END,
      'status',               s.status,
      'isRequired',           s.is_required,
      'escalationRole',       s.escalation_role,
      'escalationAfterHours', s.escalation_after_hours,
      'reassignedTo',         CASE WHEN s.reassigned_to IS NULL THEN NULL ELSE fn_user_get_by_id(s.reassigned_to) END,
      'delegatedTo',          CASE WHEN s.delegated_to IS NULL THEN NULL ELSE fn_user_get_by_id(s.delegated_to) END,
      'decidedAt',            s.decided_at,
      'decisions', (
        SELECT COALESCE(jsonb_agg(
          jsonb_build_object(
            'id',           d.id,
            'decision',     d.decision,
            'decisionNote', d.decision_note,
            'decidedBy',    fn_user_get_by_id(d.decided_by),
            'decidedAt',    d.decided_at,
            'metadata',     d.metadata
          )
          ORDER BY d.decided_at ASC, d.id ASC
        ), '[]'::jsonb)
        FROM approval_decision d
        WHERE d.approval_step_id = s.id
          AND d.is_active = TRUE
      )
    )
    ORDER BY s.step_order ASC, s.parallel_group NULLS FIRST, s.id ASC
  ), '[]'::jsonb) INTO v_steps
  FROM approval_step s
  WHERE s.approval_chain_id = v_chain.id
    AND (v_can_see_inactive OR s.is_active = TRUE);

  RETURN jsonb_build_object(
    'chain', jsonb_build_object(
      'id',                v_chain.id,
      'contractId',        v_chain.contract_id,
      'status',            v_chain.status,
      'currentStepOrder',  v_chain.current_step_order,
      'submittedBy',       fn_user_get_by_id(v_chain.initiated_by),
      'submittedAt',       v_chain.initiated_at,
      'completedAt',       v_chain.completed_at,
      'isActive',          v_chain.is_active
    ),
    'steps', v_steps
  );
END;
$$;

COMMENT ON FUNCTION fn_approval_chain_get(BIGINT, BIGINT, BIGINT) IS
  'M2 S10 — read, STABLE, INVOKER. Full chain detail with steps and decisions.';

-- ============================================================
-- 5. fn_approval_chain_list (S11 — read, INVOKER, STABLE)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approval_chain_list(
  p_actor_id     BIGINT,
  p_page         INTEGER DEFAULT 1,
  p_limit        INTEGER DEFAULT 20,
  p_contract_id  BIGINT  DEFAULT NULL,
  p_status       TEXT    DEFAULT NULL,
  p_submitted_by BIGINT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offset INTEGER := GREATEST(p_page - 1, 0) * GREATEST(p_limit, 1);
  v_total  INTEGER;
  v_data   JSONB;
BEGIN
  IF p_status IS NOT NULL AND p_status NOT IN ('in_progress','approved','rejected','resubmission_requested','cancelled') THEN
    RAISE EXCEPTION 'fn_approval_chain_list: %', 'status:Invalid status filter'
      USING ERRCODE = '22023';
  END IF;

  SELECT COUNT(*)
    INTO v_total
    FROM approval_chain ch
    INNER JOIN contract c ON c.id = ch.contract_id
    WHERE ch.is_active = TRUE
      AND c.is_active = TRUE
      AND (p_contract_id  IS NULL OR ch.contract_id  = p_contract_id)
      AND (p_status       IS NULL OR ch.status       = p_status)
      AND (p_submitted_by IS NULL OR ch.initiated_by = p_submitted_by);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',               ch.id,
      'contractId',       ch.contract_id,
      'contractNumber',   c.contract_number,
      'status',           ch.status,
      'currentStepOrder', ch.current_step_order,
      'totalSteps',       (SELECT COUNT(*) FROM approval_step s WHERE s.approval_chain_id = ch.id AND s.is_active = TRUE),
      'submittedBy',      fn_user_get_by_id(ch.initiated_by),
      'submittedAt',      ch.initiated_at,
      'completedAt',      ch.completed_at,
      'hoursPending',     ROUND(EXTRACT(EPOCH FROM (COALESCE(ch.completed_at, CURRENT_TIMESTAMP) - ch.initiated_at)) / 3600.0, 2)
    )
    ORDER BY ch.initiated_at DESC, ch.id DESC
  ), '[]'::jsonb) INTO v_data
  FROM (
    SELECT ch.*
      FROM approval_chain ch
      INNER JOIN contract c ON c.id = ch.contract_id
      WHERE ch.is_active = TRUE
        AND c.is_active = TRUE
        AND (p_contract_id  IS NULL OR ch.contract_id  = p_contract_id)
        AND (p_status       IS NULL OR ch.status       = p_status)
        AND (p_submitted_by IS NULL OR ch.initiated_by = p_submitted_by)
      ORDER BY ch.initiated_at DESC, ch.id DESC
      LIMIT GREATEST(p_limit, 1) OFFSET v_offset
  ) ch
  INNER JOIN contract c ON c.id = ch.contract_id;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total', v_total,
      'page',  p_page,
      'limit', p_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0
                         ELSE CEIL(v_total::numeric / GREATEST(p_limit, 1))::int END
    )
  );
END;
$$;

COMMENT ON FUNCTION fn_approval_chain_list(BIGINT, INTEGER, INTEGER, BIGINT, TEXT, BIGINT) IS
  'M2 S11 — read, STABLE, INVOKER. Admin chain monitor; RLS narrows to readable contracts for non-admin actors.';

-- ============================================================
-- 6. fn_approval_matrix_set (S5 — write, INVOKER, advisory lock)
-- ============================================================
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

  -- Continuity check: distinct step_orders sorted MUST equal 1..N
  SELECT ARRAY(SELECT DISTINCT unnest(v_step_orders) ORDER BY 1) INTO v_distinct_steps;
  SELECT ARRAY(SELECT generate_series(1, COALESCE(array_length(v_distinct_steps, 1), 0))) INTO v_expected;
  IF v_distinct_steps IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'fn_approval_matrix_set: %',
      'rules:step_order has gaps; expected sequence 1..N'
      USING ERRCODE = '22023';
  END IF;

  -- Advisory lock to prevent concurrent admin races
  PERFORM pg_advisory_xact_lock(
    hashtext(p_contract_type || ':' || p_min_value_aed::text || ':' || COALESCE(p_max_value_aed::text, ''))
  );

  -- Soft-delete existing active rows for this exact (type, min, max) tuple
  UPDATE approval_matrix
    SET is_active  = FALSE,
        updated_by = p_actor_id,
        updated_at = CURRENT_TIMESTAMP
    WHERE contract_type = p_contract_type
      AND min_value_aed = p_min_value_aed
      AND COALESCE(max_value_aed, -1) = COALESCE(p_max_value_aed, -1)
      AND is_active = TRUE;

  -- INSERT replacements
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

  -- AC-S5-08: high-level audit log
  PERFORM fn_audit_log_record(
    p_actor_id,
    'APPROVAL_MATRIX_SET',
    jsonb_build_object(
      'contractType', p_contract_type,
      'minValueAed',  p_min_value_aed,
      'maxValueAed',  p_max_value_aed,
      'ruleCount',    array_length(v_rule_ids, 1)
    )
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
  'M2 S5 — write, INVOKER. Permission gate: approval.matrix.write. Atomic replace-all-or-nothing for the (contract_type, min, max) range.';

-- ============================================================
-- 7. fn_approval_route_init (S7 — write, INVOKER, FOR UPDATE on contract)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approval_route_init(
  p_contract_id BIGINT,
  p_actor_id    BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_contract        RECORD;
  v_rule            RECORD;
  v_chain_id        BIGINT;
  v_total_steps     INTEGER := 0;
  v_snapshot        JSONB;
  v_existing_chain  BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('approval.submit_for_review') THEN
    RAISE EXCEPTION 'fn_approval_route_init: %', 'permission:approval.submit_for_review required'
      USING ERRCODE = '42501';
  END IF;

  SELECT id, status, contract_type, value_aed, is_active
    INTO v_contract
    FROM contract
    WHERE id = p_contract_id AND is_active = TRUE
    FOR UPDATE;
  IF v_contract.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_route_init: %', 'id:Contract not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_contract.status NOT IN ('draft','in_review') THEN
    RAISE EXCEPTION 'fn_approval_route_init: %',
      format('newStatus:Invalid transition from %s to in_approval', v_contract.status)
      USING ERRCODE = 'P0001';
  END IF;

  -- Idempotency pre-check + lock the existing in-progress chain row if any
  SELECT id INTO v_existing_chain
    FROM approval_chain
    WHERE contract_id = p_contract_id
      AND status = 'in_progress'
      AND is_active = TRUE
    FOR UPDATE;
  IF v_existing_chain IS NOT NULL THEN
    RAISE EXCEPTION 'fn_approval_route_init: %', 'id:Contract already has an in-progress approval chain'
      USING ERRCODE = 'P0001';
  END IF;

  -- Build matrix_snapshot from current rules
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
      AND v_contract.value_aed BETWEEN m.min_value_aed AND COALESCE(m.max_value_aed, 999999999999.99)
      AND m.is_active = TRUE;

  IF v_total_steps = 0 THEN
    RAISE EXCEPTION 'fn_approval_route_init: %',
      format('contractType:No approval rule configured for contract type %s at value %s',
             v_contract.contract_type, v_contract.value_aed)
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
        AND v_contract.value_aed BETWEEN m.min_value_aed AND COALESCE(m.max_value_aed, 999999999999.99)
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

  -- Transition contract.status to in_approval
  UPDATE contract
    SET status = 'in_approval',
        updated_by = p_actor_id,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_contract_id;

  -- AC-S7-08 — audit-after-render
  PERFORM fn_contract_activity_create(
    p_contract_id, 'submitted_for_approval', p_actor_id, NULL, NULL,
    jsonb_build_object('chainId', v_chain_id, 'totalSteps', v_total_steps)
  );

  RETURN jsonb_build_object(
    'chainId',           v_chain_id,
    'contractId',        p_contract_id,
    'totalSteps',        v_total_steps,
    'currentStepOrder',  1,
    'newContractStatus', 'in_approval'
  );
END;
$$;

COMMENT ON FUNCTION fn_approval_route_init(BIGINT, BIGINT) IS
  'M2 S7 — write, INVOKER. FOR UPDATE on contract. Persists chain + steps + matrix_snapshot atomically; transitions contract.status draft|in_review -> in_approval.';

-- ============================================================
-- 8. fn_approval_decide (S2 — write, INVOKER)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approval_decide(
  p_step_id       BIGINT,
  p_actor_id      BIGINT,
  p_decision      TEXT,
  p_decision_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_step                  RECORD;
  v_chain                 RECORD;
  v_contract_id           BIGINT;
  v_remaining_required    INTEGER;
  v_any_optional_peer     BOOLEAN;
  v_advance               BOOLEAN := FALSE;
  v_next_step_order       INTEGER;
  v_new_step_status       TEXT;
  v_new_chain_status      TEXT;
  v_new_contract_status   TEXT;
  v_advanced_to_step_order INTEGER;
  v_decision_id           BIGINT;
BEGIN
  IF p_decision NOT IN ('approve','reject','request_resubmission') THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'decision:Invalid decision'
      USING ERRCODE = '22023';
  END IF;

  SELECT s.*
    INTO v_step
    FROM approval_step s
    WHERE s.id = p_step_id AND s.is_active = TRUE
    FOR UPDATE;
  IF v_step.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'id:Step not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    v_step.approver_user_id = p_actor_id
    OR v_step.delegated_to  = p_actor_id
    OR v_step.reassigned_to = p_actor_id
  ) THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'actor:Not the assigned approver'
      USING ERRCODE = '42501';
  END IF;

  IF v_step.status <> 'pending' THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'status:Step already decided'
      USING ERRCODE = 'P0001';
  END IF;

  IF p_decision IN ('reject','request_resubmission')
     AND (p_decision_note IS NULL OR length(trim(p_decision_note)) = 0) THEN
    RAISE EXCEPTION 'fn_approval_decide: %',
      format('decisionNote:decisionNote is required for %s', p_decision)
      USING ERRCODE = '22023';
  END IF;

  SELECT ch.*
    INTO v_chain
    FROM approval_chain ch
    WHERE ch.id = v_step.approval_chain_id
    FOR UPDATE;
  IF v_chain.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_decide: %', 'id:Chain not found'
      USING ERRCODE = 'P0002';
  END IF;

  v_contract_id := v_chain.contract_id;
  PERFORM 1 FROM contract WHERE id = v_contract_id FOR UPDATE;

  -- Compute new step status
  v_new_step_status := CASE p_decision
    WHEN 'approve' THEN 'approved'
    WHEN 'reject' THEN 'rejected'
    WHEN 'request_resubmission' THEN 'resubmission_requested'
  END;

  UPDATE approval_step
    SET status     = v_new_step_status,
        decided_at = CURRENT_TIMESTAMP,
        updated_by = p_actor_id,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_step_id;

  INSERT INTO approval_decision (
    approval_step_id, decision, decided_by, decision_note,
    decided_at, created_by, is_active
  ) VALUES (
    p_step_id, p_decision, p_actor_id, p_decision_note,
    CURRENT_TIMESTAMP, p_actor_id, TRUE
  ) RETURNING id INTO v_decision_id;

  -- Reject (required) or request_resubmission -> chain halts
  IF p_decision = 'reject' AND v_step.is_required THEN
    UPDATE approval_chain
      SET status = 'rejected',
          completed_at = CURRENT_TIMESTAMP,
          updated_by = p_actor_id,
          updated_at = CURRENT_TIMESTAMP
      WHERE id = v_chain.id;
    v_new_chain_status := 'rejected';
    PERFORM fn_contract_status_update_internal(v_contract_id, 'rejected', p_actor_id, p_decision_note);
    v_new_contract_status := 'rejected';
  ELSIF p_decision = 'request_resubmission' THEN
    UPDATE approval_chain
      SET status = 'resubmission_requested',
          completed_at = CURRENT_TIMESTAMP,
          updated_by = p_actor_id,
          updated_at = CURRENT_TIMESTAMP
      WHERE id = v_chain.id;
    v_new_chain_status := 'resubmission_requested';
    PERFORM fn_contract_status_update_internal(v_contract_id, 'draft', p_actor_id, p_decision_note);
    v_new_contract_status := 'draft';
  ELSIF p_decision = 'approve' THEN
    -- Parallel-group resolution
    SELECT EXISTS (
      SELECT 1 FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND is_active = TRUE
          AND is_required = FALSE
    ) INTO v_any_optional_peer;

    IF v_any_optional_peer AND v_step.is_required THEN
      -- ANY-OF rule (mixed required + optional peers): approving the required short-circuits the rest
      UPDATE approval_step
        SET status     = 'skipped',
            decided_at = CURRENT_TIMESTAMP,
            updated_by = p_actor_id,
            updated_at = CURRENT_TIMESTAMP
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND status = 'pending'
          AND is_active = TRUE;
      v_advance := TRUE;
    ELSE
      -- ALL-OF rule: advance only when no required peer remains pending
      SELECT COUNT(*)
        INTO v_remaining_required
        FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND step_order = v_step.step_order
          AND id <> p_step_id
          AND is_required = TRUE
          AND status = 'pending'
          AND is_active = TRUE;
      v_advance := (v_remaining_required = 0);
    END IF;

    IF v_advance THEN
      SELECT MIN(step_order) INTO v_next_step_order
        FROM approval_step
        WHERE approval_chain_id = v_chain.id
          AND status = 'pending'
          AND step_order > v_step.step_order
          AND is_active = TRUE;
      IF v_next_step_order IS NULL THEN
        UPDATE approval_chain
          SET status = 'approved',
              current_step_order = v_step.step_order,
              completed_at = CURRENT_TIMESTAMP,
              updated_by = p_actor_id,
              updated_at = CURRENT_TIMESTAMP
          WHERE id = v_chain.id;
        v_new_chain_status := 'approved';
        PERFORM fn_contract_status_update_internal(v_contract_id, 'approved', p_actor_id, p_decision_note);
        v_new_contract_status := 'approved';
      ELSE
        UPDATE approval_chain
          SET current_step_order = v_next_step_order,
              updated_by = p_actor_id,
              updated_at = CURRENT_TIMESTAMP
          WHERE id = v_chain.id;
        v_new_chain_status := 'in_progress';
        v_new_contract_status := 'in_approval';
        v_advanced_to_step_order := v_next_step_order;
      END IF;
    ELSE
      v_new_chain_status := 'in_progress';
      v_new_contract_status := 'in_approval';
    END IF;
  END IF;

  -- AUDIT-AFTER-RENDER (BE-M1b-004)
  PERFORM fn_contract_activity_create(
    v_contract_id, 'approval_decided', p_actor_id, NULL, NULL,
    jsonb_build_object(
      'chainId',         v_chain.id,
      'stepId',          p_step_id,
      'decision',        p_decision,
      'newStepStatus',   v_new_step_status,
      'newChainStatus',  v_new_chain_status,
      'newContractStatus', v_new_contract_status
    )
  );

  RETURN jsonb_build_object(
    'stepId',                p_step_id,
    'chainId',               v_chain.id,
    'contractId',            v_contract_id,
    'decisionId',            v_decision_id,
    'newStepStatus',         v_new_step_status,
    'newChainStatus',        v_new_chain_status,
    'newContractStatus',     v_new_contract_status,
    'advancedToStepOrder',   v_advanced_to_step_order,
    'allChainStepsResolved', (v_new_chain_status <> 'in_progress')
  );
END;
$$;

COMMENT ON FUNCTION fn_approval_decide(BIGINT, BIGINT, TEXT, TEXT) IS
  'M2 S2 — write, INVOKER. Approver acts on a step. Parallel-aware. Atomically inserts decision row, updates step+chain+contract status. Calls fn_contract_status_update_internal for terminal contract transitions.';

-- ============================================================
-- 9. fn_approval_delegate (S3 — write, INVOKER)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approval_delegate(
  p_step_id       BIGINT,
  p_actor_id      BIGINT,
  p_delegated_to  BIGINT,
  p_decision_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_step          RECORD;
  v_chain         RECORD;
  v_target_role   TEXT;
  v_decision_id   BIGINT;
BEGIN
  IF p_delegated_to IS NULL THEN
    RAISE EXCEPTION 'fn_approval_delegate: %', 'delegatedTo:delegatedTo is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT fn_current_user_has_permission('approval.delegate') THEN
    RAISE EXCEPTION 'fn_approval_delegate: %', 'permission:approval.delegate required'
      USING ERRCODE = '42501';
  END IF;

  SELECT s.* INTO v_step
    FROM approval_step s
    WHERE s.id = p_step_id AND s.is_active = TRUE
    FOR UPDATE;
  IF v_step.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_delegate: %', 'id:Step not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_step.approver_user_id IS DISTINCT FROM p_actor_id THEN
    RAISE EXCEPTION 'fn_approval_delegate: %', 'actor:Not the assigned approver'
      USING ERRCODE = '42501';
  END IF;

  IF v_step.status <> 'pending' THEN
    RAISE EXCEPTION 'fn_approval_delegate: %', 'status:Step already decided'
      USING ERRCODE = 'P0001';
  END IF;

  IF p_delegated_to = p_actor_id THEN
    RAISE EXCEPTION 'fn_approval_delegate: %', 'delegatedTo:Cannot delegate to self'
      USING ERRCODE = '22023';
  END IF;

  SELECT r.name INTO v_target_role
    FROM "user" u
    INNER JOIN role r ON r.id = u.role_id
    WHERE u.id = p_delegated_to AND u.is_active = TRUE;

  IF v_target_role IS NULL OR v_target_role NOT IN ('contract_approver','contract_approver_2','legal_counsel') THEN
    RAISE EXCEPTION 'fn_approval_delegate: %', 'delegatedTo:Target user must hold a compatible approver role'
      USING ERRCODE = '22023';
  END IF;

  UPDATE approval_step
    SET delegated_to = p_delegated_to,
        updated_by   = p_actor_id,
        updated_at   = CURRENT_TIMESTAMP
    WHERE id = p_step_id;

  INSERT INTO approval_decision (
    approval_step_id, decision, decided_by, decision_note,
    delegated_to_user_id, decided_at, created_by, is_active
  ) VALUES (
    p_step_id, 'delegate', p_actor_id, p_decision_note,
    p_delegated_to, CURRENT_TIMESTAMP, p_actor_id, TRUE
  ) RETURNING id INTO v_decision_id;

  SELECT ch.* INTO v_chain FROM approval_chain ch WHERE ch.id = v_step.approval_chain_id;

  PERFORM fn_contract_activity_create(
    v_chain.contract_id, 'approval_delegated', p_actor_id, NULL, NULL,
    jsonb_build_object('chainId', v_chain.id, 'stepId', p_step_id, 'delegatedTo', p_delegated_to)
  );

  RETURN jsonb_build_object(
    'stepId',      p_step_id,
    'delegatedTo', fn_user_get_by_id(p_delegated_to),
    'decisionId',  v_decision_id
  );
END;
$$;

COMMENT ON FUNCTION fn_approval_delegate(BIGINT, BIGINT, BIGINT, TEXT) IS
  'M2 S3 — write, INVOKER. Voluntary delegation by assigned approver to another user with compatible role.';

-- ============================================================
-- 10. fn_approval_reassign (S8 — write, INVOKER, admin gate)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approval_reassign(
  p_step_id       BIGINT,
  p_actor_id      BIGINT,
  p_reassigned_to BIGINT,
  p_decision_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_step                RECORD;
  v_chain               RECORD;
  v_target_role         TEXT;
  v_original_approver   BIGINT;
  v_decision_id         BIGINT;
BEGIN
  IF p_reassigned_to IS NULL THEN
    RAISE EXCEPTION 'fn_approval_reassign: %', 'reassignedTo:reassignedTo is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT fn_current_user_has_permission('approval.reassign') THEN
    RAISE EXCEPTION 'fn_approval_reassign: %', 'permission:approval.reassign required'
      USING ERRCODE = '42501';
  END IF;

  SELECT s.* INTO v_step
    FROM approval_step s
    WHERE s.id = p_step_id AND s.is_active = TRUE
    FOR UPDATE;
  IF v_step.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_reassign: %', 'id:Step not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_step.status <> 'pending' THEN
    RAISE EXCEPTION 'fn_approval_reassign: %', 'status:Cannot reassign a non-pending step'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT r.name INTO v_target_role
    FROM "user" u
    INNER JOIN role r ON r.id = u.role_id
    WHERE u.id = p_reassigned_to AND u.is_active = TRUE;

  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'fn_approval_reassign: %', 'reassignedTo:Target user does not exist or has incompatible role'
      USING ERRCODE = '22023';
  END IF;

  IF v_step.approver_role IS NOT NULL
     AND v_target_role NOT IN ('platform_admin','Super Admin','legal_counsel')
     AND v_target_role <> v_step.approver_role THEN
    RAISE EXCEPTION 'fn_approval_reassign: %', 'reassignedTo:Target user does not exist or has incompatible role'
      USING ERRCODE = '22023';
  END IF;

  v_original_approver := v_step.approver_user_id;

  UPDATE approval_step
    SET approver_user_id = p_reassigned_to,
        reassigned_to    = p_reassigned_to,
        updated_by       = p_actor_id,
        updated_at       = CURRENT_TIMESTAMP
    WHERE id = p_step_id;

  INSERT INTO approval_decision (
    approval_step_id, decision, decided_by, decision_note,
    reassigned_to_user_id, metadata, decided_at, created_by, is_active
  ) VALUES (
    p_step_id, 'reassign', p_actor_id, p_decision_note,
    p_reassigned_to,
    jsonb_build_object('originalApproverId', v_original_approver),
    CURRENT_TIMESTAMP, p_actor_id, TRUE
  ) RETURNING id INTO v_decision_id;

  SELECT ch.* INTO v_chain FROM approval_chain ch WHERE ch.id = v_step.approval_chain_id;

  PERFORM fn_contract_activity_create(
    v_chain.contract_id, 'approval_reassigned', p_actor_id, NULL, NULL,
    jsonb_build_object(
      'chainId',            v_chain.id,
      'stepId',             p_step_id,
      'originalApproverId', v_original_approver,
      'reassignedTo',       p_reassigned_to
    )
  );

  RETURN jsonb_build_object(
    'stepId',           p_step_id,
    'originalApprover', CASE WHEN v_original_approver IS NULL THEN NULL ELSE fn_user_get_by_id(v_original_approver) END,
    'reassignedTo',     fn_user_get_by_id(p_reassigned_to),
    'decisionId',       v_decision_id
  );
END;
$$;

COMMENT ON FUNCTION fn_approval_reassign(BIGINT, BIGINT, BIGINT, TEXT) IS
  'M2 S8 — write, INVOKER. Admin reassigns a stalled pending step to another user. Permission gate: approval.reassign.';

-- ============================================================
-- 11. fn_approval_escalate (S9 — write, DEFINER, system-only)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approval_escalate(
  p_step_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_step               RECORD;
  v_chain              RECORD;
  v_existing_peer_id   BIGINT;
  v_new_peer_step_id   BIGINT;
  v_decision_id        BIGINT;
  v_acted              BOOLEAN := FALSE;
BEGIN
  SELECT s.* INTO v_step
    FROM approval_step s
    WHERE s.id = p_step_id AND s.is_active = TRUE
    FOR UPDATE;
  IF v_step.id IS NULL THEN
    RAISE EXCEPTION 'fn_approval_escalate: %', 'id:Step not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_step.status <> 'pending' THEN
    RAISE EXCEPTION 'fn_approval_escalate: %', 'status:Step is not pending'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_step.escalation_role IS NULL OR v_step.escalation_after_hours IS NULL THEN
    RETURN jsonb_build_object(
      'stepId', p_step_id,
      'escalationRole', NULL,
      'escalatedToUserId', NULL,
      'newPeerStepId', NULL,
      'decisionId', NULL,
      'acted', FALSE,
      'reason', 'no escalation configured'
    );
  END IF;

  IF (CURRENT_TIMESTAMP - v_step.created_at) < make_interval(hours => v_step.escalation_after_hours) THEN
    RAISE EXCEPTION 'fn_approval_escalate: %', 'status:escalation_after_hours has not yet elapsed'
      USING ERRCODE = 'P0001';
  END IF;

  -- Idempotency (M2-NEW-3): existing peer with same step_order + escalation_role
  SELECT s2.id INTO v_existing_peer_id
    FROM approval_step s2
    WHERE s2.approval_chain_id = v_step.approval_chain_id
      AND s2.step_order = v_step.step_order
      AND s2.parallel_group = v_step.step_order
      AND s2.approver_role = v_step.escalation_role
      AND s2.is_active = TRUE
    FOR UPDATE;
  IF v_existing_peer_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'stepId', p_step_id,
      'escalationRole', v_step.escalation_role,
      'escalatedToUserId', NULL,
      'newPeerStepId', v_existing_peer_id,
      'decisionId', NULL,
      'acted', FALSE,
      'reason', 'already escalated'
    );
  END IF;

  -- Promote sequential to parallel if needed
  IF v_step.parallel_group IS NULL THEN
    UPDATE approval_step
      SET parallel_group = v_step.step_order,
          updated_at = CURRENT_TIMESTAMP
      WHERE id = p_step_id;
  END IF;

  INSERT INTO approval_step (
    approval_chain_id, step_order, parallel_group,
    approver_user_id, approver_role,
    is_required, escalation_role, escalation_after_hours,
    status, created_by, updated_by, is_active
  ) VALUES (
    v_step.approval_chain_id, v_step.step_order, v_step.step_order,
    NULL, v_step.escalation_role,
    v_step.is_required, NULL, NULL,
    'pending', NULL, NULL, TRUE
  ) RETURNING id INTO v_new_peer_step_id;

  SELECT ch.* INTO v_chain FROM approval_chain ch WHERE ch.id = v_step.approval_chain_id;

  -- decided_by uses chain.initiated_by + metadata.systemEvent=true (no synthetic system user)
  INSERT INTO approval_decision (
    approval_step_id, decision, decided_by, decision_note,
    metadata, decided_at, created_by, is_active
  ) VALUES (
    p_step_id, 'escalate', v_chain.initiated_by, NULL,
    jsonb_build_object(
      'systemEvent',     TRUE,
      'escalationRole',  v_step.escalation_role,
      'originalStepId',  p_step_id,
      'newPeerStepId',   v_new_peer_step_id
    ),
    CURRENT_TIMESTAMP, NULL, TRUE
  ) RETURNING id INTO v_decision_id;

  PERFORM fn_contract_activity_create(
    v_chain.contract_id, 'approval_escalated', NULL, NULL, NULL,
    jsonb_build_object(
      'chainId',         v_chain.id,
      'stepId',          p_step_id,
      'escalationRole',  v_step.escalation_role,
      'newPeerStepId',   v_new_peer_step_id
    )
  );

  v_acted := TRUE;

  RETURN jsonb_build_object(
    'stepId',            p_step_id,
    'escalationRole',    v_step.escalation_role,
    'escalatedToUserId', NULL,
    'newPeerStepId',     v_new_peer_step_id,
    'decisionId',        v_decision_id,
    'acted',             v_acted
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_approval_escalate(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_approval_escalate(BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_approval_escalate(BIGINT) IS
  'M2 S9 — write, SECURITY DEFINER, system-only. Cron-driven (BE node-cron). REVOKE FROM PUBLIC; GRANT EXECUTE TO neondb_owner only. Idempotent per M2-NEW-3.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (25, 'm2_approval_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP FUNCTION IF EXISTS fn_approval_escalate(BIGINT);
DROP FUNCTION IF EXISTS fn_approval_reassign(BIGINT, BIGINT, BIGINT, TEXT);
DROP FUNCTION IF EXISTS fn_approval_delegate(BIGINT, BIGINT, BIGINT, TEXT);
DROP FUNCTION IF EXISTS fn_approval_decide(BIGINT, BIGINT, TEXT, TEXT);
DROP FUNCTION IF EXISTS fn_approval_route_init(BIGINT, BIGINT);
DROP FUNCTION IF EXISTS fn_approval_matrix_set(BIGINT, TEXT, NUMERIC, JSONB, NUMERIC);
DROP FUNCTION IF EXISTS fn_approval_chain_list(BIGINT, INTEGER, INTEGER, BIGINT, TEXT, BIGINT);
DROP FUNCTION IF EXISTS fn_approval_chain_get(BIGINT, BIGINT, BIGINT);
DROP FUNCTION IF EXISTS fn_approval_route_init_preview(BIGINT, TEXT, NUMERIC);
DROP FUNCTION IF EXISTS fn_approval_matrix_list(BIGINT, INTEGER, INTEGER, TEXT);
DROP FUNCTION IF EXISTS fn_approval_my_pending(BIGINT, INTEGER, INTEGER, TEXT);
DELETE FROM schema_migrations WHERE version = 25;
COMMIT;
-- ROLLBACK END
