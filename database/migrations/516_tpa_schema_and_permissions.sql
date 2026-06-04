-- MIGRATION: 516_tpa_schema_and_permissions.sql
-- Feature: Third-Party Agreement Assessment (TPA)
-- Date: 2026-06-03
-- Description:
--   Legal Counsel uploads a counterparty agreement (NDA, MSA, supply, service,
--   etc.). System extracts clauses via gpt-4o, compares each against the
--   ADNOC playbook for that agreement type, and produces per-clause findings
--   classified as accept / amend / reject. Legal can then export a redlined
--   DOCX to send back to the counterparty.
--
--   Schema (5 tables):
--     tpa_playbook            — header (ADNOC NDA / MSA / supply playbook etc.)
--     tpa_playbook_clause     — per-clause standard + fallback + non-negotiable
--     tpa_review              — uploaded doc header + overall verdict
--     tpa_review_finding      — per-clause finding (verdict + suggested redline)
--     tpa_review_document     — file storage refs (original + redlined)
--
--   Permissions:
--     tpa.review.read    — view own reviews
--     tpa.review.create  — upload + analyse
--     tpa.review.amend   — override AI verdict, edit redline, mark exported
--     tpa.playbook.manage — admin: maintain playbook clauses
--
--   Roles granted:
--     legal_counsel       — read + create + amend
--     platform_admin      — all four
--     Super Admin         — all four

BEGIN;

-- ============================================================
-- 1. tpa_playbook — playbook header (one per agreement type)
-- ============================================================
CREATE TABLE IF NOT EXISTS tpa_playbook (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  playbook_key      VARCHAR(60) NOT NULL,
  agreement_type    VARCHAR(40) NOT NULL CHECK (agreement_type IN (
    'nda', 'msa', 'supply', 'service', 'consultancy', 'epc', 'spa', 'other'
  )),
  name_en           VARCHAR(200) NOT NULL,
  name_ar           VARCHAR(200) NULL,
  description_en    TEXT NULL,
  version           INTEGER NOT NULL DEFAULT 1,
  status            VARCHAR(20) NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'draft', 'retired')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by        BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by        BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  UNIQUE (tenant_id, playbook_key)
);
CREATE INDEX IF NOT EXISTS ix_tpa_playbook_agreement_type
  ON tpa_playbook(tenant_id, agreement_type, status);

ALTER TABLE tpa_playbook ENABLE ROW LEVEL SECURITY;
ALTER TABLE tpa_playbook FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tpa_playbook_tenant_isolation ON tpa_playbook;
CREATE POLICY tpa_playbook_tenant_isolation ON tpa_playbook
  FOR ALL USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

DROP TRIGGER IF EXISTS audit_tpa_playbook_changes ON tpa_playbook;
CREATE TRIGGER audit_tpa_playbook_changes
  AFTER INSERT OR UPDATE OR DELETE ON tpa_playbook
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

COMMENT ON TABLE tpa_playbook IS
  'TPA — Third-Party Agreement playbook. One row per agreement type (NDA, MSA, etc.) that ADNOC accepts. tpa_playbook_clause rows hang off this with the per-clause standard wording + fallback + non-negotiables.';

-- ============================================================
-- 2. tpa_playbook_clause — per-clause standards
-- ============================================================
CREATE TABLE IF NOT EXISTS tpa_playbook_clause (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  playbook_id         BIGINT NOT NULL REFERENCES tpa_playbook(id) ON DELETE CASCADE,
  clause_key          VARCHAR(80) NOT NULL,
  clause_title_en     VARCHAR(200) NOT NULL,
  clause_title_ar     VARCHAR(200) NULL,
  criticality         VARCHAR(20) NOT NULL DEFAULT 'medium'
                      CHECK (criticality IN ('non_negotiable', 'high', 'medium', 'low')),
  display_order       INTEGER NOT NULL DEFAULT 100,
  standard_position   TEXT NOT NULL,
  fallback_position   TEXT NULL,
  non_negotiables     TEXT[] NOT NULL DEFAULT '{}',
  red_flags           TEXT[] NOT NULL DEFAULT '{}',
  guidance_notes      TEXT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by          BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,
  UNIQUE (playbook_id, clause_key)
);
CREATE INDEX IF NOT EXISTS ix_tpa_playbook_clause_lookup
  ON tpa_playbook_clause(tenant_id, playbook_id, is_active);

