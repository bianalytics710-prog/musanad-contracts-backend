-- Migration: 181_crg_seed_roles_and_grants.sql
-- Module: M15 — CR-G (Executive Decision Support Evolution + 4 Persona Dashboards + AI Risk Assistant)
-- Description: Seed 3 new role rows (operations, finance_treasury, compliance_esg) + native per-role
--              permission grants (9 for ops, 9 for finance_treasury, 12 for compliance_esg = 30 total)
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Role rows
INSERT INTO role (name, description, is_active) VALUES
  ('operations',        'CR-G: Operations & SLA persona',       TRUE),
  ('finance_treasury',  'CR-G: Finance & Treasury persona',     TRUE),
  ('compliance_esg',    'CR-G: Compliance & ESG persona',       TRUE)
ON CONFLICT (name) DO NOTHING;

-- Native per-role grants (idempotent)
WITH r AS (SELECT id, name FROM role WHERE name IN ('operations','finance_treasury','compliance_esg')),
     p AS (SELECT id, code FROM permission)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM r CROSS JOIN p
 WHERE (r.name = 'operations'       AND p.code IN (
                                                    'insights.operations',
                                                    'signal.read.all',
                                                    'correlation.read',
                                                    'clause.search',
                                                    'score.read',
                                                    'ai.invoke.risk_assistant',
                                                    'risk.acknowledge',
                                                    'internal_signal.read',
                                                    'internal_signal.resolve'))
    OR (r.name = 'finance_treasury' AND p.code IN (
                                                    'insights.finance_treasury',
                                                    'signal.read.all',
                                                    'correlation.read',
                                                    'clause.search',
                                                    'score.read',
                                                    'ai.invoke.risk_assistant',
                                                    'risk.acknowledge',
                                                    'internal_signal.read',
                                                    'internal_signal.resolve'))
    OR (r.name = 'compliance_esg'   AND p.code IN (
                                                    'insights.compliance_esg',
                                                    'signal.read.all',
                                                    'correlation.read',
                                                    'correlation.dismiss',
                                                    'clause.search',
                                                    'clause.taxonomy.read',
                                                    'score.read',
                                                    'ai.invoke.risk_assistant',
                                                    'risk.acknowledge',
                                                    'internal_signal.read',
                                                    'internal_signal.resolve',
                                                    'party.graph.read'))
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (181, '181_crg_seed_roles_and_grants', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 181;
-- DELETE FROM role_permission WHERE role_id IN (SELECT id FROM role WHERE name IN ('operations','finance_treasury','compliance_esg'));
-- DELETE FROM role WHERE name IN ('operations','finance_treasury','compliance_esg');
-- ============================================================
