-- Migration: 104_m7_rename_impact_signal_to_osint_signal.sql
-- Module: M7 — OSINT Source Framework + Adapter Protocol (CR-A)
-- Description: STRATEGY-A preserve-superset rename per Q1 + OQ-7. Steps:
--                (a) ALTER TABLE impact_signal RENAME TO osint_signal.
--                (b) ADD 14 Annex B.2.1 columns (NULL-able).
--                (c) Back-fill 18 R-LC rows: tenant_id=ADNOC, signal_kind_subtype='manual_curated',
--                    kind/severity_v2 mapped, raw_payload synthesised, dedup_hash=sha256(...).
--                (d) ADD UNIQUE(tenant_id, dedup_hash) + GIN(geographies) + GIN(affected_entities)
--                    + partial btree on osint_source_id (Stage 2 S2-7 patch).
--                (e) Drop R-LC RLS policies + create new tenant-scoped policies (RESTRICTIVE write-deny
--                    routes mutations through DEFINER fn_osint_signal_upsert).
--                (f) Rename audit trigger.
--                (g) CREATE VIEW impact_signal — preserves R-LC 19-col shape for back-compat.
--                (h) Verify FK on impact_signal_contract.signal_id_fkey auto-redirected.
-- Rollback: see ROLLBACK section.
-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ----------------------------------------------------------------
-- (a) RENAME table — PostgreSQL auto-renames the PK constraint, indexes, trigger, FKs.
-- ----------------------------------------------------------------
ALTER TABLE impact_signal RENAME TO osint_signal;

-- ----------------------------------------------------------------
-- (b) ADD 14 Annex B.2.1 superset columns (NULL-able initially so back-fill works)
-- ----------------------------------------------------------------
ALTER TABLE osint_signal
  ADD COLUMN tenant_id            UUID,
  ADD COLUMN osint_source_id      BIGINT REFERENCES osint_source(id) ON DELETE RESTRICT,
  ADD COLUMN source_id            TEXT,
  ADD COLUMN source_reliability   NUMERIC(3,2) CHECK (source_reliability BETWEEN 0 AND 1),
  ADD COLUMN fetched_at           TIMESTAMPTZ,
  ADD COLUMN event_date_v2        TIMESTAMPTZ,
  ADD COLUMN kind                 TEXT      CHECK (kind IN
                                    ('geopolitical','sanctions','weather','commodity',
                                     'fx','logistics','esg','regulatory','news','internal')),
  ADD COLUMN signal_kind_subtype  TEXT,
  ADD COLUMN title                TEXT,
  ADD COLUMN summary              TEXT,
  ADD COLUMN geographies          JSONB     NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN affected_entities    JSONB     NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN severity_v2          TEXT      CHECK (severity_v2 IN
                                    ('informational','low','medium','high','critical')),
  ADD COLUMN confidence           NUMERIC(3,2) CHECK (confidence BETWEEN 0 AND 1),
  ADD COLUMN url                  TEXT,
  ADD COLUMN raw_payload          JSONB,
  ADD COLUMN dedup_hash           TEXT,
  ADD COLUMN data_classification  VARCHAR(20) DEFAULT 'demo'
                                    CHECK (data_classification IN ('demo','pilot','production'));

