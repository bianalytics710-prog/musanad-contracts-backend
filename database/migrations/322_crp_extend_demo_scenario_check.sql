-- Migration: 322_crp_extend_demo_scenario_check.sql
-- Module: CR-P — ADNOC Demo Wiring
-- Description: Extend demo_scenario.scenario_id CHECK constraint
--              (demo_scenario_scenario_id_chk) to add 3 ADNOC tier-2 scenario_ids:
--              labor_cascade, budget_burn, trade_margin.
--              The original 8 ids are preserved byte-for-byte.
--              Pattern: DROP + re-ADD (ALTER TABLE … ADD CONSTRAINT) — standard
--              for extending a closed CHECK without losing the original set.
-- Date: 2026-05-29

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

-- Step 1: Drop the existing closed-set CHECK constraint
ALTER TABLE demo_scenario
  DROP CONSTRAINT demo_scenario_scenario_id_chk;

-- Step 2: Re-add with all 11 scenario_ids (original 8 + 3 new ADNOC tier-2)
ALTER TABLE demo_scenario
  ADD CONSTRAINT demo_scenario_scenario_id_chk CHECK (
    scenario_id IN (
      -- Original 8 hero scenarios (CR-I/CR-J) — preserved byte-for-byte
      'hormuz',
      'ofac_sanctions',
      'brent_review',
      'epc_sla',
      'renewal',
      'cyclone',
      'icv_shortfall',
      'esg_subcontractor',
      -- 3 ADNOC tier-2 stories (CR-M / CR-N / CR-O)
      'labor_cascade',
      'budget_burn',
      'trade_margin'
    )
  );

-- Update the table comment to reflect the new closed set
COMMENT ON TABLE demo_scenario IS '11 demo scenarios per tenant (8 hero + 3 ADNOC tier-2); binds a seed pack + event injection payload + expected outcome baselines. CHECK constraint on scenario_id is intentional — closed set per requirements; admin extension requires DDL.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (322, '322_crp_extend_demo_scenario_check', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 322;
-- -- Remove rows for the 3 new ids first (if seeded by migration 323):
-- -- DELETE FROM demo_scenario WHERE scenario_id IN ('labor_cascade','budget_burn','trade_margin');
-- ALTER TABLE demo_scenario DROP CONSTRAINT demo_scenario_scenario_id_chk;
-- ALTER TABLE demo_scenario ADD CONSTRAINT demo_scenario_scenario_id_chk CHECK (
--   scenario_id IN ('hormuz','ofac_sanctions','brent_review','epc_sla','renewal',
--                   'cyclone','icv_shortfall','esg_subcontractor')
-- );
-- ============================================================
