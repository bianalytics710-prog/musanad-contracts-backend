-- ============================================================================
-- 060_m_parity_relax_read_perm.sql
-- ============================================================================
-- Module:    M_parity (Lovable feature-depth parity polish)
-- Owner:     Direct work — no orchestrator pipeline
-- Depends:   058 (party + template + clause + obligation fn_'s)
-- ----------------------------------------------------------------------------
-- The original 058 fn_'s gated reads on (contract.read.department OR
-- contract.edit). Executive role holds contract.read.all instead — this
-- broke the Executive dashboard's top-counterparties enrichment which
-- relies on partiesService.list. Relax the read gate to also accept
-- contract.read.all.
-- ----------------------------------------------------------------------------

BEGIN;

CREATE OR REPLACE FUNCTION fn_party_list(
  p_actor_id    BIGINT,
  p_party_type  VARCHAR DEFAULT NULL,
  p_search      VARCHAR DEFAULT NULL,
  p_limit       INTEGER DEFAULT 100,
  p_offset      INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_rows JSONB;
  v_total BIGINT;
BEGIN
  IF NOT (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.read.all')
    OR fn_current_user_has_permission('contract.edit')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM party p
  WHERE p.is_active = TRUE
    AND (p_party_type IS NULL OR p.party_type = p_party_type)
    AND (p_search IS NULL OR p.name_en ILIKE '%' || p_search || '%' OR COALESCE(p.name_ar,'') ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',               p.id,
    'partyType',        p.party_type,
    'nameEn',           p.name_en,
    'nameAr',           p.name_ar,
    'tradeLicenseNumber', p.trade_license_number,
    'tradeLicenseIssuer', p.trade_license_issuer,
    'emirate',          p.emirate,
    'freeZone',         p.free_zone,
    'country',          p.country,
    'contactEmail',     p.contact_email,
    'contactPhone',     p.contact_phone,
    'createdAt',        p.created_at
  ) ORDER BY p.name_en), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM party
    WHERE is_active = TRUE
      AND (p_party_type IS NULL OR party_type = p_party_type)
      AND (p_search IS NULL OR name_en ILIKE '%' || p_search || '%' OR COALESCE(name_ar,'') ILIKE '%' || p_search || '%')
    ORDER BY name_en
    LIMIT p_limit OFFSET p_offset
  ) p;

  RETURN jsonb_build_object('data', v_rows, 'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset));
END;
$$;

CREATE OR REPLACE FUNCTION fn_party_get_by_id(
  p_actor_id BIGINT,
  p_party_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_row JSONB;
  v_contracts JSONB;
BEGIN
  IF NOT (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.read.all')
    OR fn_current_user_has_permission('contract.edit')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT to_jsonb(p) - 'created_at' - 'updated_at'
    || jsonb_build_object('createdAt', p.created_at, 'updatedAt', p.updated_at) INTO v_row
  FROM party p
  WHERE p.id = p_party_id AND p.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'party_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             c.id,
    'contractNumber', c.contract_number,
    'titleEn',        c.title_en,
    'status',         c.status,
    'valueAed',       c.value_aed,
    'updatedAt',      c.updated_at
  ) ORDER BY c.updated_at DESC), '[]'::jsonb) INTO v_contracts
  FROM (
    SELECT id, contract_number, title_en, status, value_aed, updated_at
    FROM contract
    WHERE counterparty_id = p_party_id AND is_active = TRUE
    ORDER BY updated_at DESC
    LIMIT 5
  ) c;

  RETURN v_row || jsonb_build_object('recentContracts5', v_contracts);
END;
$$;

