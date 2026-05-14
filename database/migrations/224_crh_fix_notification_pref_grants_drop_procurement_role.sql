-- MIGRATION: 224_crh_fix_notification_pref_grants_drop_procurement_role.sql
-- Module: M16 — Advisory Drafter + Notification Delivery (CR-H)
-- Date: 2026-05-14
-- Purpose: Closes DEFECT-CRH-DB-01 + audits the CR-H brief
--          "notification.preferences.write.self → all authenticated users" rule.
--
-- Background:
-- Migrations 210 + 220 attempted to grant `notification.preferences.write.self`
-- to a role called `procurement_supplier_risk`. Per SOT §5.1 + §5.2, that role
-- was never meant to exist — Procurement & Contracts reuses the existing
-- `contract_drafter` + `contract_approver` roles, with `insights.procurement_supplier_risk`
-- being a PERMISSION (not a role). The CR-H grant lines were a permission/role name
-- confusion; they were no-ops at apply time (role lookup returned 0 rows).
--
-- However the audit also surfaced two real gaps: active roles `contract_recipient`
-- and `contract_approver_2` did not receive `notification.preferences.write.self`
-- (the per-user preferences page should be reachable by every authenticated persona).
-- This migration backfills those two grants.
--
-- The `procurement_supplier_risk` dead grant is left as historical record in
-- migration 220 (immutable schema_migrations log) but documented as resolved here.

BEGIN;

-- Backfill notification.preferences.write.self for the 2 missing active roles
INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r
CROSS JOIN permission p
WHERE (r.name, p.code) IN (
  ('contract_recipient',  'notification.preferences.write.self'),
  ('contract_approver_2', 'notification.preferences.write.self')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (224, 'CR-H DEFECT-CRH-DB-01 resolve: drop procurement_supplier_risk role assumption (SOT §5.1: no such role); backfill notification.preferences.write.self for contract_recipient + contract_approver_2 per brief "all authenticated users" rule.', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
-- DELETE FROM role_permission
-- WHERE permission_id = (SELECT id FROM permission WHERE code = 'notification.preferences.write.self')
--   AND role_id IN (SELECT id FROM role WHERE name IN ('contract_recipient', 'contract_approver_2'));
-- DELETE FROM schema_migrations WHERE version = 224;
-- COMMIT;
-- ROLLBACK END
