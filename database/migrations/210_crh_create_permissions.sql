-- MIGRATION: 210_crh_create_permissions.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: INSERT 5 new permission rows into permission + INSERT 21 role_permission grant rows.
--              6 defensive backfill grants in migration 220.
--              DEFECT NOTE: procurement_supplier_risk role was not found in DB (no id).
--              Grants for that role are skipped here; migration 220 backfill will apply them if the role is added.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO permission (code, module, action, description, created_at, is_active)
VALUES
  ('advisory.template.manage', 'advisory', 'template.manage', 'Manage advisory templates (create/update/delete/list)', NOW(), TRUE),
  ('advisory.draft.review',    'advisory', 'draft.review',    'Review advisory drafts (generate/approve/reject/modify/list)', NOW(), TRUE),
  ('advisory.dispatch',        'advisory', 'dispatch',        'Dispatch approved advisories to configured channels', NOW(), TRUE),
  ('notification.dispatch_log.read', 'notification', 'dispatch_log.read', 'View notification dispatch log (admin auditing)', NOW(), TRUE),
  ('notification.preferences.write.self', 'notification', 'preferences.write.self', 'Update own notification preferences', NOW(), TRUE)
ON CONFLICT (code) DO NOTHING;

-- 21 explicit role_permission grants
-- (procurement_supplier_risk omitted — role not present in DB; will be backfilled in migration 220)
INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r
CROSS JOIN permission p
WHERE (r.name, p.code) IN (
  ('Super Admin',     'advisory.template.manage'),
  ('Super Admin',     'advisory.draft.review'),
  ('Super Admin',     'advisory.dispatch'),
  ('Super Admin',     'notification.dispatch_log.read'),
  ('Super Admin',     'notification.preferences.write.self'),
  ('platform_admin',  'advisory.template.manage'),
  ('platform_admin',  'advisory.draft.review'),
  ('platform_admin',  'advisory.dispatch'),
  ('platform_admin',  'notification.dispatch_log.read'),
  ('platform_admin',  'notification.preferences.write.self'),
  ('legal_counsel',   'advisory.template.manage'),
  ('legal_counsel',   'advisory.draft.review'),
  ('legal_counsel',   'advisory.dispatch'),
  ('legal_counsel',   'notification.preferences.write.self'),
  ('operations',      'notification.preferences.write.self'),
  ('finance_treasury','notification.preferences.write.self'),
  ('compliance_esg',  'notification.preferences.write.self'),
  ('executive',       'notification.preferences.write.self'),
  ('contract_drafter','notification.preferences.write.self'),
  ('contract_approver','notification.preferences.write.self')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (210, '210_crh_create_permissions', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code IN (
--   'advisory.template.manage','advisory.draft.review','advisory.dispatch',
--   'notification.dispatch_log.read','notification.preferences.write.self'
-- ));
-- DELETE FROM permission WHERE code IN (
--   'advisory.template.manage','advisory.draft.review','advisory.dispatch',
--   'notification.dispatch_log.read','notification.preferences.write.self'
-- );
-- DELETE FROM schema_migrations WHERE version = 210;
-- ============================================================
