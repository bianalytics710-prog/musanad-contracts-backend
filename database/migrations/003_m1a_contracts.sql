-- ============================================================================
-- 003_m1a_contracts.sql — M1a Contracts: tables + RLS + audit bindings + seeds
-- ============================================================================
-- Module:    M1a (Contracts: Core CRUD & Lifecycle)
-- Owner:     Agent 4 — DB Architect
-- Depends:   001_foundation.sql, 002_security_hardening.sql (both M0)
-- ----------------------------------------------------------------------------
-- Forward migration creates 4 new tables (contract, contract_tag,
-- contract_version, contract_activity), all indexes, 3 audit-trigger bindings,
-- enables RLS and creates 11 policies, then seeds 7 roles + 9 permissions +
-- 20 role-permission grants. Idempotent on re-run via ON CONFLICT DO NOTHING.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- 0. Required extensions
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================
-- 1. Tables
-- ============================================================

-- 1.1 contract — core entity
CREATE TABLE contract (
  id                      BIGSERIAL PRIMARY KEY,

  -- Business columns
  contract_number         VARCHAR(50)  NOT NULL UNIQUE,
  title_en                VARCHAR(500) NOT NULL,
  title_ar                VARCHAR(500),
  contract_type           VARCHAR(50)  NOT NULL,
  template_id             BIGINT,                       -- Forward reference to contract_template (M1b/Templates module); FK constraint added by that migration.
  status                  VARCHAR(50)  NOT NULL DEFAULT 'draft'
                            CHECK (status IN ('draft','in_review','approved','awaiting_signature_employer','awaiting_signature_counterparty','fully_signed','active','expiring_soon','expired','amended','renewed','terminated','rejected','resubmission_requested')),
  language                VARCHAR(20)  NOT NULL DEFAULT 'en'
                            CHECK (language IN ('en','ar','bilingual')),
  our_party_id            BIGINT,                       -- Forward reference to party (Parties module); FK ON DELETE RESTRICT added by Parties migration.
  counterparty_id         BIGINT,                       -- Forward reference to party (Parties module); FK ON DELETE RESTRICT added by Parties migration.
  value_aed               NUMERIC(15,2) CHECK (value_aed IS NULL OR value_aed >= 0),
  currency                CHAR(3)      NOT NULL DEFAULT 'AED',
  start_date              DATE,
  end_date                DATE,
  signed_at               TIMESTAMPTZ,
  expiry_notice_days      INTEGER      DEFAULT 30,
  emirate                 VARCHAR(50),
  governing_law           VARCHAR(50)
                            CHECK (governing_law IS NULL OR governing_law IN ('uae_federal','dubai','abu_dhabi','sharjah','difc','adgm','english','other')),
  jurisdiction_court      VARCHAR(255),
  parent_contract_id      BIGINT       REFERENCES contract(id) ON DELETE RESTRICT,
  relationship_type       VARCHAR(30)
                            CHECK (relationship_type IS NULL OR relationship_type IN ('amendment','renewal','extension','superseded','sow_under_msa')),
  body_en                 TEXT,        -- SENSITIVE — redacted by fn_audit_trigger after migration 004
  body_ar                 TEXT,        -- SENSITIVE — redacted by fn_audit_trigger after migration 004
  current_version         INTEGER      NOT NULL DEFAULT 1,
  drafted_by              BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  reviewed_by             BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  approved_by             BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  ai_risk_score           INTEGER      CHECK (ai_risk_score IS NULL OR (ai_risk_score BETWEEN 0 AND 100)),
  ai_summary_en           TEXT,
  ai_summary_ar           TEXT,
  import_batch_id         BIGINT,                       -- Forward reference to import_batch (M1c); FK ON DELETE SET NULL added by M1c migration.
  import_confidence       INTEGER      CHECK (import_confidence IS NULL OR (import_confidence BETWEEN 0 AND 100)),
  import_filename         TEXT,
  import_warnings         JSONB,

  -- Standard audit columns
  created_at              TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at              TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by              BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by              BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active               BOOLEAN      NOT NULL DEFAULT TRUE,

  -- Self-parent guard at row level (cycle detection done in fn_contract_update)
  CONSTRAINT chk_contract_not_self_parent CHECK (parent_contract_id IS NULL OR parent_contract_id <> id),
  -- End date sanity
  CONSTRAINT chk_contract_dates CHECK (start_date IS NULL OR end_date IS NULL OR end_date >= start_date)
);