-- ----------------------------------------------------------------
-- (c) Back-fill R-LC rows
--     - tenant_id := ADNOC seed
--     - signal_kind_subtype := 'manual_curated'
--     - kind := mapped from category
--     - severity_v2 := mapped from severity (free-text)
--     - raw_payload := jsonb_build_object of original R-LC fields
--     - dedup_hash := sha256('manual_curated' || '|' || isoformat(date) || '|' || lower(trim(title_en)))
-- NOTE: actual back-fill row count is the live impact_signal row count (17 in current DB; spec says 18).
--       UPDATE works on whatever rows have tenant_id IS NULL — naturally idempotent.
-- ----------------------------------------------------------------
UPDATE osint_signal
SET tenant_id           = '00000000-0000-0000-0000-000000000001',
    signal_kind_subtype = 'manual_curated',
    kind                = CASE category
                            WHEN 'regulatory'        THEN 'regulatory'
                            WHEN 'commodity_prices'  THEN 'commodity'
                            WHEN 'supply_chain'      THEN 'logistics'
                            WHEN 'geopolitical'      THEN 'geopolitical'
                            WHEN 'market_financial'  THEN 'fx'
                            ELSE 'internal'
                          END,
    severity_v2         = CASE
                            WHEN lower(severity) IN ('critical','severe')                     THEN 'critical'
                            WHEN lower(severity) IN ('major','sharp_move','high','elevated')  THEN 'high'
                            WHEN lower(severity) IN ('shifting','volatile','medium','moderate') THEN 'medium'
                            WHEN lower(severity) IN ('low','minor','stable')                  THEN 'low'
                            ELSE 'informational'
                          END,
    source_reliability  = 1.00,
    fetched_at          = COALESCE(updated_at, created_at),
    event_date_v2       = effective_date::timestamptz,
    title               = title_en,
    summary             = description_en,
    source_id           = 'manual_curated',
    raw_payload         = jsonb_build_object(
                            'extId',                    ext_id,
                            'category',                 category,
                            'source',                   source,
                            'titleEn',                  title_en,
                            'titleAr',                  title_ar,
                            'descriptionEn',            description_en,
                            'descriptionAr',            description_ar,
                            'affectedClauseCategories', affected_clause_categories,
                            'publishedDate',            published_date,
                            'effectiveDate',            effective_date,
                            'complianceDeadline',       compliance_deadline,
                            'isSeed',                   is_seed,
                            'origin',                   'r_lc_manual_curated'
                          ),
    dedup_hash          = encode(
                            digest('manual_curated|' ||
                                   COALESCE(effective_date::text, published_date::text, created_at::text) || '|' ||
                                   lower(trim(title_en)),
                                   'sha256'),
                            'hex'),
    data_classification = 'demo',
    confidence          = 1.00
WHERE tenant_id IS NULL;

-- Lock NOT NULL on the columns we promised in db-design.md §1.4 step 4.
ALTER TABLE osint_signal
  ALTER COLUMN tenant_id          SET NOT NULL,
  ALTER COLUMN source_id          SET NOT NULL,
  ALTER COLUMN source_reliability SET NOT NULL,
  ALTER COLUMN fetched_at         SET NOT NULL,
  ALTER COLUMN kind               SET NOT NULL,
  ALTER COLUMN severity_v2        SET NOT NULL,
  ALTER COLUMN confidence         SET NOT NULL,
  ALTER COLUMN raw_payload        SET NOT NULL,
  ALTER COLUMN dedup_hash         SET NOT NULL,
  ALTER COLUMN data_classification SET NOT NULL;

-- ----------------------------------------------------------------
-- (d) Constraints + indexes
-- ----------------------------------------------------------------
ALTER TABLE osint_signal
  ADD CONSTRAINT osint_signal_tenant_id_fkey
    FOREIGN KEY (tenant_id) REFERENCES tenant(id) ON DELETE RESTRICT,
  ADD CONSTRAINT osint_signal_tenant_dedup_key
    UNIQUE (tenant_id, dedup_hash);

CREATE INDEX IF NOT EXISTS idx_osint_signal_tenant_fetched_at
  ON osint_signal(tenant_id, fetched_at DESC);
CREATE INDEX IF NOT EXISTS idx_osint_signal_tenant_kind_severity
  ON osint_signal(tenant_id, kind, severity_v2);
CREATE INDEX IF NOT EXISTS idx_osint_signal_tenant_source_event
  ON osint_signal(tenant_id, source_id, event_date_v2 DESC);
CREATE INDEX IF NOT EXISTS idx_osint_signal_geographies_gin
  ON osint_signal USING GIN (geographies jsonb_path_ops);
CREATE INDEX IF NOT EXISTS idx_osint_signal_affected_entities_gin
  ON osint_signal USING GIN (affected_entities jsonb_path_ops);
-- Stage 2 S2-7 patch: partial btree on FK column (composite indexes lead on TEXT source_id, not BIGINT FK)
CREATE INDEX IF NOT EXISTS idx_osint_signal_osint_source_id
  ON osint_signal(osint_source_id) WHERE osint_source_id IS NOT NULL;