CREATE OR REPLACE FUNCTION fn_template_list(
  p_actor_id      BIGINT,
  p_contract_type VARCHAR DEFAULT NULL,
  p_search        VARCHAR DEFAULT NULL,
  p_limit         INTEGER DEFAULT 100,
  p_offset        INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_rows JSONB;
  v_total BIGINT;
BEGIN
  IF NOT (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.read.all')
    OR fn_current_user_has_permission('contract.edit')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM contract_template t
  WHERE t.is_active = TRUE
    AND (p_contract_type IS NULL OR t.contract_type = p_contract_type)
    AND (p_search IS NULL OR t.name_en ILIKE '%' || p_search || '%' OR COALESCE(t.name_ar,'') ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                t.id,
    'nameEn',            t.name_en,
    'nameAr',            t.name_ar,
    'contractType',      t.contract_type,
    'descriptionEn',     t.description_en,
    'descriptionAr',     t.description_ar,
    'language',          t.language,
    'regulatoryTags',    t.regulatory_tags,
    'usageCount',        t.usage_count,
    'createdAt',         t.created_at
  ) ORDER BY t.usage_count DESC, t.name_en), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM contract_template
    WHERE is_active = TRUE
      AND (p_contract_type IS NULL OR contract_type = p_contract_type)
      AND (p_search IS NULL OR name_en ILIKE '%' || p_search || '%' OR COALESCE(name_ar,'') ILIKE '%' || p_search || '%')
    ORDER BY usage_count DESC, name_en
    LIMIT p_limit OFFSET p_offset
  ) t;

  RETURN jsonb_build_object('data', v_rows, 'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset));
END;
$$;

CREATE OR REPLACE FUNCTION fn_template_get_by_id(
  p_actor_id    BIGINT,
  p_template_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
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
    'id', t.id, 'nameEn', t.name_en, 'nameAr', t.name_ar,
    'contractType', t.contract_type, 'descriptionEn', t.description_en, 'descriptionAr', t.description_ar,
    'bodyEn', t.body_en, 'bodyAr', t.body_ar, 'language', t.language,
    'regulatoryTags', t.regulatory_tags, 'usageCount', t.usage_count,
    'createdAt', t.created_at, 'updatedAt', t.updated_at
  ) INTO v_row
  FROM contract_template t WHERE t.id = p_template_id AND t.is_active = TRUE;

  IF v_row IS NULL THEN RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'P0002'; END IF;
  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION fn_clause_list(
  p_actor_id BIGINT, p_category VARCHAR DEFAULT NULL, p_variant VARCHAR DEFAULT NULL,
  p_search VARCHAR DEFAULT NULL, p_limit INTEGER DEFAULT 100, p_offset INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE v_rows JSONB; v_total BIGINT;
BEGIN
  IF NOT (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.read.all')
    OR fn_current_user_has_permission('contract.edit')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total FROM contract_clause cl
  WHERE cl.is_active = TRUE
    AND (p_category IS NULL OR cl.category = p_category)
    AND (p_variant IS NULL OR cl.variant = p_variant)
    AND (p_search IS NULL OR cl.title_en ILIKE '%' || p_search || '%' OR COALESCE(cl.title_ar,'') ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', cl.id, 'category', cl.category, 'titleEn', cl.title_en, 'titleAr', cl.title_ar,
    'variant', cl.variant, 'regulatoryRefs', cl.regulatory_refs, 'usageCount', cl.usage_count,
    'createdAt', cl.created_at
  ) ORDER BY cl.category, cl.usage_count DESC, cl.title_en), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM contract_clause WHERE is_active = TRUE
      AND (p_category IS NULL OR category = p_category)
      AND (p_variant IS NULL OR variant = p_variant)
      AND (p_search IS NULL OR title_en ILIKE '%' || p_search || '%' OR COALESCE(title_ar,'') ILIKE '%' || p_search || '%')
    ORDER BY category, usage_count DESC, title_en LIMIT p_limit OFFSET p_offset
  ) cl;

  RETURN jsonb_build_object('data', v_rows, 'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset));
END;
$$;

CREATE OR REPLACE FUNCTION fn_clause_get_by_id(p_actor_id BIGINT, p_clause_id BIGINT) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
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
    'id', cl.id, 'category', cl.category, 'titleEn', cl.title_en, 'titleAr', cl.title_ar,
    'bodyEn', cl.body_en, 'bodyAr', cl.body_ar, 'variant', cl.variant,
    'legalCommentaryEn', cl.legal_commentary_en, 'legalCommentaryAr', cl.legal_commentary_ar,
    'regulatoryRefs', cl.regulatory_refs, 'usageCount', cl.usage_count,
    'createdAt', cl.created_at, 'updatedAt', cl.updated_at
  ) INTO v_row FROM contract_clause cl WHERE cl.id = p_clause_id AND cl.is_active = TRUE;

  IF v_row IS NULL THEN RAISE EXCEPTION 'clause_not_found' USING ERRCODE = 'P0002'; END IF;
  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION fn_obligation_list(
  p_actor_id BIGINT, p_status VARCHAR DEFAULT NULL, p_assignee_id BIGINT DEFAULT NULL,
  p_limit INTEGER DEFAULT 100, p_offset INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE v_rows JSONB; v_total BIGINT;
BEGIN
  IF NOT (
    fn_current_user_has_permission('contract.read.department')
    OR fn_current_user_has_permission('contract.read.all')
    OR fn_current_user_has_permission('contract.edit')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total FROM contract_obligation o
  WHERE o.is_active = TRUE
    AND (p_status IS NULL OR o.status = p_status)
    AND (p_assignee_id IS NULL OR o.assignee_user_id = p_assignee_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', o.id, 'contractId', o.contract_id, 'contractNumber', c.contract_number,
    'titleEn', o.title_en, 'titleAr', o.title_ar, 'descriptionEn', o.description_en,
    'obligationType', o.obligation_type, 'dueDate', o.due_date, 'recurrence', o.recurrence,
    'responsibleParty', o.responsible_party, 'assigneeUserId', o.assignee_user_id,
    'status', o.status, 'completedAt', o.completed_at, 'createdAt', o.created_at
  ) ORDER BY (o.due_date IS NULL), o.due_date, o.id), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM contract_obligation WHERE is_active = TRUE
      AND (p_status IS NULL OR status = p_status)
      AND (p_assignee_id IS NULL OR assignee_user_id = p_assignee_id)
    ORDER BY (due_date IS NULL), due_date, id LIMIT p_limit OFFSET p_offset
  ) o JOIN contract c ON c.id = o.contract_id;

  RETURN jsonb_build_object('data', v_rows, 'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset));
END;
$$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (60, 'M_parity relax read perm: 058 fn_'' gates also accept contract.read.all (executive role)', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
