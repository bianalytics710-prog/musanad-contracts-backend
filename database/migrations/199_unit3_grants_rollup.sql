-- Migration: 199_unit3_grants_rollup.sql
-- Unit: Unit-3 (R-FT + R-CES — S2-21 catch-all)
-- Description: Defensive REVOKE EXECUTE FROM PUBLIC + GRANT EXECUTE TO neondb_owner
--              for all functions mutated or created in this Unit-3 batch:
--                - fn_dashboard_finance_treasury (mutated 194 + 195)
--                - fn_dashboard_compliance_esg (mutated 196)
--                - fn_contract_audit_rights_list (created 197)
--
--              Each per-migration tail block already includes its own REVOKE +
--              GRANT (per the per-migration S2-21 guard), so this migration is
--              a safety net + canonical enumeration point — a reviewer can read
--              this file and confirm Unit-3 left no PUBLIC EXECUTE leak.
--
--              Verification block at the bottom queries pg_proc.proacl to
--              confirm only neondb_owner has EXECUTE for each function.
--              Raises 'unit_3_acl_leak' if any function has a non-owner
--              EXECUTE grant.
-- Reference: feedback_stage2_checks_s2_16_to_s2_20.md (S2-21 mandatory),
--            feedback_s2_21_hidden_public_leak.md.
-- Rollback: not applicable (REVOKE/GRANT only).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Defensive REVOKE/GRANT for the 3 Unit-3 functions.
REVOKE EXECUTE ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION public.fn_dashboard_compliance_esg(bigint, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_dashboard_compliance_esg(bigint, integer) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION public.fn_contract_audit_rights_list(bigint, bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.fn_contract_audit_rights_list(bigint, bigint) TO neondb_owner;

-- Verification block: raise if any Unit-3 fn has non-owner EXECUTE.
DO $$
DECLARE
  v_leak_count INTEGER;
  v_acl_dump TEXT;
BEGIN
  SELECT count(*), string_agg(format('%s -> %s', p.proname, p.proacl::text), E'\n')
  INTO v_leak_count, v_acl_dump
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'fn_dashboard_finance_treasury',
      'fn_dashboard_compliance_esg',
      'fn_contract_audit_rights_list'
    )
    AND (
      p.proacl IS NULL  -- NULL proacl = effective PUBLIC EXECUTE (S2-21 hidden-leak class)
      OR EXISTS (
        SELECT 1
        FROM unnest(p.proacl) AS aclitem
        WHERE aclitem::text LIKE '=X/%' -- PUBLIC has =X (no role name before =)
      )
    );

  IF v_leak_count > 0 THEN
    RAISE EXCEPTION 'unit_3_acl_leak: % function(s) still grant EXECUTE to PUBLIC. ACL dump: %', v_leak_count, v_acl_dump
      USING ERRCODE = '42501';
  END IF;
END $$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (199, 'Unit-3: S2-21 catch-all REVOKE EXECUTE FROM PUBLIC + GRANT TO neondb_owner for 3 mutated/new fn_''s', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- N/A — REVOKE/GRANT are idempotent. To restore PUBLIC EXECUTE (not recommended):
--   GRANT EXECUTE ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) TO PUBLIC;
--   etc.
-- DELETE FROM schema_migrations WHERE version = 199;
