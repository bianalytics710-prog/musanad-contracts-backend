-- ============================================================================
-- 028_m2_approval_permissions_and_grants.sql — AE-4 (6 perms + 21 grants)
-- ============================================================================
-- Module:    M2 (Approval Workflows)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   001_foundation.sql (permission, role_permission, role tables)
-- ----------------------------------------------------------------------------
-- AE-4 — Insert 6 new approval.* permissions and 21 role-permission grants.
-- All idempotent (ON CONFLICT DO NOTHING).
--
-- Permission codes use snake_case per OI-9 (matches existing M0/M1a/M1c codes).
-- Pre-emptive Super Admin grants per M1a 006 / M1c 018 lesson.
-- approval.escalate is intentionally NOT created — fn_approval_escalate is
-- SECURITY DEFINER, system-only (REVOKE FROM PUBLIC + GRANT TO neondb_owner).
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================
-- Step A — 6 new approval.* permissions
-- ============================================================
INSERT INTO permission (code, module, action, description) VALUES
  ('approval.submit_for_review', 'approval', 'submit_for_review',
   'Submit a draft contract for approval (drafter -> in_review -> in_approval pipeline).'),
  ('approval.act',               'approval', 'act',
   'Decide on an assigned approval step (approve / reject / request_resubmission).'),
  ('approval.delegate',          'approval', 'delegate',
   'Delegate an assigned approval step to another user with a compatible role.'),
  ('approval.matrix.read',       'approval', 'matrix.read',
   'Read the approval matrix rules (admin oversight).'),
  ('approval.matrix.write',      'approval', 'matrix.write',
   'Create / update / soft-delete approval matrix rules.'),
  ('approval.reassign',          'approval', 'reassign',
   'Admin reassign a stalled approval step to another user (forced override).')
ON CONFLICT (code) DO NOTHING;

-- ============================================================
-- Step B — 21 role-permission grants
-- ============================================================
INSERT INTO role_permission (role_id, permission_id, created_by)
SELECT r.id, p.id, NULL
FROM role r
CROSS JOIN permission p
WHERE (r.name, p.code) IN (
  -- platform_admin (6)
  ('platform_admin','approval.submit_for_review'),
  ('platform_admin','approval.act'),
  ('platform_admin','approval.delegate'),
  ('platform_admin','approval.matrix.read'),
  ('platform_admin','approval.matrix.write'),
  ('platform_admin','approval.reassign'),
  -- legal_counsel (4)
  ('legal_counsel','approval.act'),
  ('legal_counsel','approval.delegate'),
  ('legal_counsel','approval.matrix.read'),
  ('legal_counsel','approval.reassign'),
  -- contract_drafter (1)
  ('contract_drafter','approval.submit_for_review'),
  -- contract_approver (2)
  ('contract_approver','approval.act'),
  ('contract_approver','approval.delegate'),
  -- contract_approver_2 (2)
  ('contract_approver_2','approval.act'),
  ('contract_approver_2','approval.delegate'),
  -- Super Admin (6) — pre-emptive M0 grant per M1a 006 / M1c 018 lesson
  ('Super Admin','approval.submit_for_review'),
  ('Super Admin','approval.act'),
  ('Super Admin','approval.delegate'),
  ('Super Admin','approval.matrix.read'),
  ('Super Admin','approval.matrix.write'),
  ('Super Admin','approval.reassign')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (28, 'm2_approval_permissions_and_grants', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DELETE FROM role_permission rp
USING role r, permission p
WHERE rp.role_id = r.id AND rp.permission_id = p.id
  AND p.code IN (
    'approval.submit_for_review','approval.act','approval.delegate',
    'approval.matrix.read','approval.matrix.write','approval.reassign'
  );
DELETE FROM permission
WHERE code IN (
  'approval.submit_for_review','approval.act','approval.delegate',
  'approval.matrix.read','approval.matrix.write','approval.reassign'
);
DELETE FROM schema_migrations WHERE version = 28;
COMMIT;
-- ROLLBACK END
