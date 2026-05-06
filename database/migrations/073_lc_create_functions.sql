-- Migration 073: R-LC3 — fn_*_create for templates / clauses / parties /
-- obligations. Per LC decision 5(b), legal counsel can author the legal
-- library (templates, clauses) and onboard parties/obligations, but NOT
-- contracts (drafter-only). All four functions gate on contract.edit
-- permission (legal_counsel role grants this through the M0 seed).

-- ============================================================================
-- 1. fn_party_create
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_party_create(
  p_actor_id            BIGINT,
  p_party_type          VARCHAR,
  p_name_en             VARCHAR,
  p_name_ar             VARCHAR  DEFAULT NULL,
  p_trade_license_number VARCHAR DEFAULT NULL,
  p_trade_license_issuer VARCHAR DEFAULT NULL,
  p_emirate             VARCHAR  DEFAULT NULL,
  p_free_zone           VARCHAR  DEFAULT NULL,
  p_country             VARCHAR  DEFAULT 'United Arab Emirates',
  p_contact_email       VARCHAR  DEFAULT NULL,
  p_contact_phone       VARCHAR  DEFAULT NULL,
  p_registered_address  TEXT     DEFAULT NULL,
  p_notes               TEXT     DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_party_type NOT IN ('individual', 'company') THEN
    RAISE EXCEPTION 'fn_party_create: partyType:invalid party_type' USING ERRCODE = '22023';
  END IF;
  IF p_name_en IS NULL OR length(trim(p_name_en)) = 0 THEN
    RAISE EXCEPTION 'fn_party_create: nameEn:nameEn is required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO party (
    party_type, name_en, name_ar, trade_license_number, trade_license_issuer,
    emirate, free_zone, country, contact_email, contact_phone,
    registered_address, notes, created_by, updated_by
  ) VALUES (
    p_party_type, p_name_en, p_name_ar, p_trade_license_number, p_trade_license_issuer,
    p_emirate, p_free_zone, p_country, p_contact_email, p_contact_phone,
    p_registered_address, p_notes, p_actor_id, p_actor_id
  ) RETURNING id INTO v_id;

  RETURN fn_party_get_by_id(p_actor_id, v_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_party_create(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_party_create(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT) TO neondb_owner;

-- ============================================================================
-- 2. fn_template_create
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_template_create(
  p_actor_id        BIGINT,
  p_name_en         VARCHAR,
  p_contract_type   VARCHAR,
  p_language        VARCHAR  DEFAULT 'en',
  p_name_ar         VARCHAR  DEFAULT NULL,
  p_description_en  TEXT     DEFAULT NULL,
  p_description_ar  TEXT     DEFAULT NULL,
  p_body_en         TEXT     DEFAULT NULL,
  p_body_ar         TEXT     DEFAULT NULL,
  p_regulatory_tags TEXT[]   DEFAULT '{}'::TEXT[]
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_id BIGINT;
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
    language, body_en, body_ar, regulatory_tags, usage_count,
    created_by, updated_by
  ) VALUES (
    p_name_en, p_name_ar, p_contract_type, p_description_en, p_description_ar,
    p_language, p_body_en, p_body_ar, p_regulatory_tags, 0,
    p_actor_id, p_actor_id
  ) RETURNING id INTO v_id;

  RETURN fn_template_get_by_id(p_actor_id, v_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_template_create(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT, TEXT, TEXT, TEXT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_template_create(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT, TEXT, TEXT, TEXT[]) TO neondb_owner;

-- ============================================================================
-- 3. fn_clause_create
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_clause_create(
  p_actor_id            BIGINT,
  p_category            VARCHAR,
  p_title_en            VARCHAR,
  p_body_en             TEXT,
  p_variant             VARCHAR  DEFAULT 'standard',
  p_title_ar            VARCHAR  DEFAULT NULL,
  p_body_ar             TEXT     DEFAULT NULL,
  p_legal_commentary_en TEXT     DEFAULT NULL,
  p_legal_commentary_ar TEXT     DEFAULT NULL,
  p_regulatory_refs     TEXT[]   DEFAULT '{}'::TEXT[]
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_title_en IS NULL OR length(trim(p_title_en)) = 0 THEN
    RAISE EXCEPTION 'fn_clause_create: titleEn:titleEn is required' USING ERRCODE = '22023';
  END IF;
  IF p_body_en IS NULL OR length(trim(p_body_en)) = 0 THEN
    RAISE EXCEPTION 'fn_clause_create: bodyEn:bodyEn is required' USING ERRCODE = '22023';
  END IF;
  IF p_variant NOT IN ('standard', 'alternative', 'fallback') THEN
    RAISE EXCEPTION 'fn_clause_create: variant:invalid variant' USING ERRCODE = '22023';
  END IF;

  INSERT INTO contract_clause (
    category, title_en, title_ar, variant, body_en, body_ar,
    legal_commentary_en, legal_commentary_ar, regulatory_refs, usage_count,
    created_by, updated_by
  ) VALUES (
    p_category, p_title_en, p_title_ar, p_variant, p_body_en, p_body_ar,
    p_legal_commentary_en, p_legal_commentary_ar, p_regulatory_refs, 0,
    p_actor_id, p_actor_id
  ) RETURNING id INTO v_id;

  RETURN fn_clause_get_by_id(p_actor_id, v_id);
END;
$$;

REVOKE ALL ON FUNCTION fn_clause_create(BIGINT, VARCHAR, VARCHAR, TEXT, VARCHAR, VARCHAR, TEXT, TEXT, TEXT, TEXT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_clause_create(BIGINT, VARCHAR, VARCHAR, TEXT, VARCHAR, VARCHAR, TEXT, TEXT, TEXT, TEXT[]) TO neondb_owner;

-- ============================================================================
-- 4. fn_obligation_create
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_obligation_create(
  p_actor_id        BIGINT,
  p_contract_id     BIGINT,
  p_title_en        VARCHAR,
  p_obligation_type VARCHAR,
  p_due_date        DATE     DEFAULT NULL,
  p_recurrence      VARCHAR  DEFAULT 'once',
  p_responsible_party VARCHAR DEFAULT 'our_party',
  p_title_ar        VARCHAR  DEFAULT NULL,
  p_description_en  TEXT     DEFAULT NULL,
  p_description_ar  TEXT     DEFAULT NULL,
  p_assignee_user_id BIGINT  DEFAULT NULL,
  p_status          VARCHAR  DEFAULT 'open'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_id BIGINT;
  v_row JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_contract_id IS NULL OR NOT EXISTS (SELECT 1 FROM contract WHERE id = p_contract_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'fn_obligation_create: contractId:contract not found' USING ERRCODE = '23503';
  END IF;
  IF p_title_en IS NULL OR length(trim(p_title_en)) = 0 THEN
    RAISE EXCEPTION 'fn_obligation_create: titleEn:titleEn is required' USING ERRCODE = '22023';
  END IF;
  IF p_obligation_type NOT IN ('payment','delivery','reporting','renewal','compliance','notice','other') THEN
    RAISE EXCEPTION 'fn_obligation_create: obligationType:invalid type' USING ERRCODE = '22023';
  END IF;
  IF p_recurrence NOT IN ('once','monthly','quarterly','annually') THEN
    RAISE EXCEPTION 'fn_obligation_create: recurrence:invalid recurrence' USING ERRCODE = '22023';
  END IF;
  IF p_responsible_party NOT IN ('our_party','counterparty','both') THEN
    RAISE EXCEPTION 'fn_obligation_create: responsibleParty:invalid value' USING ERRCODE = '22023';
  END IF;
  IF p_status NOT IN ('open','in_progress','completed','overdue','waived') THEN
    RAISE EXCEPTION 'fn_obligation_create: status:invalid status' USING ERRCODE = '22023';
  END IF;

  INSERT INTO contract_obligation (
    contract_id, title_en, title_ar, description_en, description_ar,
    obligation_type, due_date, recurrence, responsible_party,
    assignee_user_id, status, created_by, updated_by
  ) VALUES (
    p_contract_id, p_title_en, p_title_ar, p_description_en, p_description_ar,
    p_obligation_type, p_due_date, p_recurrence, p_responsible_party,
    p_assignee_user_id, p_status, p_actor_id, p_actor_id
  ) RETURNING id INTO v_id;

  -- Return the row mirror of fn_obligation_list shape (camelCase).
  SELECT jsonb_build_object(
    'id',                o.id,
    'contractId',        o.contract_id,
    'contractNumber',    c.contract_number,
    'titleEn',           o.title_en,
    'titleAr',           o.title_ar,
    'descriptionEn',     o.description_en,
    'obligationType',    o.obligation_type,
    'dueDate',           o.due_date,
    'recurrence',        o.recurrence,
    'responsibleParty',  o.responsible_party,
    'assigneeUserId',    o.assignee_user_id,
    'status',            o.status,
    'completedAt',       o.completed_at,
    'createdAt',         o.created_at
  ) INTO v_row
  FROM contract_obligation o
  JOIN contract c ON c.id = o.contract_id
  WHERE o.id = v_id;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION fn_obligation_create(BIGINT, BIGINT, VARCHAR, VARCHAR, DATE, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT, BIGINT, VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_obligation_create(BIGINT, BIGINT, VARCHAR, VARCHAR, DATE, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT, BIGINT, VARCHAR) TO neondb_owner;

-- ROLLBACK BEGIN
-- DROP FUNCTION IF EXISTS fn_party_create(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS fn_template_create(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT, TEXT, TEXT, TEXT[]);
-- DROP FUNCTION IF EXISTS fn_clause_create(BIGINT, VARCHAR, VARCHAR, TEXT, VARCHAR, VARCHAR, TEXT, TEXT, TEXT, TEXT[]);
-- DROP FUNCTION IF EXISTS fn_obligation_create(BIGINT, BIGINT, VARCHAR, VARCHAR, DATE, VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT, BIGINT, VARCHAR);
-- ROLLBACK END
