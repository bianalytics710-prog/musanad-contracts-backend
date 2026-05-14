-- MIGRATION: 216_crh_fn_advisory_draft_functions.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: fn_advisory_draft_generate (DEFINER) / _list (STABLE INVOKER) / _get_by_id (STABLE INVOKER)
--              / _approve (INVOKER) / _reject (INVOKER) / _modify (INVOKER) — 6 fn_'s.
--              Each followed by COMMENT + REVOKE FROM PUBLIC + GRANT TO neondb_owner (S2-21/S2-27/B14).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ---------------------------------------------------------------------------
-- fn_advisory_draft_get_by_id (STABLE INVOKER) — called by _approve/_reject/_modify
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_draft_get_by_id(
  p_actor_id BIGINT,
  p_id       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
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
    'sourceCorrelation', (
      SELECT jsonb_build_object(
        'id',          c.id,
        'ruleId',      c.rule_id,
        'confidence',  c.confidence,
        'matchReason', c.match_reason,
        'matchedSignal', (
          SELECT jsonb_build_object('id', os.id, 'title', os.title, 'eventDate', os.event_date, 'sourceUrl', os.source_url)
          FROM osint_signal os WHERE os.id = c.signal_id
        )
      )
      FROM correlation c WHERE c.id = d.correlation_id
    ),
    'matchedClauses', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', cce.id, 'clauseType', cce.clause_type_v2))
      FROM contract_clause_extracted cce
      JOIN correlation cor ON cor.matched_clause_id = cce.id
      WHERE cor.id = d.correlation_id
    ), '[]'::jsonb),
    'riskScoreSummary', (
      SELECT jsonb_build_object('overallScore', lrs.overall_score, 'computedAt', lrs.computed_at)
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

  RETURN v_result;  -- NULL on not-found or RLS-filtered

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_get_by_id: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT) IS
  'Returns full advisory_draft detail with embedded sourceCorrelation, matchedClauses, riskScoreSummary, templateMeta. NULL on not-found.';
