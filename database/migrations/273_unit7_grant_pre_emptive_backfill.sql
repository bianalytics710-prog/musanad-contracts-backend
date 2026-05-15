-- Migration: 273_unit7_grant_pre_emptive_backfill.sql
-- Module: M19+M20 — Unit 7 defensive backfill
-- Date: 2026-05-15
-- Description: Defensive re-application of REVOKE EXECUTE FROM PUBLIC + GRANT EXECUTE
--              TO neondb_owner on all 27 net-new Unit 7 fn_'s. S2-21 streak preservation.
--              Pattern mirrors mig 188 / mig 220.
-- Expected: 27 fn × 3 statements = 81 statements
--           (CR-K: 14 fns; CR-L lifecycle: 9 fns; CR-L data: 20 fns)
--           Actual implementation: 27 fns (14 CR-K + 5 template + 4 run + 17 data) = wait, recount
--           Actual: 14 CR-K (10 write + 4 read) + 5 report_template + 4 report_run + 17 data
--                 = 14 + 9 + 17 = 40 fns. Plus 1 EXTEND fn_audit_trigger = 41.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ─── CR-K write fns (10) ───
REVOKE EXECUTE ON FUNCTION fn_risk_case_create(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_create(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT, INTEGER, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_auto_create_from_correlation(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_auto_create_from_correlation(BIGINT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_assign(BIGINT, BIGINT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_assign(BIGINT, BIGINT, TEXT, BIGINT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_add_comment(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_add_comment(BIGINT, BIGINT, TEXT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_add_evidence(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_add_evidence(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_status_transition(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_status_transition(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_escalate(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_escalate(BIGINT, BIGINT, TEXT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_accept_risk(BIGINT, BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_accept_risk(BIGINT, BIGINT, BIGINT, TEXT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_snooze(BIGINT, BIGINT, TIMESTAMPTZ) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_snooze(BIGINT, BIGINT, TIMESTAMPTZ) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_close(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_close(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

-- ─── CR-K read fns (4) ───
REVOKE EXECUTE ON FUNCTION fn_risk_case_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, TEXT, TEXT, INTEGER, INTEGER) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_get_by_id(BIGINT, BIGINT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_evidence_get(BIGINT, BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_evidence_get(BIGINT, BIGINT, BIGINT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_risk_case_escalation_check(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_risk_case_escalation_check(INTEGER) TO neondb_owner;

-- ─── CR-L report_template fns (5) ───
REVOKE EXECUTE ON FUNCTION fn_report_template_list(BIGINT, BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_list(BIGINT, BOOLEAN) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_template_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_get_by_id(BIGINT, BIGINT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, JSONB, BOOLEAN, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT, JSONB, BOOLEAN, TEXT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, BOOLEAN, TEXT, JSONB, BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, JSONB, JSONB, BOOLEAN, TEXT, JSONB, BOOLEAN) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_template_delete(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_template_delete(BIGINT, BIGINT) TO neondb_owner;

-- ─── CR-L report_run fns (4) ───
REVOKE EXECUTE ON FUNCTION fn_report_run_trigger(BIGINT, BIGINT, TEXT, JSONB, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_run_trigger(BIGINT, BIGINT, TEXT, JSONB, TEXT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_run_complete(BIGINT, TEXT, TEXT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_run_complete(BIGINT, TEXT, TEXT, BIGINT, TEXT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_run_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_run_get_by_id(BIGINT, BIGINT) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_run_pending_get(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_run_pending_get(INTEGER) TO neondb_owner;

-- ─── CR-L data fns (17) ───
REVOKE EXECUTE ON FUNCTION fn_report_data_executive_weekly_brief(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_executive_weekly_brief(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_executive_monthly_board(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_executive_monthly_board(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_executive_avar_trend(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_executive_avar_trend(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_executive_top10_exposures(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_executive_top10_exposures(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_legal_advisory_queue(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_legal_advisory_queue(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_legal_clause_review_backlog(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_legal_clause_review_backlog(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_legal_fm_eligibility(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_legal_fm_eligibility(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_legal_regulatory_digest(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_legal_regulatory_digest(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_procurement_supplier_scorecard(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_procurement_supplier_scorecard(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_procurement_supplier_scorecard_detail(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_procurement_supplier_scorecard_detail(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_procurement_icv_compliance(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_procurement_icv_compliance(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_procurement_sla_breach(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_procurement_sla_breach(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_operations_risk_board_snapshot(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_operations_risk_board_snapshot(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_operations_delivery_delay(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_operations_delivery_delay(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_operations_penalty_exposure(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_operations_penalty_exposure(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_finance_fx_exposure(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_finance_fx_exposure(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_finance_price_review_queue(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_finance_price_review_queue(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_finance_payment_delay(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_finance_payment_delay(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_compliance_sanctions_exposure(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_compliance_sanctions_exposure(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_compliance_subcontractor_chain(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_compliance_subcontractor_chain(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_compliance_audit_rights(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_compliance_audit_rights(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_admin_system_health(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_admin_system_health(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_admin_audit_chain_verification(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_admin_audit_chain_verification(BIGINT, JSONB) TO neondb_owner;
REVOKE EXECUTE ON FUNCTION fn_report_data_admin_source_health_snapshot(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_report_data_admin_source_health_snapshot(BIGINT, JSONB) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (273, '273_unit7_grant_pre_emptive_backfill', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 273;
-- (No reverse-action required — REVOKE/GRANT trio already lives in source migrations)
-- ============================================================