ALTER TABLE tpa_playbook_clause ENABLE ROW LEVEL SECURITY;
ALTER TABLE tpa_playbook_clause FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tpa_playbook_clause_tenant_isolation ON tpa_playbook_clause;
CREATE POLICY tpa_playbook_clause_tenant_isolation ON tpa_playbook_clause
  FOR ALL USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

DROP TRIGGER IF EXISTS audit_tpa_playbook_clause_changes ON tpa_playbook_clause;
CREATE TRIGGER audit_tpa_playbook_clause_changes
  AFTER INSERT OR UPDATE OR DELETE ON tpa_playbook_clause
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

COMMENT ON TABLE tpa_playbook_clause IS
  'TPA — per-clause playbook entries. standard_position is the ideal ADNOC wording, fallback_position is what we will accept if pushed, non_negotiables are dealbreakers (e.g. "indefinite confidentiality term", "foreign jurisdiction"), red_flags are common counterparty asks to watch for.';

-- ============================================================
-- 3. tpa_review — uploaded doc header
-- ============================================================
CREATE TABLE IF NOT EXISTS tpa_review (
  id                    BIGSERIAL PRIMARY KEY,
  tenant_id             UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  playbook_id           BIGINT NOT NULL REFERENCES tpa_playbook(id) ON DELETE RESTRICT,
  reference_code        VARCHAR(40) NOT NULL,
  counterparty_name     VARCHAR(200) NOT NULL,
  counterparty_email    VARCHAR(200) NULL,
  agreement_title       VARCHAR(300) NOT NULL,
  agreement_type        VARCHAR(40) NOT NULL,
  status                VARCHAR(20) NOT NULL DEFAULT 'pending_analysis'
                        CHECK (status IN (
                          'pending_analysis', 'analyzing', 'awaiting_review',
                          'reviewed', 'redline_sent', 'closed_accepted',
                          'closed_rejected', 'failed'
                        )),
  overall_verdict       VARCHAR(20) NULL
                        CHECK (overall_verdict IN ('accept', 'amend', 'reject') OR overall_verdict IS NULL),
  overall_risk          VARCHAR(20) NULL
                        CHECK (overall_risk IN ('low', 'medium', 'high', 'critical') OR overall_risk IS NULL),
  risk_score            INTEGER NULL CHECK (risk_score IS NULL OR (risk_score BETWEEN 0 AND 100)),
  conflict_count        INTEGER NOT NULL DEFAULT 0,
  amend_count           INTEGER NOT NULL DEFAULT 0,
  reject_count          INTEGER NOT NULL DEFAULT 0,
  accept_count          INTEGER NOT NULL DEFAULT 0,
  executive_summary     TEXT NULL,
  llm_model_version     VARCHAR(80) NULL,
  llm_prompt_hash       VARCHAR(80) NULL,
  llm_analysed_at       TIMESTAMPTZ NULL,
  llm_error             TEXT NULL,
  notes                 TEXT NULL,
  data_classification   VARCHAR(20) NOT NULL DEFAULT 'production'
                        CHECK (data_classification IN ('demo', 'pilot', 'production')),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by            BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by            BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  is_active             BOOLEAN NOT NULL DEFAULT TRUE,
  UNIQUE (tenant_id, reference_code)
);
CREATE INDEX IF NOT EXISTS ix_tpa_review_status_created
  ON tpa_review(tenant_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_tpa_review_counterparty
  ON tpa_review(tenant_id, counterparty_name);

ALTER TABLE tpa_review ENABLE ROW LEVEL SECURITY;
ALTER TABLE tpa_review FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tpa_review_tenant_isolation ON tpa_review;
CREATE POLICY tpa_review_tenant_isolation ON tpa_review
  FOR ALL USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

DROP TRIGGER IF EXISTS audit_tpa_review_changes ON tpa_review;
CREATE TRIGGER audit_tpa_review_changes
  AFTER INSERT OR UPDATE OR DELETE ON tpa_review
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

COMMENT ON TABLE tpa_review IS
  'TPA — header per uploaded third-party agreement. Status progresses pending_analysis -> analyzing -> awaiting_review -> reviewed -> redline_sent -> closed_*. Counters (accept/amend/reject) and overall_verdict are populated by the analyzer after gpt-4o classification.';

-- ============================================================
-- 4. tpa_review_finding — per-clause findings
-- ============================================================
CREATE TABLE IF NOT EXISTS tpa_review_finding (
  id                  BIGSERIAL PRIMARY KEY,
  tenant_id           UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  review_id           BIGINT NOT NULL REFERENCES tpa_review(id) ON DELETE CASCADE,
  playbook_clause_id  BIGINT NULL REFERENCES tpa_playbook_clause(id) ON DELETE SET NULL,
  clause_key          VARCHAR(80) NULL,
  clause_title        VARCHAR(200) NOT NULL,
  display_order       INTEGER NOT NULL DEFAULT 100,
  extracted_text      TEXT NULL,
  extracted_location  VARCHAR(80) NULL,
  ai_verdict          VARCHAR(20) NOT NULL
                      CHECK (ai_verdict IN ('accept', 'amend', 'reject', 'missing', 'info')),
  ai_rationale        TEXT NULL,
  ai_severity         VARCHAR(20) NULL
                      CHECK (ai_severity IN ('low', 'medium', 'high', 'critical') OR ai_severity IS NULL),
  ai_suggested_redline TEXT NULL,
  ai_conflicts_with   TEXT[] NOT NULL DEFAULT '{}',
  user_verdict        VARCHAR(20) NULL
                      CHECK (user_verdict IN ('accept', 'amend', 'reject', 'missing', 'info') OR user_verdict IS NULL),
  user_redline        TEXT NULL,
  user_notes          TEXT NULL,
  resolution_status   VARCHAR(20) NOT NULL DEFAULT 'open'
                      CHECK (resolution_status IN ('open', 'accepted_ai', 'amended_by_user', 'dismissed', 'escalated')),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by          BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE INDEX IF NOT EXISTS ix_tpa_review_finding_lookup
  ON tpa_review_finding(tenant_id, review_id, display_order);

ALTER TABLE tpa_review_finding ENABLE ROW LEVEL SECURITY;
ALTER TABLE tpa_review_finding FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tpa_review_finding_tenant_isolation ON tpa_review_finding;
CREATE POLICY tpa_review_finding_tenant_isolation ON tpa_review_finding
  FOR ALL USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

DROP TRIGGER IF EXISTS audit_tpa_review_finding_changes ON tpa_review_finding;
CREATE TRIGGER audit_tpa_review_finding_changes
  AFTER INSERT OR UPDATE OR DELETE ON tpa_review_finding
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

COMMENT ON TABLE tpa_review_finding IS
  'TPA — per-clause finding. ai_verdict is the LLM call (accept/amend/reject/missing/info). user_verdict overrides ai when Layla disagrees; user_redline overrides ai_suggested_redline for the final exported DOCX.';

-- ============================================================
-- 5. tpa_review_document — file storage refs
-- ============================================================
CREATE TABLE IF NOT EXISTS tpa_review_document (
  id                BIGSERIAL PRIMARY KEY,
  tenant_id         UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  review_id         BIGINT NOT NULL REFERENCES tpa_review(id) ON DELETE CASCADE,
  document_kind     VARCHAR(30) NOT NULL CHECK (document_kind IN (
    'original_upload', 'extracted_text', 'redline_docx', 'final_signed'
  )),
  file_name         VARCHAR(255) NOT NULL,
  mime_type         VARCHAR(120) NOT NULL,
  size_bytes        INTEGER NOT NULL CHECK (size_bytes > 0),
  storage_uri       TEXT NOT NULL,
  storage_bucket    VARCHAR(80) NOT NULL DEFAULT 'contract-attachments',
  page_count        INTEGER NULL,
  extraction_engine VARCHAR(40) NULL,
  sha256_hex        VARCHAR(64) NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by        BIGINT NULL REFERENCES "user"(id) ON DELETE SET NULL,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE INDEX IF NOT EXISTS ix_tpa_review_document_lookup
  ON tpa_review_document(tenant_id, review_id, document_kind, created_at DESC);

ALTER TABLE tpa_review_document ENABLE ROW LEVEL SECURITY;
ALTER TABLE tpa_review_document FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tpa_review_document_tenant_isolation ON tpa_review_document;
CREATE POLICY tpa_review_document_tenant_isolation ON tpa_review_document
  FOR ALL USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

DROP TRIGGER IF EXISTS audit_tpa_review_document_changes ON tpa_review_document;
CREATE TRIGGER audit_tpa_review_document_changes
  AFTER INSERT OR UPDATE OR DELETE ON tpa_review_document
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

COMMENT ON TABLE tpa_review_document IS
  'TPA — file storage refs (original counterparty upload + extracted text + generated redline DOCX). storage_uri is the Supabase Storage path.';

-- ============================================================
-- 6. Permissions + role grants
-- ============================================================
INSERT INTO permission (code, module, action, description, is_active, created_at)
VALUES
  ('tpa.review.read',     'tpa', 'read',
   'View third-party agreement reviews and per-clause findings.', TRUE, NOW()),
  ('tpa.review.create',   'tpa', 'create',
   'Upload a counterparty agreement and trigger AI analysis.',     TRUE, NOW()),
  ('tpa.review.amend',    'tpa', 'amend',
   'Override AI verdicts, edit redline wording, mark a review as sent/closed.', TRUE, NOW()),
  ('tpa.playbook.manage', 'tpa', 'manage',
   'Maintain TPA playbook entries (clause standards, fallbacks, non-negotiables).', TRUE, NOW())
ON CONFLICT (code) DO NOTHING;

-- legal_counsel — read + create + amend
INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r CROSS JOIN permission p
WHERE r.name = 'legal_counsel'
  AND p.code IN ('tpa.review.read', 'tpa.review.create', 'tpa.review.amend')
ON CONFLICT DO NOTHING;

-- platform_admin + Super Admin — all four
INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r CROSS JOIN permission p
WHERE r.name IN ('platform_admin', 'Super Admin')
  AND p.code IN ('tpa.review.read', 'tpa.review.create', 'tpa.review.amend', 'tpa.playbook.manage')
ON CONFLICT DO NOTHING;

-- ============================================================
-- 7. Product module entry (for CR-W / CR-V feature toggle)
-- ============================================================
INSERT INTO product_module (
  key, bundle_code, label_key, sidebar_path,
  owned_route_prefixes, owned_permission_prefixes, default_role_codes,
  default_enabled, is_core, display_order, is_active, created_at, updated_at
)
VALUES (
  'tpa_review',
  'ecip',
  'nav.tpaReview',
  '/app/legal/third-party-review',
  '["/api/v1/tpa/"]'::jsonb,
  '["tpa."]'::jsonb,
  '["legal_counsel","platform_admin","Super Admin"]'::jsonb,
  TRUE, FALSE, 358, TRUE, NOW(), NOW()
)
ON CONFLICT (key) DO UPDATE SET
  bundle_code               = EXCLUDED.bundle_code,
  label_key                 = EXCLUDED.label_key,
  sidebar_path              = EXCLUDED.sidebar_path,
  owned_route_prefixes      = EXCLUDED.owned_route_prefixes,
  owned_permission_prefixes = EXCLUDED.owned_permission_prefixes,
  default_role_codes        = EXCLUDED.default_role_codes,
  default_enabled           = EXCLUDED.default_enabled,
  display_order             = EXCLUDED.display_order,
  updated_at                = NOW();

-- Enable for ADNOC singleton tenant
INSERT INTO product_module_enable (tenant_id, module_key, is_enabled, reason, created_at, updated_at)
VALUES (
  '00000000-0000-0000-0000-000000000001'::uuid, 'tpa_review', TRUE,
  'Initial enable on TPA feature launch (mig 516).', NOW(), NOW()
)
ON CONFLICT (tenant_id, module_key) DO UPDATE SET
  is_enabled = TRUE, updated_at = NOW();

-- ============================================================
-- 8. Schema migrations bookkeeping
-- ============================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (516, 'tpa_schema_and_permissions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