REVOKE EXECUTE ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_advisory_draft_generate (DEFINER VOLATILE) — workhorse
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_draft_generate(
  p_actor_id              BIGINT,
  p_correlation_id        BIGINT,
  p_template_id           BIGINT,
  p_contract_id           BIGINT DEFAULT NULL,
  p_llm_generated_text_en TEXT DEFAULT NULL,
  p_llm_generated_text_ar TEXT DEFAULT NULL,
  p_model_version         TEXT DEFAULT NULL,
  p_prompt_hash           TEXT DEFAULT NULL,
  p_response_hash         TEXT DEFAULT NULL,
  p_template_context      JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_actor      BIGINT;
  v_actor_role TEXT;
  v_tenant_id  UUID;
  v_corr       correlation%ROWTYPE;
  v_tpl        advisory_template%ROWTYPE;
  v_draft_id   BIGINT;
  v_contract_id BIGINT;
BEGIN
  -- S2-20 v_actor=0→NULL coercion
  v_actor := NULLIF(p_actor_id, 0);

  -- Permission gate: advisory.draft.review
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_actor AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_draft_generate: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  -- S2-23 FK pre-validate: correlation
  SELECT * INTO v_corr FROM correlation
  WHERE id = p_correlation_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_advisory_draft_generate: correlation_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Resolve contract_id with S2-22b mismatch check
  v_contract_id := COALESCE(p_contract_id, v_corr.contract_id);
  IF p_contract_id IS NOT NULL AND p_contract_id <> v_corr.contract_id THEN
    RAISE EXCEPTION 'fn_advisory_draft_generate: contract_correlation_mismatch — supplied contractId does not match correlation.contract_id'
      USING ERRCODE = '22023';
  END IF;

  -- S2-23 FK pre-validate: advisory_template
  SELECT * INTO v_tpl FROM advisory_template
  WHERE id = p_template_id AND tenant_id = v_corr.tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_advisory_draft_generate: template_not_found'
      USING ERRCODE = 'P0002';
  END IF;
  IF NOT v_tpl.is_active THEN
    RAISE EXCEPTION 'fn_advisory_draft_generate: template_inactive'
      USING ERRCODE = '23514';
  END IF;

  -- S2-23 FK pre-validate: contract
  IF NOT EXISTS (SELECT 1 FROM contract WHERE id = v_contract_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_advisory_draft_generate: contract_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  -- INSERT advisory_draft (S2-22 column-explicit — 27 named cols per spec)
  INSERT INTO advisory_draft (
    tenant_id, correlation_id, contract_id, template_id, template_version,
    draft_type, generated_text_en, generated_text_ar, template_context,
    model_version, prompt_hash, response_hash,
    approval_status, data_classification,
    created_at, updated_at, created_by, updated_by, is_active
  ) VALUES (
    v_corr.tenant_id, p_correlation_id, v_contract_id, p_template_id, v_tpl.version,
    v_tpl.draft_type,
    COALESCE(p_llm_generated_text_en, ''),
    COALESCE(p_llm_generated_text_ar, ''),
    COALESCE(p_template_context, '{}'::jsonb),
    COALESCE(p_model_version, 'gpt-4o'),
    COALESCE(p_prompt_hash, ''),
    p_response_hash,
    'unapproved', 'sensitive',
    NOW(), NOW(), v_actor, v_actor, TRUE
  )
  RETURNING id INTO v_draft_id;

  -- Note: fn_ai_request_log_create call is handled by BE service layer (advisory-drafter.service.ts)
  -- to avoid embedding the 18-arg signature in a DEFINER fn that could drift.
  -- The BE service passes the draft_id back after the fn returns.

  RETURN jsonb_build_object(
    'draftId',        v_draft_id,
    'correlationId',  p_correlation_id,
    'templateId',     p_template_id,
    'contractId',     v_contract_id,
    'templateVersion',v_tpl.version,
    'approvalStatus', 'unapproved',
    'generatedTextEn',COALESCE(p_llm_generated_text_en,''),
    'generatedTextAr',COALESCE(p_llm_generated_text_ar,'')
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_generate: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_draft_generate(BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) IS
  'DEFINER. Persists LLM-generated advisory draft. Called by BE advisory-drafter.service.ts after LLM + Mustache render. Returns draftId + generated text.';
REVOKE EXECUTE ON FUNCTION fn_advisory_draft_generate(BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_generate(BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_advisory_draft_list (STABLE INVOKER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_draft_list(
  p_actor_id       BIGINT,
  p_approval_status TEXT DEFAULT NULL,
  p_contract_id    BIGINT DEFAULT NULL,
  p_correlation_id BIGINT DEFAULT NULL,
  p_draft_type     TEXT DEFAULT NULL,
  p_my_queue       BOOLEAN DEFAULT FALSE,
  p_page           INTEGER DEFAULT 1,
  p_limit          INTEGER DEFAULT 20
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_tenant_id  UUID;
  v_actor_role TEXT;
  v_offset     INTEGER;
  v_total      INTEGER;
  v_data       JSONB;
BEGIN
  -- Permission gate: advisory.draft.review
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_draft_list: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  IF p_page < 1 THEN p_page := 1; END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN p_limit := 20; END IF;
  v_offset := (p_page - 1) * p_limit;

  SELECT COUNT(*) INTO v_total
  FROM advisory_draft d
  JOIN advisory_template t ON t.id = d.template_id
  WHERE d.tenant_id = v_tenant_id
    AND d.is_active = TRUE
    AND (p_approval_status IS NULL OR d.approval_status = p_approval_status)
    AND (p_contract_id IS NULL OR d.contract_id = p_contract_id)
    AND (p_correlation_id IS NULL OR d.correlation_id = p_correlation_id)
    AND (p_draft_type IS NULL OR d.draft_type = p_draft_type)
    AND (NOT p_my_queue OR (
      d.approval_status = 'unapproved'
      AND t.assigned_approver_role = (SELECT r.name FROM "user" u JOIN role r ON r.id = u.role_id WHERE u.id = p_actor_id)
      AND d.created_by IS DISTINCT FROM p_actor_id  -- S2-18 NULL-safe
    ));

  SELECT COALESCE(jsonb_agg(row_obj ORDER BY created_at DESC), '[]'::jsonb) INTO v_data
  FROM (
    SELECT jsonb_build_object(
      'id',                  d.id,
      'draftType',           d.draft_type,
      'contractId',          d.contract_id,
      'contractTitleEn',     c.title_en,
      'contractTitleAr',     c.title_ar,
      'counterpartyName',    (SELECT name_en FROM party WHERE id = c.counterparty_id),
      'templateId',          d.template_id,
      'templateDisplayNameEn', t.display_name_en,
      'templateDisplayNameAr', t.display_name_ar,
      'approvalStatus',      d.approval_status,
      'generatedAt',         d.created_at,
      'approvedByName',      (SELECT concat_ws(' ', u.first_name, u.last_name) FROM "user" u WHERE u.id = d.approved_by),
      'dispatchedAt',        d.dispatched_at,
      'createdBy',           d.created_by
    ) AS row_obj,
    d.created_at
    FROM advisory_draft d
    JOIN advisory_template t ON t.id = d.template_id
    JOIN contract c ON c.id = d.contract_id
    WHERE d.tenant_id = v_tenant_id
      AND d.is_active = TRUE
      AND (p_approval_status IS NULL OR d.approval_status = p_approval_status)
      AND (p_contract_id IS NULL OR d.contract_id = p_contract_id)
      AND (p_correlation_id IS NULL OR d.correlation_id = p_correlation_id)
      AND (p_draft_type IS NULL OR d.draft_type = p_draft_type)
      AND (NOT p_my_queue OR (
        d.approval_status = 'unapproved'
        AND t.assigned_approver_role = (SELECT r.name FROM "user" u JOIN role r ON r.id = u.role_id WHERE u.id = p_actor_id)
        AND d.created_by IS DISTINCT FROM p_actor_id
      ))
    ORDER BY d.created_at DESC
    LIMIT p_limit OFFSET v_offset
  ) sub;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       p_page,
      'limit',      p_limit,
      'totalPages', CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::FLOAT / p_limit)::INTEGER END
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_list: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_draft_list(BIGINT, TEXT, BIGINT, BIGINT, TEXT, BOOLEAN, INTEGER, INTEGER) IS
  'Paginated list of advisory_drafts for current tenant. Filters by approvalStatus, contractId, correlationId, draftType, myQueue (separation-of-duties). Requires advisory.draft.review.';
REVOKE EXECUTE ON FUNCTION fn_advisory_draft_list(BIGINT, TEXT, BIGINT, BIGINT, TEXT, BOOLEAN, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_list(BIGINT, TEXT, BIGINT, BIGINT, TEXT, BOOLEAN, INTEGER, INTEGER) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_advisory_draft_approve (VOLATILE INVOKER) — S2-17 concurrency lock
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_draft_approve(
  p_actor_id      BIGINT,
  p_id            BIGINT,
  p_final_text_en TEXT DEFAULT NULL,
  p_final_text_ar TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant_id   UUID;
  v_actor_role  TEXT;
  v_d           advisory_draft%ROWTYPE;
  v_tpl_role    TEXT;
BEGIN
  -- Permission gate
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_draft_approve: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  -- S2-17 row lock
  SELECT * INTO v_d FROM advisory_draft
  WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_advisory_draft_approve: draft_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Role gate: actor.role must match template.assigned_approver_role
  SELECT assigned_approver_role INTO v_tpl_role
  FROM advisory_template WHERE id = v_d.template_id;

  IF v_actor_role <> v_tpl_role AND v_actor_role NOT IN ('Super Admin','platform_admin') THEN
    RAISE EXCEPTION 'fn_advisory_draft_approve: role_mismatch — actor role % does not match template assigned_approver_role %', v_actor_role, v_tpl_role
      USING ERRCODE = '42501';
  END IF;

  -- Separation of duties (HITL-Q1 lock default-on)
  IF p_actor_id = v_d.created_by THEN
    RAISE EXCEPTION 'fn_advisory_draft_approve: self_approval_denied — cannot approve own draft'
      USING ERRCODE = '42501';
  END IF;

  -- Status transition check
  IF v_d.approval_status NOT IN ('unapproved','modified') THEN
    RAISE EXCEPTION 'fn_advisory_draft_approve: invalid_status_transition — draft already %', v_d.approval_status
      USING ERRCODE = '23514';
  END IF;

  -- Update (S2-22 explicit columns)
  UPDATE advisory_draft SET
    approval_status = 'approved',
    approved_by     = p_actor_id,
    approved_at     = NOW(),
    final_text_en   = COALESCE(p_final_text_en, v_d.generated_text_en),
    final_text_ar   = COALESCE(p_final_text_ar, v_d.generated_text_ar),
    updated_at      = NOW(),
    updated_by      = p_actor_id
  WHERE id = p_id AND tenant_id = v_tenant_id;

  -- Lineage audit (Strategy A supplement to table trigger)
  PERFORM fn_audit_log_record_v2(
    'advisory_draft', p_id, 'UPDATE',
    jsonb_build_object('approvalStatus', v_d.approval_status),
    jsonb_build_object(
      'approvalStatus',  'approved',
      'approvedBy',      p_actor_id,
      'promptHash',      v_d.prompt_hash,
      'modelVersion',    v_d.model_version,
      'templateVersion', v_d.template_version,
      'actionCode',      'advisory.approved'
    ),
    p_actor_id
  );

  RETURN fn_advisory_draft_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_approve: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_draft_approve(BIGINT, BIGINT, TEXT, TEXT) IS
  'Approves advisory draft. Enforces role match + separation-of-duties + status transition (unapproved/modified only). Emits lineage audit row.';
REVOKE EXECUTE ON FUNCTION fn_advisory_draft_approve(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_approve(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_advisory_draft_reject (VOLATILE INVOKER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_draft_reject(
  p_actor_id       BIGINT,
  p_id             BIGINT,
  p_rejection_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant_id  UUID;
  v_actor_role TEXT;
  v_d          advisory_draft%ROWTYPE;
  v_tpl_role   TEXT;
BEGIN
  -- Permission gate
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  -- Validate rejection reason (min 10 chars)
  IF p_rejection_reason IS NULL OR char_length(p_rejection_reason) < 10 THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: missing_rejection_reason — rejectionReason must be at least 10 characters'
      USING ERRCODE = '22023';
  END IF;

  -- S2-17 row lock
  SELECT * INTO v_d FROM advisory_draft
  WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: draft_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Role gate
  SELECT assigned_approver_role INTO v_tpl_role
  FROM advisory_template WHERE id = v_d.template_id;

  IF v_actor_role <> v_tpl_role AND v_actor_role NOT IN ('Super Admin','platform_admin') THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: role_mismatch'
      USING ERRCODE = '42501';
  END IF;

  -- Separation of duties
  IF p_actor_id = v_d.created_by THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: self_approval_denied — cannot reject own draft'
      USING ERRCODE = '42501';
  END IF;

  -- Status transition check
  IF v_d.approval_status NOT IN ('unapproved','modified') THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: invalid_status_transition — draft already %', v_d.approval_status
      USING ERRCODE = '23514';
  END IF;

  -- Update
  UPDATE advisory_draft SET
    approval_status  = 'rejected',
    rejection_reason = p_rejection_reason,
    approved_by      = p_actor_id,
    approved_at      = NOW(),
    updated_at       = NOW(),
    updated_by       = p_actor_id
  WHERE id = p_id AND tenant_id = v_tenant_id;

  -- Lineage audit
  PERFORM fn_audit_log_record_v2(
    'advisory_draft', p_id, 'UPDATE',
    jsonb_build_object('approvalStatus', v_d.approval_status),
    jsonb_build_object(
      'approvalStatus',  'rejected',
      'approvedBy',      p_actor_id,
      'promptHash',      v_d.prompt_hash,
      'modelVersion',    v_d.model_version,
      'templateVersion', v_d.template_version,
      'actionCode',      'advisory.rejected'
    ),
    p_actor_id
  );

  RETURN fn_advisory_draft_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_reject: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_draft_reject(BIGINT, BIGINT, TEXT) IS
  'Rejects advisory draft with mandatory rejection_reason (>=10 chars). Enforces role match + separation-of-duties + status transition. Emits lineage audit row.';
REVOKE EXECUTE ON FUNCTION fn_advisory_draft_reject(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_reject(BIGINT, BIGINT, TEXT) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_advisory_draft_modify (VOLATILE INVOKER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_draft_modify(
  p_actor_id      BIGINT,
  p_id            BIGINT,
  p_final_text_en TEXT DEFAULT NULL,
  p_final_text_ar TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant_id  UUID;
  v_actor_role TEXT;
  v_d          advisory_draft%ROWTYPE;
  v_tpl_role   TEXT;
BEGIN
  -- Permission gate
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_draft_modify: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  -- EN+AR parity required
  IF p_final_text_en IS NULL OR trim(p_final_text_en) = '' THEN
    RAISE EXCEPTION 'fn_advisory_draft_modify: missing_field — finalTextEn is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_final_text_ar IS NULL OR trim(p_final_text_ar) = '' THEN
    RAISE EXCEPTION 'fn_advisory_draft_modify: missing_field — finalTextAr is required'
      USING ERRCODE = '22023';
  END IF;

  -- S2-17 row lock
  SELECT * INTO v_d FROM advisory_draft
  WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_advisory_draft_modify: draft_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Role gate
  SELECT assigned_approver_role INTO v_tpl_role
  FROM advisory_template WHERE id = v_d.template_id;

  IF v_actor_role <> v_tpl_role AND v_actor_role NOT IN ('Super Admin','platform_admin') THEN
    RAISE EXCEPTION 'fn_advisory_draft_modify: role_mismatch'
      USING ERRCODE = '42501';
  END IF;

  -- Status transition: cannot modify approved or rejected
  IF v_d.approval_status NOT IN ('unapproved','modified') THEN
    RAISE EXCEPTION 'fn_advisory_draft_modify: invalid_status_transition — cannot modify a % draft', v_d.approval_status
      USING ERRCODE = '23514';
  END IF;

  -- Update
  UPDATE advisory_draft SET
    approval_status  = 'modified',
    modified_text_en = p_final_text_en,
    modified_text_ar = p_final_text_ar,
    final_text_en    = p_final_text_en,
    final_text_ar    = p_final_text_ar,
    updated_at       = NOW(),
    updated_by       = p_actor_id
  WHERE id = p_id AND tenant_id = v_tenant_id;

  -- Lineage audit
  PERFORM fn_audit_log_record_v2(
    'advisory_draft', p_id, 'UPDATE',
    jsonb_build_object('approvalStatus', v_d.approval_status),
    jsonb_build_object(
      'approvalStatus',  'modified',
      'approvedBy',      p_actor_id,
      'promptHash',      v_d.prompt_hash,
      'modelVersion',    v_d.model_version,
      'templateVersion', v_d.template_version,
      'actionCode',      'advisory.modified'
    ),
    p_actor_id
  );

  RETURN fn_advisory_draft_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_draft_modify: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_draft_modify(BIGINT, BIGINT, TEXT, TEXT) IS
  'Edits draft text (both EN+AR required for parity). Sets approval_status=modified. Approval still required afterward. Emits lineage audit row.';
REVOKE EXECUTE ON FUNCTION fn_advisory_draft_modify(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_modify(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (216, '216_crh_fn_advisory_draft_functions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_advisory_draft_modify(BIGINT, BIGINT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_advisory_draft_reject(BIGINT, BIGINT, TEXT);
-- DROP FUNCTION IF EXISTS fn_advisory_draft_approve(BIGINT, BIGINT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_advisory_draft_list(BIGINT, TEXT, BIGINT, BIGINT, TEXT, BOOLEAN, INTEGER, INTEGER);
-- DROP FUNCTION IF EXISTS fn_advisory_draft_generate(BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB);
-- DROP FUNCTION IF EXISTS fn_advisory_draft_get_by_id(BIGINT, BIGINT);
-- DELETE FROM schema_migrations WHERE version = 216;
-- ============================================================
