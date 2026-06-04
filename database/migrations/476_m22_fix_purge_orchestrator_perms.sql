-- Migration: 476_m22_fix_purge_orchestrator_perms.sql
-- Module: M22 — three live-walk fixes uncovered on batch 7
-- Date: 2026-06-02
--
-- A) Grant document.ingest to platform_admin so the worker actor can call
--    fn_contract_version_ingestion_complete (which persists extracted_text_uri
--    and transitions contract_version to status=complete).
--
-- B) Fix fn_migration_logical_duplicate_flag — used EXTRACT(EPOCH FROM
--    (date - date)) which fails because subtracting two DATE values yields
--    INTEGER (days), not INTERVAL. Postgres can't resolve EXTRACT(unknown,
--    integer) → raises "pg_catalog.extract(unknown, integer) does not exist".
--
-- C) (Orchestrator-side fix in TypeScript — see migration-orchestrator.service.ts)
--    fn_party_create's party_type CHECK accepts only 'individual' | 'company'.
--    Orchestrator was sending 'corporate'. Changing to 'company'.

-- ─── A. Grant document.ingest to platform_admin ─────────────────────────
DO $$
DECLARE
  v_role_id BIGINT;
  v_perm_id BIGINT;
BEGIN
  SELECT id INTO v_role_id FROM role WHERE name = 'platform_admin' LIMIT 1;
  SELECT id INTO v_perm_id FROM permission WHERE code = 'document.ingest' LIMIT 1;
  IF v_role_id IS NULL THEN
    RAISE NOTICE 'skipping document.ingest grant — platform_admin role absent on this branch';
    RETURN;
  END IF;
  IF v_perm_id IS NULL THEN
    RAISE NOTICE 'skipping document.ingest grant — permission row absent on this branch';
    RETURN;
  END IF;
  INSERT INTO role_permission (role_id, permission_id, created_at, created_by, is_active)
       VALUES (v_role_id, v_perm_id, now(), 0, TRUE)
  ON CONFLICT DO NOTHING;
END $$;

-- ─── B. Fix logical-duplicate fn (date arithmetic) ──────────────────────
CREATE OR REPLACE FUNCTION fn_migration_logical_duplicate_flag(
  p_record_id BIGINT,
  p_tenant    UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_record   RECORD;
  v_match_id BIGINT;
BEGIN
  SELECT mr.contract_id, c.counterparty_id, c.value_aed, c.start_date
    INTO v_record
  FROM migration_record mr
  LEFT JOIN contract c ON c.id = mr.contract_id
  WHERE mr.id = p_record_id AND mr.tenant_id = p_tenant;
  IF v_record.contract_id IS NULL THEN RETURN FALSE; END IF;

  -- Same tenant, different contract, same counterparty, value within ±2%,
  -- start_date within ±7 days. DATE - DATE returns INTEGER (days); use ABS()
  -- directly instead of EXTRACT(EPOCH FROM interval).
  SELECT id INTO v_match_id FROM contract
   WHERE id <> v_record.contract_id
     AND is_active = TRUE
     AND counterparty_id = v_record.counterparty_id
     AND value_aed IS NOT NULL AND v_record.value_aed IS NOT NULL
     AND ABS(value_aed - v_record.value_aed) <= GREATEST(v_record.value_aed * 0.02, 1)
     AND start_date IS NOT NULL AND v_record.start_date IS NOT NULL
     AND ABS(start_date - v_record.start_date) <= 7
   ORDER BY id ASC LIMIT 1;

  IF v_match_id IS NOT NULL THEN
    UPDATE migration_record
       SET status = 'flagged_logical_duplicate', updated_at = now()
     WHERE id = p_record_id AND tenant_id = p_tenant;
    RETURN TRUE;
  END IF;
  RETURN FALSE;
END $$;

REVOKE EXECUTE ON FUNCTION fn_migration_logical_duplicate_flag(BIGINT, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_logical_duplicate_flag(BIGINT, UUID) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_logical_duplicate_flag(BIGINT, UUID) IS
  'M22 (476) — logical-duplicate flag. DATE arithmetic fixed (no EXTRACT EPOCH on date subtraction).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (476, '476_m22_fix_purge_orchestrator_perms', CURRENT_TIMESTAMP);
