-- ============================================================================
-- Migration 673 — Grant executive role the perms + module to approve advisories
-- ============================================================================
-- The new "executive review" path on advisory drafts (mig 669) routes drafts
-- to the executive's plate via metadata.currentReviewer='executive'. For
-- Eman to actually hit the /api/v1/advisory-drafts/:id/exec-approve and
-- /by-contract/:contractId endpoints we need two things:
--   1. advisory_queue module access (route prefix is module-gated)
--   2. advisory.draft.review permission (per-route authoriser)
--
-- Both are inserted idempotently. The data_classification + tenant_id on
-- role_module_access pin it to the default tenant (single-tenant demo).
-- ============================================================================

BEGIN;

-- 1. Module access for executive on advisory_queue
INSERT INTO role_module_access (
  tenant_id, role_id, module_key, is_allowed, reason, created_by, updated_by, is_active
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  r.id,
  'advisory_queue',
  TRUE,
  'mig 673 — executive review path requires module access to call /advisory-drafts/* endpoints',
  NULL, NULL, TRUE
FROM role r
WHERE r.name = 'executive'
ON CONFLICT DO NOTHING;

-- 2. advisory.draft.review permission for executive
INSERT INTO role_permission (role_id, permission_id, created_by, is_active)
SELECT r.id, p.id, NULL, TRUE
FROM role r
CROSS JOIN permission p
WHERE r.name = 'executive'
  AND p.code = 'advisory.draft.review'
  AND NOT EXISTS (
    SELECT 1 FROM role_permission rp
    WHERE rp.role_id = r.id AND rp.permission_id = p.id AND rp.is_active = TRUE
  );

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (673, 'executive_advisory_review_grants', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
