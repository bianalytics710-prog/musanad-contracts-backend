-- Migration: 105_m7_create_source_health.sql
-- Module: M7 — OSINT Source Framework + Adapter Protocol (CR-A)
-- Description: CREATE TABLE source_health. NO audit trigger (Q-NEW6/OQ-6: 5-min × 8 sources × N tenants
--              would flood audit_log; the table's own checked_at + state columns ARE the ledger).
--              FORCE RLS + 1 SELECT policy (source.read tenant-scoped) + RESTRICTIVE write-deny
--              (writes only via DEFINER fn_source_health_record).
-- Rollback: DROP TABLE source_health CASCADE.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS source_health (
  id                  BIGSERIAL   PRIMARY KEY,
  tenant_id           UUID        NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  osint_source_id     BIGINT      NOT NULL REFERENCES osint_source(id) ON DELETE CASCADE,
  state               TEXT        NOT NULL CHECK (state IN
                        ('healthy','degraded','failing','unauthorised')),
  last_success_at     TIMESTAMPTZ,
  last_failure_at     TIMESTAMPTZ,
  last_error_message  TEXT,
  signals_24h         INTEGER     NOT NULL DEFAULT 0,
  checked_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_active           BOOLEAN     NOT NULL DEFAULT TRUE,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT source_health_tenant_source_key UNIQUE (tenant_id, osint_source_id)
);

CREATE INDEX IF NOT EXISTS idx_source_health_tenant_id        ON source_health(tenant_id);
CREATE INDEX IF NOT EXISTS idx_source_health_osint_source_id  ON source_health(osint_source_id);
CREATE INDEX IF NOT EXISTS idx_source_health_tenant_state     ON source_health(tenant_id, state);

COMMENT ON TABLE source_health IS
  'M7 per-source health snapshot — one row per (tenant_id, osint_source_id). Updated by 5-min health-check cron via fn_source_health_record. AUDIT TRIGGER DELIBERATELY OFF (Q-NEW6/OQ-6 lock): 5-min × 8 sources × N tenants would flood audit_log; the table''s own checked_at + state columns are its ledger. Future state-transition ledger (source_health_state_change) deferred to pilot if needed. Writes ONLY via DEFINER fn_source_health_record (cron-callable; no created_by/updated_by FK columns).';
COMMENT ON COLUMN source_health.last_error_message IS
  'SENSITIVE — upstream errors can leak credentials in 401/403 responses. Truncated to 500 chars by fn_source_health_record. Listed in project.config.json sensitiveFields (AE3) AND fn_audit_trigger redact list (AE1) — defence-in-depth (trigger is off but the redact-list entry guards against accidental future trigger enablement).';
COMMENT ON COLUMN source_health.signals_24h IS
  'Rolling 24h count maintained by fn_source_health_record on every cron tick.';

-- RLS
ALTER TABLE source_health ENABLE ROW LEVEL SECURITY;
ALTER TABLE source_health FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS source_health_tenant_select        ON source_health;
DROP POLICY IF EXISTS source_health_deny_direct_modify   ON source_health;

CREATE POLICY source_health_tenant_select ON source_health
  FOR SELECT
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('source.read')
  );

CREATE POLICY source_health_deny_direct_modify ON source_health
  AS RESTRICTIVE FOR ALL USING (false) WITH CHECK (false);

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (105, 'm7_create_source_health', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TABLE IF EXISTS source_health CASCADE;
-- DELETE FROM schema_migrations WHERE version = 105;
-- COMMIT;
-- ============================================================
