-- ============================================================================
-- Migration 654 — Phase E.7: widen my_work to 4 more roles
-- ============================================================================
-- WHY: per locked decision E-Q4, the noise/reassign UX in Risk Triage should
-- be consistent app-wide. For that to feel right, the receivers — operations,
-- compliance_esg, finance_treasury, procurement_supplier_risk — need their
-- own My Work surface so they see the risk_case_assigned rows that land
-- there. Today My Work is enabled for 6 roles (mig 622 + 641); this widens
-- to 10.
--
-- Two parts (mirror Phase A's mig 641 + 642 split):
--   1. Add the 4 role codes to product_module.default_role_codes for
--      'my_work' so fn_user_effective_modules surfaces the sidebar entry.
--   2. Grant the work.read.assigned permission to the 4 roles so the
--      /api/v1/my-work endpoint actually loads.
--
-- Idempotent — both INSERTs use ON CONFLICT / NOT EXISTS.
-- ============================================================================

BEGIN;

-- ─── 1. extend product_module.default_role_codes ──────────────────────────
UPDATE product_module
   SET default_role_codes = (
         SELECT jsonb_agg(DISTINCT code ORDER BY code)
           FROM (
             SELECT jsonb_array_elements_text(default_role_codes) AS code
             UNION
             SELECT unnest(ARRAY[
               'operations',
               'compliance_esg',
               'finance_treasury',
               'procurement_supplier_risk'
             ]) AS code
           ) merged
       )
 WHERE key = 'my_work';

-- ─── 2. grant work.read.assigned permission ───────────────────────────────
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
  CROSS JOIN permission p
 WHERE r.name IN ('operations', 'compliance_esg', 'finance_treasury', 'procurement_supplier_risk')
   AND p.code = 'work.read.assigned'
ON CONFLICT DO NOTHING;

-- ─── Sanity assertions ────────────────────────────────────────────────────
DO $$
DECLARE
  v_codes JSONB;
  v_count INTEGER;
BEGIN
  SELECT default_role_codes INTO v_codes FROM product_module WHERE key = 'my_work';
  IF NOT (v_codes ? 'operations')
     OR NOT (v_codes ? 'compliance_esg')
     OR NOT (v_codes ? 'finance_treasury')
     OR NOT (v_codes ? 'procurement_supplier_risk') THEN
    RAISE EXCEPTION 'mig 654: my_work default_role_codes update failed (got %)', v_codes;
  END IF;

  SELECT COUNT(*) INTO v_count
    FROM role_permission rp
    JOIN role r       ON r.id = rp.role_id
    JOIN permission p ON p.id = rp.permission_id
   WHERE r.name IN ('operations', 'compliance_esg', 'finance_treasury', 'procurement_supplier_risk')
     AND p.code = 'work.read.assigned';
  IF v_count < 4 THEN
    RAISE EXCEPTION 'mig 654: expected 4 grants for work.read.assigned (got %)', v_count;
  END IF;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (654, 'my_work_widen_to_four_roles', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
