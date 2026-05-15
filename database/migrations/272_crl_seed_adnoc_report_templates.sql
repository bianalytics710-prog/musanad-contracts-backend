-- Migration: 272_crl_seed_adnoc_report_templates.sql
-- Module: M20 — CR-L Reports & Briefings
-- Date: 2026-05-15
-- Description: Seed 24 ADNOC report_template rows.
--              Tenant: '00000000-0000-0000-0000-000000000001'.
--              HITL Q1: executive_weekly_brief + compliance_sanctions_exposure scheduled.
--              display_name_ar = '[NEEDS TRANSLATION]' placeholder per M14/M15/M16.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO report_template (
  tenant_id, template_id, display_name_en, display_name_ar, description,
  report_kind, data_source, parameter_schema, assigned_roles,
  is_scheduled, schedule_cron, schedule_recipients, enabled, data_classification
) VALUES
  -- Executive (4)
  ('00000000-0000-0000-0000-000000000001'::UUID, 'executive_weekly_brief', 'Executive Weekly Brief', '[NEEDS TRANSLATION]',
   'Weekly executive summary: health score trend, top correlations, risk-case status, pending advisory drafts.',
   'pdf', 'executive_weekly_brief', '{"dateRange":{"start":"","end":""}}'::jsonb, '["executive","platform_admin","Super Admin"]'::jsonb,
   TRUE, '0 9 * * 1', '["executive"]'::jsonb, TRUE, 'restricted'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'executive_monthly_board', 'Executive Monthly Board Report', '[NEEDS TRANSLATION]',
   'Monthly board-pack: rolling health metrics, MAR aggregates, closed-case counts, advisory dispatch counts.',
   'pdf', 'executive_monthly_board', '{"dateRange":{"start":"","end":""}}'::jsonb, '["executive","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'restricted'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'executive_avar_trend', 'AVaR 12-Month Trend', '[NEEDS TRANSLATION]',
   'Monthly Asset Value at Risk series across the past 12 months. Excel-only for chart embedding.',
   'excel', 'executive_avar_trend', '{"dateRange":{"start":"","end":""}}'::jsonb, '["executive","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'restricted'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'executive_top10_exposures', 'Top-10 Exposed Contracts', '[NEEDS TRANSLATION]',
   'Top 10 contracts by health-score risk + MAR value. Both Excel and PDF.',
   'both', 'executive_top10_exposures', '{"dateRange":{"start":"","end":""}}'::jsonb, '["executive","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'restricted'),

  -- Legal Counsel (4)
  ('00000000-0000-0000-0000-000000000001'::UUID, 'legal_advisory_queue', 'Advisory Drafter Queue', '[NEEDS TRANSLATION]',
   'Pending + approved + dispatched advisory drafts, bucketed by age.',
   'excel', 'legal_advisory_queue', '{"dateRange":{"start":"","end":""}}'::jsonb, '["legal_counsel","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'legal_clause_review_backlog', 'Clause Review Backlog', '[NEEDS TRANSLATION]',
   'Extracted clauses pending legal review with age buckets and linked risk cases.',
   'excel', 'legal_clause_review_backlog', '{"dateRange":{"start":"","end":""}}'::jsonb, '["legal_counsel","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'legal_fm_eligibility', 'Force Majeure Eligibility Report', '[NEEDS TRANSLATION]',
   'Contracts flagged by weather.fm_eligible rule with match evidence.',
   'pdf', 'legal_fm_eligibility', '{"dateRange":{"start":"","end":""}}'::jsonb, '["legal_counsel","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'legal_regulatory_digest', 'Regulatory Digest', '[NEEDS TRANSLATION]',
   'OSINT regulatory-category signals over the past period with linked correlations.',
   'pdf', 'legal_regulatory_digest', '{"dateRange":{"start":"","end":""}}'::jsonb, '["legal_counsel","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),

  -- Procurement (4)
  ('00000000-0000-0000-0000-000000000001'::UUID, 'procurement_supplier_scorecard', 'Supplier Risk Scorecard', '[NEEDS TRANSLATION]',
   'Supplier-level aggregate: contract count, average health score, open risk cases.',
   'excel', 'procurement_supplier_scorecard', '{"dateRange":{"start":"","end":""}}'::jsonb, '["contract_approver_2","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'procurement_supplier_scorecard_detail', 'Supplier Scorecard — Drill-down', '[NEEDS TRANSLATION]',
   'Per-supplier contract-level drill-down for one counterparty.',
   'excel', 'procurement_supplier_scorecard_detail', '{"dateRange":{"start":"","end":""}}'::jsonb, '["contract_approver_2","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'procurement_icv_compliance', 'ICV Compliance Report', '[NEEDS TRANSLATION]',
   'In-Country Value compliance bands by contract; drives rectification advisory.',
   'excel', 'procurement_icv_compliance', '{"dateRange":{"start":"","end":""}}'::jsonb, '["contract_approver_2","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'procurement_sla_breach', 'Supplier SLA Breach Report', '[NEEDS TRANSLATION]',
   'Risk cases of case_type=sla_breach: open count, resolved count, avg time-to-resolution.',
   'excel', 'procurement_sla_breach', '{"dateRange":{"start":"","end":""}}'::jsonb, '["contract_approver_2","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),

  -- Operations (3)
  ('00000000-0000-0000-0000-000000000001'::UUID, 'operations_risk_board_snapshot', 'Operations Risk-Board Snapshot', '[NEEDS TRANSLATION]',
   'As-of snapshot of all open operations-assigned cases + top correlations.',
   'pdf', 'operations_risk_board_snapshot', '{"dateRange":{"start":"","end":""}}'::jsonb, '["operations","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'operations_delivery_delay', 'Delivery Delay Report', '[NEEDS TRANSLATION]',
   'Correlations tagged delivery.delay with severity, detection time, remediation status.',
   'excel', 'operations_delivery_delay', '{"dateRange":{"start":"","end":""}}'::jsonb, '["operations","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'operations_penalty_exposure', 'Operational Penalty Exposure', '[NEEDS TRANSLATION]',
   'Penalty exposure aggregated from risk_score.dim_operational and MAR by contract.',
   'excel', 'operations_penalty_exposure', '{"dateRange":{"start":"","end":""}}'::jsonb, '["operations","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),

  -- Finance & Treasury (3)
  ('00000000-0000-0000-0000-000000000001'::UUID, 'finance_fx_exposure', 'FX Exposure Report', '[NEEDS TRANSLATION]',
   'MAR x FX exposure aggregated by contract currency with USD equivalent total.',
   'excel', 'finance_fx_exposure', '{"dateRange":{"start":"","end":""}}'::jsonb, '["finance_treasury","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'finance_price_review_queue', 'Price Review Queue', '[NEEDS TRANSLATION]',
   'Contracts flagged by price_review correlations with upcoming review due-dates.',
   'pdf', 'finance_price_review_queue', '{"dateRange":{"start":"","end":""}}'::jsonb, '["finance_treasury","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'finance_payment_delay', 'Payment Delay Report', '[NEEDS TRANSLATION]',
   'Payment-delay correlations with overdue days and linked risk cases.',
   'excel', 'finance_payment_delay', '{"dateRange":{"start":"","end":""}}'::jsonb, '["finance_treasury","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),

  -- Compliance & ESG (3)
  ('00000000-0000-0000-0000-000000000001'::UUID, 'compliance_sanctions_exposure', 'Sanctions Exposure Report', '[NEEDS TRANSLATION]',
   'OSINT sanctions hits + correlations + linked contracts, severity-bucketed.',
   'pdf', 'compliance_sanctions_exposure', '{"dateRange":{"start":"","end":""}}'::jsonb, '["compliance_esg","platform_admin","Super Admin"]'::jsonb,
   TRUE, '0 6 * * *', '["compliance_esg","executive"]'::jsonb, TRUE, 'restricted'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'compliance_subcontractor_chain', 'Subcontractor Chain Analysis', '[NEEDS TRANSLATION]',
   'Per-contract subcontractor chain depth and correlation density.',
   'excel', 'compliance_subcontractor_chain', '{"dateRange":{"start":"","end":""}}'::jsonb, '["compliance_esg","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'compliance_audit_rights', 'Audit Rights Inventory', '[NEEDS TRANSLATION]',
   'Extracted audit-rights clauses with expiry windows.',
   'excel', 'compliance_audit_rights', '{"dateRange":{"start":"","end":""}}'::jsonb, '["compliance_esg","platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),

  -- Platform Admin (3)
  ('00000000-0000-0000-0000-000000000001'::UUID, 'admin_system_health', 'System Health Report', '[NEEDS TRANSLATION]',
   'OSINT sources, correlation-rule activity, audit-chain status — single PDF snapshot.',
   'pdf', 'admin_system_health', '{"dateRange":{"start":"","end":""}}'::jsonb, '["platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'admin_audit_chain_verification', 'Audit Chain Verification', '[NEEDS TRANSLATION]',
   'Audit-log hash-chain verification status with break detection.',
   'pdf', 'admin_audit_chain_verification', '{"dateRange":{"start":"","end":""}}'::jsonb, '["platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'restricted'),
  ('00000000-0000-0000-0000-000000000001'::UUID, 'admin_source_health_snapshot', 'OSINT Source Health Snapshot', '[NEEDS TRANSLATION]',
   'Per-source signal counts (24h, 7d) and current health state.',
   'excel', 'admin_source_health_snapshot', '{"dateRange":{"start":"","end":""}}'::jsonb, '["platform_admin","Super Admin"]'::jsonb,
   FALSE, NULL, NULL, TRUE, 'internal')
ON CONFLICT (tenant_id, template_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (272, '272_crl_seed_adnoc_report_templates', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM report_template WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::UUID AND template_id IN ('executive_weekly_brief','executive_monthly_board','executive_avar_trend','executive_top10_exposures','legal_advisory_queue','legal_clause_review_backlog','legal_fm_eligibility','legal_regulatory_digest','procurement_supplier_scorecard','procurement_supplier_scorecard_detail','procurement_icv_compliance','procurement_sla_breach','operations_risk_board_snapshot','operations_delivery_delay','operations_penalty_exposure','finance_fx_exposure','finance_price_review_queue','finance_payment_delay','compliance_sanctions_exposure','compliance_subcontractor_chain','compliance_audit_rights','admin_system_health','admin_audit_chain_verification','admin_source_health_snapshot');
-- DELETE FROM schema_migrations WHERE version = 272;
-- ============================================================