COMMENT ON TABLE contract IS 'M1a core contract entity. Bilingual title/body, 14-state status workflow (validated by enum only in M1a; transition logic in M2), self-referencing parent/child tree, version pointer, soft-delete via is_active. body_en/body_ar are sensitive — pino-redacted in logs and fn_audit_trigger-redacted in audit_log JSONB.';
COMMENT ON COLUMN contract.contract_number       IS 'Auto-generated server-side in fn_contract_create using format CT-YYYY-NNNNNN where NNNNNN is zero-padded sequence per year. UNIQUE constraint enforced.';
COMMENT ON COLUMN contract.template_id           IS 'Forward reference to contract_template (M1b/Templates module). FK constraint deferred — added by that module via ALTER TABLE.';
COMMENT ON COLUMN contract.our_party_id          IS 'Forward reference to party (Parties module). FK ON DELETE RESTRICT added by Parties migration.';
COMMENT ON COLUMN contract.counterparty_id       IS 'Forward reference to party (Parties module). FK ON DELETE RESTRICT added by Parties migration.';
COMMENT ON COLUMN contract.import_batch_id       IS 'Forward reference to import_batch (M1c). FK ON DELETE SET NULL added by M1c migration.';
COMMENT ON COLUMN contract.body_en               IS 'SENSITIVE — pino-redacted, fn_audit_trigger-redacted (after migration 004).';
COMMENT ON COLUMN contract.body_ar               IS 'SENSITIVE — pino-redacted, fn_audit_trigger-redacted (after migration 004).';
COMMENT ON COLUMN contract.is_active             IS 'Soft-delete flag. Centrally controlled by fn_contract_delete (SECURITY DEFINER) — direct UPDATE that touches is_active is denied by RLS policy contract_deny_direct_is_active_update. Codex G2 TOCTOU defense.';

