-- Migration: 109_cra2_create_internal_signal_kind.sql
-- Module: M8 — Internal Signal Data Path (CR-A2 — CRIP Wave 1)
-- Description: (a) Add osint_signal.metadata JSONB NOT NULL DEFAULT '{}'::jsonb (Q-DA6 lock).
--              (b) Extend the M7 osint_signal_deny_direct_update RESTRICTIVE policy with a
--                  permission-gated USING/WITH CHECK clause that allows the
--                  fn_internal_signal_resolve INVOKER path when the actor holds
--                  internal_signal.resolve permission.
--              (c) CREATE TABLE internal_signal_kind (BIGSERIAL id, tenant_id UUID FK,
--                  signal_type CHECK enum-of-8, display_name + display_name_ar, description,
--                  parameter_schema JSONB, default_severity CHECK enum-of-5, audit cols)
--                  + UNIQUE(tenant_id, signal_type) + 5 indexes (3 FK btrees + soft-delete partial
--                  + composite tenant/active/type) + FORCE RLS + 2 policies + audit trigger
--                  + COMMENTs.
-- Rollback: see ROLLBACK section below.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ----------------------------------------------------------------
-- (a) Extend osint_signal with metadata JSONB column (Q-DA6 = ADD)
-- ----------------------------------------------------------------
ALTER TABLE osint_signal
  ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN osint_signal.metadata IS
  'M8 (CR-A2) — non-ingest mutable JSONB. Resolution lifecycle ({resolvedAt, resolvedBy, resolutionKind, resolutionNote}) lives here. Future per-signal annotations (review state, escalation flags) extend this map. Excluded from fn_audit_trigger because audit is OFF on osint_signal (M7 108).';

-- ----------------------------------------------------------------
-- (b) Extend the M7 RESTRICTIVE deny-direct-update policy on osint_signal so the
--     INVOKER fn_internal_signal_resolve path can write metadata when the actor
--     holds internal_signal.resolve. Defence-in-depth — the fn body also gates by
--     the signal_kind_subtype role mapping (Q-DA3).
-- ----------------------------------------------------------------
DROP POLICY IF EXISTS osint_signal_deny_direct_update ON osint_signal;
CREATE POLICY osint_signal_deny_direct_update ON osint_signal
  AS RESTRICTIVE FOR UPDATE
  USING (
    fn_current_user_has_permission('internal_signal.resolve')
  )
  WITH CHECK (
    fn_current_user_has_permission('internal_signal.resolve')
  );

COMMENT ON POLICY osint_signal_deny_direct_update ON osint_signal IS
  'M7 (104) — RESTRICTIVE deny-all UPDATE; M8 (109) carve-out for the fn_internal_signal_resolve INVOKER write path. Caller must hold internal_signal.resolve. fn_internal_signal_resolve also enforces a per-signal_type role mapping (Q-DA3) on top of this gate.';

-- ----------------------------------------------------------------
-- (c) CREATE TABLE internal_signal_kind
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS internal_signal_kind (
  id                  BIGSERIAL    PRIMARY KEY,
  tenant_id           UUID         NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  signal_type         TEXT         NOT NULL CHECK (signal_type IN (
                        'milestone_slippage','sla_breach','payment_delay','invoice_dispute',
                        'vendor_incident','ics_incident','icv_status_change','certificate_expiry')),
  display_name        VARCHAR(200) NOT NULL,
  display_name_ar     VARCHAR(200) NOT NULL,
  description         TEXT,
  parameter_schema    JSONB        NOT NULL,
  default_severity    TEXT         NOT NULL CHECK (default_severity IN
                        ('informational','low','medium','high','critical')),
  is_active           BOOLEAN      NOT NULL DEFAULT TRUE,

  created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT REFERENCES "user"(id) ON DELETE SET NULL,

  CONSTRAINT internal_signal_kind_tenant_signal_type_key UNIQUE (tenant_id, signal_type)
);

-- ----------------------------------------------------------------
-- (d) Indexes (5 total): 3 FK btrees + 1 soft-delete partial + 1 composite query-pattern
-- ----------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_internal_signal_kind_tenant_id
  ON internal_signal_kind(tenant_id);
CREATE INDEX IF NOT EXISTS idx_internal_signal_kind_created_by
  ON internal_signal_kind(created_by);
CREATE INDEX IF NOT EXISTS idx_internal_signal_kind_updated_by
  ON internal_signal_kind(updated_by);

