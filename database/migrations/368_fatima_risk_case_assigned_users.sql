-- Migration: 368_fatima_risk_case_assigned_users.sql
-- Unit: Fatima Finance QA Phase 3.5 (F1-F80 audit pass)
-- Target:
--   F65 — Risk Cases list "Assigned to" column shows role names
--          (Compliance ESG / Legal Counsel / Finance Treasury / Procurement
--          Supplier Risk). The BE fn_risk_case_list already returns both
--          assignedRole AND assignedUserName via JOIN to "user" — the FE
--          falls back to role when assignedUserName is null. So seed
--          assigned_user_id on existing risk cases by mapping
--          assigned_role → a representative persona for the demo.

DO $$
DECLARE
  v_tenant            UUID := '00000000-0000-0000-0000-000000000001';
  v_compliance_uid    BIGINT;
  v_legal_uid         BIGINT;
  v_finance_uid       BIGINT;
  v_procurement_uid   BIGINT;
  v_operations_uid    BIGINT;
BEGIN
  SELECT id INTO v_compliance_uid  FROM "user" WHERE email = 'compliance@musanad.local';
  SELECT id INTO v_legal_uid       FROM "user" WHERE email = 'legal@musanad.local';
  SELECT id INTO v_finance_uid     FROM "user" WHERE email = 'finance@musanad.local';
  SELECT id INTO v_procurement_uid FROM "user" WHERE email = 'procurement@musanad.local';
  SELECT id INTO v_operations_uid  FROM "user" WHERE email = 'operations@musanad.local';

  IF v_finance_uid IS NULL THEN
    RAISE NOTICE 'mig 368: demo personas absent, skipping.';
    RETURN;
  END IF;

  UPDATE risk_case
     SET assigned_user_id = CASE assigned_role
           WHEN 'compliance_esg'             THEN v_compliance_uid
           WHEN 'legal_counsel'              THEN v_legal_uid
           WHEN 'finance_treasury'           THEN v_finance_uid
           WHEN 'procurement_supplier_risk'  THEN v_procurement_uid
           WHEN 'operations'                 THEN v_operations_uid
           ELSE assigned_user_id
         END,
         updated_at = NOW()
   WHERE assigned_user_id IS NULL
     AND assigned_role IN (
       'compliance_esg','legal_counsel','finance_treasury',
       'procurement_supplier_risk','operations'
     );
END $$;
