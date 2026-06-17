-- ============================================================================
-- Migration 693 — Remove "Approval / Workflow Risk" from the risk surface
-- ============================================================================
-- WHY: "Approval / Workflow Risk" (fn_classify_risk → 'approval_workflow') is an
-- internal approval-pipeline delay, not a contract risk. Per mig 663 those cases
-- already belong in the Approvals module, not Risk. They were the only risk cases
-- still showing a role ("Contract Approver") instead of a person in the Risk Cases
-- "Assigned to" column. Soft-deleting them removes the type from the Risk Cases
-- surface AND fixes the role-only display (every remaining case has a persona).
--
-- Soft delete (is_active = FALSE) — reversible; nothing is hard-deleted.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001'::uuid;
  v_admin  BIGINT;
  v_count  INTEGER;
BEGIN
  SELECT id INTO v_admin FROM "user" WHERE email = 'admin@musanad.local' LIMIT 1;
  PERFORM set_config('app.current_tenant_id', v_tenant::text, true);
  PERFORM set_config('app.current_user_id', COALESCE(v_admin, 1)::text, true);

  UPDATE risk_case rc
     SET is_active  = FALSE,
         updated_at = now(),
         updated_by = v_admin
   WHERE rc.is_active = TRUE
     AND rc.tenant_id = v_tenant
     AND fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                          rc.title, rc.assigned_role, rc.case_type) = 'approval_workflow';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE '693 — soft-deleted % approval_workflow risk case(s)', v_count;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (693, 'soft-delete approval_workflow risk cases', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK: UPDATE risk_case SET is_active=TRUE WHERE <the affected ids>;
--           DELETE FROM schema_migrations WHERE version=693;