CREATE INDEX IF NOT EXISTS idx_internal_signal_kind_active
  ON internal_signal_kind(id) WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_internal_signal_kind_tenant_active_type
  ON internal_signal_kind(tenant_id, is_active, signal_type);

-- ----------------------------------------------------------------
-- (e) FORCE RLS + two policies (PERMISSIVE tenant_self_select + RESTRICTIVE deny-direct-modify)
-- ----------------------------------------------------------------
ALTER TABLE internal_signal_kind ENABLE ROW LEVEL SECURITY;
ALTER TABLE internal_signal_kind FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS internal_signal_kind_tenant_select ON internal_signal_kind;
CREATE POLICY internal_signal_kind_tenant_select ON internal_signal_kind
  FOR SELECT
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('internal_signal.read')
  );

DROP POLICY IF EXISTS internal_signal_kind_deny_direct_modify ON internal_signal_kind;
CREATE POLICY internal_signal_kind_deny_direct_modify ON internal_signal_kind
  AS RESTRICTIVE FOR ALL
  USING (false)
  WITH CHECK (false);

-- ----------------------------------------------------------------
-- (f) Audit trigger (BIGSERIAL id is fully compatible with audit_log.record_id)
-- ----------------------------------------------------------------
DROP TRIGGER IF EXISTS audit_internal_signal_kind_changes ON internal_signal_kind;
CREATE TRIGGER audit_internal_signal_kind_changes
  AFTER INSERT OR UPDATE OR DELETE ON internal_signal_kind
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ----------------------------------------------------------------
-- (g) COMMENTs
-- ----------------------------------------------------------------
COMMENT ON TABLE internal_signal_kind IS
  'M8 (CR-A2) — reference catalogue of internal signal sub-types per SOT Annex D.6.1. Tenant-scoped; 8 rows per tenant for v1 demo. parameter_schema is a JSON-Schema-style spec validating fn_internal_signal_ingest payloads. CRUD deferred to pilot — CR-A2 is seed-only via DEFINER migration insert; RESTRICTIVE deny-direct-modify policy enforces this at the row level.';
COMMENT ON COLUMN internal_signal_kind.signal_type IS
  'Stable string handle. CHECK enum is intentionally hardcoded — these 8 values are SOT-sealed; new kinds are CR-scoped (constraint dynamic-rename per M1b 010 pattern is the upgrade path).';
COMMENT ON COLUMN internal_signal_kind.parameter_schema IS
  'JSON-Schema-style spec describing required + optional fields per signal_type. fn_internal_signal_ingest validates the request payload against parameter_schema.required[] (minimum check); full per-key shape validation is deferred to BE Zod schemas (defence-in-depth at two layers).';
COMMENT ON COLUMN internal_signal_kind.default_severity IS
  'Reuses M7 osint_signal severity vocabulary verbatim (informational/low/medium/high/critical) — no new lookup table; this is a small fixed enum aligned with osint_signal.severity_v2 CHECK constraint.';

-- ----------------------------------------------------------------
-- Record this migration
-- ----------------------------------------------------------------
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (109, 'cra2_create_internal_signal_kind', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS audit_internal_signal_kind_changes ON internal_signal_kind;
-- DROP POLICY IF EXISTS internal_signal_kind_deny_direct_modify ON internal_signal_kind;
-- DROP POLICY IF EXISTS internal_signal_kind_tenant_select ON internal_signal_kind;
-- DROP INDEX IF EXISTS idx_internal_signal_kind_tenant_active_type;
-- DROP INDEX IF EXISTS idx_internal_signal_kind_active;
-- DROP INDEX IF EXISTS idx_internal_signal_kind_updated_by;
-- DROP INDEX IF EXISTS idx_internal_signal_kind_created_by;
-- DROP INDEX IF EXISTS idx_internal_signal_kind_tenant_id;
-- DROP TABLE IF EXISTS internal_signal_kind;
-- DROP POLICY IF EXISTS osint_signal_deny_direct_update ON osint_signal;
-- CREATE POLICY osint_signal_deny_direct_update ON osint_signal
--   AS RESTRICTIVE FOR UPDATE USING (false);
-- ALTER TABLE osint_signal DROP COLUMN IF EXISTS metadata;
-- DELETE FROM schema_migrations WHERE version = 109;
-- COMMIT;
-- ============================================================
