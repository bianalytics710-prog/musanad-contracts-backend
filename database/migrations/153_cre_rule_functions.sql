-- Migration: 153_cre_rule_functions.sql
-- Module: M13 / CR-E — Correlation Rule Engine
-- Description: 9 net-new fn_'s:
--   fn_rule_create, fn_rule_update, fn_rule_delete, fn_rule_list, fn_rule_get_by_id,
--   fn_rule_evaluate, fn_rule_test_against_fixture, fn_correlation_dismiss, fn_correlation_list.
--   Each fn: COMMENT + REVOKE FROM PUBLIC + GRANT TO neondb_owner trio (S2-21 / B14).
--   version_hash computed via pgcrypto encode(digest(..., 'sha256'), 'hex').
-- Standards: S2-21 MANDATORY, S2-23, S2-25, S2-26, S2-27.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ============================================================
-- 1. fn_rule_get_by_id (defined first — used by fn_rule_create / fn_rule_update)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_rule_get_by_id(p_rule_pk BIGINT, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('rule.read') THEN
    RAISE EXCEPTION 'Permission denied: rule.read required' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',                  cr.id,
    'ruleId',              cr.rule_id,
    'name',                cr.name,
    'nameAr',              cr.name_ar,
    'scenario',            cr.scenario,
    'enabled',             cr.enabled,
    'meta',                cr.meta,
    'matchYaml',           cr.match_yaml,
    'produceYaml',         cr.produce_yaml,
    'versionHash',         cr.version_hash,
    'lastReviewedBy',      cr.last_reviewed_by,
    'lastReviewedByName',  NULLIF(concat_ws(' ', u.first_name, u.last_name), ''),
    'lastReviewedAt',      cr.last_reviewed_at,
    'createdAt',           cr.created_at,
    'updatedAt',           cr.updated_at,
    'fixtures',            COALESCE(
      (SELECT jsonb_agg(jsonb_build_object(
          'id',            f.id,
          'fixtureId',     f.fixture_id,
          'description',   f.description,
          'expectedMatch', f.expected_match
        ) ORDER BY f.fixture_id)
       FROM correlation_rule_fixture f
       WHERE f.correlation_rule_id = cr.id AND f.is_active = TRUE
      ),
      '[]'::jsonb
    )
  )
  INTO v_result
  FROM   correlation_rule cr
  LEFT JOIN "user" u ON u.id = cr.last_reviewed_by
  WHERE  cr.id = p_rule_pk AND cr.is_active = TRUE;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_rule_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_rule_get_by_id(BIGINT, BIGINT) IS 'Returns single correlation_rule row with fixtures summary. Returns NULL if not found (BE translates to 404). Permission: rule.read.';
