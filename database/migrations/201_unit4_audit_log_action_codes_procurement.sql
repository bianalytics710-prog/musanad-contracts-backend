-- Migration: 201_unit4_audit_log_action_codes_procurement.sql
-- Unit: Unit-4 (R-PROC standalone — Procurement supplier-risk persona closure)
-- Description: Add 4 procurement-action codes to audit_log_action_code catalog
--              per BRD §7 + brief AC#5 (cure-notice stub) + AC#6 (ICV remediation).
--              Cure-notice action records intent; actual advisory generation lands
--              when CR-H ships in Unit 5.
-- Reference: GAP-REPORT-PROCUREMENT.md C1/C2/C3, decisions/R-PROC.json AD-4.
-- Rollback: see ROLLBACK section.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO audit_log_action_code (code, persona, description, introduced_in_migration) VALUES
  ('vendor_alternate_activated',  'procurement', 'Procurement user activated a backup supplier from the supplier-risk dashboard.',           201),
  ('vendor_performance_escalated','procurement', 'Procurement user escalated a vendor performance issue (separate from operations escalate).', 201),
  ('cure_notice_intent_recorded', 'procurement', 'Procurement user initiated cure-notice intent. Records audit row; advisory drafter ships in CR-H.', 201),
  ('icv_remediation_initiated',   'procurement', 'Procurement user initiated ICV remediation request. Compliance role completes via existing ICV upload flow (Unit 3 mig 200).', 201)
ON CONFLICT (code) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (201, 'Unit-4 R-PROC: 4 procurement action codes (vendor_alternate_activated / vendor_performance_escalated / cure_notice_intent_recorded / icv_remediation_initiated)', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM audit_log_action_code WHERE introduced_in_migration = 201;
-- DELETE FROM schema_migrations WHERE version = 201;
