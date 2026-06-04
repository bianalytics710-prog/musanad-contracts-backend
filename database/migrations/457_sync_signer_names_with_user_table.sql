-- Migration: 457_sync_signer_names_with_user_table.sql
-- Module: Persona rename — E2E walkthrough Issue #5 fix
-- Description: Migration 440 renamed user records (Rashid Recipient →
--              Rashid Al Awadi, Dana Drafter → Hala Al Suwaidi, etc.) but
--              signature_party.signer_name_en rows had the old names
--              snapshotted at invitation-creation time. The external
--              /sign/{token} page renders signature_party.signer_name_en
--              so it still shows "Rashid Recipient" on signing pages.
--              Backfill signature_party from the user table using
--              signer_user_id as the FK + first_name + ' ' + last_name.
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

UPDATE signature_party sp
SET
  signer_name_en = trim(u.first_name || ' ' || u.last_name),
  updated_at     = now()
FROM "user" u
WHERE sp.signer_user_id = u.id
  AND sp.is_active = TRUE
  AND lower(sp.signer_name_en) ~
      '(recipient|drafter|approver|counsel|executive|operations|finance|compliance|procurement|stage)$';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (457, '457_sync_signer_names_with_user_table', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 457;
-- ============================================================
