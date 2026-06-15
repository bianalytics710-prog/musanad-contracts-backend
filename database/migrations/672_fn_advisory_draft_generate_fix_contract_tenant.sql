-- ============================================================================
-- Migration 672 — fix fn_advisory_draft_generate v2 (mig 667)
-- ============================================================================
-- WHY: the contract table doesn't have a tenant_id column (RLS handles
-- per-tenant isolation via a role-aware policy). Mig 667 incorrectly
-- referenced contract.tenant_id which raised "column tenant_id does not
-- exist" at runtime, blocking the entire new draft-from-risk-case flow.
--
-- WHAT: replace the contract lookup with the same shape minus the
-- tenant_id filter. RLS still restricts the SELECT to the actor's tenant
-- (contract_select_role_aware policy), so dropping the WHERE clause
-- doesn't widen visibility.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_advisory_draft_generate(
  p_actor_id              BIGINT,
  p_correlation_id        BIGINT,
  p_template_id           BIGINT,
  p_contract_id           BIGINT DEFAULT NULL,
  p_llm_generated_text_en TEXT   DEFAULT NULL,
  p_llm_generated_text_ar TEXT   DEFAULT NULL,
  p_model_version         TEXT   DEFAULT NULL,
  p_prompt_hash           TEXT   DEFAULT NULL,
  p_response_hash         TEXT   DEFAULT NULL,
  p_template_context      JSONB  DEFAULT '{}'::jsonb,
  p_risk_case_id          BIGINT DEFAULT NULL,
  p_review_path           TEXT   DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tenant_id     UUID;
  v_template      RECORD;
  v_contract      RECORD;
  v_risk_case     RECORD;
  v_corr_id       BIGINT := p_correlation_id;
  v_signal_id     BIGINT;
  v_text_en       TEXT;
  v_text_ar       TEXT;
  v_ctx           JSONB := COALESCE(p_template_context, '{}'::jsonb);
  v_metadata      JSONB := '{}'::jsonb;
  v_current_rev   TEXT;
  v_id            BIGINT;
