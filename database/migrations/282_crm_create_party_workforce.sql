-- Migration: 282_crm_create_party_workforce.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: CREATE party_workforce table — current workforce snapshot per contractor party.
--              One active row per (tenant, party). Feeds the labor-law cascade
--              headcount-band match + Emiratisation compliance check.
--              FORCE RLS (3 policies) + audit trigger + indexes + COMMENTs.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

CREATE TABLE party_workforce (
  id                      BIGSERIAL PRIMARY KEY,
  tenant_id               UUID         NOT NULL REFERENCES tenant(id) ON DELETE RESTRICT,
  party_id                BIGINT       NOT NULL REFERENCES party(id)  ON DELETE RESTRICT,

  headcount               INTEGER      NOT NULL CHECK (headcount >= 0),
  -- Stored discriminator (policy band, not raw count). CHECK is a small closed
  -- statutory set (3 values, NOT a user-extensible dropdown) — inline CHECK per
  -- osint_source/risk_score inline-CHECK precedent (Rule 8 does not apply to
  -- fixed statutory enums).
  headcount_band          TEXT         NOT NULL
                            CHECK (headcount_band IN ('<20','20-49','50+')),

  emiratisation_target    INTEGER      NOT NULL DEFAULT 0 CHECK (emiratisation_target >= 0),
  emiratisation_actual    INTEGER      NOT NULL DEFAULT 0 CHECK (emiratisation_actual >= 0),
  is_compliant            BOOLEAN      NOT NULL DEFAULT TRUE,

  category                TEXT         NOT NULL DEFAULT 'operational_support'
                            CHECK (category IN ('drilling','logistics','epc','operational_support','other')),
  source                  TEXT         NOT NULL DEFAULT 'demo_seed'
                            CHECK (source IN ('manual','demo_seed','import')),
  notes                   TEXT,
  data_classification     TEXT         NOT NULL DEFAULT 'demo'
                            CHECK (data_classification IN ('demo','pilot','production')),

  created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  created_by              BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by              BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active               BOOLEAN      NOT NULL DEFAULT TRUE
);

COMMENT ON TABLE party_workforce IS
  'CR-M — current workforce snapshot per contractor party (one active row per tenant+party). Feeds the labor-law cascade headcount-band match + Emiratisation compliance. Tenant-scoped (party is single-tenant; this table is not). Soft-delete only; one-current-row enforced by partial UNIQUE. Future history via effective_from/_to (party_relationship pattern) deferred.';
COMMENT ON COLUMN party_workforce.headcount_band IS 'Statutory band: <20 (exempt) / 20-49 (>=1 Emirati by end-2024, 2 by 2025) / 50+ (annual % quota). Stored discriminator; cascade matches on this.';
COMMENT ON COLUMN party_workforce.emiratisation_target IS 'Required Emirati headcount per Federal Decree-Law No.9/2024 + Tawteen band rules.';
COMMENT ON COLUMN party_workforce.emiratisation_actual IS 'Current Emirati headcount. is_compliant = (actual >= target).';
COMMENT ON COLUMN party_workforce.is_compliant IS 'Denormalized convenience flag = (emiratisation_actual >= emiratisation_target). Maintained by fn_party_workforce_set.';

-- One current row per (tenant, party)
CREATE UNIQUE INDEX uq_party_workforce_tenant_party_active
  ON party_workforce(tenant_id, party_id) WHERE is_active = TRUE;
-- FK indexes
CREATE INDEX idx_party_workforce_tenant_id  ON party_workforce(tenant_id);
CREATE INDEX idx_party_workforce_party_id   ON party_workforce(party_id);
CREATE INDEX idx_party_workforce_created_by ON party_workforce(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX idx_party_workforce_updated_by ON party_workforce(updated_by) WHERE updated_by IS NOT NULL;
-- is_active partial + query-pattern (cascade scans non-compliant by band)
CREATE INDEX idx_party_workforce_active         ON party_workforce(id) WHERE is_active = TRUE;
CREATE INDEX idx_party_workforce_band_compliance
  ON party_workforce(tenant_id, headcount_band, is_compliant) WHERE is_active = TRUE;

-- RLS
ALTER TABLE party_workforce ENABLE ROW LEVEL SECURITY;
ALTER TABLE party_workforce FORCE  ROW LEVEL SECURITY;

CREATE POLICY party_workforce_tenant_select ON party_workforce
  FOR SELECT USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('party.workforce.read')
  );

CREATE POLICY party_workforce_tenant_modify ON party_workforce
  FOR ALL USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('party.workforce.manage')
  ) WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true),'')::uuid
    AND fn_current_user_has_permission('party.workforce.manage')
  );

CREATE POLICY party_workforce_deny_direct_delete ON party_workforce
  AS RESTRICTIVE FOR DELETE USING (FALSE);

-- Audit trigger (id BIGSERIAL PK — default fn_audit_trigger applies cleanly, S2-28)
CREATE TRIGGER audit_party_workforce_changes
  AFTER INSERT OR UPDATE OR DELETE ON party_workforce
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (282, '282_crm_create_party_workforce', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP TABLE IF EXISTS party_workforce CASCADE;
-- DELETE FROM schema_migrations WHERE version = 282;
-- COMMIT;
-- ============================================================
