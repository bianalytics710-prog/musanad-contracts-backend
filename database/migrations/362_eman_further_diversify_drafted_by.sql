-- Migration: 362_eman_further_diversify_drafted_by.sql
-- Unit: Eman Executive QA Phase 3.3 (2026-05-31)
-- Fix:
--   E22 follow-up — mig 354 only rewrote rows where drafted_by was NULL or
--   bootstrap-admin. Dana's pre-existing 35 contracts stayed unchanged and
--   happened to be the most recent batch, so the contracts list (sorted
--   created_at DESC) still showed "Dana Drafter" on every visible row.
--
--   This migration redistributes the FULL set across the persona pool by
--   id-modulo, ignoring current drafted_by, so the first page of the
--   contracts list reads as diverse signatories.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM "user" WHERE id IN (4, 5, 6, 8, 12, 13, 14, 15) HAVING COUNT(*) = 8) THEN
    RAISE NOTICE 'Skipping persona redistribution — required demo persona users not present.';
    RETURN;
  END IF;

  -- E22 follow-up: distribute ALL contracts (not just NULL/admin) across the
  -- persona pool via id-modulo. Same weighting as mig 354. Keep HERO-001
  -- with its original owner (Dana) since the demo runbook references that.
  UPDATE contract
    SET drafted_by = CASE (id % 20)
      WHEN 0 THEN 5  WHEN 1 THEN 5  WHEN 2 THEN 5  WHEN 3 THEN 5
      WHEN 4 THEN 5  WHEN 5 THEN 5  WHEN 6 THEN 5
      WHEN 7 THEN 4  WHEN 8 THEN 4  WHEN 9 THEN 4
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
    WHERE is_active = TRUE
      AND contract_number NOT ILIKE '%HERO-001%';  -- preserve demo-hero ownership
END $$;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- Data redistribution migration. To undo:
--   UPDATE contract SET drafted_by = 5 WHERE drafted_by IN (4, 6, 8, 12, 13, 14, 15);
-- ============================================================
