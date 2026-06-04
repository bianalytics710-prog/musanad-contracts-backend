-- 511_advisory_context_build_customer_ready.sql
-- ============================================================================
-- Purpose: fn_advisory_context_build feeds the Mustache template that produces
--   the customer-visible advisory body. Today it returns only the contract
--   reference number, no title, and the rule join is broken (joins
--   correlation_rule.id = correlation.rule_id, but the latter is text — the
--   reference is on correlation_rule.rule_id). As a result customer-bound
--   drafts read like "Contract OQOOD-..." with no title and a missing
--   "identified by ..." source name.
--
-- This migration:
--   1. Fixes the rule join (joins on rule_id text, mirroring mig 395 for the
--      get fn).
--   2. Adds contractTitleEn / contractTitleAr to the returned JSONB.
--   3. Adds matchedClauseTitle (humanised clause_type_v2) and
--      matchedClauseExcerpt (verbatim source text from text_excerpts JSONB).
-- ============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION fn_advisory_context_build(
  p_actor_id       BIGINT,
  p_correlation_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_tenant_id UUID;
  v_result    JSONB;
BEGIN
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_context_missing'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM correlation c
    WHERE c.id = p_correlation_id AND c.tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'correlation_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT jsonb_build_object(
    'correlationId',              c.id,
    'contractId',                 c.contract_id,
    'contractReferenceNumber',    ct.contract_number,
    'contractTitleEn',            ct.title_en,
    'contractTitleAr',            ct.title_ar,
    'correlationRuleDescription', cr.name,
    'matchExplanation',           c.match_reason,
    'matchedClauseText',          COALESCE(
                                    NULLIF(cce.summary_en, ''),
                                    NULLIF(cce.summary_ar, ''),
                                    NULL
                                  ),
    -- Humanised clause label (e.g. "force_majeure" → "Force Majeure")
    'matchedClauseTitle',         CASE
                                    WHEN cce.clause_type_v2 IS NULL THEN NULL
                                    ELSE initcap(replace(cce.clause_type_v2, '_', ' '))
                                  END,
    -- Verbatim excerpt — concatenated text_excerpts values, capped 600 chars
    'matchedClauseExcerpt',       (
                                    SELECT LEFT(string_agg(value::text, ' '), 600)
                                    FROM jsonb_each_text(COALESCE(cce.text_excerpts, '{}'::jsonb))
                                    WHERE value IS NOT NULL AND length(value) > 0
                                  ),
    'counterpartyName',           COALESCE(p.name_en, p.name_ar, NULL),
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
  -- L26 FIX: correlation_rule.rule_id is text, correlation.rule_id is text.
  -- The old join "cr.id = c.rule_id" silently mismatched types and returned NULL.
  LEFT JOIN correlation_rule cr ON cr.rule_id = c.rule_id AND cr.tenant_id = v_tenant_id
  LEFT JOIN contract ct ON ct.id = c.contract_id
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
$fn$;

COMMENT ON FUNCTION fn_advisory_context_build(BIGINT, BIGINT) IS
  'Builds the correlation+contract+clause+signal context dictionary for advisory draft generation. Customer-ready (mig 510/511): includes contract title, humanised matched clause title + verbatim excerpt, and corrects the rule_id text join. Tenant-scoped via app.current_tenant_id GUC.';
REVOKE EXECUTE ON FUNCTION fn_advisory_context_build(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_context_build(BIGINT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (511, 'advisory_context_build_customer_ready', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
-- Restore via re-apply of migration 223.
-- ROLLBACK END
