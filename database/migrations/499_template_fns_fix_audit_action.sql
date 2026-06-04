-- Migration: 499_template_fns_fix_audit_action.sql
-- Module: Contract templates — repoint audit action values
-- Date: 2026-06-02
--
-- Mig 497 introduced fn_template_create/update/delete and called
-- fn_audit_log_record_v2 with lower-case action verbs ('create', 'update',
-- 'delete'). The audit fn enforces SQL-DML semantics and only accepts
-- ('INSERT','UPDATE','DELETE'). Every template write was failing with:
--   fn_audit_log_record_v2: invalid_action_value
--
-- Fix: re-declare the three fn_template_* bodies with the correct action
-- strings. No schema or signature changes.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_template_create(
  p_actor_id             BIGINT,
  p_name_en              VARCHAR,
  p_contract_type        VARCHAR,
  p_language             VARCHAR DEFAULT 'en',
  p_name_ar              VARCHAR DEFAULT NULL,
  p_description_en       TEXT    DEFAULT NULL,
  p_description_ar       TEXT    DEFAULT NULL,
  p_body_en              TEXT    DEFAULT NULL,
  p_body_ar              TEXT    DEFAULT NULL,
  p_regulatory_tags      TEXT[]  DEFAULT '{}',
  p_placeholders         JSONB   DEFAULT '[]'::jsonb,
  p_regulatory_reference VARCHAR DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_name_en IS NULL OR length(trim(p_name_en)) = 0 THEN
    RAISE EXCEPTION 'fn_template_create: nameEn:nameEn is required' USING ERRCODE = '22023';
  END IF;
  IF p_contract_type IS NULL OR length(trim(p_contract_type)) = 0 THEN
    RAISE EXCEPTION 'fn_template_create: contractType:contractType is required' USING ERRCODE = '22023';
  END IF;
  IF p_language NOT IN ('en', 'ar', 'bilingual') THEN
    RAISE EXCEPTION 'fn_template_create: language:invalid language' USING ERRCODE = '22023';
  END IF;

  INSERT INTO contract_template (
    name_en, name_ar, contract_type, description_en, description_ar,
    language, body_en, body_ar, regulatory_tags, regulatory_reference,
    placeholders, usage_count, created_by, updated_by
  ) VALUES (
    p_name_en, p_name_ar, p_contract_type, p_description_en, p_description_ar,
    p_language, p_body_en, p_body_ar, p_regulatory_tags, p_regulatory_reference,
    COALESCE(p_placeholders, '[]'::jsonb), 0, p_actor_id, p_actor_id
  ) RETURNING id INTO v_id;

  PERFORM fn_audit_log_record_v2(
    'contract_template', v_id, 'INSERT',
    NULL::jsonb,
    jsonb_build_object('nameEn', p_name_en, 'contractType', p_contract_type),
    p_actor_id
  );

  RETURN fn_template_get_by_id(p_actor_id, v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_template_update(
  p_actor_id             BIGINT,
  p_template_id          BIGINT,
  p_name_en              VARCHAR DEFAULT NULL,
  p_name_ar              VARCHAR DEFAULT NULL,
  p_description_en       TEXT    DEFAULT NULL,
  p_description_ar       TEXT    DEFAULT NULL,
  p_body_en              TEXT    DEFAULT NULL,
  p_body_ar              TEXT    DEFAULT NULL,
  p_language             VARCHAR DEFAULT NULL,
  p_contract_type        VARCHAR DEFAULT NULL,
  p_regulatory_tags      TEXT[]  DEFAULT NULL,
  p_placeholders         JSONB   DEFAULT NULL,
  p_regulatory_reference VARCHAR DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE v_found BOOLEAN;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_language IS NOT NULL AND p_language NOT IN ('en','ar','bilingual') THEN
    RAISE EXCEPTION 'fn_template_update: language:invalid language' USING ERRCODE = '22023';
  END IF;

  SELECT TRUE INTO v_found
    FROM contract_template
    WHERE id = p_template_id AND is_active = TRUE;
  IF NOT v_found THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'P0002';
  END IF;

  UPDATE contract_template SET
    name_en              = COALESCE(p_name_en, name_en),
    name_ar              = COALESCE(p_name_ar, name_ar),
    description_en       = COALESCE(p_description_en, description_en),
    description_ar       = COALESCE(p_description_ar, description_ar),
    body_en              = COALESCE(p_body_en, body_en),
    body_ar              = COALESCE(p_body_ar, body_ar),
    language             = COALESCE(p_language, language),
    contract_type        = COALESCE(p_contract_type, contract_type),
    regulatory_tags      = COALESCE(p_regulatory_tags, regulatory_tags),
    placeholders         = COALESCE(p_placeholders, placeholders),
    regulatory_reference = COALESCE(p_regulatory_reference, regulatory_reference),
    updated_by           = p_actor_id,
    updated_at           = NOW()
  WHERE id = p_template_id;

  PERFORM fn_audit_log_record_v2(
    'contract_template', p_template_id, 'UPDATE',
    NULL::jsonb,
    jsonb_build_object('updatedFields', jsonb_strip_nulls(jsonb_build_object(
      'nameEn',              p_name_en,
      'nameAr',              p_name_ar,
      'descriptionEn',       p_description_en,
      'descriptionAr',       p_description_ar,
      'language',            p_language,
      'contractType',        p_contract_type,
      'regulatoryReference', p_regulatory_reference,
      'placeholdersChanged', (p_placeholders IS NOT NULL),
      'bodyEnChanged',       (p_body_en IS NOT NULL),
      'bodyArChanged',       (p_body_ar IS NOT NULL)
    ))),
    p_actor_id
  );

  RETURN fn_template_get_by_id(p_actor_id, p_template_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_template_delete(
  p_actor_id    BIGINT,
  p_template_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE v_usage INT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT usage_count INTO v_usage
    FROM contract_template
    WHERE id = p_template_id AND is_active = TRUE;
  IF v_usage IS NULL THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'P0002';
  END IF;

  UPDATE contract_template
    SET is_active = FALSE,
        updated_by = p_actor_id,
        updated_at = NOW()
  WHERE id = p_template_id;

  PERFORM fn_audit_log_record_v2(
    'contract_template', p_template_id, 'DELETE',
    NULL::jsonb,
    jsonb_build_object('usageCountAtDelete', v_usage),
    p_actor_id
  );

  RETURN jsonb_build_object('id', p_template_id, 'deleted', TRUE);
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (499, '499_template_fns_fix_audit_action', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
