-- MIGRATION: 221_crh_fix_advisory_draft_get_by_id_risk_score_columns.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: Fix DEFECT-CRH-DB-03 — fn_advisory_draft_get_by_id referenced
--              latest_risk_score.overall_score and .computed_at which do not exist.
--              Actual columns from CR-F (migration 167) are health_score and calculated_at.
--              Cascade fix: fn_advisory_draft_approve/reject/modify all call get_by_id at return.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_advisory_draft_get_by_id(
  p_actor_id BIGINT,
  p_id       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'id',              d.id,
    'tenantId',        d.tenant_id,
    'correlationId',   d.correlation_id,
    'contractId',      d.contract_id,
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
    'updatedAt',       d.updated_at,
    'createdBy',       d.created_by,
    'updatedBy',       d.updated_by,
    'riskScoreSummary', (
      SELECT jsonb_build_object('healthScore', lrs.health_score, 'calculatedAt', lrs.calculated_at)
      FROM latest_risk_score lrs
      WHERE lrs.contract_id = d.contract_id
        AND lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    ),
    'templateMeta', (
      SELECT jsonb_build_object(
        'id',                  at.id,
        'version',             at.version,
        'displayNameEn',       at.display_name_en,
        'displayNameAr',       at.display_name_ar,
        'assignedApproverRole',at.assigned_approver_role,
        'draftType',           at.draft_type
      )
      FROM advisory_template at WHERE at.id = d.template_id
    )
  ) INTO v_result
  FROM advisory_draft d
  WHERE d.id = p_id
    AND d.tenant_id = current_setting('app.current_tenant_id', true)::uuid;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_get_by_id: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT)
  IS 'CR-H: Returns full advisory draft row by id. Fix 221: corrected latest_risk_score column refs overall_score->health_score, computed_at->calculated_at.';

REVOKE EXECUTE ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (221, '221_crh_fix_advisory_draft_get_by_id_risk_score_columns', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Revert to the original (broken) body by re-applying migration 216 fn_advisory_draft_get_by_id.
-- DELETE FROM schema_migrations WHERE version = 221;
-- ============================================================
