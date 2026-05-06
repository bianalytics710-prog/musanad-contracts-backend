-- ============================================================================
-- 064_approver_parity_r2_chain_breadcrumb.sql
-- ============================================================================
-- Module:    M_parity (approver E2E sweep — Round 2)
-- Owner:     Direct work — no orchestrator pipeline
-- Depends:   025 (fn_approval_my_pending), 058 (party + clause + obligation)
-- ----------------------------------------------------------------------------
-- R2 audit gaps from audit/approver/E2E-COVERAGE-V1.md:
--   6.4.3 — Inbox stage-chain breadcrumb missing. Lovable shows the full
--           chain "Legal Counsel → Contract Approver → Contract Approver
--           (Stage 2)" with avatars per stage and an Urgent/approved status
--           pill. Need chainSteps[] data per row.
--   6.4.4 — Stage column should be "Step X of Y: <approver_role>" (Lovable
--           pattern). Need totalSteps + currentStepRole.
--
-- Extend fn_approval_my_pending to return:
--   - chainSteps[] — array of {order, role, status, approverName} for the
--     contract's full approval chain (not just the user's step)
--   - totalSteps — count of steps in the chain
--
-- Existing fields preserved verbatim (additive change). Sort/ordering
-- unchanged. Permission gating unchanged.
-- ----------------------------------------------------------------------------

BEGIN;

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
          'contractType',     c.contract_type,
          'valueAed',         c.value_aed,
          'requesterUserRef', fn_user_get_by_id(ch.initiated_by),
          'stepOrder',        s.step_order,
          'parallelGroup',    s.parallel_group,
          'isRequired',       s.is_required,
          'hoursPending',     ROUND(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - s.created_at)) / 3600.0, 2),
          'escalationRole',   s.escalation_role,
          'escalationAfterHours', s.escalation_after_hours,
          -- R2 additive — chain breadcrumb data
          'totalSteps',       (
            SELECT COUNT(*)
            FROM approval_step ss
            WHERE ss.approval_chain_id = ch.id
              AND ss.is_active = TRUE
          ),
          'chainSteps',       (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'order',         ss.step_order,
              'role',          ss.approver_role,
              'status',        ss.status,
              'approverName',  CASE
                                WHEN ss.approver_user_id IS NOT NULL THEN (
                                  SELECT u.first_name || ' ' || u.last_name
                                  FROM "user" u WHERE u.id = ss.approver_user_id
                                )
                                ELSE NULL
                              END
            ) ORDER BY ss.step_order), '[]'::jsonb)
            FROM approval_step ss
            WHERE ss.approval_chain_id = ch.id
              AND ss.is_active = TRUE
          )
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

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (64, 'M_parity R2: extend fn_approval_my_pending with chainSteps[] + totalSteps + contractType', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
