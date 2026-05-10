-- Migration: 114_crb_extend_party.sql
-- Module: M9 — Counterparty Graph (CR-B)
-- Description: ALTER TABLE party ADD 11 columns for graph + sanctions + ESG/ICV + aliases.
--              Add 6 indexes (incl. GIN trigram on name_en for fuzzy match NFR).
--              No data migration required (defaults safe for existing rows).
-- Rollback: ALTER TABLE party DROP COLUMN ... × 11; DROP INDEX × 6.

BEGIN;

-- 1. Add 11 columns (additive; existing rows take defaults)
ALTER TABLE party
  ADD COLUMN parent_id                 BIGINT       NULL
    REFERENCES party(id) ON DELETE SET NULL,
  ADD COLUMN ubo_id                    BIGINT       NULL
    REFERENCES party(id) ON DELETE SET NULL,
  ADD COLUMN sanctions_status          TEXT         NOT NULL DEFAULT 'clean'
    CHECK (sanctions_status IN ('clean','flagged','sanctioned','under_review')),
  ADD COLUMN sanctions_last_checked    TIMESTAMPTZ  NULL,
  ADD COLUMN sanctions_match_signal_id BIGINT       NULL
    REFERENCES osint_signal(id) ON DELETE SET NULL,
  ADD COLUMN esg_score                 INTEGER      NULL
    CHECK (esg_score IS NULL OR (esg_score BETWEEN 0 AND 100)),
  ADD COLUMN icv_status                TEXT         NULL
    CHECK (icv_status IS NULL OR icv_status IN ('certified','expired','downgraded','pending','none')),
  ADD COLUMN icv_pct                   NUMERIC(5,2) NULL
    CHECK (icv_pct IS NULL OR (icv_pct BETWEEN 0 AND 100)),
  ADD COLUMN icv_last_checked          TIMESTAMPTZ  NULL,
  ADD COLUMN aliases                   JSONB        NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN metadata                  JSONB        NOT NULL DEFAULT '{}'::jsonb;

-- 2. Self-FK row-level guards (CHECK works because parent_id/ubo_id are nullable)
ALTER TABLE party
  ADD CONSTRAINT party_no_self_parent CHECK (parent_id IS NULL OR parent_id <> id),
  ADD CONSTRAINT party_no_self_ubo    CHECK (ubo_id    IS NULL OR ubo_id    <> id);

-- 3. Indexes
-- 3a. GIN trigram on name_en for pg_trgm.similarity matching (sanctions match NFR)
CREATE INDEX IF NOT EXISTS idx_party_name_en_trgm
  ON party USING GIN (name_en gin_trgm_ops);

-- 3b. GIN jsonb_path_ops on aliases for fast contains lookups
CREATE INDEX IF NOT EXISTS idx_party_aliases_gin
  ON party USING GIN (aliases jsonb_path_ops);

-- 3c. Partial btree on parent_id for traverse_up seed + "children of X" counts
CREATE INDEX IF NOT EXISTS idx_party_parent_id
  ON party(parent_id) WHERE is_active = TRUE AND parent_id IS NOT NULL;

-- 3d. Partial btree on ubo_id for UBO-direct lookups
CREATE INDEX IF NOT EXISTS idx_party_ubo_id
  ON party(ubo_id) WHERE is_active = TRUE AND ubo_id IS NOT NULL;

-- 3e. Partial btree on sanctions_status (compliance dashboards filter on flagged set)
CREATE INDEX IF NOT EXISTS idx_party_sanctions_flagged
  ON party(sanctions_status) WHERE is_active = TRUE AND sanctions_status <> 'clean';

-- 3f. FK btree on sanctions_match_signal_id (M7 S2-7 lesson)
CREATE INDEX IF NOT EXISTS idx_party_sanctions_match_signal_id
  ON party(sanctions_match_signal_id) WHERE sanctions_match_signal_id IS NOT NULL;

-- 4. COMMENT ON COLUMN — new columns
COMMENT ON COLUMN party.parent_id                 IS 'M9 — direct parent party (self-FK). Single-tenant. Cycle prevention via traversal-time depth cap, not DDL.';
COMMENT ON COLUMN party.ubo_id                    IS 'M9 — ultimate beneficial owner shortcut. Often >1 hop above parent_id; populated for top of chain.';
COMMENT ON COLUMN party.sanctions_status          IS 'M9 — clean | flagged | sanctioned | under_review. Read-only from FE; written ONLY by CR-E rule engine via separate DEFINER fn (HITL Q4).';
COMMENT ON COLUMN party.sanctions_last_checked    IS 'M9 — when sanctions_status was last evaluated. Surfaces freshness label in FE party header.';
COMMENT ON COLUMN party.sanctions_match_signal_id IS 'M9 — FK -> osint_signal.id for source-traceability (Production-Credibility Invariant #8).';
COMMENT ON COLUMN party.esg_score                 IS 'M9 — 0..100 ESG rating. Manual entry in v1; D&B/Sayari import deferred to pilot.';
COMMENT ON COLUMN party.icv_status                IS 'M9 — UAE In-Country Value certification: certified | expired | downgraded | pending | none.';
COMMENT ON COLUMN party.icv_pct                   IS 'M9 — ICV percentage 0..100. Surfaced alongside icv_status badge.';
COMMENT ON COLUMN party.icv_last_checked          IS 'M9 — freshness stamp for ICV badge.';
COMMENT ON COLUMN party.aliases                   IS 'M9 — JSONB array of alternative names for fuzzy entity matching against sanctions lists. SENSITIVE — may carry UBO personal names; redacted by fn_audit_trigger (116).';
COMMENT ON COLUMN party.metadata                  IS 'M9 — extensible JSONB bag for future fields (insurance metadata deferred). SENSITIVE — pre-emptive audit redact applied.';

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (114, 'crb_extend_party', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP INDEX IF EXISTS idx_party_sanctions_match_signal_id;
-- DROP INDEX IF EXISTS idx_party_sanctions_flagged;
-- DROP INDEX IF EXISTS idx_party_ubo_id;
-- DROP INDEX IF EXISTS idx_party_parent_id;
-- DROP INDEX IF EXISTS idx_party_aliases_gin;
-- DROP INDEX IF EXISTS idx_party_name_en_trgm;
-- ALTER TABLE party DROP CONSTRAINT IF EXISTS party_no_self_parent;
-- ALTER TABLE party DROP CONSTRAINT IF EXISTS party_no_self_ubo;
-- ALTER TABLE party
--   DROP COLUMN IF EXISTS metadata,
--   DROP COLUMN IF EXISTS aliases,
--   DROP COLUMN IF EXISTS icv_last_checked,
--   DROP COLUMN IF EXISTS icv_pct,
--   DROP COLUMN IF EXISTS icv_status,
--   DROP COLUMN IF EXISTS esg_score,
--   DROP COLUMN IF EXISTS sanctions_match_signal_id,
--   DROP COLUMN IF EXISTS sanctions_last_checked,
--   DROP COLUMN IF EXISTS sanctions_status,
--   DROP COLUMN IF EXISTS ubo_id,
--   DROP COLUMN IF EXISTS parent_id;
-- DELETE FROM schema_migrations WHERE version = 114;
-- COMMIT;
