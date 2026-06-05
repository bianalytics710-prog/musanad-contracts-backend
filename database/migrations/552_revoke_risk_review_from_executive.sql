-- MIGRATION: 552_revoke_risk_review_from_executive.sql
-- Date: 2026-06-04
-- Description:
--   Risk Review (the bulk Confirm / Mark-as-noise surface for Tier 2
--   borderline alerts) is no longer mounted on the Executive dashboard.
--   It now lives at /app/admin/risk-review under Workflow & rules per
--   product decision — business-admin-owned, not C-level.
--
--   Revoke risk.review.manage from the executive role so the page stays
--   under the right shoulders. platform_admin + Super Admin keep their
--   grants. The 3 seed Tier 2 cases stay assigned to assigned_role
--   = 'executive' since the auto-create branching uses that as a queue
--   pointer — but only platform_admin's surface lets you action them.
--
--   Reversible: rerun the original grant from migration 550 if Risk
--   Review needs to relocate.

BEGIN;

UPDATE role_permission rp
   SET is_active = FALSE
  FROM role r, permission p
 WHERE rp.role_id = r.id
   AND rp.permission_id = p.id
   AND r.name = 'executive'
   AND p.code = 'risk.review.manage'
   AND rp.is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (552, 'revoke_risk_review_from_executive', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
