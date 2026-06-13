-- ============================================================================
-- Migration 643 — Phase B: risk.review.manage permission for executive role
-- ============================================================================
-- Phase B exposes the Tier-2 risk-review queue on the Executive surface
-- (sidebar entry "Risk Triage" + an Insights tile). The mechanism is the
-- exact same RiskReviewPage that platform_admin uses today at
-- /app/admin/risk-review — just rendered behind the executive's nav.
--
-- Mig 552 had explicitly REVOKED this perm from executive. Phase B reverses
-- that: the exec is the right judge of borderline cases since their job is
-- to triage between specialist queues. Platform admin keeps the perm too.
--
-- Idempotent — ON CONFLICT DO NOTHING.
-- ============================================================================

-- INSERT … ON CONFLICT DO UPDATE: mig 552 had previously REVOKED this perm
-- from executive by setting role_permission.is_active = false. A plain
-- DO NOTHING would preserve that inactive row; we explicitly reactivate.
INSERT INTO role_permission (role_id, permission_id, is_active)
SELECT r.id, p.id, true
  FROM role r
  CROSS JOIN permission p
 WHERE r.name = 'executive'
   AND p.code = 'risk.review.manage'
ON CONFLICT (role_id, permission_id) DO UPDATE
  SET is_active = true;

-- Sanity assertion.
DO $$
DECLARE
  v_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count
    FROM role_permission rp
    JOIN role       r ON r.id = rp.role_id
    JOIN permission p ON p.id = rp.permission_id
   WHERE r.name = 'executive'
     AND p.code = 'risk.review.manage';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'mig 643: expected 1 grant for executive/risk.review.manage (got %)', v_count;
  END IF;
END $$;
