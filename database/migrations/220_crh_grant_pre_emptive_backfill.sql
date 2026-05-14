-- MIGRATION: 220_crh_grant_pre_emptive_backfill.sql
-- Module: M16 — Advisory Drafter + Notification Delivery
-- CR: CR-H
-- Date: 2026-05-14
-- Description: Defensive re-application of all 20 role_permission grants + 6 defensive backfill grants.
--              Pattern mirrors M15/Unit-2B 14-grant backfill — closes S2-21 latent leak risk.
--              NOTE: procurement_supplier_risk grant skipped — role not in DB (logged as DEFECT below).
--              Also: re-apply REVOKE FROM PUBLIC + GRANT TO neondb_owner on all 20 fn_'s (B14 tail block).

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Defensive re-application of role_permission grants (idempotent)
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

-- 6 defensive backfill grants: try procurement_supplier_risk if role was added after migration 210
INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r
CROSS JOIN permission p
WHERE (r.name, p.code) IN (
  ('procurement_supplier_risk','notification.preferences.write.self'),
  -- Defensive re-grants for admin review roles (belt-and-suspenders)
  ('Admin',           'notification.preferences.write.self'),
  ('User',            'notification.preferences.write.self')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Re-apply REVOKE FROM PUBLIC + GRANT TO neondb_owner on all 20 CR-H fn_'s (B14 mandatory)
-- fn_advisory_template_* (5)
REVOKE EXECUTE ON FUNCTION fn_advisory_template_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_template_get_by_id(BIGINT, BIGINT) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_advisory_template_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_template_list(BIGINT, TEXT, TEXT, BOOLEAN, INTEGER, INTEGER) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_advisory_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_template_create(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_advisory_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_template_update(BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, JSONB) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_advisory_template_delete(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_template_delete(BIGINT, BIGINT) TO neondb_owner;

-- fn_advisory_draft_* (6)
REVOKE EXECUTE ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_get_by_id(BIGINT, BIGINT) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_advisory_draft_generate(BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_generate(BIGINT, BIGINT, BIGINT, BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_advisory_draft_list(BIGINT, TEXT, BIGINT, BIGINT, TEXT, BOOLEAN, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_list(BIGINT, TEXT, BIGINT, BIGINT, TEXT, BOOLEAN, INTEGER, INTEGER) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_advisory_draft_approve(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_approve(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_advisory_draft_reject(BIGINT, BIGINT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_reject(BIGINT, BIGINT, TEXT) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_advisory_draft_modify(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_draft_modify(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

-- fn_advisory_dispatch_* (2)
REVOKE EXECUTE ON FUNCTION fn_advisory_dispatch(BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_dispatch(BIGINT, BIGINT, JSONB) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_advisory_dispatch_log_list(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_advisory_dispatch_log_list(BIGINT, BIGINT) TO neondb_owner;

-- fn_notification_send / retry_due / update_retry_outcome (3)
REVOKE EXECUTE ON FUNCTION fn_notification_send(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, JSONB, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_send(BIGINT, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, JSONB, BIGINT) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_notification_dispatch_retry_due(INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_dispatch_retry_due(INTEGER) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_notification_dispatch_update_retry_outcome(BIGINT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_dispatch_update_retry_outcome(BIGINT, BOOLEAN, TEXT) TO neondb_owner;

-- fn_notification_dispatch_log_* / subscription_* (4)
REVOKE EXECUTE ON FUNCTION fn_notification_dispatch_log_list(BIGINT, TEXT, TEXT, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_dispatch_log_list(BIGINT, TEXT, TEXT, TEXT, TEXT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, INTEGER) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_notification_dispatch_log_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_dispatch_log_get_by_id(BIGINT, BIGINT) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_notification_subscription_list(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_subscription_list(BIGINT) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_notification_subscription_set(BIGINT, TEXT, TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_notification_subscription_set(BIGINT, TEXT, TEXT, TEXT, BOOLEAN) TO neondb_owner;

-- Also re-apply on fn_audit_trigger (extended in 209)
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (220, '220_crh_grant_pre_emptive_backfill', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code IN (
--   'advisory.template.manage','advisory.draft.review','advisory.dispatch',
--   'notification.dispatch_log.read','notification.preferences.write.self'
-- ));
-- DELETE FROM schema_migrations WHERE version = 220;
-- ============================================================

-- ============================================================
-- DEFECT REPORT (do not fix — flag for Agent 4 re-spawn)
-- ============================================================
-- DEFECT-CRH-DB-01: procurement_supplier_risk role does not exist in the DB.
-- db-design.md + db-design-summary.json mandate a grant of notification.preferences.write.self
-- to procurement_supplier_risk. Role was added in M15 (Unit 2B) but is absent from this DB snapshot.
-- Status: grant skipped in migrations 210 + 220 (ON CONFLICT DO NOTHING pattern applied but role not found).
-- Action required: verify if procurement_supplier_risk was applied to m0-foundation branch, or if M15
-- seed migration is missing for this branch. DB Implementation reports, does not fix.
-- ============================================================