-- Indexes for contract
CREATE INDEX idx_contract_active             ON contract(id) WHERE is_active = true;
CREATE INDEX idx_contract_status             ON contract(status) WHERE is_active = true;
CREATE INDEX idx_contract_contract_type      ON contract(contract_type) WHERE is_active = true;
CREATE INDEX idx_contract_counterparty_id    ON contract(counterparty_id) WHERE counterparty_id IS NOT NULL;
CREATE INDEX idx_contract_our_party_id       ON contract(our_party_id) WHERE our_party_id IS NOT NULL;
CREATE INDEX idx_contract_drafted_by         ON contract(drafted_by) WHERE drafted_by IS NOT NULL;
CREATE INDEX idx_contract_reviewed_by        ON contract(reviewed_by) WHERE reviewed_by IS NOT NULL;
CREATE INDEX idx_contract_approved_by        ON contract(approved_by) WHERE approved_by IS NOT NULL;
CREATE INDEX idx_contract_template_id        ON contract(template_id) WHERE template_id IS NOT NULL;
CREATE INDEX idx_contract_parent_contract_id ON contract(parent_contract_id) WHERE parent_contract_id IS NOT NULL;
CREATE INDEX idx_contract_import_batch_id    ON contract(import_batch_id) WHERE import_batch_id IS NOT NULL;
CREATE INDEX idx_contract_created_at_desc    ON contract(created_at DESC) WHERE is_active = true;
CREATE INDEX idx_contract_end_date           ON contract(end_date) WHERE is_active = true AND end_date IS NOT NULL;
CREATE INDEX idx_contract_start_date         ON contract(start_date) WHERE is_active = true AND start_date IS NOT NULL;
CREATE INDEX idx_contract_created_by         ON contract(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_contract_updated_by         ON contract(updated_by) WHERE updated_by IS NOT NULL;
CREATE INDEX idx_contract_search_trgm        ON contract USING gin (lower(coalesce(contract_number,'') || ' ' || coalesce(title_en,'') || ' ' || coalesce(title_ar,'')) gin_trgm_ops);

-- 1.2 contract_tag — junction (chosen over TEXT[]+GIN)
CREATE TABLE contract_tag (
  id           BIGSERIAL PRIMARY KEY,
  contract_id  BIGINT       NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
  tag          VARCHAR(64)  NOT NULL,

  -- Standard audit columns (no updated_at/updated_by — tags are immutable; lifecycle is insert + soft-delete)
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by   BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active    BOOLEAN      NOT NULL DEFAULT TRUE,

  CONSTRAINT chk_contract_tag_length CHECK (char_length(tag) BETWEEN 1 AND 64),
  CONSTRAINT chk_contract_tag_no_control CHECK (tag !~ '[\x00-\x1F\x7F]')
);

CREATE UNIQUE INDEX uq_contract_tag_active ON contract_tag(contract_id, tag) WHERE is_active = true;

COMMENT ON TABLE contract_tag IS 'Junction normalising the contract.tags set. fn_contract_set_tags is the canonical writer. UNIQUE(contract_id, tag) WHERE is_active=true allows tag reactivation. Bound to fn_audit_trigger.';
COMMENT ON COLUMN contract_tag.tag IS 'Free-form text 1..64 chars; trimmed by fn_contract_set_tags before storage; no control chars.';

CREATE INDEX idx_contract_tag_contract_id ON contract_tag(contract_id);
CREATE INDEX idx_contract_tag_tag         ON contract_tag(tag) WHERE is_active = true;
CREATE INDEX idx_contract_tag_active      ON contract_tag(id) WHERE is_active = true;
CREATE INDEX idx_contract_tag_created_by  ON contract_tag(created_by) WHERE created_by IS NOT NULL;

-- 1.3 contract_version — append-only version history
CREATE TABLE contract_version (
  id              BIGSERIAL PRIMARY KEY,
  contract_id     BIGINT       NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
  version_number  INTEGER      NOT NULL,
  body_en         TEXT,
  body_ar         TEXT,
  diff_summary    TEXT,
  change_note     VARCHAR(500),
  changed_by      BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,

  created_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by      BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active       BOOLEAN      NOT NULL DEFAULT TRUE,

  CONSTRAINT uq_contract_version UNIQUE (contract_id, version_number),
  CONSTRAINT chk_contract_version_body_present CHECK (body_en IS NOT NULL OR body_ar IS NOT NULL)
);

COMMENT ON TABLE contract_version IS 'Append-only version history snapshot. fn_contract_version_create is the canonical writer; UPDATE/DELETE forbidden by RLS. Bound to fn_audit_trigger. body_en/body_ar are sensitive.';
COMMENT ON COLUMN contract_version.diff_summary IS 'Free-text plain-language summary in M1a. AI-generated path is M4.';
COMMENT ON COLUMN contract_version.body_en IS 'SENSITIVE — pino + fn_audit_trigger redacted (after migration 004).';
COMMENT ON COLUMN contract_version.body_ar IS 'SENSITIVE — pino + fn_audit_trigger redacted (after migration 004).';

CREATE INDEX idx_contract_version_contract_id    ON contract_version(contract_id);
CREATE INDEX idx_contract_version_active         ON contract_version(id) WHERE is_active = true;
CREATE INDEX idx_contract_version_changed_by     ON contract_version(changed_by) WHERE changed_by IS NOT NULL;
CREATE INDEX idx_contract_version_created_by     ON contract_version(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_contract_version_contract_vnum  ON contract_version(contract_id, version_number DESC);

-- 1.4 contract_activity — append-only timeline (NO updated_at, NO audit-trigger binding)
CREATE TABLE contract_activity (
  id              BIGSERIAL PRIMARY KEY,
  contract_id     BIGINT       NOT NULL REFERENCES contract(id) ON DELETE CASCADE,
  activity_type   VARCHAR(50)  NOT NULL
                    CHECK (activity_type IN ('created','updated','status_changed','version_created','tagged','soft_deleted','restored')),
  actor_id        BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  description_en  VARCHAR(1000),
  description_ar  VARCHAR(1000),
  metadata        JSONB,

  created_at      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  is_active       BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE contract_activity IS 'Append-only contract activity timeline. NEVER bound to fn_audit_trigger (it IS the activity-style audit; double-binding amplifies audit_log volume — Agent 3 ND-2). Only fn_contract_activity_create (SECURITY DEFINER, invoked from triggers) may INSERT; UPDATE/DELETE/direct-INSERT denied by RLS. Future activity_type values (approval_decided M2, signed M3, etc.) MUST be added to the CHECK by their owning module via ALTER TABLE … DROP/ADD CONSTRAINT.';
COMMENT ON COLUMN contract_activity.metadata IS 'Free-form structured data per activity_type. Examples: status_changed → { fromStatus, toStatus, reason }; version_created → { versionNumber }; tagged → { added: [], removed: [] }. Body content is FORBIDDEN here — sensitive-body changes record only fieldsChanged.';

CREATE INDEX idx_contract_activity_contract_id          ON contract_activity(contract_id);
CREATE INDEX idx_contract_activity_active               ON contract_activity(id) WHERE is_active = true;
CREATE INDEX idx_contract_activity_actor_id             ON contract_activity(actor_id) WHERE actor_id IS NOT NULL;
CREATE INDEX idx_contract_activity_created_at_desc      ON contract_activity(contract_id, created_at DESC);
CREATE INDEX idx_contract_activity_type                 ON contract_activity(activity_type);

-- ============================================================
-- 2. Audit-trigger bindings (NOT on contract_activity — W3 / Agent 3 ND-2)
-- ============================================================

DROP TRIGGER IF EXISTS audit_contract_changes ON contract;
CREATE TRIGGER audit_contract_changes
  AFTER INSERT OR UPDATE OR DELETE ON contract
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

DROP TRIGGER IF EXISTS audit_contract_version_changes ON contract_version;
CREATE TRIGGER audit_contract_version_changes
  AFTER INSERT OR UPDATE OR DELETE ON contract_version
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

DROP TRIGGER IF EXISTS audit_contract_tag_changes ON contract_tag;
CREATE TRIGGER audit_contract_tag_changes
  AFTER INSERT OR UPDATE OR DELETE ON contract_tag
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();
-- INTENTIONALLY: NO audit_contract_activity_changes binding. (W3 / Agent 3 ND-2)

-- ============================================================
-- 3. Enable RLS + Policies
-- ============================================================

ALTER TABLE contract           ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_tag       ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_version   ENABLE ROW LEVEL SECURITY;
ALTER TABLE contract_activity  ENABLE ROW LEVEL SECURITY;

-- 3.1 contract policies (5)
-- AC-S1-02 / AC-S2-03 / AC-S7-04 — composite SELECT
CREATE POLICY contract_select_role_aware ON contract
  FOR SELECT
  USING (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
          INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin', 'legal_counsel', 'executive', 'Super Admin')
      )
      OR drafted_by  = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
      OR reviewed_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
      OR approved_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
      OR created_by  = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
    )
  );

-- AC-S3-10 — INSERT gated by contract.draft permission and role membership
CREATE POLICY contract_insert_drafter_or_admin ON contract
  FOR INSERT
  WITH CHECK (
    fn_current_user_has_permission('contract.draft')
    AND EXISTS (
      SELECT 1 FROM "user" u
        INNER JOIN role r ON r.id = u.role_id
        WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
          AND r.name IN ('platform_admin', 'legal_counsel', 'contract_drafter', 'Super Admin')
    )
  );

-- AC-S4-08 — UPDATE gated by role + ownership + status guard, EXCEPT the is_active flip
CREATE POLICY contract_update_owner_or_admin ON contract
  FOR UPDATE
  USING (
    is_active = TRUE
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
          INNER JOIN role r ON r.id = u.role_id
          WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
            AND r.name IN ('platform_admin', 'legal_counsel', 'Super Admin')
      )
      OR (
        EXISTS (
          SELECT 1 FROM "user" u
            INNER JOIN role r ON r.id = u.role_id
            WHERE u.id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
              AND r.name = 'contract_drafter'
        )
        AND drafted_by = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT
        AND status IN ('draft', 'resubmission_requested')
      )
    )
  )
  WITH CHECK (TRUE);

