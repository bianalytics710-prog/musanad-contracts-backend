-- ============================================================================
-- Migration 641 — Phase A grant: my_work module for legal_counsel + approver
-- ============================================================================
-- The product_module.default_role_codes array on `my_work` currently lists
-- Super Admin / platform_admin / contract_drafter / executive. Phase A wires
-- the unified inbox for Legal Counsel and Contract Approver too — add their
-- role codes so fn_user_effective_modules picks them up without needing
-- explicit role_module_access rows.
--
-- Idempotent: appends only the role codes that aren't already present.
-- ============================================================================

-- default_role_codes is JSONB (array of strings). Merge with the two new
-- role codes, deduplicate, and write the JSONB array back.
UPDATE product_module
   SET default_role_codes = (
         SELECT jsonb_agg(DISTINCT code ORDER BY code)
           FROM (
             SELECT jsonb_array_elements_text(default_role_codes) AS code
             UNION
             SELECT unnest(ARRAY['legal_counsel', 'contract_approver']) AS code
           ) merged
       )
 WHERE key = 'my_work';

-- Sanity assertion — the JSONB array must contain both new role codes.
DO $$
DECLARE
  v_codes JSONB;
BEGIN
  SELECT default_role_codes INTO v_codes FROM product_module WHERE key = 'my_work';
  IF NOT (v_codes ? 'legal_counsel') OR NOT (v_codes ? 'contract_approver') THEN
    RAISE EXCEPTION 'mig 641: my_work default_role_codes update failed (got %)', v_codes;
  END IF;
END $$;
