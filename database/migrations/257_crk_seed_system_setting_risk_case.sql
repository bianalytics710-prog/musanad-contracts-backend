-- Migration: 257_crk_seed_system_setting_risk_case.sql
-- Module: M19 — CR-K Risk Cases
-- CR: CR-K
-- Date: 2026-05-15
-- Description: Seed 3 system_setting rows for CR-K matrices: escalation_matrix,
--              risk_case_visibility_map, accept_risk_approval_matrix.
--              category='risk_case' (10th value added by mig 252).
-- ADAPTATION NOTE (DEFECT-CRKL-DB-A4): Design §7.3 INSERT references
--              data_classification column — that column does NOT exist on
--              system_setting (verified at apply time). Adapted by omitting
--              that column; using is_secret=FALSE instead.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO system_setting (key, value, description, category, is_secret) VALUES
  ('escalation_matrix',
   '{"priorities":{"critical":{"operations":{"next":"executive"},"finance_treasury":{"next":"executive"},"compliance_esg":{"next":"executive"},"legal_counsel":{"next":"executive"},"executive":{"next":null},"platform_admin":{"next":null}},"high":{"operations":{"next":"legal_counsel"},"finance_treasury":{"next":"legal_counsel"},"compliance_esg":{"next":"legal_counsel"},"legal_counsel":{"next":"executive"},"executive":{"next":null}},"medium":{"operations":{"next":"compliance_esg"},"finance_treasury":{"next":"compliance_esg"},"compliance_esg":{"next":"legal_counsel"}},"low":{"operations":{"next":null}}}}'::jsonb,
   'Per-priority + per-role escalation routing. Used by fn_risk_case_escalate. Terminates at top-of-org. CR-C admin-editable.',
   'risk_case', FALSE),
  ('risk_case_visibility_map',
   '{"operations":["sla_breach","correlation_alert","system","manual"],"finance_treasury":["correlation_alert","system","manual"],"compliance_esg":["correlation_alert","sla_breach","system","manual"],"legal_counsel":["correlation_alert","obligation_due","manual"],"executive":["*"],"platform_admin":["*"],"Super Admin":["*"],"contract_drafter":["manual"],"contract_approver":["manual"],"contract_approver_2":["manual","correlation_alert"]}'::jsonb,
   'Per-role case_type visibility map. fn_risk_case_list consults this when assigned_role/_user_id are NULL.',
   'risk_case', FALSE),
  ('accept_risk_approval_matrix',
   '{"priorities":{"critical":"executive","high":"legal_counsel","medium":"operations","low":"operations"}}'::jsonb,
   'Per-priority required-role for risk acceptance. Used by fn_risk_case_accept_risk. HITL Q2 lock.',
   'risk_case', FALSE)
ON CONFLICT (key) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (257, '257_crk_seed_system_setting_risk_case', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM system_setting WHERE key IN ('escalation_matrix','risk_case_visibility_map','accept_risk_approval_matrix') AND category='risk_case';
-- DELETE FROM schema_migrations WHERE version = 257;
-- ============================================================