-- Codex G2 TOCTOU defense — companion to fn_contract_delete
CREATE POLICY contract_deny_direct_is_active_update ON contract
  AS RESTRICTIVE
  FOR UPDATE
  USING (TRUE)
  WITH CHECK (
    coalesce(current_setting('app.fn_contract_delete', true), '') = 'true'
    OR
    is_active = (SELECT c.is_active FROM contract c WHERE c.id = contract.id)
  );

-- AC-S5-05 — direct DELETE forbidden (only fn_contract_delete soft-deletes)
CREATE POLICY contract_deny_direct_delete ON contract
  AS RESTRICTIVE
  FOR DELETE
  USING (FALSE);

-- 3.2 contract_tag policies (3)
CREATE POLICY contract_tag_select_parent_aware ON contract_tag
  FOR SELECT
  USING (
    is_active = TRUE
    AND EXISTS (SELECT 1 FROM contract c WHERE c.id = contract_tag.contract_id)
  );

CREATE POLICY contract_tag_insert_parent_writable ON contract_tag
  FOR INSERT
  WITH CHECK (
    fn_current_user_has_permission('contract.tag.manage')
    AND EXISTS (SELECT 1 FROM contract c WHERE c.id = contract_tag.contract_id AND c.is_active = TRUE)
  );

