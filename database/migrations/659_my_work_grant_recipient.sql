-- ============================================================================
-- Migration 659 — Gap 5 follow-up: widen my_work to contract_recipient
-- ============================================================================
-- The signature_required branch in mig 657 only fires for users whose
-- /app/work route renders the unified inbox, and that gate (FE
-- UNIFIED_INBOX_ROLES) needed contract_recipient added. To complete the
-- chain we also widen the BE-side product_module + permission grant so
-- the recipient's effective modules + API gate let them through.
--
-- Pattern: mirrors mig 654.
-- ============================================================================

BEGIN;

UPDATE product_module
   SET default_role_codes = (
         SELECT jsonb_agg(DISTINCT code ORDER BY code)
           FROM (
             SELECT jsonb_array_elements_text(default_role_codes) AS code
             UNION
             SELECT 'contract_recipient' AS code
           ) merged
       )
 WHERE key = 'my_work';

INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
  CROSS JOIN permission p
 WHERE r.name = 'contract_recipient'
   AND p.code = 'work.read.assigned'
ON CONFLICT DO NOTHING;

DO $$
DECLARE
  v_codes JSONB;
  v_count INTEGER;
BEGIN
  SELECT default_role_codes INTO v_codes FROM product_module WHERE key = 'my_work';
  IF NOT (v_codes ? 'contract_recipient') THEN
    RAISE EXCEPTION 'mig 659: contract_recipient missing from default_role_codes (got %)', v_codes;
  END IF;
  SELECT COUNT(*) INTO v_count
    FROM role_permission rp
    JOIN role r       ON r.id = rp.role_id
    JOIN permission p ON p.id = rp.permission_id
   WHERE r.name = 'contract_recipient' AND p.code = 'work.read.assigned';
  IF v_count < 1 THEN
    RAISE EXCEPTION 'mig 659: expected work.read.assigned grant for contract_recipient (got %)', v_count;
  END IF;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (659, 'my_work_grant_recipient', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
