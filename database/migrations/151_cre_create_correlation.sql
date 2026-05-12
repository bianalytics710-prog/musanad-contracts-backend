-- Migration: 151_cre_create_correlation.sql
-- Module: M13 / CR-E — Correlation Rule Engine
-- Description: CREATE TABLE correlation + FORCE RLS + 3 policies + audit trigger + COMMENTs + 6 indexes.
--   Rule-firing output table. UNIQUE on (tenant_id, signal_id, contract_id, rule_id).
--   rule_id is TEXT not FK — survives rule soft-delete per OD-3. Per HITL Q2: two rules matching
--   same signal+contract produce two rows.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE TABLE correlation (
  id                       BIGSERIAL PRIMARY KEY,
  tenant_id                UUID NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  signal_id                BIGINT NOT NULL REFERENCES osint_signal(id) ON DELETE RESTRICT,
  contract_id              BIGINT NOT NULL REFERENCES contract(id) ON DELETE RESTRICT,
  rule_id                  TEXT NOT NULL,
  rule_version_hash        TEXT NOT NULL,
  confidence               NUMERIC(5,4) NOT NULL
    CHECK (confidence >= 0 AND confidence <= 1),
  match_reason             TEXT NOT NULL,
  match_evidence           JSONB NOT NULL DEFAULT '{}'::jsonb,
  match_geographies        JSONB NOT NULL DEFAULT '[]'::jsonb,
  match_entities           JSONB NOT NULL DEFAULT '[]'::jsonb,
  status                   TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','dismissed','expired')),
  dismissed_by             BIGINT REFERENCES "user"(id),
  dismissed_at             TIMESTAMPTZ,
  dismissed_reason         TEXT,
  expires_at               TIMESTAMPTZ,
  data_classification      TEXT NOT NULL DEFAULT 'demo'
    CHECK (data_classification IN ('demo','pilot','production')),

  -- Standard 6 audit columns
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by               BIGINT REFERENCES "user"(id),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by               BIGINT REFERENCES "user"(id),
  is_active                BOOLEAN NOT NULL DEFAULT TRUE,

  CONSTRAINT correlation_idempotency_key
    UNIQUE (tenant_id, signal_id, contract_id, rule_id)
);

COMMENT ON TABLE correlation IS 'Rule firings — output of fn_rule_evaluate. Per HITL Q2 accept-both-correlations: UNIQUE includes rule_id (two rules matching same signal+contract create two rows). Per OD-3: rows persist with status=active even if contract archived between rule-fire and persist; admin dismisses via fn_correlation_dismiss.';
COMMENT ON COLUMN correlation.rule_id IS 'String reference per Annex C.3 (e.g. rule.sanctions.direct_counterparty). NOT a FK to correlation_rule.id — preserves audit history across rule soft-delete + supports cross-export portability.';
COMMENT ON COLUMN correlation.rule_version_hash IS 'Snapshot of correlation_rule.version_hash at firing time. AC-S15-03 contract — retroactive audit possible even after rule body changes.';
COMMENT ON COLUMN correlation.match_evidence IS 'JSONB pointers per Annex C.5.1 evidence array. SENSITIVE — may include signal raw_payload field values (sanctions entity IDs, counterparty names). Redacted from fn_audit_trigger.';
COMMENT ON COLUMN correlation.match_entities IS 'Entity-identifiable info per matched-entity rule. SENSITIVE — contains counterparty names + sanctions designations. Redacted from fn_audit_trigger.';
COMMENT ON COLUMN correlation.status IS 'active = freshly fired; dismissed = admin/legal explicitly dismissed with reason; expired = past expires_at (BE worker can sweep status=expired).';
COMMENT ON COLUMN correlation.expires_at IS 'Nullable. Default 30 days set by BE at insert if NULL on rule.produce block. BE expire-sweep cron updates status=expired.';

-- 6 indexes
CREATE INDEX idx_correlation_tenant_contract_status ON correlation(tenant_id, contract_id, status) WHERE is_active = TRUE;
CREATE INDEX idx_correlation_tenant_rule_status ON correlation(tenant_id, rule_id, status) WHERE is_active = TRUE;
CREATE INDEX idx_correlation_tenant_signal ON correlation(tenant_id, signal_id) WHERE is_active = TRUE;
CREATE INDEX idx_correlation_active ON correlation(id) WHERE is_active = TRUE;
CREATE INDEX idx_correlation_tenant_status_created ON correlation(tenant_id, status, created_at DESC) WHERE is_active = TRUE;
CREATE INDEX idx_correlation_expires_at ON correlation(expires_at) WHERE expires_at IS NOT NULL AND is_active = TRUE AND status = 'active';

-- FORCE RLS + 3 policies
ALTER TABLE correlation ENABLE ROW LEVEL SECURITY;
ALTER TABLE correlation FORCE ROW LEVEL SECURITY;

CREATE POLICY correlation_tenant_select ON correlation
  FOR SELECT USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY correlation_tenant_modify ON correlation
  FOR ALL USING (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  ) WITH CHECK (
    tenant_id = current_setting('app.current_tenant_id', true)::uuid
  );

CREATE POLICY correlation_deny_direct_delete ON correlation
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger
CREATE TRIGGER audit_correlation_changes
  AFTER INSERT OR UPDATE OR DELETE ON correlation
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (151, '151_cre_create_correlation', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 151;
-- DROP TRIGGER IF EXISTS audit_correlation_changes ON correlation;
-- DROP TABLE IF EXISTS correlation;
-- ============================================================