-- ----------------------------------------------------------------
-- (e) Drop old R-LC RLS policies + create new tenant-scoped ones
-- ----------------------------------------------------------------
DROP POLICY IF EXISTS impact_signal_select_read_perm    ON osint_signal;
DROP POLICY IF EXISTS impact_signal_modify_edit_perm    ON osint_signal;
DROP POLICY IF EXISTS impact_signal_deny_direct_delete  ON osint_signal;

ALTER TABLE osint_signal ENABLE ROW LEVEL SECURITY;
ALTER TABLE osint_signal FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS osint_signal_tenant_isolation_select ON osint_signal;
CREATE POLICY osint_signal_tenant_isolation_select ON osint_signal
  FOR SELECT
  USING (
    tenant_id = NULLIF(current_setting('app.current_tenant_id', true), '')::uuid
    AND (
      fn_current_user_has_permission('signal.read.all')
      OR fn_current_user_has_permission('contract.read.department')   -- R-LC compatibility
      OR fn_current_user_has_permission('contract.edit')              -- R-LC compatibility
    )
  );

DROP POLICY IF EXISTS osint_signal_deny_direct_insert ON osint_signal;
CREATE POLICY osint_signal_deny_direct_insert ON osint_signal
  AS RESTRICTIVE FOR INSERT WITH CHECK (false);

DROP POLICY IF EXISTS osint_signal_deny_direct_update ON osint_signal;
CREATE POLICY osint_signal_deny_direct_update ON osint_signal
  AS RESTRICTIVE FOR UPDATE USING (false);

DROP POLICY IF EXISTS osint_signal_deny_direct_delete ON osint_signal;
CREATE POLICY osint_signal_deny_direct_delete ON osint_signal
  AS RESTRICTIVE FOR DELETE USING (false);

-- ----------------------------------------------------------------
-- (f) Trigger rename — preserves audit history continuity
-- ----------------------------------------------------------------
ALTER TRIGGER audit_impact_signal_changes ON osint_signal
  RENAME TO audit_osint_signal_changes;

-- ----------------------------------------------------------------
-- (g) CREATE VIEW impact_signal — back-compat shim (Q1 / OQ-7)
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW impact_signal AS
SELECT
  id,
  ext_id,
  category,
  source,
  severity,
  title_en,
  title_ar,
  description_en,
  description_ar,
  affected_clause_categories,
  published_date,
  effective_date,
  compliance_deadline,
  is_seed,
  created_at,
  updated_at,
  created_by,
  updated_by,
  is_active
FROM osint_signal;

COMMENT ON VIEW impact_signal IS
  'M7 backward-compat shim (Q1 lock). Exposes the original 19 R-LC columns over the renamed osint_signal table. R-LC fn_''s (fn_impact_signal_list / _get / _bulk_amend / _mark_reviewed / _notify_drafters) read this view without rewrite (AC-S2-03 + AC-S2-05).';

-- ----------------------------------------------------------------
-- (h) COMMENTs on osint_signal
-- ----------------------------------------------------------------
COMMENT ON TABLE osint_signal IS
  'M7 normalised signal store per Annex B.2.1 (renamed from R-LC impact_signal — Q1 lock). STRATEGY-A preserve-superset: R-LC columns retained physically as nullable additions; Annex columns added. View `impact_signal` exposes the original R-LC shape for FE/BE backward-compat (R-LC fn_''s require zero rewrite). Tenant-scoped via app.current_tenant_id GUC. Writes ONLY via DEFINER fn_osint_signal_upsert (RESTRICTIVE INSERT/UPDATE/DELETE-deny RLS).';
COMMENT ON COLUMN osint_signal.signal_kind_subtype IS
  'Discriminator. ''manual_curated'' for the R-LC seed rows (Q1 backfill). NULL or specific tags (milestone_slippage / sla_breach) for live OSINT.';
COMMENT ON COLUMN osint_signal.dedup_hash IS
  'sha256(source_id || ''|'' || isoformat(event_date OR fetched_at) || ''|'' || lower(trim(title))). Canonical algorithm — every adapter MUST compute identically (mismatch breaks idempotency). UNIQUE(tenant_id, dedup_hash) enforces upsert idempotency.';