CREATE POLICY contract_tag_update_parent_writable ON contract_tag
  FOR UPDATE
  USING (
    fn_current_user_has_permission('contract.tag.manage')
    AND EXISTS (SELECT 1 FROM contract c WHERE c.id = contract_tag.contract_id AND c.is_active = TRUE)
  )
  WITH CHECK (TRUE);
-- DELETE on contract_tag is implicit-deny (no policy created)

-- 3.3 contract_version policies (2)
CREATE POLICY contract_version_select_parent_aware ON contract_version
  FOR SELECT
  USING (
    is_active = TRUE
    AND EXISTS (SELECT 1 FROM contract c WHERE c.id = contract_version.contract_id)
  );

CREATE POLICY contract_version_insert_edit ON contract_version
  FOR INSERT
  WITH CHECK (
    fn_current_user_has_permission('contract.edit')
    AND EXISTS (SELECT 1 FROM contract c WHERE c.id = contract_version.contract_id AND c.is_active = TRUE)
  );
-- UPDATE / DELETE on contract_version are implicit-deny

-- 3.4 contract_activity policies (2)
CREATE POLICY contract_activity_select_parent_aware ON contract_activity
  FOR SELECT
  USING (
    is_active = TRUE
    AND EXISTS (SELECT 1 FROM contract c WHERE c.id = contract_activity.contract_id)
  );

-- INSERT direct via app role is forbidden — fn_contract_activity_create is SECURITY DEFINER and bypasses RLS.
CREATE POLICY contract_activity_deny_direct_insert ON contract_activity
  AS RESTRICTIVE
  FOR INSERT
  WITH CHECK (FALSE);
-- UPDATE / DELETE on contract_activity are implicit-deny

-- ============================================================
-- 4. Cross-module seed inserts (CMSW-1, CMSW-2, CMSW-3)
-- ============================================================

-- CMSW-1 — 7 new role rows
INSERT INTO role (name, description, created_by) VALUES
  ('platform_admin',     'Platform Admin / مسؤول المنصة — system-scope contracts admin (M1a). Coexists with M0 Super Admin pending consolidation.', NULL),
  ('legal_counsel',      'Legal Counsel / مستشار قانوني — read-all + edit/export/tag/status across contracts.',                           NULL),
  ('contract_drafter',   'Contract Drafter / محرر العقد — department-scope drafting + edit-own-while-draft.',                              NULL),
  ('contract_approver',  'Contract Approver / معتمد العقد — department-scope read for approval queue (M2 will refine).',                 NULL),
  ('contract_approver_2','Contract Approver Stage 2 / معتمد العقد المرحلة 2 — second-stage approval read scope.',                          NULL),
  ('contract_recipient', 'Contract Recipient / مستلم العقد — own-scope read (placeholder for party-membership; refined by Parties module).', NULL),
  ('executive',          'Executive / تنفيذي — read-all access to contracts.',                                                            NULL)
ON CONFLICT (name) DO NOTHING;

-- CMSW-2 — 9 new permission rows
INSERT INTO permission (code, module, action, description) VALUES
  ('contract.read.all',         'contract', 'read.all',          'Read all contracts across the organisation regardless of ownership.'),
  ('contract.read.department',  'contract', 'read.department',   'Read contracts within own department.'),
  ('contract.read.own',         'contract', 'read.own',          'Read only contracts the caller is a party to or drafted.'),
  ('contract.draft',            'contract', 'draft',             'Create new contract drafts.'),
  ('contract.edit',             'contract', 'edit',              'Update contract fields and create new versions.'),
  ('contract.delete',           'contract', 'delete',            'Soft-delete contracts (system-scope only).'),
  ('contract.export',           'contract', 'export',            'Export contracts to PDF/XLSX. Required by M1b but defined in M1a so role seeds reference it.'),
  ('contract.tag.manage',       'contract', 'tag.manage',        'Add/remove tags on contracts.'),
  ('contract.status.update',    'contract', 'status.update',     'Change contract status (placeholder transitions only — replaced by approval engine in M2).')
