-- Migration: 440_oqoodai_persona_names.sql
-- Unit: OqoodAI rebrand (2026-06-01) — Phase 2 — Persona Arab names
-- Scope: rename the 11 demo personas (excluding the System Admin bootstrap
--        account) so that (a) every first name is clearly Arab and (b) the
--        last name is a proper Emirati family name rather than a role-label
--        echo ("Drafter", "Counsel", "Approver", etc.).
-- Functional impact: NONE — login email + password unchanged. user.id, role_id,
--        every FK reference unchanged. Display names re-render automatically
--        across welcome line, avatar, activity feed, comments, etc.

BEGIN;

UPDATE "user" SET first_name='Layla',  last_name='Al Hashemi',  updated_at=NOW(), updated_by=1 WHERE lower(email)='legal@musanad.local';
UPDATE "user" SET first_name='Hala',   last_name='Al Suwaidi',  updated_at=NOW(), updated_by=1 WHERE lower(email)='drafter@musanad.local';
UPDATE "user" SET first_name='Aisha',  last_name='Al Nahyan',   updated_at=NOW(), updated_by=1 WHERE lower(email)='approver@musanad.local';
UPDATE "user" SET first_name='Sara',   last_name='Al Shamsi',   updated_at=NOW(), updated_by=1 WHERE lower(email)='approver2@musanad.local';
UPDATE "user" SET first_name='Rashid', last_name='Al Awadi',    updated_at=NOW(), updated_by=1 WHERE lower(email)='recipient@musanad.local';
UPDATE "user" SET first_name='Eman',   last_name='Al Mazrouei', updated_at=NOW(), updated_by=1 WHERE lower(email)='executive@musanad.local';
UPDATE "user" SET first_name='Yusuf',  last_name='Al Falasi',   updated_at=NOW(), updated_by=1 WHERE lower(email)='operations@musanad.local';
UPDATE "user" SET first_name='Fatima', last_name='Al Marri',    updated_at=NOW(), updated_by=1 WHERE lower(email)='finance@musanad.local';
UPDATE "user" SET first_name='Khalid', last_name='Al Qubaisi',  updated_at=NOW(), updated_by=1 WHERE lower(email)='compliance@musanad.local';
UPDATE "user" SET first_name='Hessa',  last_name='Al Hamadi',   updated_at=NOW(), updated_by=1 WHERE lower(email)='procurement@musanad.local';
-- platform@musanad.local (Omar Al Mansoori) deliberately unchanged — already Arab + Emirati family.
-- admin@musanad.local (System Admin) deliberately unchanged — system account, not a real persona.

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (440, 'OqoodAI Phase 2 — Arab persona display names (drop role-label last names)', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK BEGIN
-- BEGIN;
--   UPDATE "user" SET first_name='Layla',  last_name='Counsel'    WHERE lower(email)='legal@musanad.local';
--   UPDATE "user" SET first_name='Dana',   last_name='Drafter'    WHERE lower(email)='drafter@musanad.local';
--   UPDATE "user" SET first_name='Aisha',  last_name='Approver'   WHERE lower(email)='approver@musanad.local';
--   UPDATE "user" SET first_name='Sarah',  last_name='Stage'      WHERE lower(email)='approver2@musanad.local';
--   UPDATE "user" SET first_name='Rashid', last_name='Recipient'  WHERE lower(email)='recipient@musanad.local';
--   UPDATE "user" SET first_name='Eman',   last_name='Executive'  WHERE lower(email)='executive@musanad.local';
--   UPDATE "user" SET first_name='Omar',   last_name='Operations' WHERE lower(email)='operations@musanad.local';
--   UPDATE "user" SET first_name='Fatima', last_name='Finance'    WHERE lower(email)='finance@musanad.local';
--   UPDATE "user" SET first_name='Khalid', last_name='Compliance' WHERE lower(email)='compliance@musanad.local';
--   UPDATE "user" SET first_name='Pari',   last_name='Procurement' WHERE lower(email)='procurement@musanad.local';
--   DELETE FROM schema_migrations WHERE version=440;
-- COMMIT;
-- ROLLBACK END
