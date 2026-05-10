-- Migration: 115_crb_create_party_relationship.sql
-- Module: M9 — Counterparty Graph (CR-B)
-- Description: Net-new tenant-scoped edge table. FORCE RLS + 3 policies + audit trigger.
-- Rollback: DROP TABLE party_relationship CASCADE.

BEGIN;

CREATE TABLE IF NOT EXISTS party_relationship (
  id                  BIGSERIAL PRIMARY KEY,

  tenant_id           UUID         NOT NULL
    REFERENCES tenant(id) ON DELETE RESTRICT,

  parent_id           BIGINT       NOT NULL
    REFERENCES party(id) ON DELETE RESTRICT,
  child_id            BIGINT       NOT NULL
    REFERENCES party(id) ON DELETE RESTRICT,

  relationship_type   TEXT         NOT NULL
    CHECK (relationship_type IN ('parent','ubo','subsidiary','sub_contractor','jv','controlling_shareholder')),

  ownership_pct       NUMERIC(5,2) NULL
    CHECK (ownership_pct IS NULL OR (ownership_pct BETWEEN 0 AND 100)),

  effective_from      DATE         NULL,
  effective_to        DATE         NULL
    CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from),

  source              TEXT         NOT NULL DEFAULT 'manual'
    CHECK (source IN ('dnb','sayari','manual','demo_seed')),

  confidence          NUMERIC(3,2) NOT NULL DEFAULT 1.00
    CHECK (confidence BETWEEN 0 AND 1),

  metadata            JSONB        NOT NULL DEFAULT '{}'::jsonb,
  data_classification TEXT         NOT NULL DEFAULT 'internal',

  created_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_by          BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  updated_by          BIGINT       REFERENCES "user"(id) ON DELETE SET NULL,
  is_active           BOOLEAN      NOT NULL DEFAULT TRUE,

  CONSTRAINT party_relationship_no_self_loop CHECK (child_id <> parent_id),
  CONSTRAINT party_relationship_unique_directed_typed
    UNIQUE (tenant_id, parent_id, child_id, relationship_type)
);

COMMENT ON TABLE  party_relationship IS
  'M9 (CR-B) — tenant-scoped directed edge between two parties. Encodes parent / UBO / subsidiary / sub-contractor / JV / controlling_shareholder. UNIQUE (tenant_id, parent_id, child_id, relationship_type) supports idempotent upsert; CHECK (child_id <> parent_id) prevents row-level self-loops; multi-hop cycle prevention is at traversal time (depth cap + visited-set).';

COMMENT ON COLUMN party_relationship.id                  IS 'Surrogate key.';
COMMENT ON COLUMN party_relationship.tenant_id           IS 'M9 — tenant scope (set from app.current_tenant_id GUC; FORCE RLS enforces).';
COMMENT ON COLUMN party_relationship.parent_id           IS 'FK -> party.id. The "owning" or "above" party in the directed edge.';
COMMENT ON COLUMN party_relationship.child_id            IS 'FK -> party.id. The "owned" or "below" party in the directed edge.';
COMMENT ON COLUMN party_relationship.relationship_type   IS
  'M9 — closed enum 6 values: parent / ubo / subsidiary / sub_contractor / jv / controlling_shareholder. Locked for v1 per HITL Q5 (OD-M9-5a). Pilot upgrade path: ALTER TABLE DROP/ADD CHECK in single tx (M1b 010 dynamic-rename pattern), or convert to FK lookup table.';
COMMENT ON COLUMN party_relationship.ownership_pct       IS 'M9 — 0..100 percentage (NULL when unknown).';
COMMENT ON COLUMN party_relationship.effective_from      IS 'M9 — when relationship became effective (NULL = open-start).';
COMMENT ON COLUMN party_relationship.effective_to        IS 'M9 — when relationship ended (NULL = ongoing).';
COMMENT ON COLUMN party_relationship.source              IS 'M9 — provenance: dnb | sayari | manual | demo_seed.';
COMMENT ON COLUMN party_relationship.confidence          IS 'M9 — 0..1 confidence score (1.00 for manual entries; lower for auto-imported).';
COMMENT ON COLUMN party_relationship.metadata            IS 'M9 — extensible JSONB bag. SENSITIVE (audit-redacted by fn_audit_trigger 116).';
COMMENT ON COLUMN party_relationship.data_classification IS 'demo | pilot | production — drives data retention.';
COMMENT ON COLUMN party_relationship.is_active           IS 'Soft-delete flag (FALSE = removed).';

-- Indexes (every FK gets a btree per M7 S2-7 lesson)
CREATE INDEX IF NOT EXISTS idx_party_rel_tenant_parent_active
  ON party_relationship(tenant_id, parent_id) WHERE is_active = TRUE;  -- drives traverse_down

CREATE INDEX IF NOT EXISTS idx_party_rel_tenant_child_active
  ON party_relationship(tenant_id, child_id) WHERE is_active = TRUE;   -- drives traverse_up

CREATE INDEX IF NOT EXISTS idx_party_rel_tenant_active
  ON party_relationship(tenant_id, is_active);                          -- tenant active-set scans

CREATE INDEX IF NOT EXISTS idx_party_rel_tenant_id   ON party_relationship(tenant_id);
CREATE INDEX IF NOT EXISTS idx_party_rel_parent_id   ON party_relationship(parent_id);
CREATE INDEX IF NOT EXISTS idx_party_rel_child_id    ON party_relationship(child_id);
CREATE INDEX IF NOT EXISTS idx_party_rel_created_by  ON party_relationship(created_by) WHERE created_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_party_rel_updated_by  ON party_relationship(updated_by) WHERE updated_by IS NOT NULL;

-- Audit trigger (BIGSERIAL id makes default fn_audit_trigger compatible)
CREATE TRIGGER audit_party_relationship_changes
  AFTER INSERT OR UPDATE OR DELETE ON party_relationship
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- RLS: ENABLE + FORCE
ALTER TABLE party_relationship ENABLE ROW LEVEL SECURITY;
ALTER TABLE party_relationship FORCE  ROW LEVEL SECURITY;

-- Policy 1 — tenant-scoped SELECT gated on party.graph.read
CREATE POLICY party_relationship_tenant_select ON party_relationship
  AS PERMISSIVE FOR SELECT
  USING (
    is_active = TRUE
    AND tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('party.graph.read')
  );

-- Policy 2 — tenant-scoped INSERT/UPDATE gated on party.graph.manage
CREATE POLICY party_relationship_tenant_modify ON party_relationship
  AS PERMISSIVE FOR ALL
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('party.graph.manage')
  )
  WITH CHECK (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND fn_current_user_has_permission('party.graph.manage')
  );

-- Policy 3 — RESTRICTIVE deny direct hard-DELETE (soft-delete-only via fn_party_relationship_delete)
CREATE POLICY party_relationship_deny_direct_delete ON party_relationship
  AS RESTRICTIVE FOR DELETE
  USING (FALSE);

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (115, 'crb_create_party_relationship', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP POLICY IF EXISTS party_relationship_deny_direct_delete ON party_relationship;
-- DROP POLICY IF EXISTS party_relationship_tenant_modify       ON party_relationship;
-- DROP POLICY IF EXISTS party_relationship_tenant_select       ON party_relationship;
-- DROP TRIGGER IF EXISTS audit_party_relationship_changes ON party_relationship;
-- DROP TABLE IF EXISTS party_relationship CASCADE;
-- DELETE FROM schema_migrations WHERE version = 115;
-- COMMIT;
