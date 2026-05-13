-- =====================================================================
-- 177_crf_fix_mv_id_column_and_scoring_weights_audit.sql
-- =====================================================================
-- DEFECT-DB-02: latest_risk_score MV column inconsistency between branches
--   Migration 170 file uses `id AS risk_score_id` (test branch state).
--   m0-foundation got an in-flight rename to plain `id` during Agent 6's
--   DEFECT-3 work. fn_risk_score_explain (migration 171) SELECTs `id` from
--   the MV, so test branch raises 42703 (column "id" does not exist) for
--   every caller.
--   Fix: DROP + CREATE MV uniformly with `id` column on BOTH branches.
--
-- DEFECT-DB-01: fn_scoring_weights_set manual audit_log INSERT misses the
--   prev_hash + this_hash NOT NULL columns added in migration 128 (R-PA7).
--   PATCH /api/v1/admin/scoring-weights returns 400 (23502 not_null_violation
--   maps to VALIDATION_ERROR) for any valid weights update.
--   Fix: replace the manual INSERT with a call to fn_audit_log_record_v2()
--   per migration 128 hash-chaining helper convention.
--
-- Body preservation per memory feedback_fn_rewrites_lose_safety_guards.md:
--   - Permission gate `score.weights.manage` preserved
--   - 22023 / 42501 / SQLSTATE raises preserved
--   - FOR UPDATE row lock preserved
--   - sum tolerance (±0.001) preserved
--   - REVOKE FROM PUBLIC + GRANT TO neondb_owner re-issued at end
-- =====================================================================

-- ----------------------------------------------------------------------
-- (A) Drop + recreate latest_risk_score MV with `id` column
-- ----------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS latest_risk_score CASCADE;

CREATE MATERIALIZED VIEW latest_risk_score AS
SELECT DISTINCT ON (tenant_id, contract_id)
  id, tenant_id, contract_id, health_score, dim_legal, dim_financial,
  dim_operational, dim_reputational, dim_compliance, mar_value, mar_currency,
  contributing_correlations, explanation, weights_version, calculated_at, triggered_by
FROM risk_score
ORDER BY tenant_id, contract_id, calculated_at DESC;

CREATE UNIQUE INDEX latest_risk_score_pk ON latest_risk_score (tenant_id, contract_id);
CREATE INDEX        latest_risk_score_health_score_idx ON latest_risk_score (tenant_id, health_score);
CREATE INDEX        latest_risk_score_calculated_at_idx ON latest_risk_score (tenant_id, calculated_at DESC);

REVOKE ALL  ON latest_risk_score FROM PUBLIC;
GRANT SELECT ON latest_risk_score TO neondb_owner;

COMMENT ON MATERIALIZED VIEW latest_risk_score IS
  'M14/CR-F latest risk_score snapshot per (tenant_id, contract_id). DISTINCT ON ordered by calculated_at DESC. UNIQUE INDEX (tenant_id, contract_id) enables future REFRESH MATERIALIZED VIEW CONCURRENTLY. PostgreSQL RLS does NOT apply to materialized views; every SELECT call site MUST include explicit `WHERE tenant_id = current_setting(''app.current_tenant_id'', true)::uuid` for tenant isolation. Rebuilt in migration 177 (DEFECT-DB-02): test branch had column aliased to risk_score_id; reverted to plain `id` to match m0-foundation + fn_risk_score_explain expectation.';

REFRESH MATERIALIZED VIEW latest_risk_score;

-- ----------------------------------------------------------------------
-- (B) fn_scoring_weights_set — use fn_audit_log_record_v2
-- ----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_scoring_weights_set(p_weights jsonb, p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_dim             TEXT;
  v_w               NUMERIC;
  v_sum             NUMERIC := 0;
  v_current_version TEXT;
  v_new_version     TEXT;
  v_new_value       JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('score.weights.manage') THEN
    RAISE EXCEPTION 'Permission denied: score.weights.manage required' USING ERRCODE = '42501';
  END IF;
  FOREACH v_dim IN ARRAY ARRAY['legal','financial','operational','reputational','compliance'] LOOP
    IF NOT (p_weights ? v_dim) THEN RAISE EXCEPTION 'weights.% missing', v_dim USING ERRCODE = '22023'; END IF;
    v_w := (p_weights->>v_dim)::numeric;
    IF v_w IS NULL OR v_w < 0 OR v_w > 1 THEN RAISE EXCEPTION 'weights.% out of [0,1] (got %)', v_dim, v_w USING ERRCODE = '22023'; END IF;
    v_sum := v_sum + v_w;
  END LOOP;
  IF ABS(v_sum - 1.0) > 0.001 THEN
    RAISE EXCEPTION 'weights.sum: weights sum to % (must be 1.0 ± 0.001)', v_sum USING ERRCODE = '22023';
  END IF;
  SELECT value->>'version' INTO v_current_version FROM system_setting WHERE key = 'scoring.weights' AND is_active = TRUE FOR UPDATE;
  IF v_current_version IS NULL THEN v_current_version := '0'; END IF;
  v_new_version := (v_current_version::integer + 1)::text;
  v_new_value := p_weights || jsonb_build_object('version', v_new_version);
  UPDATE system_setting SET value = v_new_value, updated_at = NOW(), updated_by = p_actor_id WHERE key = 'scoring.weights';
  PERFORM fn_audit_log_record_v2('system_setting', NULL::bigint, 'UPDATE', jsonb_build_object('key', 'scoring.weights', 'version', v_current_version), jsonb_build_object('key', 'scoring.weights', 'version', v_new_version), p_actor_id);
  RETURN jsonb_build_object('newVersion', v_new_version, 'weightsApplied', v_new_value, 'totalSum', v_sum);
EXCEPTION
  WHEN OTHERS THEN RAISE EXCEPTION 'fn_scoring_weights_set: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_scoring_weights_set(JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_scoring_weights_set(JSONB, BIGINT) TO neondb_owner;

COMMENT ON FUNCTION fn_scoring_weights_set(JSONB, BIGINT) IS
  'M14/CR-F. Sets scoring weights with sum-to-1.0 (±0.001) validation. Increments version. Patched in migration 177 (DEFECT-DB-01): now uses fn_audit_log_record_v2() helper to satisfy R-PA7 prev_hash/this_hash NOT NULL audit_log hash-chaining contract.';

-- ----------------------------------------------------------------------
-- Migration record
-- ----------------------------------------------------------------------

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (177, '177_crf_fix_mv_id_column_and_scoring_weights_audit', NOW())
ON CONFLICT (version) DO NOTHING;

-- =====================================================================
-- ROLLBACK
-- =====================================================================
-- DROP MV + recreate with `id AS risk_score_id` (test-branch pre-177 state)
-- + re-apply fn_scoring_weights_set with the manual INSERT INTO audit_log
-- (breaks PATCH /admin/scoring-weights). Not advised.
-- =====================================================================
