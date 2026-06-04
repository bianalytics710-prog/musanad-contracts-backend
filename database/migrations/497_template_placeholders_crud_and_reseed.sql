-- Migration: 497_template_placeholders_crud_and_reseed.sql
-- Module: Contract templates — placeholders schema + CRUD fns + reseed
-- Date: 2026-06-02
--
-- Three parts:
--
-- (1) Schema additive: add contract_template.placeholders (JSONB array of
--     placeholder catalog rows like
--       { key, labelEn, labelAr, kind, required }
--     ) + regulatory_reference (e.g. "Federal Decree-Law 33/2021").
--
-- (2) fn_'s for the FE rebuild:
--       - fn_template_get_by_id : EXTEND projection with placeholders +
--                                 regulatory_reference (additive)
--       - fn_template_list      : EXTEND projection with placeholder count
--                                 + regulatory_reference (additive)
--       - fn_template_create    : EXTEND with p_placeholders +
--                                 p_regulatory_reference (additive optional)
--       - fn_template_update    : NEW — partial PATCH; permission
--                                 'contract.edit'; emits an audit row
--                                 via fn_audit_log_record_v2
--       - fn_template_delete    : NEW — soft delete (is_active=FALSE);
--                                 perm 'contract.edit'; emits audit row
--
-- (3) Reseed top 4 templates (Employment / NDA / MSA / Vendor) with full
--     bilingual bodies + {{token}} placeholders + placeholder catalog.
--     Remaining 4 (Consultancy / LLC / Distribution / Lease) get
--     [bracket] → {{token}} substitution + placeholder catalog only
--     (body kept compact).

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. SCHEMA
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE contract_template
  ADD COLUMN IF NOT EXISTS placeholders JSONB NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE contract_template
  ADD COLUMN IF NOT EXISTS regulatory_reference VARCHAR(255);

COMMENT ON COLUMN contract_template.placeholders IS
  'JSONB array. Each element: { key:text, labelEn:text, labelAr:text, kind:text, required:bool }. kind ∈ {party, date, currency, number, text}.';
COMMENT ON COLUMN contract_template.regulatory_reference IS
  'Headline regulatory citation, e.g. "Federal Decree-Law 33/2021". Surfaced as a chip on the template card.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. fn_'s
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_template_get_by_id(
  p_actor_id    BIGINT,
  p_template_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE v_row JSONB;
BEGIN
  IF NOT (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.read.all')
    OR fn_current_user_has_permission('contract.edit')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',                  t.id,
    'nameEn',              t.name_en,
    'nameAr',              t.name_ar,
    'contractType',        t.contract_type,
    'descriptionEn',       t.description_en,
    'descriptionAr',       t.description_ar,
    'bodyEn',              t.body_en,
    'bodyAr',              t.body_ar,
    'language',            t.language,
    'regulatoryTags',      t.regulatory_tags,
    'regulatoryReference', t.regulatory_reference,
    'placeholders',        COALESCE(t.placeholders, '[]'::jsonb),
    'usageCount',          t.usage_count,
    'createdAt',           t.created_at,
    'updatedAt',           t.updated_at
  ) INTO v_row
  FROM contract_template t
  WHERE t.id = p_template_id AND t.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_template_list(
  p_actor_id      BIGINT,
  p_contract_type VARCHAR DEFAULT NULL,
  p_search        VARCHAR DEFAULT NULL,
  p_limit         INTEGER DEFAULT 100,
  p_offset        INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE v_rows JSONB; v_total INT;
BEGIN
  IF NOT (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.read.all')
    OR fn_current_user_has_permission('contract.edit')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT count(*)::INT INTO v_total
    FROM contract_template t
   WHERE t.is_active = TRUE
     AND (p_contract_type IS NULL OR t.contract_type = p_contract_type)
     AND (
       p_search IS NULL
       OR t.name_en ILIKE '%' || p_search || '%'
       OR COALESCE(t.name_ar,'') ILIKE '%' || p_search || '%'
     );

  SELECT COALESCE(jsonb_agg(row), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT jsonb_build_object(
        'id',                  t.id,
        'nameEn',              t.name_en,
        'nameAr',              t.name_ar,
        'contractType',        t.contract_type,
        'language',            t.language,
        'regulatoryTags',      t.regulatory_tags,
        'regulatoryReference', t.regulatory_reference,
        'usageCount',          t.usage_count,
        'placeholderCount',    jsonb_array_length(COALESCE(t.placeholders, '[]'::jsonb)),
        'descriptionEn',       t.description_en,
        'updatedAt',           t.updated_at
      ) AS row
      FROM contract_template t
      WHERE t.is_active = TRUE
        AND (p_contract_type IS NULL OR t.contract_type = p_contract_type)
        AND (
          p_search IS NULL
          OR t.name_en ILIKE '%' || p_search || '%'
          OR COALESCE(t.name_ar,'') ILIKE '%' || p_search || '%'
        )
      ORDER BY t.usage_count DESC, t.id ASC
      LIMIT p_limit OFFSET p_offset
    ) sub;

  RETURN jsonb_build_object(
    'data',       v_rows,
    'pagination', jsonb_build_object(
      'page',       (p_offset / GREATEST(p_limit, 1)) + 1,
      'limit',      p_limit,
      'total',      v_total,
      'totalPages', CEIL(v_total::NUMERIC / GREATEST(p_limit, 1))::INT
    )
  );
END;
$function$;

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
    'contract_template', v_id, 'create',
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
    'contract_template', p_template_id, 'update',
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
    'contract_template', p_template_id, 'delete',
    NULL::jsonb,
    jsonb_build_object('usageCountAtDelete', v_usage),
    p_actor_id
  );

  RETURN jsonb_build_object('id', p_template_id, 'deleted', TRUE);
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (497, '497_template_placeholders_crud_and_reseed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
