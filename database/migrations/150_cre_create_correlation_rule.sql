-- Migration: 150_cre_create_correlation_rule.sql
-- Module: M13 / CR-E — Correlation Rule Engine
-- Description: CREATE TABLE correlation_rule + FORCE RLS + 3 policies + audit trigger + COMMENTs + 4 indexes.
--   DB-backed rule registry per SOT §4.2. Tenant-scoped. match_yaml + produce_yaml stored as TEXT.
--   version_hash SHA-256 computed at INSERT/UPDATE time by fn_rule_create / fn_rule_update.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE correlation_rule (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  rule_id                  TEXT NOT NULL,
  name                     TEXT NOT NULL,
  name_ar                  TEXT NOT NULL,
  scenario                 TEXT,
  enabled                  BOOLEAN NOT NULL DEFAULT TRUE,
  meta                     JSONB NOT NULL DEFAULT '{}'::jsonb,
  match_yaml               TEXT NOT NULL,
  produce_yaml             TEXT NOT NULL,
  version_hash             TEXT NOT NULL,
  last_reviewed_by         BIGINT REFERENCES "user"(id),
  last_reviewed_at         TIMESTAMPTZ,
  data_classification      TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),

  -- Standard 6 audit columns
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by               BIGINT REFERENCES "user"(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT correlation_rule_tenant_rule_id_unique UNIQUE (tenant_id, rule_id)
);

COMMENT ON TABLE correlation_rule IS 'DB-backed correlation rule registry per SOT §4.2. Stores Annex C YAML bodies + SHA-256 version_hash. Tenant-scoped — same rule_id allowed across tenants. Edits via /app/admin/rules emit PG NOTIFY correlation_rule_changed for in-memory cache hot-reload.';
COMMENT ON COLUMN correlation_rule.rule_id IS 'Stable dotted-snake identifier e.g. rule.sanctions.direct_counterparty per Annex C.3. UNIQUE per tenant.';
COMMENT ON COLUMN correlation_rule.match_yaml IS 'YAML body of the match block per Annex C.4 (~30 predicate primitives + joins + disjunction/negation). SENSITIVE — may contain counterparty names / source_ids. Redacted from audit logs.';
COMMENT ON COLUMN correlation_rule.produce_yaml IS 'YAML body of the produce block per Annex C.5 (correlation + alert + advisory output). SENSITIVE — may contain template variables referencing counterparty fields. Redacted from audit logs.';
COMMENT ON COLUMN correlation_rule.version_hash IS 'SHA-256 of canonical YAML (sorted-key serialization of {match, produce, meta}). Recomputed on every save by fn_rule_create / fn_rule_update. Snapshot copied to correlation.rule_version_hash at firing time for retroactive audit per AC-S15-03.';
COMMENT ON COLUMN correlation_rule.scenario IS 'Scenario tag: hormuz | sanctions | brent | epc_sla | renewal | weather_fm | icv | esg. No DB CHECK — future scenarios additive.';
COMMENT ON COLUMN correlation_rule.meta IS 'Rule metadata JSONB: { owner, lastReviewedAt, rationale, evaluationTimeoutSecondsOverride }.';

-- 4 indexes
CREATE INDEX idx_correlation_rule_tenant_enabled ON correlation_rule(tenant_id, enabled) WHERE is_active = TRUE;
CREATE INDEX idx_correlation_rule_tenant_scenario ON correlation_rule(tenant_id, scenario) WHERE is_active = TRUE;
CREATE INDEX idx_correlation_rule_active ON correlation_rule(id) WHERE is_active = TRUE;
CREATE INDEX idx_correlation_rule_last_reviewed ON correlation_rule(tenant_id, last_reviewed_at DESC NULLS LAST) WHERE is_active = TRUE;

-- FORCE RLS + 3 policies
ALTER TABLE correlation_rule ENABLE ROW LEVEL SECURITY;
ALTER TABLE correlation_rule FORCE ROW LEVEL SECURITY;

CREATE POLICY correlation_rule_tenant_select ON correlation_rule
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY correlation_rule_tenant_modify ON correlation_rule
  FOR ALL USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  ) WITH CHECK (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY correlation_rule_deny_direct_delete ON correlation_rule
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger
CREATE TRIGGER audit_correlation_rule_changes
  AFTER INSERT OR UPDATE OR DELETE ON correlation_rule
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (150, '150_cre_create_correlation_rule', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 150;
-- DROP TRIGGER IF EXISTS audit_correlation_rule_changes ON correlation_rule;
-- DROP TABLE IF EXISTS correlation_rule;
-- ============================================================
