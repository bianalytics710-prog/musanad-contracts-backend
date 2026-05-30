-- Migration: 334_crq_seed_icv_attachments.sql
-- Module: CR-Q — ADNOC Data Scale-Up (v1.4 foundation)
-- Description: Seeds contract_attachment rows with kind='icv_certificate' for ~42
--              CRQ-% services contracts spread across emirates.
--              ~10% of contractor universe (plausible ADNOC tendering reality).
--              Picks specific contract numbers from each ADNOC subsidiary batch seeded in mig 328.
--              contract_attachment columns: contract_id, filename, mime_type, size_bytes,
--                storage_bucket, storage_path, uploaded_by, description, kind, is_active,
--                created_at, updated_at, created_by, updated_by.
--              No tenant_id on contract_attachment.
--              Idempotent: ON CONFLICT ON CONSTRAINT contract_attachment_storage_path_uq DO NOTHING.
-- Rollback: See ROLLBACK section below.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_seed_user  BIGINT;
  v_counter    INTEGER := 0;
  r            RECORD;
BEGIN
  SELECT MIN(id) INTO v_seed_user FROM "user" WHERE is_active = TRUE;

  -- Insert ICV certificate attachments for ~42 CRQ services contracts
  FOR r IN
    SELECT c.id, c.contract_number
    FROM contract c
    WHERE c.contract_number IN (
      -- Onshore (12 — mix Abu Dhabi, Dubai, Sharjah)
      'CRQ-ONS-002','CRQ-ONS-004','CRQ-ONS-006','CRQ-ONS-008',
      'CRQ-ONS-011','CRQ-ONS-015','CRQ-ONS-018','CRQ-ONS-022',
      'CRQ-ONS-028','CRQ-ONS-035','CRQ-ONS-042','CRQ-ONS-058',
      -- Offshore (10)
      'CRQ-OFF-002','CRQ-OFF-005','CRQ-OFF-009','CRQ-OFF-013',
      'CRQ-OFF-017','CRQ-OFF-022','CRQ-OFF-030','CRQ-OFF-038',
      'CRQ-OFF-048','CRQ-OFF-055',
      -- Drilling (8)
      'CRQ-DRL-002','CRQ-DRL-006','CRQ-DRL-012','CRQ-DRL-018',
      'CRQ-DRL-025','CRQ-DRL-033','CRQ-DRL-040','CRQ-DRL-048',
      -- Gas (4 — excludes gas_spa rows)
      'CRQ-GAS-002','CRQ-GAS-007','CRQ-GAS-018','CRQ-GAS-025',
      -- L&S (4)
      'CRQ-LS-003','CRQ-LS-008','CRQ-LS-014','CRQ-LS-020',
      -- Distribution (4)
      'CRQ-DIS-003','CRQ-DIS-009','CRQ-DIS-016','CRQ-DIS-022'
    )
    AND c.contract_type = 'services'  -- guard: skip any non-services
    ORDER BY c.contract_number
  LOOP
    INSERT INTO contract_attachment
      (contract_id, filename, mime_type, size_bytes, storage_bucket, storage_path,
       uploaded_by, description, kind,
       created_at, updated_at, created_by, updated_by, is_active)
    VALUES (
      r.id,
      'ICV-CERT-' || r.contract_number || '-FY2026.pdf',
      'application/pdf',
      204800,
      'contract-attachments',
      'demo/crq-334/' || lower(replace(r.contract_number, '-', '_')) || '_icv_fy2026.pdf',
      v_seed_user,
      'valid_until=2027-03-31 ICV Certificate FY2026 — ' || r.contract_number || '. Score: 35%. Issued by ADNOC ICV Programme.',
      'icv_certificate',
      NOW(), NOW(), v_seed_user, v_seed_user, TRUE
    )
    ON CONFLICT ON CONSTRAINT contract_attachment_storage_path_uq DO NOTHING;

    v_counter := v_counter + 1;
  END LOOP;

  RAISE NOTICE '334: ICV certificate attachments seeded for % CRQ services contracts.', v_counter;
END;
$$;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (334, '334_crq_seed_icv_attachments', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DELETE FROM contract_attachment
--   WHERE storage_bucket = 'contract-attachments'
--     AND storage_path LIKE 'demo/crq-334/%';
-- DELETE FROM schema_migrations WHERE version = 334;
-- COMMIT;
-- ============================================================
