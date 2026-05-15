-- Migration: 266_crl_fn_report_data_legal.sql
-- Module: M20 — CR-L Reports & Briefings
-- Date: 2026-05-15
-- Description: 4 legal data fn_'s (advisory_queue, clause_review_backlog, fm_eligibility, regulatory_digest).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_report_data_legal_advisory_queue(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := fn_demo_now();
  v_payload JSONB;
  v_trace JSONB;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT jsonb_object_agg(approval_status, cnt) INTO v_payload FROM (
    SELECT approval_status, COUNT(*) AS cnt FROM advisory_draft
     WHERE tenant_id = v_tenant AND is_active = TRUE
     GROUP BY approval_status
  ) s;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','advisory_draft','count', (SELECT COUNT(*) FROM advisory_draft WHERE tenant_id = v_tenant AND is_active = TRUE)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('byApprovalStatus', COALESCE(v_payload, '{}'::jsonb)),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_legal_advisory_queue: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_legal_advisory_queue(BIGINT, JSONB) IS 'Advisory drafts bucketed by approval_status.';
REVOKE EXECUTE ON FUNCTION fn_report_data_legal_advisory_queue(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_legal_advisory_queue(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_legal_clause_review_backlog(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := fn_demo_now();
  v_payload JSONB;
  v_trace JSONB;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT jsonb_object_agg(review_status, cnt) INTO v_payload FROM (
    SELECT review_status, COUNT(*) AS cnt FROM contract_clause_extracted
     WHERE tenant_id = v_tenant AND is_active = TRUE
     GROUP BY review_status
  ) s;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','contract_clause_extracted','count', (SELECT COUNT(*) FROM contract_clause_extracted WHERE tenant_id = v_tenant AND is_active = TRUE)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('byReviewStatus', COALESCE(v_payload, '{}'::jsonb)),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_legal_clause_review_backlog: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_legal_clause_review_backlog(BIGINT, JSONB) IS 'Extracted clauses bucketed by review_status.';
REVOKE EXECUTE ON FUNCTION fn_report_data_legal_clause_review_backlog(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_legal_clause_review_backlog(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_legal_fm_eligibility(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := fn_demo_now();
  v_data JSONB;
  v_trace JSONB;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'correlationId', c.id, 'contractId', c.contract_id,
    'contractTitle', COALESCE(co.title_en, co.title_ar), 'confidence', c.confidence, 'matchReason', c.match_reason
  )), '[]'::jsonb) INTO v_data
  FROM correlation c
  LEFT JOIN contract co ON co.id = c.contract_id
  WHERE c.tenant_id = v_tenant
    AND c.rule_id = 'rule.weather.fm_eligible'
    AND c.is_active = TRUE
    AND c.status = 'active';

  v_trace := jsonb_build_array(jsonb_build_object('tableName','correlation','count', COALESCE(jsonb_array_length(v_data), 0)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('matches', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_legal_fm_eligibility: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_legal_fm_eligibility(BIGINT, JSONB) IS 'Force Majeure eligibility — correlations under rule.weather.fm_eligible.';
REVOKE EXECUTE ON FUNCTION fn_report_data_legal_fm_eligibility(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_legal_fm_eligibility(BIGINT, JSONB) TO neondb_owner;


CREATE OR REPLACE FUNCTION fn_report_data_legal_regulatory_digest(
  p_actor_id   BIGINT,
  p_parameters JSONB DEFAULT '{}'
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
  v_now TIMESTAMPTZ := fn_demo_now();
  v_data JSONB;
  v_trace JSONB;
BEGIN
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'signalId', s.id, 'title', s.title, 'kind', s.kind, 'severity', s.severity_v2,
    'fetchedAt', s.fetched_at, 'eventDate', s.event_date_v2
  ) ORDER BY s.fetched_at DESC), '[]'::jsonb) INTO v_data
  FROM osint_signal s
  WHERE s.tenant_id = v_tenant
    AND s.kind = 'regulatory'
    AND s.is_active = TRUE
    AND s.fetched_at >= v_now - INTERVAL '30 days'
  LIMIT 50;

  v_trace := jsonb_build_array(jsonb_build_object('tableName','osint_signal','count', COALESCE(jsonb_array_length(v_data), 0)));

  RETURN jsonb_build_object(
    'payload', jsonb_build_object('signals', v_data),
    'meta', jsonb_build_object('tenantId', v_tenant, 'generatedAt', v_now, 'sourceTraceability', v_trace, 'parameters', p_parameters)
  );
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_report_data_legal_regulatory_digest: %', SQLERRM USING ERRCODE = SQLSTATE;
END; $$;
COMMENT ON FUNCTION fn_report_data_legal_regulatory_digest(BIGINT, JSONB) IS 'OSINT regulatory signals over past 30 days.';
REVOKE EXECUTE ON FUNCTION fn_report_data_legal_regulatory_digest(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_legal_regulatory_digest(BIGINT, JSONB) TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (266, '266_crl_fn_report_data_legal', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_report_data_legal_advisory_queue(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_legal_clause_review_backlog(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_legal_fm_eligibility(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_report_data_legal_regulatory_digest(BIGINT, JSONB);
-- DELETE FROM schema_migrations WHERE version = 266;
-- ============================================================
