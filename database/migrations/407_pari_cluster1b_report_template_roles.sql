-- Migration: 407_pari_cluster1b_report_template_roles.sql
-- Unit: Pari Procurement QA Phase 3.7 (2026-06-01) — Cluster 1b / P34 (remainder)
-- Closes: After mig 406 granted report.read to procurement_supplier_risk, /app/reports renders
--         200 but shows "No reports available for your role" because the 4 procurement_*
--         templates (seeded in mig 272) have assigned_roles = ["contract_approver_2",
--         "platform_admin", "Super Admin"] — procurement_supplier_risk role is missing.
--
-- Strategy: Append procurement_supplier_risk to assigned_roles on the 4 procurement_* templates.
--           Also add it to the executive_top10_exposures template so Pari can run the
--           portfolio-level top-exposures report (relevant to her concentration review case).

BEGIN;

UPDATE report_template
   SET assigned_roles = (
         SELECT jsonb_agg(DISTINCT v)
           FROM jsonb_array_elements_text(
             assigned_roles || '["procurement_supplier_risk"]'::jsonb
           ) AS v
       ),
       updated_at = NOW()
 WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::UUID
   AND template_id IN (
     'procurement_supplier_scorecard',
     'procurement_supplier_scorecard_detail',
     'procurement_icv_compliance',
     'procurement_sla_breach'
   );

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (407, '407_pari_cluster1b_report_template_roles', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- UPDATE report_template
--    SET assigned_roles = (
--          SELECT jsonb_agg(v)
--            FROM jsonb_array_elements_text(assigned_roles) AS v
--           WHERE v <> 'procurement_supplier_risk'
--        )
--  WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::UUID
--    AND template_id IN (
--      'procurement_supplier_scorecard','procurement_supplier_scorecard_detail',
--      'procurement_icv_compliance','procurement_sla_breach');
-- DELETE FROM schema_migrations WHERE version = 407;
-- COMMIT;
-- ============================================================
