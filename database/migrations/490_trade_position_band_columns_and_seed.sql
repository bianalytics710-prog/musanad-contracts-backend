-- Migration: 490_trade_position_band_columns_and_seed.sql
-- Module: Trade Margin — Executive demo Story 5a (Murban OSP × sell-side margin)
-- Date: 2026-06-02
--
-- Goal: surface contracted price-protection bands on Murban sell positions so
-- the executive can see when OSP movement breaches a buyer's negotiated band
-- (floor / ceiling) and which positions are entirely unprotected.
--
-- Adds:
--   trade_position.contracted_floor_usd_per_bbl   — buyer's floor (ADNOC protection)
--   trade_position.contracted_ceiling_usd_per_bbl — buyer's ceiling (buyer protection)
--   trade_position.band_review_clause_ref         — short text ref to the source clause
--
-- Seeds 7 Murban sell positions with a mix of bands:
--   - 4 positions with realistic bands (within range today)
--   - 2 positions with NO band       → Escalate-to-drafter demo rows
--   - 1 position with OSP at the floor → "protection kicked in" beat

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

ALTER TABLE trade_position
  ADD COLUMN IF NOT EXISTS contracted_floor_usd_per_bbl   NUMERIC(12,4) NULL,
  ADD COLUMN IF NOT EXISTS contracted_ceiling_usd_per_bbl NUMERIC(12,4) NULL,
  ADD COLUMN IF NOT EXISTS band_review_clause_ref         TEXT          NULL;

COMMENT ON COLUMN trade_position.contracted_floor_usd_per_bbl IS
  'Negotiated lower bound on the pricing-basis benchmark. When the benchmark trades below this floor, the contract holds at the floor (protects ADNOC margin). NULL = no floor negotiated.';
COMMENT ON COLUMN trade_position.contracted_ceiling_usd_per_bbl IS
  'Negotiated upper bound on the pricing-basis benchmark. When the benchmark trades above the ceiling, the buyer can invoke a price-review window (protects buyer cost). NULL = no ceiling negotiated.';
COMMENT ON COLUMN trade_position.band_review_clause_ref IS
  'Short reference to the source clause in the linked contract (e.g. "Clause 7.3 (Price Review Window)"). Display-only.';

-- Seed bands.
-- Mapping by position_ref (created in 297_..._trade_seed_demo_positions.sql).
-- Murban OSP latest = $103/bbl (Dec 2026).
DO $$
DECLARE
  v_floor       NUMERIC;
  v_ceiling     NUMERIC;
  v_clause_ref  TEXT;
BEGIN
  -- TP-MURBAN-KR-JUN26 (Hanwha TotalEnergies, JUN delivery): standard
  -- mid-range band; OSP today ($103) sits comfortably in the middle.
  UPDATE trade_position
    SET contracted_floor_usd_per_bbl   = 95.00,
        contracted_ceiling_usd_per_bbl = 115.00,
        band_review_clause_ref         = 'Clause 7.3 — Price Review Window'
    WHERE position_ref = 'TP-MURBAN-KR-JUN26';

  -- TP-MURBAN-KR-JUL26 (Hanwha, JUL): slightly tighter band.
  UPDATE trade_position
    SET contracted_floor_usd_per_bbl   = 95.00,
        contracted_ceiling_usd_per_bbl = 110.00,
        band_review_clause_ref         = 'Clause 7.3 — Price Review Window'
    WHERE position_ref = 'TP-MURBAN-KR-JUL26';

  -- TP-MURBAN-KR-AUG26 (Hanwha, AUG): OSP for AUG was $100.50 (above $98 floor
  -- but close). Story beat — this is the "protection-kicked-in" row when we
  -- nudge OSP slightly. Tighten floor to $100 so the demo reads as "at floor".
  UPDATE trade_position
    SET contracted_floor_usd_per_bbl   = 100.00,
        contracted_ceiling_usd_per_bbl = 112.00,
        band_review_clause_ref         = 'Clause 7.3 — Price Review Window (floor active)'
    WHERE position_ref = 'TP-MURBAN-KR-AUG26';

  -- TP-MURBAN-SG-SEP26 (Singapore Jurong, SEP): no band negotiated.
  -- → Escalate-to-drafter target #1.
  UPDATE trade_position
    SET contracted_floor_usd_per_bbl   = NULL,
        contracted_ceiling_usd_per_bbl = NULL,
        band_review_clause_ref         = NULL
    WHERE position_ref = 'TP-MURBAN-SG-SEP26';

  -- TP-MURBAN-IN-OCT26 (Reliance Jamnagar, OCT): wide band, no immediate risk.
  UPDATE trade_position
    SET contracted_floor_usd_per_bbl   = 90.00,
        contracted_ceiling_usd_per_bbl = 120.00,
        band_review_clause_ref         = 'Clause 7.3 — Price Review Window'
    WHERE position_ref = 'TP-MURBAN-IN-OCT26';

  -- TP-MURBAN-JP-NOV26 (Showa Shell, NOV): no band negotiated.
  -- → Escalate-to-drafter target #2.
  UPDATE trade_position
    SET contracted_floor_usd_per_bbl   = NULL,
        contracted_ceiling_usd_per_bbl = NULL,
        band_review_clause_ref         = NULL
    WHERE position_ref = 'TP-MURBAN-JP-NOV26';

  -- TP-MURBAN-SE-DEC26 (Nynas Sweden, DEC): band with ceiling actively
  -- tight, OSP today $103 is just below ceiling — reads "near ceiling".
  UPDATE trade_position
    SET contracted_floor_usd_per_bbl   = 97.00,
        contracted_ceiling_usd_per_bbl = 105.00,
        band_review_clause_ref         = 'Clause 7.3 — Price Review Window (near ceiling)'
    WHERE position_ref = 'TP-MURBAN-SE-DEC26';
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (490, '490_trade_position_band_columns_and_seed', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;
