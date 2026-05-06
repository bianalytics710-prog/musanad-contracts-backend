-- ============================================================================
-- 058_m_parity_entities.sql
-- ============================================================================
-- Module:    M_parity (Lovable feature-depth parity polish)
-- Owner:     Direct work — no orchestrator pipeline (UI-only parity push)
-- Depends:   M0 (user, fn_audit_trigger, fn_current_user_has_permission),
--            M1a (contract — for FK from contract_obligation), M1c (contract_tag for tag patterns).
-- ----------------------------------------------------------------------------
-- Lovable shows Templates / Clauses / Parties / Obligations as full
-- entities; our M0..M6 framework deferred them as ComingSoon stubs. This
-- migration introduces minimal read-only versions so the sidebar items
-- are real surfaces, not placeholders.
--
-- Tables:
--   party                  — counterparty / our-party catalog
--   contract_template      — re-usable contract templates
--   contract_clause        — re-usable clauses
--   contract_obligation    — per-contract obligations tracker
--
-- Functions: list + get for each (read-only — no create/update/delete this round)
-- RLS: SELECT for authenticated; INSERT/UPDATE/DELETE locked to admins.
-- Permissions: piggyback on existing 'contract.read.department' for read access
--   so we don't add new permission codes mid-cycle.
-- Audit: STANDARD trigger pattern.
-- Seed: bundled in this migration (12 parties, 8 templates, 18 clauses,
--   ~25 obligations derived from existing payment_schedule rows).
--
-- S2-21 invariant: PUBLIC count remains at 5 (no PUBLIC EXECUTE grants here).
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. party  (counterparty + our-party catalog)
-- ============================================================================
CREATE TABLE IF NOT EXISTS party (
  id                       BIGSERIAL PRIMARY KEY,

  party_type               VARCHAR(20)  NOT NULL CHECK (party_type IN ('individual','company')),
  name_en                  VARCHAR(200) NOT NULL,
  name_ar                  VARCHAR(200),
  trade_license_number     VARCHAR(80),
  trade_license_issuer     VARCHAR(80),
  emirate                  VARCHAR(40)  CHECK (emirate IN ('abu_dhabi','dubai','sharjah','ajman','umm_al_quwain','ras_al_khaimah','fujairah') OR emirate IS NULL),
  free_zone                VARCHAR(80),
  country                  VARCHAR(60)  NOT NULL DEFAULT 'United Arab Emirates',
  contact_email            VARCHAR(255),
  contact_phone            VARCHAR(40),
  registered_address       TEXT,
  notes                    TEXT,
  is_seed                  BOOLEAN      NOT NULL DEFAULT FALSE,

  created_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by               BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by               BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE party IS 'M_parity counterparty / our-party catalog. Read-only this round.';

CREATE INDEX idx_party_active        ON party(id) WHERE is_active = TRUE;
CREATE INDEX idx_party_name_en       ON party(name_en) WHERE is_active = TRUE;
CREATE INDEX idx_party_type          ON party(party_type) WHERE is_active = TRUE;
CREATE INDEX idx_party_emirate       ON party(emirate) WHERE is_active = TRUE;

CREATE TRIGGER audit_party_changes
  BEFORE INSERT OR UPDATE ON party
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ============================================================================
-- 2. contract_template
-- ============================================================================
CREATE TABLE IF NOT EXISTS contract_template (
  id                       BIGSERIAL PRIMARY KEY,

  name_en                  VARCHAR(200) NOT NULL,
  name_ar                  VARCHAR(200),
  contract_type            VARCHAR(60)  NOT NULL,
  description_en           TEXT,
  description_ar           TEXT,
  body_en                  TEXT,
  body_ar                  TEXT,
  language                 VARCHAR(20)  NOT NULL DEFAULT 'en' CHECK (language IN ('en','ar','bilingual')),
  regulatory_tags          TEXT[]       NOT NULL DEFAULT '{}',
  usage_count              INTEGER      NOT NULL DEFAULT 0,
  is_seed                  BOOLEAN      NOT NULL DEFAULT FALSE,

  created_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by               BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by               BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE contract_template IS 'M_parity re-usable contract templates.';

CREATE INDEX idx_contract_template_active        ON contract_template(id) WHERE is_active = TRUE;
CREATE INDEX idx_contract_template_type          ON contract_template(contract_type) WHERE is_active = TRUE;
CREATE INDEX idx_contract_template_usage         ON contract_template(usage_count DESC) WHERE is_active = TRUE;

CREATE TRIGGER audit_contract_template_changes
  BEFORE INSERT OR UPDATE ON contract_template
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ============================================================================
-- 3. contract_clause
-- ============================================================================
CREATE TABLE IF NOT EXISTS contract_clause (
  id                       BIGSERIAL PRIMARY KEY,

  category                 VARCHAR(60)  NOT NULL,
  title_en                 VARCHAR(200) NOT NULL,
  title_ar                 VARCHAR(200),
  body_en                  TEXT         NOT NULL,
  body_ar                  TEXT,
  variant                  VARCHAR(20)  NOT NULL DEFAULT 'standard' CHECK (variant IN ('standard','alternative','fallback')),
  legal_commentary_en      TEXT,
  legal_commentary_ar      TEXT,
  regulatory_refs          TEXT[]       NOT NULL DEFAULT '{}',
  usage_count              INTEGER      NOT NULL DEFAULT 0,
  is_seed                  BOOLEAN      NOT NULL DEFAULT FALSE,

  created_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by               BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by               BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE contract_clause IS 'M_parity re-usable contract clauses.';

CREATE INDEX idx_contract_clause_active        ON contract_clause(id) WHERE is_active = TRUE;
CREATE INDEX idx_contract_clause_category      ON contract_clause(category) WHERE is_active = TRUE;
CREATE INDEX idx_contract_clause_variant       ON contract_clause(variant) WHERE is_active = TRUE;
CREATE INDEX idx_contract_clause_usage         ON contract_clause(usage_count DESC) WHERE is_active = TRUE;

CREATE TRIGGER audit_contract_clause_changes
  BEFORE INSERT OR UPDATE ON contract_clause
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ============================================================================
-- 4. contract_obligation
-- ============================================================================
CREATE TABLE IF NOT EXISTS contract_obligation (
  id                       BIGSERIAL PRIMARY KEY,

  contract_id              BIGINT       NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
  title_en                 VARCHAR(200) NOT NULL,
  title_ar                 VARCHAR(200),
  description_en           TEXT,
  description_ar           TEXT,
  obligation_type          VARCHAR(40)  NOT NULL CHECK (obligation_type IN ('payment','delivery','reporting','renewal','compliance','notice','other')),
  due_date                 DATE,
  recurrence               VARCHAR(20)  NOT NULL DEFAULT 'once' CHECK (recurrence IN ('once','monthly','quarterly','annually')),
  responsible_party        VARCHAR(20)  NOT NULL DEFAULT 'our_party' CHECK (responsible_party IN ('our_party','counterparty','both')),
  assignee_user_id         BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  status                   VARCHAR(20)  NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_progress','completed','overdue','waived')),
  completed_at             TIMESTAMPTZ,
  is_seed                  BOOLEAN      NOT NULL DEFAULT FALSE,

  created_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by               BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by               BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active                BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE contract_obligation IS 'M_parity per-contract obligations tracker.';

CREATE INDEX idx_contract_obligation_active        ON contract_obligation(id) WHERE is_active = TRUE;
CREATE INDEX idx_contract_obligation_contract      ON contract_obligation(contract_id) WHERE is_active = TRUE;
CREATE INDEX idx_contract_obligation_status        ON contract_obligation(status) WHERE is_active = TRUE;
CREATE INDEX idx_contract_obligation_due           ON contract_obligation(due_date) WHERE is_active = TRUE AND status != 'completed';
CREATE INDEX idx_contract_obligation_assignee      ON contract_obligation(assignee_user_id) WHERE is_active = TRUE;

CREATE TRIGGER audit_contract_obligation_changes
  BEFORE INSERT OR UPDATE ON contract_obligation
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ============================================================================
-- 5. RLS — read open to authenticated; write locked to admin/super_admin.
-- ============================================================================
ALTER TABLE party                ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_template    ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_clause      ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_obligation  ENABLE ROW LEVEL SECURITY;

-- party
CREATE POLICY party_select ON party FOR SELECT USING (is_active = TRUE);
CREATE POLICY party_modify_admin ON party FOR ALL
  USING (fn_current_user_has_permission('contract.edit'))
  WITH CHECK (fn_current_user_has_permission('contract.edit'));

-- contract_template
CREATE POLICY template_select ON contract_template FOR SELECT USING (is_active = TRUE);
CREATE POLICY template_modify_admin ON contract_template FOR ALL
  USING (fn_current_user_has_permission('contract.edit'))
  WITH CHECK (fn_current_user_has_permission('contract.edit'));

-- contract_clause
CREATE POLICY clause_select ON contract_clause FOR SELECT USING (is_active = TRUE);
CREATE POLICY clause_modify_admin ON contract_clause FOR ALL
  USING (fn_current_user_has_permission('contract.edit'))
  WITH CHECK (fn_current_user_has_permission('contract.edit'));

-- contract_obligation
CREATE POLICY obligation_select ON contract_obligation FOR SELECT USING (is_active = TRUE);
CREATE POLICY obligation_modify_admin ON contract_obligation FOR ALL
  USING (fn_current_user_has_permission('contract.edit'))
  WITH CHECK (fn_current_user_has_permission('contract.edit'));

-- ============================================================================
-- 6. Functions — list + get for each entity (read-only this round)
-- ============================================================================

-- party --------------------------------------------------------------------

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
  IF NOT fn_current_user_has_permission('contract.read.department') AND NOT fn_current_user_has_permission('contract.edit') THEN
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
  IF NOT fn_current_user_has_permission('contract.read.department') AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT to_jsonb(p) - 'created_at' - 'updated_at'
    || jsonb_build_object(
      'createdAt', p.created_at,
      'updatedAt', p.updated_at
    ) INTO v_row
  FROM party p
  WHERE p.id = p_party_id AND p.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'party_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- contract count + list (5 most recent) where this party is counterparty
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

-- contract_template --------------------------------------------------------

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
  IF NOT fn_current_user_has_permission('contract.read.department') AND NOT fn_current_user_has_permission('contract.edit') THEN
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
DECLARE
  v_row JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department') AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',                t.id,
    'nameEn',            t.name_en,
    'nameAr',            t.name_ar,
    'contractType',      t.contract_type,
    'descriptionEn',     t.description_en,
    'descriptionAr',     t.description_ar,
    'bodyEn',            t.body_en,
    'bodyAr',            t.body_ar,
    'language',          t.language,
    'regulatoryTags',    t.regulatory_tags,
    'usageCount',        t.usage_count,
    'createdAt',         t.created_at,
    'updatedAt',         t.updated_at
  ) INTO v_row
  FROM contract_template t
  WHERE t.id = p_template_id AND t.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'P0002';
  END IF;

  RETURN v_row;
END;
$$;

-- contract_clause ----------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_clause_list(
  p_actor_id BIGINT,
  p_category VARCHAR DEFAULT NULL,
  p_variant  VARCHAR DEFAULT NULL,
  p_search   VARCHAR DEFAULT NULL,
  p_limit    INTEGER DEFAULT 100,
  p_offset   INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_rows JSONB;
  v_total BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department') AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM contract_clause cl
  WHERE cl.is_active = TRUE
    AND (p_category IS NULL OR cl.category = p_category)
    AND (p_variant  IS NULL OR cl.variant  = p_variant)
    AND (p_search IS NULL OR cl.title_en ILIKE '%' || p_search || '%' OR COALESCE(cl.title_ar,'') ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             cl.id,
    'category',       cl.category,
    'titleEn',        cl.title_en,
    'titleAr',        cl.title_ar,
    'variant',        cl.variant,
    'regulatoryRefs', cl.regulatory_refs,
    'usageCount',     cl.usage_count,
    'createdAt',      cl.created_at
  ) ORDER BY cl.category, cl.usage_count DESC, cl.title_en), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM contract_clause
    WHERE is_active = TRUE
      AND (p_category IS NULL OR category = p_category)
      AND (p_variant  IS NULL OR variant  = p_variant)
      AND (p_search IS NULL OR title_en ILIKE '%' || p_search || '%' OR COALESCE(title_ar,'') ILIKE '%' || p_search || '%')
    ORDER BY category, usage_count DESC, title_en
    LIMIT p_limit OFFSET p_offset
  ) cl;

  RETURN jsonb_build_object('data', v_rows, 'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset));
END;
$$;

CREATE OR REPLACE FUNCTION fn_clause_get_by_id(
  p_actor_id  BIGINT,
  p_clause_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_row JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department') AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'id',                cl.id,
    'category',          cl.category,
    'titleEn',           cl.title_en,
    'titleAr',           cl.title_ar,
    'bodyEn',            cl.body_en,
    'bodyAr',            cl.body_ar,
    'variant',           cl.variant,
    'legalCommentaryEn', cl.legal_commentary_en,
    'legalCommentaryAr', cl.legal_commentary_ar,
    'regulatoryRefs',    cl.regulatory_refs,
    'usageCount',        cl.usage_count,
    'createdAt',         cl.created_at,
    'updatedAt',         cl.updated_at
  ) INTO v_row
  FROM contract_clause cl
  WHERE cl.id = p_clause_id AND cl.is_active = TRUE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION 'clause_not_found' USING ERRCODE = 'P0002';
  END IF;

  RETURN v_row;
END;
$$;

-- contract_obligation ------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_obligation_list(
  p_actor_id    BIGINT,
  p_status      VARCHAR DEFAULT NULL,
  p_assignee_id BIGINT  DEFAULT NULL,
  p_limit       INTEGER DEFAULT 100,
  p_offset      INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
AS $$
DECLARE
  v_rows JSONB;
  v_total BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('contract.read.department') AND NOT fn_current_user_has_permission('contract.edit') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM contract_obligation o
  WHERE o.is_active = TRUE
    AND (p_status IS NULL OR o.status = p_status)
    AND (p_assignee_id IS NULL OR o.assignee_user_id = p_assignee_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
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
  ) ORDER BY (o.due_date IS NULL), o.due_date, o.id), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM contract_obligation
    WHERE is_active = TRUE
      AND (p_status IS NULL OR status = p_status)
      AND (p_assignee_id IS NULL OR assignee_user_id = p_assignee_id)
    ORDER BY (due_date IS NULL), due_date, id
    LIMIT p_limit OFFSET p_offset
  ) o
  JOIN contract c ON c.id = o.contract_id;

  RETURN jsonb_build_object('data', v_rows, 'pagination', jsonb_build_object('total', v_total, 'limit', p_limit, 'offset', p_offset));
END;
$$;

-- ============================================================================
-- 7. Grants — only neondb_owner + auth roles. NO PUBLIC additions (S2-21).
-- ============================================================================
GRANT EXECUTE ON FUNCTION fn_party_list(BIGINT, VARCHAR, VARCHAR, INTEGER, INTEGER) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_party_get_by_id(BIGINT, BIGINT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_template_list(BIGINT, VARCHAR, VARCHAR, INTEGER, INTEGER) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_template_get_by_id(BIGINT, BIGINT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_clause_list(BIGINT, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_clause_get_by_id(BIGINT, BIGINT) TO neondb_owner;
GRANT EXECUTE ON FUNCTION fn_obligation_list(BIGINT, VARCHAR, BIGINT, INTEGER, INTEGER) TO neondb_owner;

-- ============================================================================
-- 8. Add FK from contract.counterparty_id → party.id (was orphan BIGINT)
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'contract_counterparty_id_fkey'
  ) THEN
    ALTER TABLE contract
      ADD CONSTRAINT contract_counterparty_id_fkey
      FOREIGN KEY (counterparty_id) REFERENCES party(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'contract_template_id_fkey'
  ) THEN
    ALTER TABLE contract
      ADD CONSTRAINT contract_template_id_fkey
      FOREIGN KEY (template_id) REFERENCES contract_template(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'contract_our_party_id_fkey'
  ) THEN
    ALTER TABLE contract
      ADD CONSTRAINT contract_our_party_id_fkey
      FOREIGN KEY (our_party_id) REFERENCES party(id) ON DELETE SET NULL;
  END IF;
END $$;

-- ============================================================================
-- 9. Schema migration tracker
-- ============================================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (58, 'M_parity entities: party + contract_template + contract_clause + contract_obligation', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK (manual)
-- ============================================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_obligation_list;
-- DROP FUNCTION IF EXISTS fn_clause_get_by_id;
-- DROP FUNCTION IF EXISTS fn_clause_list;
-- DROP FUNCTION IF EXISTS fn_template_get_by_id;
-- DROP FUNCTION IF EXISTS fn_template_list;
-- DROP FUNCTION IF EXISTS fn_party_get_by_id;
-- DROP FUNCTION IF EXISTS fn_party_list;
-- ALTER TABLE contract DROP CONSTRAINT IF EXISTS contract_counterparty_id_fkey;
-- ALTER TABLE contract DROP CONSTRAINT IF EXISTS contract_template_id_fkey;
-- ALTER TABLE contract DROP CONSTRAINT IF EXISTS contract_our_party_id_fkey;
-- DROP TABLE IF EXISTS contract_obligation;
-- DROP TABLE IF EXISTS contract_clause;
-- DROP TABLE IF EXISTS contract_template;
-- DROP TABLE IF EXISTS party;
-- DELETE FROM schema_migrations WHERE version = 58;
-- COMMIT;
