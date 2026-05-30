-- Migration: 340_cru_v15_seed_module_catalog.sql
-- Module: CR-U — Product Module Toggle (wave v1.5)
-- Description: Seeds 33 product_module rows (12 CLM + 15 ECIP + 6 PLATFORM).
--              default_role_codes uses role.name strings — the role identifier
--              column in this schema is role.name (confirmed via 001_foundation.sql:70
--              and DB query against the role table). Role values align 1:1 with
--              the 14 active roles seeded across M1a..CR-G migrations:
--                Super Admin, platform_admin, contract_drafter, legal_counsel,
--                contract_approver, contract_approver_2, contract_recipient,
--                executive, operations, finance_treasury, compliance_esg,
--                procurement_supplier_risk (+ Admin/User legacy, not used here).
--              Catalog is idempotent: ON CONFLICT (key) DO NOTHING.
--              CLM display_order block: 100-210 (12 modules)
--              ECIP display_order block: 300-440 (15 modules)
--              PLATFORM display_order block: 500-560 (6 modules, all is_core=TRUE)
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_actor BIGINT;
BEGIN
  SELECT MIN(u.id) INTO v_actor
  FROM "user" u
  JOIN role r ON r.id = u.role_id
  WHERE r.name = 'Super Admin' AND u.is_active = TRUE AND r.is_active = TRUE;
  PERFORM set_config('app.current_user_id', COALESCE(v_actor::text, ''), false);

  -- ============================================================================
  -- CLM bundle (12 modules — display_order 100-210)
  -- ============================================================================
  INSERT INTO product_module (
    key, bundle_code, parent_key, label_key, sidebar_path,
    owned_route_prefixes, owned_permission_prefixes, default_role_codes,
    default_enabled, is_core, display_order, created_by, updated_by
  ) VALUES
    ('contracts.browse', 'clm', NULL,
     'admin.modules.clm.contracts_browse', '/app/contracts',
     '["/api/v1/contracts"]'::jsonb,
     '["contract.read."]'::jsonb,
     '["Super Admin","platform_admin","contract_drafter","legal_counsel","contract_approver","contract_approver_2","contract_recipient","executive","operations","finance_treasury","compliance_esg","procurement_supplier_risk"]'::jsonb,
     TRUE, FALSE, 100, v_actor, v_actor),

    ('contracts.compose', 'clm', 'contracts.browse',
     'admin.modules.clm.contracts_compose', '/app/contracts/compose',
     '["/api/v1/contracts/compose","/api/v1/contracts/new"]'::jsonb,
     '["contract.draft","contract.edit"]'::jsonb,
     '["Super Admin","contract_drafter","legal_counsel","platform_admin"]'::jsonb,
     TRUE, FALSE, 110, v_actor, v_actor),

    ('templates', 'clm', NULL,
     'admin.modules.clm.templates', '/app/templates',
     '["/api/v1/templates"]'::jsonb,
     '["contract.read."]'::jsonb,
     '["Super Admin","platform_admin","contract_drafter","legal_counsel"]'::jsonb,
     TRUE, FALSE, 120, v_actor, v_actor),

    ('clauses', 'clm', NULL,
     'admin.modules.clm.clauses', '/app/clauses',
     '["/api/v1/clauses","/api/v1/clause-extraction","/api/v1/clause-review"]'::jsonb,
     '["clause."]'::jsonb,
     '["Super Admin","platform_admin","contract_drafter","legal_counsel"]'::jsonb,
     TRUE, FALSE, 130, v_actor, v_actor),

    ('parties', 'clm', NULL,
     'admin.modules.clm.parties', '/app/parties',
     '["/api/v1/parties"]'::jsonb,
     '["party."]'::jsonb,
     '["Super Admin","platform_admin","contract_drafter","legal_counsel"]'::jsonb,
     TRUE, FALSE, 140, v_actor, v_actor),

    ('obligations', 'clm', NULL,
     'admin.modules.clm.obligations', '/app/obligations',
     '["/api/v1/obligations"]'::jsonb,
     '["obligation."]'::jsonb,
     '["Super Admin","contract_drafter","legal_counsel"]'::jsonb,
     TRUE, FALSE, 150, v_actor, v_actor),

    ('regulations', 'clm', NULL,
     'admin.modules.clm.regulations', '/app/regulations',
     '["/api/v1/regulations","/api/v1/regulatory-updates","/api/v1/regulatory-impacts"]'::jsonb,
     '["regulations."]'::jsonb,
     '["Super Admin","platform_admin","legal_counsel","contract_drafter","contract_approver","contract_approver_2","executive","compliance_esg"]'::jsonb,
     TRUE, FALSE, 160, v_actor, v_actor),

    ('regulatory_radar', 'clm', 'regulations',
     'admin.modules.clm.regulatory_radar', '/app/regulatory-radar',
     '["/api/v1/regulatory-radar"]'::jsonb,
     '["regulations."]'::jsonb,
     '["Super Admin","legal_counsel","compliance_esg"]'::jsonb,
     TRUE, FALSE, 170, v_actor, v_actor),

    ('approvals', 'clm', NULL,
     'admin.modules.clm.approvals', '/app/approvals',
     '["/api/v1/approvals"]'::jsonb,
     '["approval."]'::jsonb,
     '["Super Admin","legal_counsel","contract_approver","contract_approver_2"]'::jsonb,
     TRUE, FALSE, 180, v_actor, v_actor),

    ('queue', 'clm', 'approvals',
     'admin.modules.clm.queue', '/app/queue',
     '["/api/v1/queue"]'::jsonb,
     '["approval.","signature."]'::jsonb,
     '["Super Admin","contract_approver","contract_approver_2"]'::jsonb,
     TRUE, FALSE, 190, v_actor, v_actor),

    ('signatures', 'clm', NULL,
     'admin.modules.clm.signatures', NULL,
     '["/api/v1/sign","/api/v1/signature-parties","/api/v1/signature-invitations"]'::jsonb,
     '["signature."]'::jsonb,
     '["Super Admin","platform_admin","contract_drafter","legal_counsel","contract_approver","contract_approver_2","contract_recipient"]'::jsonb,
     TRUE, FALSE, 200, v_actor, v_actor),

    ('imports', 'clm', 'contracts.compose',
     'admin.modules.clm.imports', '/app/imports/bulk',
     '["/api/v1/import-batches","/api/v1/admin/imports"]'::jsonb,
     '["contract.draft"]'::jsonb,
     '["Super Admin","platform_admin","contract_drafter"]'::jsonb,
     TRUE, FALSE, 210, v_actor, v_actor)
  ON CONFLICT (key) DO NOTHING;

  -- ============================================================================
  -- ECIP bundle (15 modules — display_order 300-440)
  -- ============================================================================
  INSERT INTO product_module (
    key, bundle_code, parent_key, label_key, sidebar_path,
    owned_route_prefixes, owned_permission_prefixes, default_role_codes,
    default_enabled, is_core, display_order, created_by, updated_by
  ) VALUES
    ('insights_hub', 'ecip', NULL,
     'admin.modules.ecip.insights_hub', '/app/dashboards/insights',
     '["/api/v1/dashboards"]'::jsonb,
     '["insights."]'::jsonb,
     '["Super Admin","platform_admin","contract_drafter","legal_counsel","contract_approver","contract_approver_2","executive","operations","finance_treasury","compliance_esg","procurement_supplier_risk"]'::jsonb,
     TRUE, FALSE, 300, v_actor, v_actor),

    ('dashboards.executive', 'ecip', 'insights_hub',
     'admin.modules.ecip.dashboards_executive', '/app/dashboards/executive',
     '["/api/v1/dashboards/executive"]'::jsonb,
     '["insights.executive"]'::jsonb,
     '["Super Admin","platform_admin","executive"]'::jsonb,
     TRUE, FALSE, 310, v_actor, v_actor),

    ('dashboards.operations', 'ecip', 'insights_hub',
     'admin.modules.ecip.dashboards_operations', '/app/dashboards/operations',
     '["/api/v1/dashboards-crg/operations","/api/v1/dashboards/operations"]'::jsonb,
     '["insights.operations"]'::jsonb,
     '["Super Admin","platform_admin","operations"]'::jsonb,
     TRUE, FALSE, 320, v_actor, v_actor),

    ('dashboards.finance_treasury', 'ecip', 'insights_hub',
     'admin.modules.ecip.dashboards_finance_treasury', '/app/dashboards/finance-treasury',
     '["/api/v1/dashboards-crg/finance-treasury","/api/v1/dashboards/finance-treasury"]'::jsonb,
     '["insights.finance_treasury"]'::jsonb,
     '["Super Admin","platform_admin","finance_treasury"]'::jsonb,
     TRUE, FALSE, 330, v_actor, v_actor),

    ('dashboards.compliance_esg', 'ecip', 'insights_hub',
     'admin.modules.ecip.dashboards_compliance_esg', '/app/dashboards/compliance-esg',
     '["/api/v1/dashboards-crg/compliance-esg","/api/v1/dashboards/compliance-esg"]'::jsonb,
     '["insights.compliance_esg"]'::jsonb,
     '["Super Admin","platform_admin","compliance_esg"]'::jsonb,
     TRUE, FALSE, 340, v_actor, v_actor),

    ('dashboards.procurement', 'ecip', 'insights_hub',
     'admin.modules.ecip.dashboards_procurement', '/app/dashboards/procurement',
     '["/api/v1/dashboards-crg/procurement","/api/v1/dashboards/procurement"]'::jsonb,
     '["insights.procurement_supplier_risk"]'::jsonb,
     '["Super Admin","platform_admin","procurement_supplier_risk","contract_drafter","contract_approver","contract_approver_2"]'::jsonb,
     TRUE, FALSE, 350, v_actor, v_actor),

    ('impact_signals', 'ecip', NULL,
     'admin.modules.ecip.impact_signals', NULL,
     '["/api/v1/internal-signals","/api/v1/signals","/api/v1/admin-sources","/api/v1/admin/internal-signals","/api/v1/admin/sources"]'::jsonb,
     '["signal.","internal_signal.","source."]'::jsonb,
     '["Super Admin","platform_admin","legal_counsel","executive","operations","finance_treasury","compliance_esg"]'::jsonb,
     TRUE, FALSE, 360, v_actor, v_actor),

    ('advisory_queue', 'ecip', NULL,
     'admin.modules.ecip.advisory_queue', '/app/legal/advisory-queue',
     '["/api/v1/advisory-drafts"]'::jsonb,
     '["advisory."]'::jsonb,
     '["Super Admin","platform_admin","legal_counsel"]'::jsonb,
     TRUE, FALSE, 370, v_actor, v_actor),

    ('risk_cases', 'ecip', NULL,
     'admin.modules.ecip.risk_cases', '/app/risk-cases',
     '["/api/v1/risk-cases"]'::jsonb,
     '["risk.case."]'::jsonb,
     '["Super Admin","platform_admin","contract_drafter","contract_approver","contract_approver_2","legal_counsel","executive","operations","finance_treasury","compliance_esg","procurement_supplier_risk"]'::jsonb,
     TRUE, FALSE, 380, v_actor, v_actor),

    ('reports', 'ecip', NULL,
     'admin.modules.ecip.reports', '/app/reports',
     '["/api/v1/reports"]'::jsonb,
     '[]'::jsonb,
     '["Super Admin","platform_admin","contract_drafter","contract_approver","contract_approver_2","contract_recipient","legal_counsel","executive","operations","finance_treasury","compliance_esg","procurement_supplier_risk"]'::jsonb,
     TRUE, FALSE, 390, v_actor, v_actor),

    ('regulatory_cascade', 'ecip', NULL,
     'admin.modules.ecip.regulatory_cascade', '/app/compliance/regulatory-cascade',
     '["/api/v1/compliance-actions/regulatory-cascade","/api/v1/regulatory-cascade"]'::jsonb,
     '["regulatory.cascade."]'::jsonb,
     '["Super Admin","platform_admin","legal_counsel","executive","compliance_esg","procurement_supplier_risk"]'::jsonb,
     TRUE, FALSE, 400, v_actor, v_actor),

    ('financial.budget_burn', 'ecip', NULL,
     'admin.modules.ecip.financial_budget_burn', '/app/financial/budget-burn',
     '["/api/v1/financial-budget-burn","/api/v1/financial/budget-burn"]'::jsonb,
     '["finance.budget."]'::jsonb,
     '["Super Admin","platform_admin","legal_counsel","executive","operations","finance_treasury","procurement_supplier_risk"]'::jsonb,
     TRUE, FALSE, 410, v_actor, v_actor),

    ('financial.trade_margin', 'ecip', NULL,
     'admin.modules.ecip.financial_trade_margin', '/app/financial/trade-margin',
     '["/api/v1/financial-trade-margin","/api/v1/financial/trade-margin"]'::jsonb,
     '["finance.margin.","finance.trade."]'::jsonb,
     '["Super Admin","platform_admin","executive","finance_treasury"]'::jsonb,
     TRUE, FALSE, 420, v_actor, v_actor),

    ('ai_risk_assistant', 'ecip', 'insights_hub',
     'admin.modules.ecip.ai_risk_assistant', NULL,
     '["/api/v1/ai-risk-assistant"]'::jsonb,
     '["ai.invoke.risk_assistant"]'::jsonb,
     '["Super Admin","platform_admin","executive","operations","finance_treasury","compliance_esg","procurement_supplier_risk"]'::jsonb,
     TRUE, FALSE, 430, v_actor, v_actor),

    ('demo_harness', 'ecip', NULL,
     'admin.modules.ecip.demo_harness', '/app/admin/demo',
     '["/api/v1/admin/demo"]'::jsonb,
     '["demo."]'::jsonb,
     '["Super Admin","platform_admin"]'::jsonb,
     TRUE, FALSE, 440, v_actor, v_actor)
  ON CONFLICT (key) DO NOTHING;

  -- ============================================================================
  -- PLATFORM bundle (6 modules — all is_core=TRUE — display_order 500-560)
  -- ============================================================================
  INSERT INTO product_module (
    key, bundle_code, parent_key, label_key, sidebar_path,
    owned_route_prefixes, owned_permission_prefixes, default_role_codes,
    default_enabled, is_core, display_order, created_by, updated_by
  ) VALUES
    ('admin', 'platform', NULL,
     'admin.modules.platform.admin', '/app/admin',
     '["/api/v1/admin"]'::jsonb,
     '["admin."]'::jsonb,
     '["Super Admin","platform_admin"]'::jsonb,
     TRUE, TRUE, 500, v_actor, v_actor),

    ('users_roles', 'platform', 'admin',
     'admin.modules.platform.users_roles', '/app/admin/users',
     '["/api/v1/users","/api/v1/roles","/api/v1/permission"]'::jsonb,
     '["user.","role."]'::jsonb,
     '["Super Admin","platform_admin"]'::jsonb,
     TRUE, TRUE, 510, v_actor, v_actor),

    ('audit', 'platform', 'admin',
     'admin.modules.platform.audit', '/app/admin/audit',
     '["/api/v1/admin/audit"]'::jsonb,
     '["audit."]'::jsonb,
     '["Super Admin","platform_admin"]'::jsonb,
     TRUE, TRUE, 520, v_actor, v_actor),

    ('settings', 'platform', 'admin',
     'admin.modules.platform.settings', '/app/admin/config',
     '["/api/v1/admin/config","/api/v1/admin/email-config","/api/v1/admin/tenants"]'::jsonb,
     '["settings."]'::jsonb,
     '["Super Admin","platform_admin"]'::jsonb,
     TRUE, TRUE, 530, v_actor, v_actor),

    ('branding', 'platform', 'admin',
     'admin.modules.platform.branding', '/app/admin/branding',
     '["/api/v1/admin/branding","/api/v1/admin/email-templates"]'::jsonb,
     '["branding.","notification.template."]'::jsonb,
     '["Super Admin","platform_admin"]'::jsonb,
     TRUE, TRUE, 540, v_actor, v_actor),

    ('profile', 'platform', NULL,
     'admin.modules.platform.profile', '/app/settings',
     '["/api/v1/auth/me","/api/v1/profile"]'::jsonb,
     '["notification.preferences."]'::jsonb,
     '["Super Admin","platform_admin","contract_drafter","legal_counsel","contract_approver","contract_approver_2","contract_recipient","executive","operations","finance_treasury","compliance_esg","procurement_supplier_risk"]'::jsonb,
     TRUE, TRUE, 560, v_actor, v_actor)
  ON CONFLICT (key) DO NOTHING;

  RAISE NOTICE '340: product_module seeded (expected 33 rows = 12 CLM + 15 ECIP + 6 PLATFORM).';
END;
$$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (340, 'cru_v15_seed_module_catalog', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
-- DELETE FROM product_module WHERE bundle_code IN ('clm','ecip','platform');
-- DELETE FROM schema_migrations WHERE version = 340;
-- COMMIT;
-- ROLLBACK END
