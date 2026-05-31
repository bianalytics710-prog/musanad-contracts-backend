-- Migration: 354_eman_diversify_drafter_signatory_and_emirate_norm.sql
-- Unit: Eman Executive QA Phase 3.3 (2026-05-31)
-- Fixes:
--   E22 — Signatory column shows "System Admin" for ALL contracts. Root cause:
--         drafted_by NULL on 291/327 contracts → UI fallback shows admin name.
--         Distribute drafted_by across 10 demo personas (drafter / approver /
--         legal_counsel / executive / operations / finance / compliance /
--         procurement) using a deterministic id-modulo bucket so the same
--         contract always lands on the same persona.
--
--   E22 (cont) — signature_party.signer_user_id was admin or NULL for most
--         rows. Re-distribute signer_user_id across the same persona pool so
--         the contract list "Signatory" column reads diversely.
--
--   E15 / E26 — emirate column has MIXED casing: 'abu_dhabi' (203 rows) +
--         'Abu Dhabi' (5 rows) + 'dubai' (35) + 'Dubai' (15) etc. Normalize
--         all to lowercase snake_case (the canonical project convention).
--         Display layer will title-case via i18n key map.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- ── E15/E26 — emirate normalization ──────────────────────────
-- Map: title-case display strings → snake_case canonical
UPDATE contract
  SET emirate = lower(replace(emirate, ' ', '_'))
  WHERE emirate IS NOT NULL
    AND emirate ~ '[A-Z ]';

-- Test-branch guard: skip persona-based UPDATE if required demo personas
-- aren't seeded (test branch has different user IDs).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM "user" WHERE id IN (4, 5, 6, 8, 12, 13, 14, 15) HAVING COUNT(*) = 8) THEN
    RAISE NOTICE 'Skipping persona backfill — required demo persona users (4,5,6,8,12,13,14,15) not present in this branch.';
    RETURN;
  END IF;

-- ── E22 — drafted_by distribution ────────────────────────────
-- Persona pool (user IDs from probe):
--   5  drafter@musanad.local        Dana Drafter
--   6  approver@musanad.local       Aisha Approver
--   4  legal@musanad.local          Layla Counsel
--   8  executive@musanad.local      Eman Executive
--   12 operations@musanad.local     Omar Operations
--   13 finance@musanad.local        Fatima Finance
--   14 compliance@musanad.local     Khalid Compliance
--   15 procurement@musanad.local    Pari Procurement
--
-- Distribution: weight Dana 35% (she's the primary drafter), spread the rest.
-- Bucket via (id % 20):
--   0..6   (35%) → 5  Dana
--   7..9   (15%) → 4  Layla
--   10..12 (15%) → 6  Aisha
--   13..14 (10%) → 13 Fatima
--   15..16 (10%) → 14 Khalid
--   17     (5%)  → 12 Omar
--   18     (5%)  → 15 Pari
--   19     (5%)  → 8  Eman
UPDATE contract
  SET drafted_by = CASE (id % 20)
    WHEN 0 THEN 5 WHEN 1 THEN 5 WHEN 2 THEN 5 WHEN 3 THEN 5
    WHEN 4 THEN 5 WHEN 5 THEN 5 WHEN 6 THEN 5
    WHEN 7 THEN 4 WHEN 8 THEN 4 WHEN 9 THEN 4
    WHEN 10 THEN 6 WHEN 11 THEN 6 WHEN 12 THEN 6
    WHEN 13 THEN 13 WHEN 14 THEN 13
    WHEN 15 THEN 14 WHEN 16 THEN 14
    WHEN 17 THEN 12
    WHEN 18 THEN 15
    WHEN 19 THEN 8
    ELSE drafted_by
  END,
  updated_by = 1,
  updated_at = NOW()
  WHERE drafted_by IS NULL OR drafted_by IN (1, 2); -- replace null + bootstrap admin + test user

-- ── E22 (cont) — signature_party signer diversity ───────────
-- Re-assign signature_party.signer_user_id where it currently points to
-- admin/null or to non-persona users. Use signer_side to pick a sensible
-- signer pool: 'our' side gets internal personas (Aisha/Eman/Layla),
-- 'counterparty' side keeps existing email-only signers (no internal user).
UPDATE signature_party sp
  SET signer_user_id = CASE
    WHEN sp.signer_side = 'our' THEN
      CASE (sp.id % 4)
        WHEN 0 THEN 8  -- Eman Executive
        WHEN 1 THEN 6  -- Aisha Approver
        WHEN 2 THEN 4  -- Layla Counsel
        ELSE       12  -- Omar Operations
      END
    ELSE sp.signer_user_id
  END,
  updated_by = 1,
  updated_at = NOW()
  WHERE sp.signer_user_id IS NULL OR sp.signer_user_id IN (1, 2);

-- Also backfill signer_name_en where it shows "System Admin" (the UI source
-- of truth — the column the contract list actually reads).
UPDATE signature_party sp
  SET signer_name_en = u.first_name || ' ' || u.last_name,
      signer_name_ar = COALESCE(sp.signer_name_ar, u.first_name || ' ' || u.last_name),
      updated_by = 1,
      updated_at = NOW()
  FROM "user" u
  WHERE u.id = sp.signer_user_id
    AND (sp.signer_name_en IS NULL OR sp.signer_name_en ILIKE 'System Admin%' OR sp.signer_name_en = '');

END $$;  -- close test-branch guard

-- ============================================================
-- ROLLBACK
-- ============================================================
-- This is a data-mutation migration; rollback is best-effort:
--   - Emirate normalization is monotonic (lower+snake) — no rollback.
--   - drafted_by/signer_user_id were predominantly NULL or admin before;
--     re-running the original seed migrations is the recovery path.
-- ============================================================
