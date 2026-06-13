-- ============================================================================
-- Migration 642 — Phase A: work.read.assigned for legal_counsel + approver
-- ============================================================================
-- Mig 641 added the my_work module to legal_counsel + contract_approver's
-- sidebar set, but the /api/v1/my-work endpoint still 403s because they're
-- missing the underlying work.read.assigned permission (granted today only
-- to drafter / executive / platform_admin / Super Admin). Grant it so the
-- inbox actually loads for the new personas.
--
-- Idempotent — ON CONFLICT DO NOTHING.
-- ============================================================================

INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
  FROM role r
  CROSS JOIN permission p
 WHERE r.name IN ('legal_counsel', 'contract_approver')
   AND p.code = 'work.read.assigned'
ON CONFLICT DO NOTHING;

-- Sanity assertion.
DO $$
DECLARE
  v_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM role_permission rp
    JOIN role r       ON r.id = rp.role_id
    JOIN permission p ON p.id = rp.permission_id
   WHERE r.name IN ('legal_counsel', 'contract_approver')
     AND p.code = 'work.read.assigned';
  IF v_count < 2 THEN
    RAISE EXCEPTION 'mig 642: expected 2 grants for work.read.assigned (got %)', v_count;
  END IF;
END $$;
