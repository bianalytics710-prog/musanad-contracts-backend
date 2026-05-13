-- Migration: 172_crf_extend_fn_rule_evaluate_notify.sql
-- Module: M14 — CR-F (5-Dim Risk Scoring + MaR + AVaR)
-- Description: CREATE OR REPLACE fn_rule_evaluate(BIGINT, JSONB, BIGINT) — body byte-identical to
--   migration 153 lines 397-464 EXCEPT for the single additive CR-F block (10 lines):
--   PERFORM pg_notify('correlation_inserted', jsonb_build_object(...)) post-LOOP when v_inserted > 0.
--
--   BYTE-AWARE DIFF (feedback_fn_rewrites_lose_safety_guards.md — non-negotiable):
--   Preserved invariants verified line-by-line vs live pg_get_functiondef:
--   ✓ LANGUAGE plpgsql / VOLATILE / SECURITY DEFINER
--   ✓ DECLARE block: v_tenant_id UUID, v_firing JSONB, v_inserted INTEGER:=0, v_skipped INTEGER:=0, v_new_id BIGINT
--   ✓ v_tenant_id GUC read: current_setting('app.current_tenant_id', true)::uuid
--   ✓ S2-23 IF NOT EXISTS guard: RAISE ERRCODE = 'P0002'
--   ✓ FOR LOOP over p_evaluation_payload->'firings'
--   ✓ All 14 INSERT columns + 14 VALUES (tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
--       confidence, match_reason, match_evidence, match_entities, match_geographies,
--       status, expires_at, created_by, updated_by)
--   ✓ ON CONFLICT (tenant_id, signal_id, contract_id, rule_id) DO NOTHING
--   ✓ RETURNING id INTO v_new_id
--   ✓ IF v_new_id IS NOT NULL accounting + v_new_id := NULL reset
--   ✓ RETURN jsonb_build_object('signalId','correlationsInserted','correlationsSkippedAsDup')
--   ✓ EXCEPTION WHEN OTHERS RAISE USING ERRCODE = SQLSTATE (S2-26)
--   ✓ COMMENT ON FUNCTION (updated to mention CR-F additive)
--   ✓ REVOKE EXECUTE + GRANT EXECUTE trio re-issued (S2-21 / B14)
--
--   S2-21 note: QA Stage 3 W1 (signalId BIGINT serializes as number in JSONB pg_notify payload) —
--   JSON-stringify is not needed: Postgres BIGINT in JSONB jsonb_build_object serializes as JSON number,
--   which is safe for the BE worker to parse as number. Documented per Agent 4 design §8 + §S2-21.
--
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Capture current body for rollback validation (informational comment — Agent 6 already read live body above)
-- Live body as of version 167: migration 153 fn_rule_evaluate body (confirmed byte-identical)

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

  -- ===== CR-F migration 172 — additive pg_notify block (only net-new lines vs migration 153) =====
  IF v_inserted > 0 THEN
    PERFORM pg_notify(
      'correlation_inserted',
      jsonb_build_object(
        'tenantId',  v_tenant_id,
        'signalId',  p_signal_id,
        'inserted',  v_inserted
      )::text
    );
  END IF;
  -- ===== end CR-F additive block =====

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

COMMENT ON FUNCTION fn_rule_evaluate(BIGINT, JSONB, BIGINT) IS
  'Persists correlation rows for rule firings. BE rule-evaluator does in-memory predicate evaluation (faster than SQL); this fn handles only the DB INSERT. Idempotent on (tenant_id, signal_id, contract_id, rule_id). CR-F 172: emits pg_notify(''correlation_inserted'', {tenantId, signalId, inserted}) post-LOOP when v_inserted > 0 — consumed by score-recompute.worker. SECURITY DEFINER (worker context).';
REVOKE EXECUTE ON FUNCTION fn_rule_evaluate(BIGINT, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_rule_evaluate(BIGINT, JSONB, BIGINT) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (172, '172_crf_extend_fn_rule_evaluate_notify', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 172;
-- [Restore fn_rule_evaluate to migration 153 body — remove the CR-F pg_notify block (10 lines)]
-- See migration 153_cre_rule_functions.sql lines 397-468 for the verbatim rollback body.
-- ============================================================
