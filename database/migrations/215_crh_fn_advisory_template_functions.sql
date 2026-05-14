-- MIGRATION: 215_crh_fn_advisory_template_functions.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: fn_advisory_template_list / _get_by_id / _create / _update / _delete (5 fn_'s)
--              Each followed by COMMENT + REVOKE FROM PUBLIC + GRANT TO neondb_owner (S2-21/S2-27/B14).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ---------------------------------------------------------------------------
-- fn_advisory_template_get_by_id (STABLE INVOKER) — called by _create / _update
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_template_get_by_id(
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
    'id',                  at.id,
    'tenantId',            at.tenant_id,
    'templateId',          at.template_id,
    'displayNameEn',       at.display_name_en,
    'displayNameAr',       at.display_name_ar,
    'description',         at.description,
    'draftType',           at.draft_type,
    'bodyTemplateEn',      at.body_template_en,
    'bodyTemplateAr',      at.body_template_ar,
    'parameterSchema',     at.parameter_schema,
    'assignedApproverRole',at.assigned_approver_role,
    'dispatchChannels',    at.dispatch_channels,
    'version',             at.version,
    'dataClassification',  at.data_classification,
    'isActive',            at.is_active,
    'lastModifiedByName',  (SELECT concat_ws(' ', u.first_name, u.last_name) FROM "user" u WHERE u.id = at.last_modified_by),
    'createdAt',           at.created_at,
    'updatedAt',           at.updated_at,
    'createdBy',           at.created_by,
    'updatedBy',           at.updated_by
  ) INTO v_result
  FROM advisory_template at
  WHERE at.id = p_id
    AND at.tenant_id = current_setting('app.current_tenant_id', true)::uuid;

  RETURN v_result;  -- NULL if not found (M10 pattern)

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_template_get_by_id: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_template_get_by_id(BIGINT, BIGINT) IS
  'Returns full advisory_template row as JSONB for current tenant. Returns NULL if not found.';
REVOKE EXECUTE ON FUNCTION fn_advisory_template_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_template_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_advisory_template_list (STABLE INVOKER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_template_list(
  p_actor_id  BIGINT,
  p_draft_type TEXT DEFAULT NULL,
  p_search    TEXT DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT TRUE,
  p_page      INTEGER DEFAULT 1,
  p_limit     INTEGER DEFAULT 20
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_tenant_id UUID;
  v_actor_role TEXT;
  v_offset    INTEGER;
  v_total     INTEGER;
  v_data      JSONB;
BEGIN
  -- Permission gate: advisory.template.manage
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_template_list: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  IF p_page < 1 THEN p_page := 1; END IF;
  IF p_limit NOT BETWEEN 1 AND 100 THEN p_limit := 20; END IF;
  v_offset := (p_page - 1) * p_limit;

  SELECT COUNT(*) INTO v_total
  FROM advisory_template at
  WHERE at.tenant_id = v_tenant_id
    AND (p_is_active IS NULL OR at.is_active = p_is_active)
    AND (p_draft_type IS NULL OR at.draft_type = p_draft_type)
    AND (p_search IS NULL OR (
      at.display_name_en ILIKE '%' || p_search || '%'
      OR at.display_name_ar ILIKE '%' || p_search || '%'
    ));

  SELECT COALESCE(jsonb_agg(row_obj ORDER BY updated_at DESC), '[]'::jsonb) INTO v_data
  FROM (
    SELECT jsonb_build_object(
      'id',                  at.id,
      'templateId',          at.template_id,
      'displayNameEn',       at.display_name_en,
      'displayNameAr',       at.display_name_ar,
      'draftType',           at.draft_type,
      'assignedApproverRole',at.assigned_approver_role,
      'version',             at.version,
      'isActive',            at.is_active,
      'dispatchChannels',    at.dispatch_channels,
      'lastModifiedByName',  (SELECT concat_ws(' ', u.first_name, u.last_name) FROM "user" u WHERE u.id = at.last_modified_by),
      'createdAt',           at.created_at,
      'updatedAt',           at.updated_at
    ) AS row_obj,
    at.updated_at
    FROM advisory_template at
    WHERE at.tenant_id = v_tenant_id
      AND (p_is_active IS NULL OR at.is_active = p_is_active)
      AND (p_draft_type IS NULL OR at.draft_type = p_draft_type)
      AND (p_search IS NULL OR (
        at.display_name_en ILIKE '%' || p_search || '%'
        OR at.display_name_ar ILIKE '%' || p_search || '%'
      ))
    ORDER BY at.updated_at DESC
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
    RAISE EXCEPTION 'fn_advisory_template_list: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_template_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, INTEGER) IS
  'Returns paginated list of advisory_templates for current tenant. Filters by draft_type, is_active, free-text search. Requires advisory.template.manage.';
REVOKE EXECUTE ON FUNCTION fn_advisory_template_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_template_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, INTEGER) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_advisory_template_create (VOLATILE INVOKER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_template_create(
  p_actor_id              BIGINT,
  p_template_id           TEXT,
  p_display_name_en       TEXT,
  p_display_name_ar       TEXT,
  p_description           TEXT,
  p_draft_type            TEXT,
  p_body_template_en      TEXT,
  p_body_template_ar      TEXT,
  p_parameter_schema      JSONB DEFAULT '{}'::jsonb,
  p_assigned_approver_role TEXT DEFAULT NULL,
  p_dispatch_channels     JSONB DEFAULT '["email","teams_capture","slack_capture"]'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant_id  UUID;
  v_actor_role TEXT;
  v_id         BIGINT;
  v_chan       TEXT;
  v_valid_chan BOOLEAN := TRUE;
BEGIN
  -- Permission gate: advisory.template.manage
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_template_create: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  -- Input validation (S2-25)
  IF p_template_id IS NULL OR trim(p_template_id) = '' THEN
    RAISE EXCEPTION 'fn_advisory_template_create: templateId is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_display_name_en IS NULL OR trim(p_display_name_en) = '' THEN
    RAISE EXCEPTION 'fn_advisory_template_create: displayNameEn is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_display_name_ar IS NULL OR trim(p_display_name_ar) = '' THEN
    RAISE EXCEPTION 'fn_advisory_template_create: displayNameAr is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_body_template_en IS NULL OR trim(p_body_template_en) = '' THEN
    RAISE EXCEPTION 'fn_advisory_template_create: bodyTemplateEn is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_body_template_ar IS NULL OR trim(p_body_template_ar) = '' THEN
    RAISE EXCEPTION 'fn_advisory_template_create: bodyTemplateAr is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_draft_type NOT IN ('fm_invocation','cure_notice','sanctions_hold','price_review',
                           'icv_rectification','insurance_renewal','esg_concern','custom') THEN
    RAISE EXCEPTION 'fn_advisory_template_create: invalid_draft_type — must be one of fm_invocation,cure_notice,sanctions_hold,price_review,icv_rectification,insurance_renewal,esg_concern,custom'
      USING ERRCODE = '22023';
  END IF;
  IF p_assigned_approver_role IS NULL OR trim(p_assigned_approver_role) = '' THEN
    RAISE EXCEPTION 'fn_advisory_template_create: assignedApproverRole is required'
      USING ERRCODE = '22023';
  END IF;
  -- Validate assignedApproverRole exists
  IF NOT EXISTS (SELECT 1 FROM role WHERE name = p_assigned_approver_role AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_advisory_template_create: invalid_role — role % not found', p_assigned_approver_role
      USING ERRCODE = '22023';
  END IF;
  -- Validate dispatch_channels array
  IF p_dispatch_channels IS NOT NULL THEN
    IF jsonb_typeof(p_dispatch_channels) <> 'array' OR jsonb_array_length(p_dispatch_channels) < 1 THEN
      RAISE EXCEPTION 'fn_advisory_template_create: invalid_dispatch_channels — must be a non-empty array'
        USING ERRCODE = '22023';
    END IF;
    FOR v_chan IN SELECT jsonb_array_elements_text(p_dispatch_channels) LOOP
      IF v_chan NOT IN ('email','teams_capture','slack_capture') THEN
        v_valid_chan := FALSE;
      END IF;
    END LOOP;
    IF NOT v_valid_chan THEN
      RAISE EXCEPTION 'fn_advisory_template_create: invalid_dispatch_channels — valid values are email, teams_capture, slack_capture'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Insert (S2-22 explicit columns)
  INSERT INTO advisory_template (
    tenant_id, template_id, display_name_en, display_name_ar, description,
    draft_type, body_template_en, body_template_ar,
    parameter_schema, assigned_approver_role, dispatch_channels,
    version, data_classification, last_modified_by,
    created_at, updated_at, created_by, updated_by, is_active
  ) VALUES (
    v_tenant_id, p_template_id, p_display_name_en, p_display_name_ar, p_description,
    p_draft_type, p_body_template_en, p_body_template_ar,
    COALESCE(p_parameter_schema, '{}'::jsonb),
    p_assigned_approver_role,
    COALESCE(p_dispatch_channels, '["email","teams_capture","slack_capture"]'::jsonb),
    1, 'demo', p_actor_id,
    NOW(), NOW(), p_actor_id, p_actor_id, TRUE
  )
  RETURNING id INTO v_id;

  RETURN fn_advisory_template_get_by_id(p_actor_id, v_id);

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'fn_advisory_template_create: duplicate_template_id — template_id already exists for this tenant'
      USING ERRCODE = '23505';
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_template_create: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB) IS
  'Creates a new advisory_template for the current tenant. Validates draft_type enum, role existence, dispatch_channels array, EN+AR body. Returns full template row.';
REVOKE EXECUTE ON FUNCTION fn_advisory_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_advisory_template_update (VOLATILE INVOKER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_template_update(
  p_actor_id              BIGINT,
  p_id                    BIGINT,
  p_display_name_en       TEXT DEFAULT NULL,
  p_display_name_ar       TEXT DEFAULT NULL,
  p_description           TEXT DEFAULT NULL,
  p_body_template_en      TEXT DEFAULT NULL,
  p_body_template_ar      TEXT DEFAULT NULL,
  p_parameter_schema      JSONB DEFAULT NULL,
  p_assigned_approver_role TEXT DEFAULT NULL,
  p_dispatch_channels     JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant_id  UUID;
  v_actor_role TEXT;
  v_rec        advisory_template%ROWTYPE;
  v_new_ver    INTEGER;
  v_body_changed BOOLEAN := FALSE;
BEGIN
  -- Permission gate
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_template_update: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  -- S2-17 row lock
  SELECT * INTO v_rec FROM advisory_template
  WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_advisory_template_update: template_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Validate optional assigned_approver_role
  IF p_assigned_approver_role IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM role WHERE name = p_assigned_approver_role AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_advisory_template_update: invalid_role — role % not found', p_assigned_approver_role
      USING ERRCODE = '22023';
  END IF;

  -- Determine version bump (if body or schema changed)
  v_body_changed := (p_body_template_en IS NOT NULL AND p_body_template_en IS DISTINCT FROM v_rec.body_template_en)
                 OR (p_body_template_ar IS NOT NULL AND p_body_template_ar IS DISTINCT FROM v_rec.body_template_ar)
                 OR (p_parameter_schema IS NOT NULL AND p_parameter_schema IS DISTINCT FROM v_rec.parameter_schema);
  v_new_ver := CASE WHEN v_body_changed THEN v_rec.version + 1 ELSE v_rec.version END;

  -- Apply partial update (S2-22 column-explicit)
  UPDATE advisory_template SET
    display_name_en       = CASE WHEN p_display_name_en IS NOT NULL THEN p_display_name_en ELSE display_name_en END,
    display_name_ar       = CASE WHEN p_display_name_ar IS NOT NULL THEN p_display_name_ar ELSE display_name_ar END,
    description           = CASE WHEN p_description IS NOT NULL THEN p_description ELSE description END,
    body_template_en      = CASE WHEN p_body_template_en IS NOT NULL THEN p_body_template_en ELSE body_template_en END,
    body_template_ar      = CASE WHEN p_body_template_ar IS NOT NULL THEN p_body_template_ar ELSE body_template_ar END,
    parameter_schema      = CASE WHEN p_parameter_schema IS NOT NULL THEN p_parameter_schema ELSE parameter_schema END,
    assigned_approver_role= CASE WHEN p_assigned_approver_role IS NOT NULL THEN p_assigned_approver_role ELSE assigned_approver_role END,
    dispatch_channels     = CASE WHEN p_dispatch_channels IS NOT NULL THEN p_dispatch_channels ELSE dispatch_channels END,
    version               = v_new_ver,
    last_modified_by      = p_actor_id,
    updated_at            = NOW(),
    updated_by            = p_actor_id
  WHERE id = p_id AND tenant_id = v_tenant_id;

  RETURN fn_advisory_template_get_by_id(p_actor_id, p_id);

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_template_update: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB) IS
  'Partial update of advisory_template. Body/schema changes increment version. Returns updated full template row.';
REVOKE EXECUTE ON FUNCTION fn_advisory_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB) TO neondb_owner;

-- ---------------------------------------------------------------------------
-- fn_advisory_template_delete (VOLATILE INVOKER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_advisory_template_delete(
  p_actor_id BIGINT,
  p_id       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant_id  UUID;
  v_actor_role TEXT;
  v_active_draft_count INTEGER;
BEGIN
  -- Permission gate
  v_tenant_id := current_setting('app.current_tenant_id', true)::uuid;
  SELECT r.name INTO v_actor_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = p_actor_id AND u.is_active = TRUE;

  IF v_actor_role NOT IN ('Super Admin','platform_admin','legal_counsel') THEN
    RAISE EXCEPTION 'fn_advisory_template_delete: permission_denied'
      USING ERRCODE = '42501';
  END IF;

  -- Existence check
  IF NOT EXISTS (
    SELECT 1 FROM advisory_template
    WHERE id = p_id AND tenant_id = v_tenant_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'fn_advisory_template_delete: template_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Active draft reference check (S2-23 FK pre-validation)
  SELECT COUNT(*) INTO v_active_draft_count
  FROM advisory_draft
  WHERE template_id = p_id AND is_active = TRUE;

  IF v_active_draft_count > 0 THEN
    RAISE EXCEPTION 'fn_advisory_template_delete: template_in_use — % active advisory_draft rows reference this template', v_active_draft_count
      USING ERRCODE = '23514';
  END IF;

  -- Soft delete
  UPDATE advisory_template SET
    is_active  = FALSE,
    updated_at = NOW(),
    updated_by = p_actor_id
  WHERE id = p_id AND tenant_id = v_tenant_id;

  RETURN jsonb_build_object(
    'id',        p_id,
    'isActive',  FALSE,
    'deletedAt', NOW()
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_advisory_template_delete: %', SQLERRM
      USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_advisory_template_delete(BIGINT, BIGINT) IS
  'Soft-deletes an advisory_template (is_active=false). Rejected if active advisory_draft rows reference the template (23514 template_in_use).';
REVOKE EXECUTE ON FUNCTION fn_advisory_template_delete(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_template_delete(BIGINT, BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (215, '215_crh_fn_advisory_template_functions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP FUNCTION IF EXISTS fn_advisory_template_delete(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_advisory_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB);
-- DROP FUNCTION IF EXISTS fn_advisory_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB);
-- DROP FUNCTION IF EXISTS fn_advisory_template_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, INTEGER);
-- DROP FUNCTION IF EXISTS fn_advisory_template_get_by_id(BIGINT, BIGINT);
-- DELETE FROM schema_migrations WHERE version = 215;
-- ============================================================
