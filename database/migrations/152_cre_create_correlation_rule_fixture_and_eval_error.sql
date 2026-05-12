-- Migration: 152_cre_create_correlation_rule_fixture_and_eval_error.sql
-- Module: M13 / CR-E — Correlation Rule Engine
-- Description: CREATE TABLE correlation_rule_fixture + CREATE TABLE correlation_evaluation_error (OD-2).
--   FORCE RLS + 3 policies on each + audit triggers + COMMENTs.
--   WARN-1 applied: correlation_evaluation_error includes data_classification column (Stage 2 check).
--   INFO-1 applied: per-column COMMENTs added to correlation_evaluation_error (Stage 2 check).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- -----------------------------------------------
-- Table 1: correlation_rule_fixture
-- -----------------------------------------------
CREATE TABLE correlation_rule_fixture (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  correlation_rule_id      BIGINT NOT NULL REFERENCES correlation_rule(id) ON DELETE CASCADE,
  fixture_id               TEXT NOT NULL,
  description              TEXT NOT NULL,
  given_signal             JSONB NOT NULL,
  given_contract_seed_set  TEXT,
  expected_match           BOOLEAN NOT NULL,
  expected_correlation     JSONB NOT NULL DEFAULT '{}'::jsonb,
  data_classification      TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),

  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by               BIGINT REFERENCES "user"(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT correlation_rule_fixture_rule_fixture_unique UNIQUE (correlation_rule_id, fixture_id)
);

COMMENT ON TABLE correlation_rule_fixture IS 'Per-rule test fixtures per Annex C.9. 14 seeded rows (7 rules × 1 positive + 1 negative). Used by /app/admin/rules/$id test-against-fixture panel + CI integration tests via fn_rule_test_against_fixture.';
COMMENT ON COLUMN correlation_rule_fixture.given_signal IS 'Signal payload per Annex C.9.1 — fields: source_id, kind, severity, confidence, title, geographies, affected_entities, raw_payload.';
COMMENT ON COLUMN correlation_rule_fixture.given_contract_seed_set IS 'Optional reference to Annex E §E.6 seed set names (e.g. hormuz_demo_seed). BE evaluator resolves to concrete contract IDs at test time.';
COMMENT ON COLUMN correlation_rule_fixture.expected_correlation IS 'Expected correlation output shape per the rule produce block. Diff target for fn_rule_test_against_fixture passed verdict.';

CREATE INDEX idx_correlation_rule_fixture_rule ON correlation_rule_fixture(correlation_rule_id) WHERE is_active = TRUE;
CREATE INDEX idx_correlation_rule_fixture_active ON correlation_rule_fixture(id) WHERE is_active = TRUE;

ALTER TABLE correlation_rule_fixture ENABLE ROW LEVEL SECURITY;
ALTER TABLE correlation_rule_fixture FORCE ROW LEVEL SECURITY;