BEGIN
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant context required' USING ERRCODE = '22023';
  END IF;
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'actorId required' USING ERRCODE = '22023';
  END IF;
  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'templateId required' USING ERRCODE = '22023';
  END IF;
  IF p_review_path IS NOT NULL
     AND p_review_path NOT IN ('send_directly', 'executive_review') THEN
    RAISE EXCEPTION 'reviewPath must be send_directly or executive_review'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_template FROM advisory_template WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template not found: %', p_template_id USING ERRCODE = 'P0002';
  END IF;

  IF p_risk_case_id IS NOT NULL THEN
    SELECT * INTO v_risk_case
      FROM risk_case
     WHERE id = p_risk_case_id AND tenant_id = v_tenant_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'risk case not found: %', p_risk_case_id USING ERRCODE = 'P0002';
    END IF;
    IF p_contract_id IS NULL THEN
      p_contract_id := v_risk_case.contract_id;
    END IF;
    IF v_corr_id IS NULL THEN
      v_corr_id := v_risk_case.correlation_id;
    END IF;
  END IF;

  -- mig 672 fix: contract table has no tenant_id column; RLS handles
  -- per-tenant restriction via contract_select_role_aware.
  IF p_contract_id IS NOT NULL THEN
    SELECT * INTO v_contract FROM contract WHERE id = p_contract_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'contract not found: %', p_contract_id USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF v_corr_id IS NULL AND p_contract_id IS NOT NULL THEN
    SELECT id INTO v_corr_id
      FROM correlation
     WHERE contract_id = p_contract_id
       AND tenant_id   = v_tenant_id
       AND is_active   = TRUE
     ORDER BY id ASC
     LIMIT 1;
  END IF;

  IF v_corr_id IS NULL THEN
    SELECT COALESCE((SELECT 1 WHERE EXISTS (SELECT 1 FROM osint_signal WHERE id = 1)),
                    (SELECT MIN(id) FROM osint_signal))
      INTO v_signal_id;
    IF v_signal_id IS NULL THEN
      RAISE EXCEPTION 'cannot create synthetic correlation: no osint_signal rows in tenant'
        USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO correlation (
      tenant_id, signal_id, contract_id, rule_id, rule_version_hash,
      confidence, match_reason, match_evidence, match_geographies,
      match_entities, status, data_classification, created_by, updated_by
    ) VALUES (
      v_tenant_id, v_signal_id, COALESCE(p_contract_id, 0),
      'manual.advisory_anchor', 'v1',
      0.0, 'Synthetic anchor for manually-generated advisory draft.',
      jsonb_build_object('synthetic', TRUE,
                         'riskCaseId', p_risk_case_id,
                         'actorId',    p_actor_id),
      '[]'::jsonb, '[]'::jsonb,
      'active', 'demo', p_actor_id, p_actor_id
    ) RETURNING id INTO v_corr_id;
  END IF;

  IF p_llm_generated_text_en IS NOT NULL THEN
    v_text_en := p_llm_generated_text_en;
  ELSE
    v_text_en := fn_mustache_render(v_template.body_template_en, v_ctx);
  END IF;
  IF p_llm_generated_text_ar IS NOT NULL THEN
    v_text_ar := p_llm_generated_text_ar;
  ELSE
    v_text_ar := fn_mustache_render(v_template.body_template_ar, v_ctx);
  END IF;

  v_current_rev := CASE
    WHEN p_review_path = 'executive_review' THEN 'executive'
    WHEN p_review_path = 'send_directly'    THEN 'legal_counsel'
    ELSE NULL
  END;
  v_metadata := jsonb_strip_nulls(jsonb_build_object(
    'reviewPath',       p_review_path,
    'linkedRiskCaseId', p_risk_case_id,
    'currentReviewer',  v_current_rev,
    'routedAt',         CASE WHEN p_review_path IS NOT NULL THEN now() ELSE NULL END
  ));

  INSERT INTO advisory_draft (
    tenant_id, correlation_id, contract_id, template_id, template_version,
    draft_type, generated_text_en, generated_text_ar, template_context,
    model_version, prompt_hash, response_hash, approval_status,
    dispatch_recipients, data_classification,
    created_by, updated_by
  ) VALUES (
    v_tenant_id,
    v_corr_id,
    COALESCE(p_contract_id, v_template.id),
    v_template.id,
    v_template.version,
    v_template.draft_type,
    v_text_en,
    v_text_ar,
    v_ctx || COALESCE(v_metadata, '{}'::jsonb),
    COALESCE(p_model_version, 'mustache-only'),
    COALESCE(p_prompt_hash,   'manual-' || extract(epoch from now())::text),
    p_response_hash,
    'unapproved',
    '[]'::jsonb,
    'demo',
    p_actor_id,
    p_actor_id
  ) RETURNING id INTO v_id;

  IF p_risk_case_id IS NOT NULL THEN
    INSERT INTO risk_case_event (tenant_id, risk_case_id, event_type, actor_id, payload)
    VALUES (v_tenant_id, p_risk_case_id, 'comment_added', p_actor_id,
            jsonb_build_object(
              'kind',           'advisory_drafted',
              'advisoryDraftId', v_id,
              'templateId',      v_template.template_id,
              'reviewPath',      p_review_path
            ));
  END IF;

  RETURN jsonb_build_object(
    'id',              v_id,
    'correlationId',   v_corr_id,
    'contractId',      p_contract_id,
    'templateId',      p_template_id,
    'draftType',       v_template.draft_type,
    'approvalStatus',  'unapproved',
    'reviewPath',      p_review_path,
    'currentReviewer', v_current_rev,
    'linkedRiskCaseId', p_risk_case_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_advisory_draft_generate(
  BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BIGINT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_advisory_draft_generate(
  BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BIGINT, TEXT
) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (672, 'fn_advisory_draft_generate_fix_contract_tenant', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
