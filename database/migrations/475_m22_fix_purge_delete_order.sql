-- Migration: 475_m22_fix_purge_delete_order.sql
-- Module: M22 — fix fn_migration_purge_all delete ordering
-- Date: 2026-06-02
--
-- The fn (467) deleted migration_record + migration_batch LAST. But
-- migration_record has outbound FKs to contract.id, contract_version.id,
-- and ingestion_review_queue.id — meaning deleting contract / version /
-- IRQ first raises FK violations. Mig 473 widened scope but didn't fix
-- order.
--
-- Correct order (children before parents):
--   1. migration_record   (clears outbound FKs to contract/version/IRQ)
--   2. ingestion_review_queue   (now no inbound FK from migration_record)
--   3. contract_clause_extracted   (cleared by contract_id; also has
--      contract_version_id FK — gone before contract_version)
--   4. risk_score, obligation, attachment, activity, comment
--   5. contract_version
--   6. contract
--   7. migration_batch   (last — both inbound refs cleared)

CREATE OR REPLACE FUNCTION fn_migration_purge_all(p_dry_run BOOLEAN DEFAULT FALSE)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
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
    SELECT DISTINCT id FROM (
      SELECT contract_id AS id FROM migration_record
        WHERE tenant_id = v_tenant AND contract_id IS NOT NULL
      UNION
      SELECT c.id FROM contract c
        WHERE c.migration_batch_id IS NOT NULL
    ) s WHERE id IS NOT NULL;

  -- Stash IRQ ids referenced by migration_record before we delete the records.
  CREATE TEMP TABLE IF NOT EXISTS _purge_target_irq (id BIGINT PRIMARY KEY) ON COMMIT DROP;
  TRUNCATE _purge_target_irq;
  INSERT INTO _purge_target_irq (id)
    SELECT DISTINCT ingestion_review_queue_id FROM migration_record
     WHERE tenant_id = v_tenant AND ingestion_review_queue_id IS NOT NULL;

  -- COUNTS (computed before any DELETE)
  SELECT COUNT(*) INTO v_n_irq      FROM ingestion_review_queue WHERE id IN (SELECT id FROM _purge_target_irq);
  SELECT COUNT(*) INTO v_n_clauses  FROM contract_clause_extracted WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_risk     FROM risk_score                WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_oblig    FROM contract_obligation       WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_attach   FROM contract_attachment       WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_activity FROM contract_activity         WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_comments FROM contract_comment          WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_versions FROM contract_version          WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_contracts FROM contract                 WHERE id IN (SELECT id FROM _purge_target_contracts);
  SELECT COUNT(*) INTO v_n_records  FROM migration_record          WHERE tenant_id = v_tenant;
  SELECT COUNT(*) INTO v_n_batches  FROM migration_batch           WHERE tenant_id = v_tenant;
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

  -- ORDER: children + cross-references first.
  -- migration_record references contract / contract_version / IRQ —
  -- must be deleted before any of them. Self-FK (duplicate_of_record_id)
  -- nulled out first so we don't trip ourselves on the sweep.
  UPDATE migration_record SET duplicate_of_record_id = NULL
   WHERE tenant_id = v_tenant AND duplicate_of_record_id IS NOT NULL;
  DELETE FROM migration_record WHERE tenant_id = v_tenant;

  -- IRQ now has no inbound migration_record FK.
  DELETE FROM ingestion_review_queue WHERE id IN (SELECT id FROM _purge_target_irq);

  -- contract_clause_extracted has FK to contract_version.id too.
  DELETE FROM contract_clause_extracted WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM risk_score                WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_obligation       WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_attachment       WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_activity         WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_comment          WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract_version          WHERE contract_id IN (SELECT id FROM _purge_target_contracts);
  DELETE FROM contract                  WHERE id          IN (SELECT id FROM _purge_target_contracts);
  -- migration_batch last: contract.migration_batch_id + migration_record.migration_batch_id both gone.
  DELETE FROM migration_batch WHERE tenant_id = v_tenant;

  BEGIN
    REFRESH MATERIALIZED VIEW latest_risk_score;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  PERFORM fn_audit_log_record_v2(
    '__migration_purge__',
    NULL,
    'DELETE',
    jsonb_build_object('tenantId', v_tenant),
    jsonb_build_object('counts', v_counts, 'totalRows', v_total, 'event', 'migration_purge'),
    v_actor
  );

  RETURN jsonb_build_object('dryRun', FALSE, 'counts', v_counts, 'totalRows', v_total);
END $$;

REVOKE EXECUTE ON FUNCTION fn_migration_purge_all(BOOLEAN) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_migration_purge_all(BOOLEAN) TO neondb_owner;
COMMENT ON FUNCTION fn_migration_purge_all(BOOLEAN) IS
  'M22 (475) — purge migration data. Delete order: migration_record (cross-FK source) → IRQ → contract children → version → contract → batch. Fixes FK violation when batch references real contract_version + IRQ rows.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (475, '475_m22_fix_purge_delete_order', CURRENT_TIMESTAMP);
