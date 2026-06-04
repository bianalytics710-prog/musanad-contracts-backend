-- MIGRATION: 530_risk_score_recompute_all_helper.sql
-- Date: 2026-06-03
-- Description:
--   Helper fn the admin config controller calls after a config save so the
--   FE sees fresh scores immediately. Iterates every contract that has
--   either a stored risk_score snapshot or an active correlation, calls
--   fn_risk_score_compute for each, refreshes latest_risk_score.
--
--   Errors per-contract are swallowed inside the loop — one bad contract
--   shouldn't abort the whole recompute. Returns counts.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_risk_score_recompute_all(p_actor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $fn$
DECLARE
  v_tenant_id   UUID;
  v_cid         BIGINT;
  v_ok          INTEGER := 0;
  v_err         INTEGER := 0;
  v_started     TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF NOT (fn_current_user_has_permission('score.config.manage')
       OR fn_current_user_has_permission('score.weights.manage')) THEN
    RAISE EXCEPTION 'Permission denied: score.config.manage required' USING ERRCODE = '42501';
  END IF;

  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;

  FOR v_cid IN
    SELECT DISTINCT contract_id FROM risk_score WHERE tenant_id = v_tenant_id
    UNION
    SELECT DISTINCT contract_id FROM correlation
      WHERE tenant_id = v_tenant_id AND status = 'active' AND is_active = TRUE
  LOOP
    BEGIN
      PERFORM fn_risk_score_compute(v_cid, 'config_change', p_actor_id);
      v_ok := v_ok + 1;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err + 1;
    END;
  END LOOP;

  REFRESH MATERIALIZED VIEW latest_risk_score;

  RETURN jsonb_build_object(
    'recomputedCount', v_ok,
    'failedCount',     v_err,
    'elapsedMs',       (EXTRACT(EPOCH FROM (clock_timestamp() - v_started)) * 1000)::integer
  );
END;
$fn$;

REVOKE EXECUTE ON FUNCTION fn_risk_score_recompute_all(bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_score_recompute_all(bigint) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (530, 'risk_score_recompute_all_helper', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