COMMENT ON COLUMN osint_signal.raw_payload IS
  'SENSITIVE — original source payload. OFAC SDN entries may include personal data (names/addresses/DOBs). Listed in project.config.json sensitiveFields (AE3) AND fn_audit_trigger redact list (AE1).';
COMMENT ON COLUMN osint_signal.severity_v2 IS
  'Annex B.2.1 Severity enum (informational/low/medium/high/critical). The original R-LC `severity` text column is retained for backward-compat — both columns coexist. The view `impact_signal` exposes the R-LC `severity` (free-text); fn_osint_signal_list reads `severity_v2`.';
COMMENT ON COLUMN osint_signal.event_date_v2 IS
  'Annex B.2.1 TIMESTAMPTZ. The original R-LC `effective_date DATE` column is retained for backward-compat. Live OSINT inserts populate event_date_v2; R-LC view exposes effective_date.';

-- ----------------------------------------------------------------
-- (i) Verify FK on impact_signal_contract.signal_id_fkey auto-redirected
--     PostgreSQL handles this automatically via RENAME — verification block.
--     Raises notice (does not abort migration; verification probe in DB Impl will confirm).
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_fk_def TEXT;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_fk_def
  FROM pg_constraint c
  JOIN pg_class cl ON cl.oid = c.conrelid
  WHERE cl.relname = 'impact_signal_contract'
    AND c.conname = 'impact_signal_contract_signal_id_fkey';

  IF v_fk_def IS NULL THEN
    RAISE NOTICE 'impact_signal_contract_signal_id_fkey not found — verify manually.';
  ELSIF v_fk_def NOT LIKE '%REFERENCES osint_signal(%' THEN
    RAISE EXCEPTION 'impact_signal_contract_signal_id_fkey did NOT auto-redirect to osint_signal: %', v_fk_def
      USING ERRCODE = '0A000';
  ELSE
    RAISE NOTICE 'impact_signal_contract_signal_id_fkey verified: %', v_fk_def;
  END IF;
END $$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (104, 'm7_rename_impact_signal_to_osint_signal', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP VIEW IF EXISTS impact_signal;
-- ALTER TABLE osint_signal DROP CONSTRAINT IF EXISTS osint_signal_tenant_dedup_key;
-- ALTER TABLE osint_signal DROP CONSTRAINT IF EXISTS osint_signal_tenant_id_fkey;
-- DROP INDEX IF EXISTS idx_osint_signal_osint_source_id;
-- DROP INDEX IF EXISTS idx_osint_signal_affected_entities_gin;
-- DROP INDEX IF EXISTS idx_osint_signal_geographies_gin;
-- DROP INDEX IF EXISTS idx_osint_signal_tenant_source_event;
-- DROP INDEX IF EXISTS idx_osint_signal_tenant_kind_severity;
-- DROP INDEX IF EXISTS idx_osint_signal_tenant_fetched_at;
-- DROP POLICY IF EXISTS osint_signal_tenant_isolation_select ON osint_signal;
-- DROP POLICY IF EXISTS osint_signal_deny_direct_insert ON osint_signal;
-- DROP POLICY IF EXISTS osint_signal_deny_direct_update ON osint_signal;
-- DROP POLICY IF EXISTS osint_signal_deny_direct_delete ON osint_signal;
-- ALTER TABLE osint_signal DROP COLUMN data_classification, DROP COLUMN dedup_hash,
--   DROP COLUMN raw_payload, DROP COLUMN url, DROP COLUMN confidence, DROP COLUMN severity_v2,
--   DROP COLUMN affected_entities, DROP COLUMN geographies, DROP COLUMN summary, DROP COLUMN title,
--   DROP COLUMN signal_kind_subtype, DROP COLUMN kind, DROP COLUMN event_date_v2,
--   DROP COLUMN fetched_at, DROP COLUMN source_reliability, DROP COLUMN source_id,
--   DROP COLUMN osint_source_id, DROP COLUMN tenant_id;
-- ALTER TRIGGER audit_osint_signal_changes ON osint_signal RENAME TO audit_impact_signal_changes;
-- ALTER TABLE osint_signal RENAME TO impact_signal;
-- DELETE FROM schema_migrations WHERE version = 104;
-- COMMIT;
-- ============================================================
