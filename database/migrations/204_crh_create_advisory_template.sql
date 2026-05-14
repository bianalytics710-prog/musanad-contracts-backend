-- MIGRATION: 204_crh_create_advisory_template.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: CREATE advisory_template table + 4 indexes + 3 RLS policies (FORCE RLS + RESTRICTIVE deny-DELETE) + audit trigger.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE IF NOT EXISTS advisory_template (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  template_id              TEXT NOT NULL,
  display_name_en          TEXT NOT NULL,
  display_name_ar          TEXT NOT NULL,
  description              TEXT,
  draft_type               TEXT NOT NULL
    CHECK (draft_type IN (
      'fm_invocation','cure_notice','sanctions_hold','price_review',
      'icv_rectification','insurance_renewal','esg_concern','custom'
    )),
  body_template_en         TEXT NOT NULL,
  body_template_ar         TEXT NOT NULL,
  parameter_schema         JSONB NOT NULL DEFAULT '{}'::jsonb,
  assigned_approver_role   TEXT NOT NULL,
  dispatch_channels        JSONB NOT NULL
    DEFAULT '["email","teams_capture","slack_capture"]'::jsonb,
  version                  INTEGER NOT NULL DEFAULT 1
    CHECK (version >= 1),
  last_modified_by         BIGINT REFERENCES "user"(id),
  data_classification      TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production','sensitive')),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id),
  updated_by               BIGINT REFERENCES "user"(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT advisory_template_uq UNIQUE (tenant_id, template_id)
);

COMMENT ON TABLE advisory_template IS
  'M16/CR-H. Parameterised Mustache advisory letter templates. Each template defines draft_type, body EN+AR, parameter_schema, assigned_approver_role, and dispatch_channels. Soft-delete only.';

CREATE INDEX IF NOT EXISTS idx_advisory_template_tenant_active
  ON advisory_template(tenant_id, is_active)
  WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_advisory_template_draft_type
  ON advisory_template(tenant_id, draft_type)
  WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_advisory_template_search_en
  ON advisory_template USING GIN (to_tsvector('simple', display_name_en))
  WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_advisory_template_search_ar
  ON advisory_template USING GIN (to_tsvector('simple', display_name_ar))
  WHERE is_active = TRUE;

-- RLS
ALTER TABLE advisory_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE advisory_template FORCE ROW LEVEL SECURITY;

CREATE POLICY advisory_template_tenant_select ON advisory_template
  FOR SELECT USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

CREATE POLICY advisory_template_tenant_modify ON advisory_template
  FOR ALL USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

CREATE POLICY advisory_template_deny_direct_delete ON advisory_template
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger (default — table has id BIGSERIAL PK, per S2-28 strategy)
CREATE TRIGGER audit_advisory_template_changes
  AFTER INSERT OR UPDATE OR DELETE ON advisory_template
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (204, '204_crh_create_advisory_template', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP TRIGGER IF EXISTS audit_advisory_template_changes ON advisory_template;
-- DROP POLICY IF EXISTS advisory_template_deny_direct_delete ON advisory_template;
-- DROP POLICY IF EXISTS advisory_template_tenant_modify ON advisory_template;
-- DROP POLICY IF EXISTS advisory_template_tenant_select ON advisory_template;
-- DROP INDEX IF EXISTS idx_advisory_template_search_ar;
-- DROP INDEX IF EXISTS idx_advisory_template_search_en;
-- DROP INDEX IF EXISTS idx_advisory_template_draft_type;
-- DROP INDEX IF EXISTS idx_advisory_template_tenant_active;
-- DROP TABLE IF EXISTS advisory_template;
-- DELETE FROM schema_migrations WHERE version = 204;
-- ============================================================
