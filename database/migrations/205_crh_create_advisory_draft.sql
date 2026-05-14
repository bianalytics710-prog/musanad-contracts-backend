-- MIGRATION: 205_crh_create_advisory_draft.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: CREATE advisory_draft table + 6 indexes + 3 RLS policies (FORCE RLS + RESTRICTIVE deny-DELETE + draft visibility) + audit trigger.
--              Annex D §D.6.6 conformant — 30 columns.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE IF NOT EXISTS advisory_draft (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  correlation_id           BIGINT NOT NULL REFERENCES correlation(id) ON DELETE RESTRICT,
  contract_id              BIGINT NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,
  template_id              BIGINT NOT NULL REFERENCES advisory_template(id) ON DELETE RESTRICT,
  template_version         INTEGER NOT NULL,
  draft_type               TEXT NOT NULL,
  generated_text_en        TEXT NOT NULL,
  generated_text_ar        TEXT NOT NULL,
  template_context         JSONB NOT NULL DEFAULT '{}'::jsonb,
  model_version            TEXT NOT NULL,
  prompt_hash              TEXT NOT NULL,
  response_hash            TEXT,
  approval_status          TEXT NOT NULL DEFAULT 'unapproved'
    CHECK (approval_status IN ('unapproved','approved','rejected','modified')),
  approved_by              BIGINT REFERENCES "user"(id),
  approved_at              TIMESTAMPTZ,
  final_text_en            TEXT,
  final_text_ar            TEXT,
  modified_text_en         TEXT,
  modified_text_ar         TEXT,
  rejection_reason         TEXT,
  dispatched_at            TIMESTAMPTZ,
  dispatch_channel         TEXT
    CHECK (dispatch_channel IS NULL OR dispatch_channel IN ('email','teams_capture','slack_capture','multi')),
  dispatch_recipients      JSONB NOT NULL DEFAULT '[]'::jsonb,
  data_classification      TEXT NOT NULL DEFAULT 'sensitive'
    CHECK (data_classification IN ('demo','pilot','production','sensitive')),
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id),
  updated_by               BIGINT REFERENCES "user"(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE advisory_draft IS
  'M16/CR-H. Persisted advisory draft lifecycle — unapproved → approved/rejected/modified → dispatched. Annex D §D.6.6 conformant. Soft-delete only. Sensitive text fields redacted in audit_log (migration 209).';

CREATE INDEX IF NOT EXISTS idx_advisory_draft_tenant_status
  ON advisory_draft(tenant_id, approval_status)
  WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_advisory_draft_correlation
  ON advisory_draft(correlation_id)
  WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_advisory_draft_contract
  ON advisory_draft(tenant_id, contract_id)
  WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_advisory_draft_template
  ON advisory_draft(template_id)
  WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_advisory_draft_approver_queue
  ON advisory_draft(tenant_id, approval_status, created_at DESC)
  WHERE is_active = TRUE AND approval_status = 'unapproved';

CREATE INDEX IF NOT EXISTS idx_advisory_draft_dispatched
  ON advisory_draft(tenant_id, dispatched_at DESC)
  WHERE dispatched_at IS NOT NULL AND is_active = TRUE;

-- RLS
ALTER TABLE advisory_draft ENABLE ROW LEVEL SECURITY;
ALTER TABLE advisory_draft FORCE ROW LEVEL SECURITY;

CREATE POLICY advisory_draft_tenant_select ON advisory_draft
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
    AND (
      EXISTS (
        SELECT 1 FROM "user" u
        JOIN role r ON r.id = u.role_id
        WHERE u.id = current_setting('app.current_user_id', true)::bigint
          AND r.name IN ('Super Admin', 'platform_admin', 'legal_counsel')
      )
      OR created_by = current_setting('app.current_user_id', true)::bigint
      OR approved_by = current_setting('app.current_user_id', true)::bigint
    )
  );

CREATE POLICY advisory_draft_tenant_modify ON advisory_draft
  FOR ALL USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::uuid);

CREATE POLICY advisory_draft_deny_direct_delete ON advisory_draft
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger (default — table has id BIGSERIAL PK per S2-28 strategy)
CREATE TRIGGER audit_advisory_draft_changes
  AFTER INSERT OR UPDATE OR DELETE ON advisory_draft
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (205, '205_crh_create_advisory_draft', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DROP TRIGGER IF EXISTS audit_advisory_draft_changes ON advisory_draft;
-- DROP POLICY IF EXISTS advisory_draft_deny_direct_delete ON advisory_draft;
-- DROP POLICY IF EXISTS advisory_draft_tenant_modify ON advisory_draft;
-- DROP POLICY IF EXISTS advisory_draft_tenant_select ON advisory_draft;
-- DROP INDEX IF EXISTS idx_advisory_draft_dispatched;
-- DROP INDEX IF EXISTS idx_advisory_draft_approver_queue;
-- DROP INDEX IF EXISTS idx_advisory_draft_template;
-- DROP INDEX IF EXISTS idx_advisory_draft_contract;
-- DROP INDEX IF EXISTS idx_advisory_draft_correlation;
-- DROP INDEX IF EXISTS idx_advisory_draft_tenant_status;
-- DROP TABLE IF EXISTS advisory_draft;
-- DELETE FROM schema_migrations WHERE version = 205;
-- ============================================================
