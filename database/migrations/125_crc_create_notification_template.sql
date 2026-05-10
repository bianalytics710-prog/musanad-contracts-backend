-- ============================================================
-- Migration 125 — CRC create_notification_template
-- ============================================================
-- Module:      M10 — CR-C
-- Description: CREATE notification_template + 6 indexes + FORCE RLS + 3 policies
--              + audit trigger via standard fn_audit_trigger() (BIGSERIAL id
--              compatible — agentNote A9). data_classification column included
--              at CREATE-time (NOT re-altered in 127 per AC-S5-01).
-- Decisions:   UNIQUE(tenant_id, template_id). channel CHECK 4-enum.
--              FK on_delete RESTRICT for tenant_id.
-- ============================================================

BEGIN;

-- 1. CREATE TABLE
CREATE TABLE IF NOT EXISTS notification_template (
  id                  BIGSERIAL    PRIMARY KEY,
  tenant_id           UUID         NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  template_id         TEXT         NOT NULL,
  channel             TEXT         NOT NULL
                      CHECK (channel IN ('email','in_app','teams_capture','slack_capture')),
  subject_en          TEXT,
  subject_ar          TEXT,
  body_en             TEXT         NOT NULL,
  body_ar             TEXT         NOT NULL,
  parameter_schema    JSONB        NOT NULL DEFAULT '{}'::jsonb,
  last_modified_by    BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  data_classification TEXT         NOT NULL DEFAULT 'demo'
                      CHECK (data_classification IN ('demo','pilot','production')),
  created_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by          BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN      NOT NULL DEFAULT TRUE,
  CONSTRAINT notification_template_tenant_template_unique UNIQUE (tenant_id, template_id)
);

-- 2. Indexes (FK + soft-delete + filter+search patterns)
CREATE INDEX IF NOT EXISTS idx_notification_template_tenant
  ON notification_template(tenant_id);                                   -- FK
CREATE INDEX IF NOT EXISTS idx_notification_template_last_modified_by
  ON notification_template(last_modified_by);                            -- FK
CREATE INDEX IF NOT EXISTS idx_notification_template_active
  ON notification_template(id) WHERE is_active = TRUE;                   -- soft-delete partial
CREATE INDEX IF NOT EXISTS idx_notification_template_channel
  ON notification_template(tenant_id, channel) WHERE is_active = TRUE;   -- list filter
CREATE INDEX IF NOT EXISTS idx_notification_template_template_id
  ON notification_template(tenant_id, template_id) WHERE is_active = TRUE; -- render lookup
CREATE INDEX IF NOT EXISTS idx_notification_template_data_class
  ON notification_template(data_classification) WHERE is_active = TRUE;  -- demo purge scan

-- 3. RLS — FORCE + 3 policies (tenant SELECT, tenant ALL gated by perm, deny direct DELETE)
ALTER TABLE notification_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_template FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notification_template_tenant_select ON notification_template;
CREATE POLICY notification_template_tenant_select ON notification_template
  FOR SELECT
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
  );

DROP POLICY IF EXISTS notification_template_tenant_modify ON notification_template;
CREATE POLICY notification_template_tenant_modify ON notification_template
  FOR ALL
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('notification.template.manage')
  )
  WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('notification.template.manage')
  );

DROP POLICY IF EXISTS notification_template_deny_delete ON notification_template;
CREATE POLICY notification_template_deny_delete ON notification_template
  AS RESTRICTIVE
  FOR DELETE
  USING (false);

-- 4. Audit trigger (standard fn_audit_trigger; BIGSERIAL id compatible — agentNote A9)
DROP TRIGGER IF EXISTS audit_notification_template_changes ON notification_template;
CREATE TRIGGER audit_notification_template_changes
  AFTER INSERT OR UPDATE OR DELETE ON notification_template
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- 5. COMMENT ONs (Stage 2 standards)
COMMENT ON TABLE notification_template IS
  'CR-C bilingual transactional message template. Tenant-scoped (UNIQUE per tenant_id+template_id). channel = email / in_app / teams_capture / slack_capture. Render via fn_notification_template_render with Mustache {{paramName}} substitution. Audit trigger fires through fn_audit_log_record_v2 hash chain (post-128).';
COMMENT ON COLUMN notification_template.template_id IS
  'Stable code-side identifier (e.g. signature.invitation.email). Code references this string, not the BIGSERIAL id. Immutable after create per AC-S12-05.';
COMMENT ON COLUMN notification_template.channel IS
  'Delivery channel. CHECK enum: email / in_app / teams_capture / slack_capture. teams_capture + slack_capture deferred to CR-H.';
COMMENT ON COLUMN notification_template.parameter_schema IS
  'JSONB object declaring placeholder names + types: {"signerName":"string","contractTitle":"string"}. Used by fn_notification_template_render to populate missingParameters[]. Must be a JSON object (not array, not scalar) — enforced by fn_notification_template_update.';
COMMENT ON COLUMN notification_template.data_classification IS
  'demo / pilot / production. Default ''demo''. Demo rows purged by fn_demo_data_purge. Column included at CREATE-time (NOT re-altered by 127).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (125, 'crc_create_notification_template', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_notification_template_changes ON notification_template;
-- DROP POLICY  IF EXISTS notification_template_deny_delete   ON notification_template;
-- DROP POLICY  IF EXISTS notification_template_tenant_modify ON notification_template;
-- DROP POLICY  IF EXISTS notification_template_tenant_select ON notification_template;
-- DROP TABLE   IF EXISTS notification_template;
-- DELETE FROM schema_migrations WHERE version = 125;
-- COMMIT;
-- ROLLBACK END
