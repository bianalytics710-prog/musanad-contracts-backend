-- Migration: 471_m22_purge_audit_helper.sql
-- Module: M22 — patch fn_migration_purge_all to use fn_audit_log_record_v2
-- Date: 2026-06-02
--
-- audit_log carries a NOT NULL prev_hash + this_hash (M10 hash-chain). A
-- direct INSERT INTO audit_log bypasses the chain helper and fails. Route
-- the purge's audit entry through fn_audit_log_record_v2 instead.

CREATE OR REPLACE FUNCTION fn_migration_purge_all(p_dry_run BOOLEAN DEFAULT FALSE)
RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
AS $$
DECLARE
  v_tenant      UUID := fn_require_tenant_guc();
  v_actor       BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::bigint;
  v_role        TEXT;
  v_n_irq       INTEGER := 0;
  v_n_clauses   INTEGER := 0;
  v_n_risk      INTEGER := 0;
  v_n_oblig     INTEGER := 0;
  v_n_attach    INTEGER := 0;
  v_n_activity  INTEGER := 0;
  v_n_comments  INTEGER := 0;
  v_n_versions  INTEGER := 0;
  v_n_contracts INTEGER := 0;
  v_n_records   INTEGER := 0;
  v_n_batches   INTEGER := 0;
  v_total       INTEGER;
  v_counts      JSONB;
BEGIN
  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_actor;
  IF NOT fn_current_user_has_permission('migration.purge.all')
     AND COALESCE(v_role, '') <> 'Super Admin' THEN
    RAISE EXCEPTION 'migration_purge_permission_required' USING ERRCODE = '42501';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _purge_target_contracts (id BIGINT PRIMARY KEY) ON COMMIT DROP;
  TRUNCATE _purge_target_contracts;
  INSERT INTO _purge_target_contracts (id)
    SELECT DISTINCT contract_id
    FROM migration_record
    WHERE tenant_id = v_tenant AND contract_id IS NOT NULL;

  SELECT COUNT(*) INTO v_n_irq FROM ingestion_review_queue irq
    WHERE irq.id IN (SELECT ingestion_review_queue_id FROM migration_record
                      WHERE tenant_id = v_tenant AND ingestion_review_queue_id IS NOT NULL);
  SELECT COUNT(*) INTO v_n_clauses FROM contract_clause_extracted
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_risk FROM risk_score
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_oblig FROM contract_obligation
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_attach FROM contract_attachment
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_activity FROM contract_activity
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_comments FROM contract_comment
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_versions FROM contract_version
    WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_contracts FROM contract
    WHERE id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_records FROM migration_record WHERE tenant_id = v_tenant;
  SELECT COUNT(*) INTO v_n_batches FROM migration_batch  WHERE tenant_id = v_tenant;
  v_total := v_n_irq + v_n_clauses + v_n_risk + v_n_oblig + v_n_attach
           + v_n_activity + v_n_comments + v_n_versions + v_n_contracts
           + v_n_records + v_n_batches;
  v_counts := jsonb_build_object(
    'ingestionReviewQueue', v_n_irq,
    'contractClauseExtracted', v_n_clauses,
    'riskScore', v_n_risk,
    'contractObligation', v_n_oblig,
    'contractAttachment', v_n_attach,
    'contractActivity', v_n_activity,
    'contractComment', v_n_comments,
    'contractVersion', v_n_versions,
    'contract', v_n_contracts,
    'migrationRecord', v_n_records,
    'migrationBatch', v_n_batches
  );

  IF p_dry_run THEN
    RETURN jsonb_build_object('dryRun', TRUE, 'counts', v_counts, 'totalRows', v_total);
  END IF;

  SET LOCAL row_security = off;

  DELETE FROM ingestion_review_queue
   WHERE id IN (SELECT ingestion_review_queue_id FROM migration_record
                 WHERE tenant_id = v_tenant AND ingestion_review_queue_id IS NOT NULL);
  DELETE FROM contract_clause_extracted
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM risk_score
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_obligation
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_attachment
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_activity
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_comment
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_version
   WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract
   WHERE id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM migration_record WHERE tenant_id = v_tenant;
  DELETE FROM migration_batch  WHERE tenant_id = v_tenant;

  BEGIN
    REFRESH MATERIALIZED VIEW latest_risk_score;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- Use the hash-chain helper instead of a bare INSERT
  PERFORM fn_audit_log_record_v2(
    '__migration_purge__',
    NULL,
    'PURGE',
    jsonb_build_object('tenantId', v_tenant),
    jsonb_build_object('counts', v_counts, 'totalRows', v_total),
    v_actor
  );

  RETURN jsonb_build_object('dryRun', FALSE, 'counts', v_counts, 'totalRows', v_total);
END $$;

REVOKE EXECUTE ON FUNCTION fn_migration_purge_all(BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_purge_all(BOOLEAN) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_purge_all(BOOLEAN) IS
  'M22 (471) — uses fn_audit_log_record_v2 for hash-chain compliance.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (471, '471_m22_purge_audit_helper', CURRENT_TIMESTAMP);
