-- MIGRATION: 537_drafter_users_and_initiated_by_backfill.sql
-- Date: 2026-06-03
-- Description:
--   Two cleanups for demo realism:
--
--   1. Add two additional contract_drafter users so the approver's pending
--      queue can show multiple distinct requesters. Until now only Hala
--      Al Suwaidi (user 5) carried the drafter role.
--
--   2. Backfill approval_chain.initiated_by — replace any non-drafter
--      requester (System Admin, Platform Admin, approver, etc.) with one
--      of the three drafters, rotated by chain id so the distribution is
--      varied. Real contracts are always initiated by a drafter, never by
--      ops/admin personas.

BEGIN;

-- ============================================================
-- 1. Seed two additional drafter users.
--    Same bcrypt hash as the other dev personas (ChangeMe@123).
-- ============================================================
INSERT INTO "user"
  (email, password_hash, first_name, last_name, role_id, is_active, created_at, updated_at, created_by, updated_by)
SELECT
  'drafter2@musanad.local',
  '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS',
  'Mariam',
  'Al Mansoori',
  r.id,
  TRUE,
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP,
  1,
  1
  FROM role r WHERE r.name = 'contract_drafter' AND r.is_active = TRUE
ON CONFLICT (email) DO NOTHING;

INSERT INTO "user"
  (email, password_hash, first_name, last_name, role_id, is_active, created_at, updated_at, created_by, updated_by)
SELECT
  'drafter3@musanad.local',
  '$2b$12$DKnrZ6AcYVymaaBFl9Yej.oXis7msJzFklrdATKoT4RCbQxlZeHZS',
  'Faisal',
  'Al Otaibi',
  r.id,
  TRUE,
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP,
  1,
  1
  FROM role r WHERE r.name = 'contract_drafter' AND r.is_active = TRUE
ON CONFLICT (email) DO NOTHING;

-- ============================================================
-- 2. Backfill chain.initiated_by — rotate across all drafters.
--    initiated_by has an immutability trigger (M2 anti-tamper). Temporarily
--    disable it for this maintenance pass; production code paths still
--    can't reassign requesters via fn_'s.
-- ============================================================
ALTER TABLE approval_chain DISABLE TRIGGER trg_approval_chain_immutable_fields;

DO $bf$
DECLARE
  v_drafters BIGINT[];
  v_drafter_count INTEGER;
BEGIN
  SELECT array_agg(u.id ORDER BY u.id)
    INTO v_drafters
    FROM "user" u
    JOIN role r ON r.id = u.role_id
   WHERE r.name = 'contract_drafter' AND u.is_active = TRUE;

  v_drafter_count := COALESCE(array_length(v_drafters, 1), 0);
  IF v_drafter_count = 0 THEN
    RAISE EXCEPTION 'backfill: no drafters available';
  END IF;

  UPDATE approval_chain ch
     SET initiated_by = v_drafters[((ch.id - 1) % v_drafter_count) + 1],
         updated_at   = CURRENT_TIMESTAMP
   WHERE NOT EXISTS (
           SELECT 1 FROM "user" u
            JOIN role r ON r.id = u.role_id
           WHERE u.id = ch.initiated_by
             AND r.name = 'contract_drafter'
         );
END;
$bf$;

ALTER TABLE approval_chain ENABLE TRIGGER trg_approval_chain_immutable_fields;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (537, 'drafter_users_and_initiated_by_backfill', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
