-- Migration: 182_crg_preemptive_grants_backfill.sql
-- Module: M15 — CR-G (Executive Decision Support Evolution + 4 Persona Dashboards + AI Risk Assistant)
-- Description: Idempotent re-assertion of grants that M7/M8/M9/M12/M13/M14 migrations attempted to
--              INSERT via WHERE EXISTS (SELECT 1 FROM role WHERE name=...) and got 0 rows because
--              the roles didn't exist at that time. All rows also appear in migration 181's native
--              grant set — ON CONFLICT makes them no-ops if 181 already applied them.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

WITH grants AS (
  SELECT 'operations'::text       AS role_name, code FROM (VALUES
    ('internal_signal.read'),
    ('internal_signal.resolve'),
    ('signal.read.all'),
    ('correlation.read'),
    ('clause.search'),
    ('score.read'),
    ('risk.acknowledge')
  ) AS x(code)
  UNION ALL
  SELECT 'finance_treasury'::text, code FROM (VALUES
    ('internal_signal.read'),
    ('internal_signal.resolve'),
    ('signal.read.all'),
    ('correlation.read'),
    ('clause.search'),
    ('score.read'),
    ('risk.acknowledge')
  ) AS x(code)
  UNION ALL
  SELECT 'compliance_esg'::text,   code FROM (VALUES
    ('signal.read.all'),
    ('internal_signal.read'),
    ('internal_signal.resolve'),
    ('party.graph.read'),
    ('clause.taxonomy.read'),
    ('clause.search'),
    ('correlation.read'),
    ('correlation.dismiss'),
    ('risk.acknowledge'),
    ('score.read')
  ) AS x(code)
)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM grants g
  JOIN role       r ON r.name = g.role_name
  JOIN permission p ON p.code = g.code
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (182, '182_crg_preemptive_grants_backfill', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 182;
-- (Role grants covered by 181 rollback — this migration is idempotent with 181)
-- ============================================================
