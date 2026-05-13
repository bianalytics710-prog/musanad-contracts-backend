-- Migration: 178_crg_permissions_seed.sql
-- Module: M15 — CR-G (Executive Decision Support Evolution + 4 Persona Dashboards + AI Risk Assistant)
-- Description: Seed 5 net-new permission rows for CR-G dashboard personas and AI Risk Assistant
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO permission (code, module, action, description) VALUES
  ('insights.operations',               'dashboard', 'read',   'CR-G: View the Operations & SLA dashboard'),
  ('insights.finance_treasury',         'dashboard', 'read',   'CR-G: View the Finance & Treasury dashboard'),
  ('insights.compliance_esg',           'dashboard', 'read',   'CR-G: View the Compliance & ESG dashboard'),
  ('insights.procurement_supplier_risk','dashboard', 'read',   'CR-G: View the Procurement supplier-risk dashboard'),
  ('ai.invoke.risk_assistant',          'ai',        'invoke', 'CR-G: Invoke the AI Risk Assistant SSE Q&A endpoint')
ON CONFLICT (code) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (178, '178_crg_permissions_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 178;
-- DELETE FROM permission WHERE code IN (
--   'insights.operations',
--   'insights.finance_treasury',
--   'insights.compliance_esg',
--   'insights.procurement_supplier_risk',
--   'ai.invoke.risk_assistant'
-- );
-- ============================================================