ON CONFLICT (code) DO NOTHING;

-- CMSW-3 — 20 role-permission grants
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
  FROM (VALUES
    -- platform_admin (7)
    ('platform_admin',     'contract.read.all'),
    ('platform_admin',     'contract.draft'),
    ('platform_admin',     'contract.edit'),
    ('platform_admin',     'contract.delete'),
    ('platform_admin',     'contract.export'),
    ('platform_admin',     'contract.tag.manage'),
    ('platform_admin',     'contract.status.update'),
    -- legal_counsel (5)
    ('legal_counsel',      'contract.read.all'),
    ('legal_counsel',      'contract.edit'),
    ('legal_counsel',      'contract.export'),
    ('legal_counsel',      'contract.tag.manage'),
    ('legal_counsel',      'contract.status.update'),
    -- contract_drafter (4)
    ('contract_drafter',   'contract.read.department'),
    ('contract_drafter',   'contract.draft'),
    ('contract_drafter',   'contract.edit'),
    ('contract_drafter',   'contract.tag.manage'),
    -- contract_approver (1)
    ('contract_approver',  'contract.read.department'),
    -- contract_approver_2 (1)
    ('contract_approver_2','contract.read.department'),
    -- contract_recipient (1)
    ('contract_recipient', 'contract.read.own'),
    -- executive (1)
    ('executive',          'contract.read.all')
  ) AS grants(role_name, permission_code)
  INNER JOIN role       r ON r.name = grants.role_name
  INNER JOIN permission p ON p.code = grants.permission_code
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- ============================================================
-- 5. Record migration
-- ============================================================

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (3, 'm1a_contracts', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK — 003_m1a_contracts.sql
-- ============================================================================
-- ROLLBACK BEGIN
BEGIN;
  -- Drop policies
  DROP POLICY IF EXISTS contract_activity_deny_direct_insert ON contract_activity;
  DROP POLICY IF EXISTS contract_activity_select_parent_aware ON contract_activity;
  DROP POLICY IF EXISTS contract_version_insert_edit ON contract_version;
  DROP POLICY IF EXISTS contract_version_select_parent_aware ON contract_version;
  DROP POLICY IF EXISTS contract_tag_update_parent_writable ON contract_tag;
  DROP POLICY IF EXISTS contract_tag_insert_parent_writable ON contract_tag;
  DROP POLICY IF EXISTS contract_tag_select_parent_aware ON contract_tag;
  DROP POLICY IF EXISTS contract_deny_direct_delete ON contract;
  DROP POLICY IF EXISTS contract_deny_direct_is_active_update ON contract;
  DROP POLICY IF EXISTS contract_update_owner_or_admin ON contract;
  DROP POLICY IF EXISTS contract_insert_drafter_or_admin ON contract;
  DROP POLICY IF EXISTS contract_select_role_aware ON contract;
  -- Drop triggers
  DROP TRIGGER IF EXISTS audit_contract_tag_changes ON contract_tag;
  DROP TRIGGER IF EXISTS audit_contract_version_changes ON contract_version;
  DROP TRIGGER IF EXISTS audit_contract_changes ON contract;
  -- Drop tables (cascade to indexes)
  DROP TABLE IF EXISTS contract_activity CASCADE;
  DROP TABLE IF EXISTS contract_version CASCADE;
  DROP TABLE IF EXISTS contract_tag CASCADE;
  DROP TABLE IF EXISTS contract CASCADE;
  -- Roll back the seed inserts
  DELETE FROM role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code LIKE 'contract.%');
  DELETE FROM permission WHERE code LIKE 'contract.%';
  DELETE FROM role WHERE name IN ('platform_admin','legal_counsel','contract_drafter','contract_approver','contract_approver_2','contract_recipient','executive');
  -- Drop migration row
  DELETE FROM schema_migrations WHERE version = 3;
COMMIT;
-- ROLLBACK END