REVOKE EXECUTE ON FUNCTION fn_rule_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_rule_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- 2. fn_rule_create
-- ============================================================
CREATE OR REPLACE FUNCTION fn_rule_create(p_data JSONB, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id    UUID;
  v_rule_id      TEXT;
  v_name         TEXT;
  v_name_ar      TEXT;
  v_match_yaml   TEXT;
  v_produce_yaml TEXT;
  v_scenario     TEXT;
  v_meta         JSONB;
  v_enabled      BOOLEAN;
  v_version_hash TEXT;
  v_new_pk       BIGINT;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('rule.manage') THEN
    RAISE EXCEPTION 'Permission denied: rule.manage required' USING ERRCODE = '42501';
  END IF;

  v_tenant_id    := current_setting('app.current_tenant_id', true)::uuid;
  v_rule_id      := p_data->>'ruleId';
  v_name         := p_data->>'name';
  v_name_ar      := p_data->>'nameAr';
  v_match_yaml   := p_data->>'matchYaml';
  v_produce_yaml := p_data->>'produceYaml';
  v_scenario     := p_data->>'scenario';
  v_meta         := COALESCE(p_data->'meta', '{}'::jsonb);
  v_enabled      := COALESCE((p_data->>'enabled')::boolean, TRUE);

  -- Validate required fields (S2-25)
  IF v_rule_id IS NULL OR v_rule_id = '' THEN
    RAISE EXCEPTION 'field_required: ruleId' USING ERRCODE = '22023';
  END IF;
  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION 'field_required: name' USING ERRCODE = '22023';
  END IF;
  IF v_name_ar IS NULL OR v_name_ar = '' THEN
    RAISE EXCEPTION 'field_required: nameAr' USING ERRCODE = '22023';
  END IF;
  IF v_match_yaml IS NULL OR v_match_yaml = '' THEN
    RAISE EXCEPTION 'field_required: matchYaml' USING ERRCODE = '22023';
  END IF;
  IF v_produce_yaml IS NULL OR v_produce_yaml = '' THEN
    RAISE EXCEPTION 'field_required: produceYaml' USING ERRCODE = '22023';
  END IF;

  -- Compute version_hash via pgcrypto
  v_version_hash := encode(
    digest(v_match_yaml || E'\n' || v_produce_yaml || E'\n' || v_meta::text, 'sha256'),
    'hex'
  );

  INSERT INTO correlation_rule (
    tenant_id, rule_id, name, name_ar, scenario, enabled, meta,
    match_yaml, produce_yaml, version_hash,
    created_by, updated_by
  ) VALUES (
    v_tenant_id, v_rule_id, v_name, v_name_ar, v_scenario, v_enabled, v_meta,
    v_match_yaml, v_produce_yaml, v_version_hash,
    p_actor_id, p_actor_id
  )
  RETURNING id INTO v_new_pk;

  -- PG NOTIFY for cache hot-reload
  PERFORM pg_notify(
    'correlation_rule_changed',
    jsonb_build_object(
      'tenantId',    v_tenant_id,
      'ruleId',      v_rule_id,
      'versionHash', v_version_hash,
      'action',      'create'
    )::text
  );

  RETURN fn_rule_get_by_id(v_new_pk, p_actor_id);

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Rule with rule_id % already exists for this tenant', v_rule_id USING ERRCODE = '23505';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_rule_create: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_rule_create(JSONB, BIGINT) IS 'Creates a new correlation_rule. Computes SHA-256 version_hash via pgcrypto. Emits PG NOTIFY correlation_rule_changed for cache hot-reload. Unique per (tenant_id, rule_id). Permission: rule.manage.';
REVOKE EXECUTE ON FUNCTION fn_rule_create(JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_rule_create(JSONB, BIGINT) TO neondb_owner;

-- ============================================================
-- 3. fn_rule_update
-- ============================================================
CREATE OR REPLACE FUNCTION fn_rule_update(p_rule_pk BIGINT, p_data JSONB, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
AS $$
DECLARE
  v_current        RECORD;
  v_new_match      TEXT;
  v_new_produce    TEXT;
  v_new_meta       JSONB;
  v_version_hash   TEXT;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('rule.manage') THEN
    RAISE EXCEPTION 'Permission denied: rule.manage required' USING ERRCODE = '42501';
  END IF;

  -- Fetch and lock current row (S2-23)
  SELECT match_yaml, produce_yaml, meta, version_hash
  INTO   v_current
  FROM   correlation_rule
  WHERE  id = p_rule_pk AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'correlation_rule with id % not found', p_rule_pk USING ERRCODE = 'P0002';
  END IF;

  -- Merge fields from p_data — only apply provided keys
  v_new_match   := COALESCE(p_data->>'matchYaml',   v_current.match_yaml);
  v_new_produce := COALESCE(p_data->>'produceYaml', v_current.produce_yaml);
  v_new_meta    := COALESCE(p_data->'meta',         v_current.meta);

  -- Recompute version_hash if content changed
  IF v_new_match <> v_current.match_yaml
     OR v_new_produce <> v_current.produce_yaml
     OR v_new_meta::text <> v_current.meta::text THEN
    v_version_hash := encode(
      digest(v_new_match || E'\n' || v_new_produce || E'\n' || v_new_meta::text, 'sha256'),
      'hex'
    );
  ELSE
    v_version_hash := v_current.version_hash;
  END IF;

  UPDATE correlation_rule SET
    name             = COALESCE(p_data->>'name',            name),
    name_ar          = COALESCE(p_data->>'nameAr',          name_ar),
    scenario         = COALESCE(p_data->>'scenario',        scenario),
    enabled          = COALESCE((p_data->>'enabled')::boolean, enabled),
    meta             = v_new_meta,
    match_yaml       = v_new_match,
    produce_yaml     = v_new_produce,
    version_hash     = v_version_hash,
    updated_at       = NOW(),
    updated_by       = p_actor_id
  WHERE id = p_rule_pk;

  -- PG NOTIFY for cache hot-reload
  PERFORM pg_notify(
    'correlation_rule_changed',
    jsonb_build_object(
      'tenantId',    current_setting('app.current_tenant_id', true)::uuid,
      'rulePk',      p_rule_pk,
      'versionHash', v_version_hash,
      'action',      'update'
    )::text
  );

  RETURN fn_rule_get_by_id(p_rule_pk, p_actor_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_rule_update: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_rule_update(BIGINT, JSONB, BIGINT) IS 'Updates correlation_rule fields. Recomputes SHA-256 version_hash if match_yaml / produce_yaml / meta changed. Emits PG NOTIFY correlation_rule_changed. Permission: rule.manage.';
REVOKE EXECUTE ON FUNCTION fn_rule_update(BIGINT, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_rule_update(BIGINT, JSONB, BIGINT) TO neondb_owner;

-- ============================================================
-- 4. fn_rule_delete (soft-delete)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_rule_delete(p_rule_pk BIGINT, p_actor_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
AS $$
DECLARE
  v_rule_id TEXT;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('rule.manage') THEN
    RAISE EXCEPTION 'Permission denied: rule.manage required' USING ERRCODE = '42501';
  END IF;

  UPDATE correlation_rule SET
    is_active  = FALSE,
    updated_at = NOW(),
    updated_by = p_actor_id
  WHERE id = p_rule_pk AND is_active = TRUE
  RETURNING rule_id INTO v_rule_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'correlation_rule with id % not found', p_rule_pk USING ERRCODE = 'P0002';
  END IF;

  -- PG NOTIFY — BE cache evicts the rule (existing correlation rows persist per AC-S13-03)
  PERFORM pg_notify(
    'correlation_rule_changed',
    jsonb_build_object(
      'tenantId', current_setting('app.current_tenant_id', true)::uuid,
      'rulePk',   p_rule_pk,
      'ruleId',   v_rule_id,
      'action',   'delete'
    )::text
  );

  RETURN jsonb_build_object('rulePk', p_rule_pk, 'ruleId', v_rule_id, 'deleted', true);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_rule_delete: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_rule_delete(BIGINT, BIGINT) IS 'Soft-deletes correlation_rule (is_active = FALSE). Emits PG NOTIFY correlation_rule_changed so BE cache evicts the rule. Existing correlation rows with this rule_id persist per AC-S13-03 (rule_id is TEXT not FK). Permission: rule.manage.';
REVOKE EXECUTE ON FUNCTION fn_rule_delete(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_rule_delete(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- 5. fn_rule_list
-- ============================================================
CREATE OR REPLACE FUNCTION fn_rule_list(
  p_page     INTEGER,
  p_limit    INTEGER,
  p_scenario TEXT,
  p_enabled  BOOLEAN,
  p_search   TEXT,
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_page   INTEGER := GREATEST(1, COALESCE(p_page, 1));
  v_limit  INTEGER := LEAST(100, GREATEST(1, COALESCE(p_limit, 20)));
  v_offset INTEGER;
  v_data   JSONB;
  v_total  BIGINT;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('rule.read') THEN
    RAISE EXCEPTION 'Permission denied: rule.read required' USING ERRCODE = '42501';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  SELECT
    jsonb_agg(
      jsonb_build_object(
        'id',                 cr.id,
        'ruleId',             cr.rule_id,
        'name',               cr.name,
        'nameAr',             cr.name_ar,
        'scenario',           cr.scenario,
        'enabled',            cr.enabled,
        'versionHashShort',   substr(cr.version_hash, 1, 8),
        'lastReviewedAt',     cr.last_reviewed_at,
        'createdAt',          cr.created_at,
        'updatedAt',          cr.updated_at,
        'fixtureCount',       COALESCE(
          (SELECT COUNT(*) FROM correlation_rule_fixture f
           WHERE f.correlation_rule_id = cr.id AND f.is_active = TRUE), 0)
      )
      ORDER BY cr.last_reviewed_at ASC NULLS FIRST, cr.created_at ASC
    ),
    COUNT(*) OVER ()
  INTO v_data, v_total
  FROM correlation_rule cr
  WHERE cr.is_active = TRUE
    AND (p_scenario IS NULL OR cr.scenario = p_scenario)
    AND (p_enabled IS NULL OR cr.enabled = p_enabled)
    AND (
      p_search IS NULL
      OR cr.name ILIKE '%' || p_search || '%'
      OR cr.name_ar ILIKE '%' || p_search || '%'
    )
  ORDER BY cr.last_reviewed_at ASC NULLS FIRST, cr.created_at ASC
  LIMIT  v_limit
  OFFSET v_offset;

  RETURN jsonb_build_object(
    'data',       COALESCE(v_data, '[]'::jsonb),
    'pagination', jsonb_build_object(
      'total',      COALESCE(v_total, 0),
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', GREATEST(1, CEIL(COALESCE(v_total, 0)::numeric / v_limit))
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_rule_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_rule_list(INTEGER, INTEGER, TEXT, BOOLEAN, TEXT, BIGINT) IS 'Paginated list of correlation_rules. Filters: scenario, enabled, search (ILIKE name + name_ar). Sorted by last_reviewed_at ASC NULLS FIRST (stalest reviewed first per AC-S12-02). Permission: rule.read.';
REVOKE EXECUTE ON FUNCTION fn_rule_list(INTEGER, INTEGER, TEXT, BOOLEAN, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_rule_list(INTEGER, INTEGER, TEXT, BOOLEAN, TEXT, BIGINT) TO neondb_owner;

-- ============================================================
-- 6. fn_rule_evaluate
-- ============================================================
CREATE OR REPLACE FUNCTION fn_rule_evaluate(
  p_signal_id          BIGINT,
  p_evaluation_payload JSONB,
  p_actor_id           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id   UUID;
  v_firing      JSONB;
  v_inserted    INTEGER := 0;
  v_skipped     INTEGER := 0;
  v_new_id      BIGINT;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  -- S2-23 FK pre-validation: signal must exist
  IF NOT EXISTS (SELECT 1 FROM osint_signal WHERE id = p_signal_id) THEN
    RAISE EXCEPTION 'osint_signal with id % not found', p_signal_id USING ERRCODE = 'P0002';
  END IF;

  -- Iterate firings array and persist each correlation row
  FOR v_firing IN SELECT jsonb_array_elements(p_evaluation_payload->'firings') LOOP
    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
      confidence, match_reason, match_evidence, match_entities, match_geographies,
      status, expires_at, created_by, updated_by
    ) VALUES (
      v_tenant_id,
      p_signal_id,
      (v_firing->>'contractId')::bigint,
      v_firing->>'ruleId',
      v_firing->>'ruleVersionHash',
      (v_firing->>'confidence')::numeric,
      v_firing->>'matchReason',
      COALESCE(v_firing->'matchEvidence', '{}'::jsonb),
      COALESCE(v_firing->'matchEntities', '[]'::jsonb),
      COALESCE(v_firing->'matchGeographies', '[]'::jsonb),
      'active',
      NULLIF(v_firing->>'expiresAt', '')::timestamptz,
      p_actor_id, p_actor_id
    )
    ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING
    RETURNING id INTO v_new_id;

    IF v_new_id IS NOT NULL THEN
      v_inserted := v_inserted + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;

    v_new_id := NULL;
  END LOOP;

  RETURN jsonb_build_object(
    'signalId',              p_signal_id,
    'correlationsInserted',  v_inserted,
    'correlationsSkippedAsDup', v_skipped
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_rule_evaluate: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_rule_evaluate(BIGINT, JSONB, BIGINT) IS 'Persists correlation rows for rule firings. BE rule-evaluator does in-memory predicate evaluation (faster than SQL); this fn handles only the DB INSERT. Idempotent on (tenant_id, signal_id, contract_id, rule_id). Evaluation timeouts are written to correlation_evaluation_error by BE (not through this fn). SECURITY DEFINER (worker context).';
REVOKE EXECUTE ON FUNCTION fn_rule_evaluate(BIGINT, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_rule_evaluate(BIGINT, JSONB, BIGINT) TO neondb_owner;

-- ============================================================
-- 7. fn_rule_test_against_fixture
-- ============================================================
CREATE OR REPLACE FUNCTION fn_rule_test_against_fixture(
  p_rule_pk            BIGINT,
  p_fixture_pk         BIGINT,
  p_evaluation_payload JSONB,
  p_actor_id           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_rule     RECORD;
  v_fixture  RECORD;
  v_passed   BOOLEAN;
  v_diff     JSONB := '[]'::jsonb;
  v_actual_match BOOLEAN;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('rule.manage') THEN
    RAISE EXCEPTION 'Permission denied: rule.manage required' USING ERRCODE = '42501';
  END IF;

  -- Fetch rule (S2-23)
  SELECT id, rule_id FROM correlation_rule WHERE id = p_rule_pk AND is_active = TRUE INTO v_rule;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'correlation_rule with id % not found', p_rule_pk USING ERRCODE = 'P0002';
  END IF;

  -- Fetch fixture (S2-23)
  SELECT id, fixture_id, expected_match, expected_correlation
  INTO   v_fixture
  FROM   correlation_rule_fixture
  WHERE  id = p_fixture_pk AND correlation_rule_id = p_rule_pk AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'correlation_rule_fixture with id % not found for rule %', p_fixture_pk, p_rule_pk USING ERRCODE = 'P0002';
  END IF;

  v_actual_match := COALESCE((p_evaluation_payload->>'actualMatch')::boolean, FALSE);
  v_passed := (v_fixture.expected_match = v_actual_match);

  IF NOT v_passed THEN
    v_diff := jsonb_build_array(jsonb_build_object(
      'field',    'match',
      'expected', v_fixture.expected_match,
      'actual',   v_actual_match
    ));
  END IF;

  RETURN jsonb_build_object(
    'ruleId',          v_rule.rule_id,
    'fixtureId',       v_fixture.fixture_id,
    'expectedMatch',   v_fixture.expected_match,
    'actualMatch',     v_actual_match,
    'actualConfidence', p_evaluation_payload->>'actualConfidence',
    'matchReason',     p_evaluation_payload->>'actualMatchReason',
    'matchEvidence',   COALESCE(p_evaluation_payload->'actualMatchEvidence', '{}'::jsonb),
    'diffNotes',       v_diff,
    'passed',          v_passed
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_rule_test_against_fixture: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_rule_test_against_fixture(BIGINT, BIGINT, JSONB, BIGINT) IS 'Pure simulation — returns expected vs actual diff + passed verdict for a rule fixture test. No correlation rows persisted. BE pre-computes the actual evaluation result before calling this fn. Permission: rule.manage.';
REVOKE EXECUTE ON FUNCTION fn_rule_test_against_fixture(BIGINT, BIGINT, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_rule_test_against_fixture(BIGINT, BIGINT, JSONB, BIGINT) TO neondb_owner;

-- ============================================================
-- 8. fn_correlation_dismiss
-- ============================================================
CREATE OR REPLACE FUNCTION fn_correlation_dismiss(
  p_correlation_pk BIGINT,
  p_reason         TEXT,
  p_actor_id       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
AS $$
DECLARE
  v_current_status TEXT;
  v_tenant_id      UUID;
  v_corr_tenant    UUID;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('correlation.dismiss') THEN
    RAISE EXCEPTION 'Permission denied: correlation.dismiss required' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  -- Fetch and lock current row (S2-23)
  SELECT status, tenant_id
  INTO   v_current_status, v_corr_tenant
  FROM   correlation
  WHERE  id = p_correlation_pk AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'correlation with id % not found', p_correlation_pk USING ERRCODE = 'P0002';
  END IF;

  -- Defence-in-depth tenant cross-check (RLS also enforces — this is belt-and-suspenders)
  IF v_corr_tenant <> v_tenant_id THEN
    RAISE EXCEPTION 'tenant_mismatch' USING ERRCODE = '42501';
  END IF;

  -- Already dismissed / expired guard
  IF v_current_status != 'active' THEN
    RAISE EXCEPTION 'already_dismissed: correlation % has status %', p_correlation_pk, v_current_status USING ERRCODE = 'P0001';
  END IF;

  UPDATE correlation SET
    status           = 'dismissed',
    dismissed_by     = p_actor_id,
    dismissed_at     = NOW(),
    dismissed_reason = p_reason,
    updated_at       = NOW(),
    updated_by       = p_actor_id
  WHERE id = p_correlation_pk;

  RETURN jsonb_build_object(
    'correlationId', p_correlation_pk,
    'newStatus',     'dismissed'
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_correlation_dismiss: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_correlation_dismiss(BIGINT, TEXT, BIGINT) IS 'Dismisses a correlation with a required reason. Guards against double-dismiss (P0001 already_dismissed → BE 409). Tenant cross-check as defence-in-depth (RLS also enforces). Permission: correlation.dismiss.';
REVOKE EXECUTE ON FUNCTION fn_correlation_dismiss(BIGINT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_correlation_dismiss(BIGINT, TEXT, BIGINT) TO neondb_owner;

-- ============================================================
-- 9. fn_correlation_list
-- ============================================================
CREATE OR REPLACE FUNCTION fn_correlation_list(
  p_page        INTEGER,
  p_limit       INTEGER,
  p_contract_id BIGINT,
  p_rule_id     TEXT,
  p_signal_id   BIGINT,
  p_status      TEXT,
  p_scenario    TEXT,
  p_since       TIMESTAMPTZ,
  p_actor_id    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_page   INTEGER := GREATEST(1, COALESCE(p_page, 1));
  v_limit  INTEGER := LEAST(100, GREATEST(1, COALESCE(p_limit, 20)));
  v_offset INTEGER;
  v_data   JSONB;
  v_total  BIGINT;
BEGIN
  -- Permission gate
  IF NOT fn_current_user_has_permission('correlation.read') THEN
    RAISE EXCEPTION 'Permission denied: correlation.read required' USING ERRCODE = '42501';
  END IF;

  v_offset := (v_page - 1) * v_limit;

  SELECT
    jsonb_agg(
      jsonb_build_object(
        'id',                corr.id,
        'signalId',          corr.signal_id,
        'contractId',        corr.contract_id,
        'contractTitleEn',   c.title_en,
        'contractTitleAr',   c.title_ar,
        'ruleId',            corr.rule_id,
        'ruleName',          cr.name,
        'ruleNameAr',        cr.name_ar,
        'scenario',          cr.scenario,
        'ruleVersionHash',   corr.rule_version_hash,
        'confidence',        corr.confidence,
        'matchReason',       corr.match_reason,
        'status',            corr.status,
        'expiresAt',         corr.expires_at,
        'dismissedAt',       corr.dismissed_at,
        'dismissedReason',   corr.dismissed_reason,
        'createdAt',         corr.created_at
      )
      ORDER BY corr.created_at DESC
    ),
    COUNT(*) OVER ()
  INTO v_data, v_total
  FROM correlation corr
  JOIN contract c ON c.id = corr.contract_id
  LEFT JOIN correlation_rule cr ON cr.tenant_id = corr.tenant_id
    AND cr.rule_id = corr.rule_id
    AND cr.is_active = TRUE
  WHERE corr.is_active = TRUE
    AND (p_contract_id IS NULL OR corr.contract_id = p_contract_id)
    AND (p_rule_id IS NULL OR corr.rule_id = p_rule_id)
    AND (p_signal_id IS NULL OR corr.signal_id = p_signal_id)
    AND (p_status IS NULL OR corr.status = p_status)
    AND (p_scenario IS NULL OR cr.scenario = p_scenario)
    AND (p_since IS NULL OR corr.created_at >= p_since)
  ORDER BY corr.created_at DESC
  LIMIT  v_limit
  OFFSET v_offset;

  RETURN jsonb_build_object(
    'data',       COALESCE(v_data, '[]'::jsonb),
    'pagination', jsonb_build_object(
      'total',      COALESCE(v_total, 0),
      'page',       v_page,
      'limit',      v_limit,
      'totalPages', GREATEST(1, CEIL(COALESCE(v_total, 0)::numeric / v_limit))
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_correlation_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_correlation_list(INTEGER, INTEGER, BIGINT, TEXT, BIGINT, TEXT, TEXT, TIMESTAMPTZ, BIGINT) IS 'Paginated list of correlations. 7 optional filters: contractId, ruleId, signalId, status, scenario, since. Sorted by created_at DESC. RLS narrows by tenant. Permission: correlation.read (platform_admin sees all; legal_counsel sees contracts they can read via RLS).';
REVOKE EXECUTE ON FUNCTION fn_correlation_list(INTEGER, INTEGER, BIGINT, TEXT, BIGINT, TEXT, TEXT, TIMESTAMPTZ, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_correlation_list(INTEGER, INTEGER, BIGINT, TEXT, BIGINT, TEXT, TEXT, TIMESTAMPTZ, BIGINT) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (153, '153_cre_rule_functions', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 153;
-- DROP FUNCTION IF EXISTS fn_correlation_list(INTEGER, INTEGER, BIGINT, TEXT, BIGINT, TEXT, TEXT, TIMESTAMPTZ, BIGINT);
-- DROP FUNCTION IF EXISTS fn_correlation_dismiss(BIGINT, TEXT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_rule_test_against_fixture(BIGINT, BIGINT, JSONB, BIGINT);
-- DROP FUNCTION IF EXISTS fn_rule_evaluate(BIGINT, JSONB, BIGINT);
-- DROP FUNCTION IF EXISTS fn_rule_list(INTEGER, INTEGER, TEXT, BOOLEAN, TEXT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_rule_delete(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_rule_update(BIGINT, JSONB, BIGINT);
-- DROP FUNCTION IF EXISTS fn_rule_create(JSONB, BIGINT);
-- DROP FUNCTION IF EXISTS fn_rule_get_by_id(BIGINT, BIGINT);
-- ============================================================
