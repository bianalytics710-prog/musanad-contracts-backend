-- Migration: 234_fn_demo_scenario_read.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: fn_demo_scenario_list + fn_demo_scenario_get_by_id + fn_demo_scenario_run_list read functions.
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- 1. fn_demo_scenario_list
CREATE OR REPLACE FUNCTION fn_demo_scenario_list(
  p_actor_id    BIGINT,
  p_only_active BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_result    JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  IF NOT (fn_current_user_has_permission('demo.scenario.trigger')
       OR fn_current_user_has_permission('demo.reset')) THEN
    RAISE EXCEPTION 'fn_demo_scenario_list: permission_denied — demo.scenario.trigger or demo.reset required'
      USING ERRCODE = '42501';
  END IF;

  WITH last_run AS (
    SELECT DISTINCT ON (demo_scenario_id)
           demo_scenario_id, triggered_at, success, elapsed_ms, outcome
    FROM demo_scenario_run
    WHERE tenant_id = v_tenant_id
    ORDER BY demo_scenario_id, triggered_at DESC
  )
  SELECT jsonb_build_object('data', COALESCE(jsonb_agg(jsonb_build_object(
    'id',               s.id,
    'scenarioId',       s.scenario_id,
    'displayNameEn',    s.display_name_en,
    'displayNameAr',    s.display_name_ar,
    'description',      s.description,
    'tier',             s.tier,
    'seedPackRef',      s.seed_pack_ref,
    'expectedOutcomes', s.expected_outcomes,
    'isActive',         s.is_active,
    'lastRun', CASE WHEN lr.demo_scenario_id IS NULL THEN NULL ELSE
      jsonb_build_object(
        'triggeredAt', lr.triggered_at,
        'success',     lr.success,
        'elapsedMs',   lr.elapsed_ms,
        'outcome',     lr.outcome
      )
    END
  ) ORDER BY s.scenario_id), '[]'::jsonb))
  INTO v_result
  FROM demo_scenario s
  LEFT JOIN last_run lr ON lr.demo_scenario_id = s.id
  WHERE s.tenant_id = v_tenant_id
    AND (p_only_active = FALSE OR s.is_active = TRUE);

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_scenario_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_scenario_list(BIGINT, BOOLEAN) IS 'STABLE INVOKER: list all demo_scenario rows for tenant with last-run status. Bounded to 8 rows per tenant. Requires demo.scenario.trigger or demo.reset.';
REVOKE EXECUTE ON FUNCTION fn_demo_scenario_list(BIGINT, BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_scenario_list(BIGINT, BOOLEAN) TO neondb_owner;

-- 2. fn_demo_scenario_get_by_id
CREATE OR REPLACE FUNCTION fn_demo_scenario_get_by_id(
  p_actor_id BIGINT,
  p_id       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id  UUID;
  v_scenario   JSONB;
  v_runs       JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;

  IF NOT fn_current_user_has_permission('demo.scenario.trigger') THEN
    RAISE EXCEPTION 'fn_demo_scenario_get_by_id: permission_denied — demo.scenario.trigger required'
      USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',                     s.id,
    'scenarioId',             s.scenario_id,
    'displayNameEn',          s.display_name_en,
    'displayNameAr',          s.display_name_ar,
    'description',            s.description,
    'tier',                   s.tier,
    'seedPackRef',            s.seed_pack_ref,
    'eventInjectionPayload',  s.event_injection_payload,
    'expectedOutcomes',       s.expected_outcomes,
    'isActive',               s.is_active,
    'createdAt',              s.created_at,
    'updatedAt',              s.updated_at,
    'createdBy',              s.created_by,
    'updatedBy',              s.updated_by
  )
  INTO v_scenario
  FROM demo_scenario s
  WHERE s.tenant_id = v_tenant_id AND s.id = p_id;

  IF v_scenario IS NULL THEN
    RAISE EXCEPTION 'demo_scenario with id % not found in tenant scope', p_id
      USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',          r.id,
    'triggeredAt', r.triggered_at,
    'success',     r.success,
    'elapsedMs',   r.elapsed_ms,
    'outcome',     r.outcome,
    'errorMessage', CASE WHEN r.success = FALSE THEN r.error_message ELSE NULL END
  ) ORDER BY r.triggered_at DESC), '[]'::jsonb)
  INTO v_runs
  FROM (
    SELECT * FROM demo_scenario_run
    WHERE tenant_id = v_tenant_id AND demo_scenario_id = p_id
    ORDER BY triggered_at DESC LIMIT 10
  ) r;

  RETURN jsonb_build_object('scenario', v_scenario, 'recentRuns', v_runs);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_scenario_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_scenario_get_by_id(BIGINT, BIGINT) IS 'STABLE INVOKER: return full demo_scenario detail including last 10 run records. Raises P0002 if not found in tenant scope.';
