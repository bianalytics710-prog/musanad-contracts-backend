-- MIGRATION: 223_crh_fn_advisory_context_build.sql
-- Module: M16 | CR: CR-H
-- Date: 2026-05-14
-- Purpose: Patch DEBT-CRH-1 caught at QA Stage 4. BE service advisory-drafter.service.ts
--          calls fn_advisory_context_build which Agent 4 omitted from db-design.
--          Without this fn the BE service falls back to a minimal context (no correlation
--          rule description / matched clause text / signal title — meaning Hormuz AC#1
--          ships with stub LLM prompts).
-- S2-21: REVOKE+GRANT trio applied. S2-22 column-explicit. S2-23 P0002 on missing correlation.

BEGIN;

CREATE OR REPLACE FUNCTION fn_advisory_context_build(
  p_actor_id       BIGINT,
  p_correlation_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_tenant_id UUID;
  v_result    JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_context_missing'
      USING ERRCODE = '22023';
  END IF;

  -- S2-23 FK pre-validation
  IF NOT EXISTS (
    SELECT 1 FROM correlation c
    WHERE c.id = p_correlation_id AND c.tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'correlation_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  -- S2-24 split-aggregate not required — this is a single-row projection
  SELECT jsonb_build_object(
    'correlationId',              c.id,
    'contractId',                 c.contract_id,
    'correlationRuleDescription', cr.name,
    'matchExplanation',           c.match_reason,
    'matchedClauseText',          COALESCE(
                                    NULLIF(cce.summary_en, ''),
                                    NULLIF(cce.summary_ar, ''),
                                    NULL
                                  ),
    'counterpartyName',           COALESCE(p.name_en, p.name_ar, NULL),
    'contractReferenceNumber',    ct.contract_number,
    'signalDate',                 to_char(
                                    COALESCE(os.event_date_v2, os.published_date),
                                    'YYYY-MM-DD"T"HH24:MI:SS"Z"'
                                  ),
    'signalSummary',              COALESCE(
                                    NULLIF(os.summary, ''),
                                    NULLIF(os.title, ''),
                                    NULLIF(os.description_en, ''),
                                    NULL
                                  ),
    'signalKind',                 os.kind,
    'riskHealthScore',            lrs.health_score,
    'riskCalculatedAt',           to_char(
                                    lrs.calculated_at,
                                    'YYYY-MM-DD"T"HH24:MI:SS"Z"'
                                  )
  )
  INTO v_result
  FROM correlation c
  LEFT JOIN correlation_rule cr ON cr.id = c.rule_id AND cr.tenant_id = v_tenant_id
  LEFT JOIN contract ct ON ct.id = c.contract_id AND ct.tenant_id = v_tenant_id
  LEFT JOIN party p ON p.id = ct.counterparty_id AND p.tenant_id = v_tenant_id
  LEFT JOIN contract_clause_extracted cce ON cce.id = c.matched_clause_id
    AND cce.tenant_id = v_tenant_id AND cce.is_active = TRUE
  LEFT JOIN osint_signal os ON os.id = c.signal_id AND os.tenant_id = v_tenant_id
  LEFT JOIN latest_risk_score lrs ON lrs.contract_id = c.contract_id
    AND lrs.tenant_id = v_tenant_id
  WHERE c.id = p_correlation_id
    AND c.tenant_id = v_tenant_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'correlation_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_context_build: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_context_build(BIGINT, BIGINT) IS
  'CR-H DEBT-CRH-1 fix. Builds the LLM context payload for fn_advisory_draft_generate from correlation + correlation_rule + contract + party + contract_clause_extracted + osint_signal + latest_risk_score. STABLE INVOKER — relies on caller tenant_id GUC. Tenant-scoped at every join (S2-22b JOIN-target column tracing).';

REVOKE EXECUTE ON FUNCTION fn_advisory_context_build(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_context_build(BIGINT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (223, 'CR-H DEBT-CRH-1 — fn_advisory_context_build (correlation→contract→party→clause→signal→risk score projection)', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_advisory_context_build(BIGINT, BIGINT);
-- DELETE FROM schema_migrations WHERE version=223;
-- COMMIT;
-- ROLLBACK END
