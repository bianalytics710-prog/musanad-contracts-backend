-- Migration: 293_crm_grant_pre_emptive_backfill.sql
-- Module: CR-M — Labor-Law Cascade + ADNOC-World Foundation
-- Description: Belt-and-suspenders defensive re-application (pattern: mig 220/273):
--              (1) Re-apply REVOKE EXECUTE FROM PUBLIC + GRANT EXECUTE TO neondb_owner
--                  on all 8 CR-M fn_'s (CREATE OR REPLACE drops COMMENT + grants — B14/S2-21).
--              (2) Re-apply all role_permission grants from 292 defensively.
--              This migration is safe to re-run (all idempotent).
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- Part 1: REVOKE/GRANT on all 8 CR-M fn_'s (S2-21 / B14)
-- ============================================================

-- Cascade functions
REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_run(BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_run(BIGINT, BIGINT, JSONB) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_list(BIGINT, BIGINT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_list(BIGINT, BIGINT, INTEGER, INTEGER) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_get(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_get(BIGINT, BIGINT) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_item_set_status(BIGINT, BIGINT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_item_set_status(BIGINT, BIGINT, TEXT, TEXT) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_regulatory_cascade_item_link_draft(BIGINT, BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_regulatory_cascade_item_link_draft(BIGINT, BIGINT, BIGINT) TO neondb_owner;

-- Workforce functions
REVOKE EXECUTE ON FUNCTION fn_party_workforce_set(BIGINT, BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_workforce_set(BIGINT, BIGINT, JSONB) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_party_workforce_get(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_workforce_get(BIGINT, BIGINT) TO neondb_owner;

REVOKE EXECUTE ON FUNCTION fn_party_workforce_list(BIGINT, TEXT, BOOLEAN, VARCHAR, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_party_workforce_list(BIGINT, TEXT, BOOLEAN, VARCHAR, INTEGER, INTEGER) TO neondb_owner;

-- Also re-apply audit trigger tail (fn_audit_trigger — extended in 281)
REVOKE EXECUTE ON FUNCTION fn_audit_trigger() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_audit_trigger() TO neondb_owner;

-- ============================================================
-- Part 2: Defensive role_permission re-application (all 292 grants)
-- ============================================================

INSERT INTO role_permission (role_id, permission_id, created_at, is_active)
SELECT r.id, p.id, NOW(), TRUE
FROM role r
CROSS JOIN permission p
WHERE (r.name, p.code) IN (
  ('Super Admin',                 'regulatory.cascade.read'),
  ('platform_admin',              'regulatory.cascade.read'),
  ('compliance_esg',              'regulatory.cascade.read'),
  ('legal_counsel',               'regulatory.cascade.read'),
  ('executive',                   'regulatory.cascade.read'),
  ('procurement_supplier_risk',   'regulatory.cascade.read'),
  ('Super Admin',                 'regulatory.cascade.run'),
  ('platform_admin',              'regulatory.cascade.run'),
  ('compliance_esg',              'regulatory.cascade.run'),
  ('Super Admin',                 'party.workforce.read'),
  ('platform_admin',              'party.workforce.read'),
  ('compliance_esg',              'party.workforce.read'),
  ('legal_counsel',               'party.workforce.read'),
  ('executive',                   'party.workforce.read'),
  ('procurement_supplier_risk',   'party.workforce.read'),
  ('Super Admin',                 'party.workforce.manage'),
  ('platform_admin',              'party.workforce.manage'),
  ('compliance_esg',              'party.workforce.manage')
)
ON CONFLICT (role_id, permission_id) DO NOTHING;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (293, '293_crm_grant_pre_emptive_backfill', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM schema_migrations WHERE version = 293;
-- -- REVOKE/GRANT cannot be rolled back meaningfully; no-op.
-- COMMIT;
-- ============================================================