REVOKE EXECUTE ON FUNCTION fn_demo_scenario_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_scenario_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- 3. fn_demo_scenario_run_list
CREATE OR REPLACE FUNCTION fn_demo_scenario_run_list(
  p_actor_id    BIGINT,
  p_page        INT DEFAULT 1,
  p_limit       INT DEFAULT 20,
  p_scenario_id TEXT DEFAULT NULL,
  p_success     BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_offset    INT;
  v_total     INT;
  v_data      JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::UUID;
  v_offset := (p_page - 1) * p_limit;

  IF NOT fn_current_user_has_permission('demo.scenario.trigger') THEN
    RAISE EXCEPTION 'fn_demo_scenario_run_list: permission_denied — demo.scenario.trigger required'
      USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM demo_scenario_run dsr
  JOIN demo_scenario ds ON ds.id = dsr.demo_scenario_id
  WHERE dsr.tenant_id = v_tenant_id
    AND (p_scenario_id IS NULL OR ds.scenario_id = p_scenario_id)
    AND (p_success IS NULL OR dsr.success = p_success);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             dsr.id,
    'tenantId',       dsr.tenant_id,
    'demoScenarioId', dsr.demo_scenario_id,
    'scenarioId',     ds.scenario_id,
    'triggeredBy',    dsr.triggered_by,
    'triggeredByName', COALESCE(u.first_name || ' ' || u.last_name, NULL),
    'triggeredAt',    dsr.triggered_at,
    'outcome',        dsr.outcome,
    'success',        dsr.success,
    'elapsedMs',      dsr.elapsed_ms,
    'errorMessage',   CASE WHEN dsr.success = FALSE THEN dsr.error_message ELSE NULL END
  ) ORDER BY dsr.triggered_at DESC), '[]'::jsonb)
  INTO v_data
  FROM (
    SELECT dsr2.*
    FROM demo_scenario_run dsr2
    JOIN demo_scenario ds2 ON ds2.id = dsr2.demo_scenario_id
    WHERE dsr2.tenant_id = v_tenant_id
      AND (p_scenario_id IS NULL OR ds2.scenario_id = p_scenario_id)
      AND (p_success IS NULL OR dsr2.success = p_success)
    ORDER BY dsr2.triggered_at DESC
    LIMIT p_limit OFFSET v_offset
  ) dsr
  JOIN demo_scenario ds ON ds.id = dsr.demo_scenario_id
  LEFT JOIN "user" u ON u.id = dsr.triggered_by;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       p_page,
      'limit',      p_limit,
      'totalPages', CEIL(v_total::FLOAT / p_limit)::INTEGER
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_demo_scenario_run_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_demo_scenario_run_list(BIGINT, INT, INT, TEXT, BOOLEAN) IS 'STABLE INVOKER: paginated list of demo scenario run history with optional filters by scenario_id and success flag.';
REVOKE EXECUTE ON FUNCTION fn_demo_scenario_run_list(BIGINT, INT, INT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_demo_scenario_run_list(BIGINT, INT, INT, TEXT, BOOLEAN) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (234, '234_fn_demo_scenario_read', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 234;
-- DROP FUNCTION IF EXISTS fn_demo_scenario_run_list(BIGINT, INT, INT, TEXT, BOOLEAN);
-- DROP FUNCTION IF EXISTS fn_demo_scenario_get_by_id(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_demo_scenario_list(BIGINT, BOOLEAN);
-- ============================================================
