-- 515_advisory_draft_expose_counterparty_contact.sql
-- ============================================================================
-- Extend fn_advisory_draft_get_by_id to expose counterpartyName + counterpartyEmail
-- so the FE Dispatch popup can pre-fill the recipient without a second roundtrip.
-- ============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.fn_advisory_draft_get_by_id(p_actor_id bigint, p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'id',              d.id,
    'tenantId',        d.tenant_id,
    'correlationId',   d.correlation_id,
    'contractId',      d.contract_id,
    'contractNumber',  c.contract_number,
    'contractTitleEn', c.title_en,
    'contractTitleAr', c.title_ar,
    'counterpartyName',  COALESCE(p.name_en, p.name_ar),
    'counterpartyEmail', p.contact_email,
    'templateId',      d.template_id,
    'templateVersion', d.template_version,
    'draftType',       d.draft_type,
    'generatedTextEn', d.generated_text_en,
    'generatedTextAr', d.generated_text_ar,
    'templateContext', d.template_context,
    'modelVersion',    d.model_version,
    'promptHash',      d.prompt_hash,
    'responseHash',    d.response_hash,
    'approvalStatus',  d.approval_status,
    'approvedBy',      d.approved_by,
    'approvedByName',  (SELECT concat_ws(' ', u.first_name, u.last_name) FROM "user" u WHERE u.id = d.approved_by),
    'approvedAt',      d.approved_at,
    'createdByName',   (SELECT concat_ws(' ', u.first_name, u.last_name) FROM "user" u WHERE u.id = d.created_by),
    'finalTextEn',     d.final_text_en,
    'finalTextAr',     d.final_text_ar,
    'modifiedTextEn',  d.modified_text_en,
    'modifiedTextAr',  d.modified_text_ar,
    'rejectionReason', d.rejection_reason,
    'dispatchedAt',    d.dispatched_at,
    'dispatchChannel', d.dispatch_channel,
    'dispatchRecipients', d.dispatch_recipients,
    'dataClassification', d.data_classification,
    'isActive',        d.is_active,
    'createdAt',       d.created_at,
    'generatedAt',     d.created_at,
    'updatedAt',       d.updated_at,
    'createdBy',       d.created_by,
    'updatedBy',       d.updated_by,
    'riskScoreSummary', (
      SELECT jsonb_build_object(
        'healthScore',           lrs.health_score,
        'computedAt',            lrs.calculated_at,
        'calculatedAt',          lrs.calculated_at,
        'marValue',              lrs.mar_value,
        'marCurrency',           lrs.mar_currency,
        'dimensions',            lrs.explanation->'dimensions',
        'weightsAtCalculation',  lrs.explanation->'weightsAtCalculation',
        'weightsVersion',        lrs.weights_version
      )
      FROM latest_risk_score lrs
      WHERE lrs.contract_id = d.contract_id
        AND lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    ),
    'sourceCorrelation', (
      SELECT jsonb_build_object(
        'id', co.id, 'ruleId', co.rule_id, 'ruleName', cr.name,
        'severity', COALESCE(co.match_evidence->>'severity', 'medium'),
        'createdAt', co.created_at
      )
      FROM correlation co
      LEFT JOIN correlation_rule cr ON cr.rule_id = co.rule_id
      WHERE co.id = d.correlation_id
    ),
    'matchedClauses', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', cce.id,
        'clauseType', cce.clause_type_v2,
        'clauseTitle', CASE
          WHEN cce.clause_type_v2 IS NULL THEN COALESCE(cce.summary_en, 'Clause')
          ELSE initcap(replace(cce.clause_type_v2, '_', ' '))
        END,
        'snippet', COALESCE(
          (SELECT LEFT(string_agg(value::text, ' '), 280)
             FROM jsonb_each_text(cce.text_excerpts)
            WHERE value IS NOT NULL AND length(value) > 0
            LIMIT 2),
          LEFT(cce.summary_en, 280), ''
        ),
        'pageNo',  cce.page_no,
        'summary', cce.summary_en
      ))
      FROM correlation co
      JOIN contract_clause_extracted cce ON cce.id = co.matched_clause_id
      WHERE co.id = d.correlation_id AND co.matched_clause_id IS NOT NULL
    ), '[]'::jsonb),
    'matchedSignal', (
      SELECT jsonb_build_object(
        'id', os.id,
        'kind', COALESCE(os.kind, os.category),
        'title', COALESCE(os.title_en, os.title)
      )
      FROM correlation co
      JOIN osint_signal os ON os.id = co.signal_id
      WHERE co.id = d.correlation_id
    ),
    'templateMeta', (
      SELECT jsonb_build_object(
        'templateId',          at.template_id,
        'displayNameEn',       at.display_name_en,
        'displayNameAr',       at.display_name_ar,
        'draftType',           at.draft_type,
        'version',             at.version,
        'assignedApproverRole', at.assigned_approver_role
      )
      FROM advisory_template at WHERE at.id = d.template_id
    )
  ) INTO v_result
  FROM advisory_draft d
  JOIN contract c ON c.id = d.contract_id
  LEFT JOIN party p ON p.id = c.counterparty_id
  WHERE d.id = p_id
    AND d.tenant_id = current_setting('app.current_tenant_id', true)::uuid;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_get_by_id: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (515, 'advisory_draft_expose_counterparty_contact', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