CREATE POLICY correlation_rule_fixture_tenant_select ON correlation_rule_fixture
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY correlation_rule_fixture_tenant_modify ON correlation_rule_fixture
  FOR ALL USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  ) WITH CHECK (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY correlation_rule_fixture_deny_direct_delete ON correlation_rule_fixture
  AS RESTRICTIVE FOR DELETE USING (FALSE);

CREATE TRIGGER audit_correlation_rule_fixture_changes
  AFTER INSERT OR UPDATE OR DELETE ON correlation_rule_fixture
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- -----------------------------------------------
-- Table 2: correlation_evaluation_error (OD-2)
-- WARN-1 APPLIED: data_classification column added (Stage 2 check outcome)
-- INFO-1 APPLIED: per-column COMMENTs added (Stage 2 check outcome)
-- -----------------------------------------------
CREATE TABLE correlation_evaluation_error (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  signal_id                BIGINT NOT NULL REFERENCES osint_signal(id) ON DELETE RESTRICT,
  rule_id                  TEXT NOT NULL,
  status                   TEXT NOT NULL
    CHECK (status IN ('evaluation_timeout','predicate_error','template_render_error','other')),
  elapsed_ms               INTEGER,
  error_message            TEXT,
  diagnostics              JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- WARN-1: data_classification added (was missing in original design spec)
  data_classification      TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),

  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by               BIGINT REFERENCES "user"(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE correlation_evaluation_error IS 'Diagnostic log for rule-evaluation failures per OD-2. Captures evaluation_timeout (5s default per HITL Q1) + predicate_error + template_render_error. Separate from correlation table (a timeout is NOT a rule firing). Surfaced in /app/admin/rules health panel (post-MVP).';

-- INFO-1 APPLIED: per-column COMMENTs (Stage 2 check outcome)
COMMENT ON COLUMN correlation_evaluation_error.tenant_id IS 'Tenant FK. Denormalized from app.current_tenant_id GUC at evaluation time. RLS scopes reads/writes.';
COMMENT ON COLUMN correlation_evaluation_error.signal_id IS 'Source osint_signal that triggered the evaluation. FK to osint_signal(id) RESTRICT — preserves error history on signal soft-delete.';
COMMENT ON COLUMN correlation_evaluation_error.rule_id IS 'String reference per Annex C.3. NOT a FK to correlation_rule.id — preserves error history across rule soft-delete lifecycle.';
COMMENT ON COLUMN correlation_evaluation_error.status IS 'evaluation_timeout = BE wall-clock exceeded 5s (HITL Q1); predicate_error = predicate evaluation threw; template_render_error = produce-block template failed; other = catch-all.';
COMMENT ON COLUMN correlation_evaluation_error.elapsed_ms IS 'Wall-clock milliseconds for rule evaluation attempt. NULL if measurement not available.';
COMMENT ON COLUMN correlation_evaluation_error.error_message IS 'Human-readable error description. Sanitized before storage (no raw stack traces).';
COMMENT ON COLUMN correlation_evaluation_error.diagnostics IS 'Structured diagnostic payload. Shape varies by status — e.g. { predicateName, signalFields } for predicate_error; { ruleId, matchYamlHash } for evaluation_timeout.';
COMMENT ON COLUMN correlation_evaluation_error.data_classification IS 'CR-C / M10 127 rollout marker. WARN-1 fix: column added to match project pattern (all tenant-scoped tables carry data_classification).';

CREATE INDEX idx_correlation_evaluation_error_tenant_rule ON correlation_evaluation_error(tenant_id, rule_id) WHERE is_active = TRUE;
CREATE INDEX idx_correlation_evaluation_error_tenant_status ON correlation_evaluation_error(tenant_id, status) WHERE is_active = TRUE;
CREATE INDEX idx_correlation_evaluation_error_created ON correlation_evaluation_error(tenant_id, created_at DESC) WHERE is_active = TRUE;

ALTER TABLE correlation_evaluation_error ENABLE ROW LEVEL SECURITY;
ALTER TABLE correlation_evaluation_error FORCE ROW LEVEL SECURITY;

CREATE POLICY correlation_evaluation_error_tenant_select ON correlation_evaluation_error
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY correlation_evaluation_error_tenant_modify ON correlation_evaluation_error
  FOR ALL USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  ) WITH CHECK (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY correlation_evaluation_error_deny_direct_delete ON correlation_evaluation_error
  AS RESTRICTIVE FOR DELETE USING (FALSE);

CREATE TRIGGER audit_correlation_evaluation_error_changes
  AFTER INSERT OR UPDATE OR DELETE ON correlation_evaluation_error
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (152, '152_cre_create_correlation_rule_fixture_and_eval_error', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 152;
-- DROP TRIGGER IF EXISTS audit_correlation_evaluation_error_changes ON correlation_evaluation_error;
-- DROP TABLE IF EXISTS correlation_evaluation_error;
-- DROP TRIGGER IF EXISTS audit_correlation_rule_fixture_changes ON correlation_rule_fixture;
-- DROP TABLE IF EXISTS correlation_rule_fixture;
-- ============================================================
