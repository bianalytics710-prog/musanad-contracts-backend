-- Migration: 592_executive_index_linked_outside_band.sql
-- Module: Executive Insights — Index-Linked Contracts revamp
-- Date: 2026-06-05
--
-- Adds fn_executive_index_linked_outside_band() — a sidecar reader that
-- powers the revamped "Index-Linked Contracts" section in the executive
-- dashboard.
--
-- Today the section shows misleading data:
--   • "At-risk contracts: 0" — but the module page shows 3.
--   • "Top contracts by margin" — vanity (biggest earners), not action items.
-- The bug: fn_dashboard_executive infers at-risk from
--   (recentMarginChange.deltaAed < 0)
-- which is a stale 30-day rolling proxy. It has nothing to do with whether
-- a contract is currently breaching its protection band.
--
-- This fn applies the same band-status rule the module page uses
-- (mig 491 fn_trade_position_list_band_projection) and computes per-position
-- margin impact:
--   above_ceiling → (benchmark - ceiling) * volume * usd_aed_rate
--   below_floor   → (floor - benchmark) * volume * usd_aed_rate
--   no_band       → 0 (no current breach, but flagged for amendment)
--
-- Returns a single JSONB envelope:
--   {
--     "count":               3,
--     "marginAtRiskAed":     "13800000.00",
--     "needsAmendmentCount": 1,
--     "benchmarkCode":       "murban_osp",
--     "benchmarkPriceUsd":   "103.00",
--     "asOf":                "2026-05-31",
--     "contracts": [
--       { "tradePositionId": 7, "positionRef": "TP-MURBAN-KR-JUL26",
--         "counterpartyName": "Hanwha TotalEnergies",
--         "bandStatus": "above_ceiling", "marginImpactAed": "7300000.00",
--         "hasClause": true,
--         "thresholdLabel": "Ceiling $102.00 vs OSP $103.00" },
--       ...
--     ]
--   }
--
-- The BE service appends this onto the existing executive response under
-- tradeMarginSummary.outsideBand without touching fn_dashboard_executive.
--
-- Permission: same gate as fn_dashboard_executive callers ("dashboard.executive.read");
-- DEFINER + tenant GUC ensures RLS-equivalent scoping.

BEGIN;

CREATE OR REPLACE FUNCTION fn_executive_index_linked_outside_band()
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tenant_id     UUID := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  v_benchmark     TEXT;
  v_benchmark_usd NUMERIC(10,4);
  v_benchmark_as  DATE;
  v_usd_aed       NUMERIC(10,4) := 3.67; -- demo default; overridden below
  v_total_at_risk NUMERIC(20,2) := 0;
  v_count         INTEGER       := 0;
  v_no_band_count INTEGER       := 0;
  v_contracts     JSONB         := '[]'::jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RETURN jsonb_build_object(
      'count', 0, 'marginAtRiskAed', '0', 'needsAmendmentCount', 0,
      'contracts', '[]'::jsonb
    );
  END IF;

  -- Pull the freshest usd→aed rate from any margin_snapshot we've already
  -- written for this tenant (consistency with the existing tradeMarginSummary
  -- aggregates). Falls back to 3.67 (demo seed) when no rows.
  SELECT lm.usd_aed_rate INTO v_usd_aed
    FROM latest_margin lm
   WHERE lm.tenant_id = v_tenant_id
   ORDER BY lm.computed_at DESC
   LIMIT 1;
  IF v_usd_aed IS NULL OR v_usd_aed <= 0 THEN
    v_usd_aed := 3.67;
  END IF;

  -- Identify the "active" benchmark: the pricing_basis used by the largest
  -- number of active sell-side positions. The demo has all positions on
  -- murban_osp; in production, the largest cohort drives the headline.
  SELECT tp.pricing_basis
    INTO v_benchmark
    FROM trade_position tp
   WHERE tp.tenant_id = v_tenant_id
     AND tp.is_active = TRUE
     AND tp.side      = 'sell'
   GROUP BY tp.pricing_basis
   ORDER BY COUNT(*) DESC
   LIMIT 1;

  -- Latest benchmark price + as-of date.
  IF v_benchmark IS NOT NULL THEN
    SELECT pb.price_value, pb.price_date
      INTO v_benchmark_usd, v_benchmark_as
      FROM price_benchmark pb
     WHERE pb.benchmark_code = v_benchmark
       AND pb.is_active = TRUE
     ORDER BY pb.price_date DESC
     LIMIT 1;
  END IF;

  -- Per-position band status + impact (S2-24 split-aggregate style: one
  -- pass builds the per-row dataset; aggregates pull from it separately).
  WITH positions AS (
    SELECT
      tp.id                                                       AS trade_position_id,
      tp.position_ref,
      COALESCE(p.name_en, 'Party #' || tp.counterparty_id::text)  AS counterparty_name,
      tp.contracted_floor_usd_per_bbl                             AS floor_usd,
      tp.contracted_ceiling_usd_per_bbl                           AS ceiling_usd,
      tp.band_review_clause_ref                                   AS clause_ref,
      tp.volume_bbl                                               AS volume_bbl,
      pb.price_value                                              AS benchmark_usd,
      CASE
        WHEN tp.contracted_floor_usd_per_bbl IS NULL
         AND tp.contracted_ceiling_usd_per_bbl IS NULL                 THEN 'no_band'
        WHEN pb.price_value IS NULL                                    THEN 'no_band'
        WHEN tp.contracted_floor_usd_per_bbl IS NOT NULL
         AND pb.price_value < tp.contracted_floor_usd_per_bbl          THEN 'below_floor'
        WHEN tp.contracted_ceiling_usd_per_bbl IS NOT NULL
         AND pb.price_value > tp.contracted_ceiling_usd_per_bbl        THEN 'above_ceiling'
        ELSE 'within_band'
      END                                                          AS band_status
    FROM trade_position tp
    LEFT JOIN party p ON p.id = tp.counterparty_id
    LEFT JOIN LATERAL (
      SELECT pb1.price_value
        FROM price_benchmark pb1
       WHERE pb1.benchmark_code = tp.pricing_basis
         AND pb1.is_active = TRUE
       ORDER BY pb1.price_date DESC
       LIMIT 1
    ) pb ON TRUE
    WHERE tp.tenant_id = v_tenant_id
      AND tp.is_active = TRUE
      AND tp.side      = 'sell'
  ),
  flagged AS (
    SELECT
      pos.*,
      CASE pos.band_status
        WHEN 'above_ceiling' THEN
          GREATEST(pos.benchmark_usd - pos.ceiling_usd, 0) * pos.volume_bbl * v_usd_aed
        WHEN 'below_floor'   THEN
          GREATEST(pos.floor_usd     - pos.benchmark_usd, 0) * pos.volume_bbl * v_usd_aed
        ELSE 0::NUMERIC
      END AS margin_impact_aed
    FROM positions pos
    WHERE pos.band_status IN ('above_ceiling', 'below_floor', 'no_band')
  )
  -- Aggregate scalars in one pass, then aggregate the top-3 contracts list.
  SELECT
    COUNT(*)::INTEGER,
    COUNT(*) FILTER (WHERE f.band_status = 'no_band')::INTEGER,
    COALESCE(SUM(f.margin_impact_aed), 0)
  INTO v_count, v_no_band_count, v_total_at_risk
  FROM flagged f;

  -- Top-3 by impact (then no_band tie-broken by position_ref).
  WITH positions AS (
    SELECT
      tp.id                                                       AS trade_position_id,
      tp.position_ref,
      COALESCE(p.name_en, 'Party #' || tp.counterparty_id::text)  AS counterparty_name,
      tp.contracted_floor_usd_per_bbl                             AS floor_usd,
      tp.contracted_ceiling_usd_per_bbl                           AS ceiling_usd,
      tp.band_review_clause_ref                                   AS clause_ref,
      tp.volume_bbl                                               AS volume_bbl,
      pb.price_value                                              AS benchmark_usd,
      CASE
        WHEN tp.contracted_floor_usd_per_bbl IS NULL
         AND tp.contracted_ceiling_usd_per_bbl IS NULL                 THEN 'no_band'
        WHEN pb.price_value IS NULL                                    THEN 'no_band'
        WHEN tp.contracted_floor_usd_per_bbl IS NOT NULL
         AND pb.price_value < tp.contracted_floor_usd_per_bbl          THEN 'below_floor'
        WHEN tp.contracted_ceiling_usd_per_bbl IS NOT NULL
         AND pb.price_value > tp.contracted_ceiling_usd_per_bbl        THEN 'above_ceiling'
        ELSE 'within_band'
      END                                                          AS band_status
    FROM trade_position tp
    LEFT JOIN party p ON p.id = tp.counterparty_id
    LEFT JOIN LATERAL (
      SELECT pb1.price_value
        FROM price_benchmark pb1
       WHERE pb1.benchmark_code = tp.pricing_basis
         AND pb1.is_active = TRUE
       ORDER BY pb1.price_date DESC
       LIMIT 1
    ) pb ON TRUE
    WHERE tp.tenant_id = v_tenant_id
      AND tp.is_active = TRUE
      AND tp.side      = 'sell'
  ),
  flagged AS (
    SELECT
      pos.*,
      CASE pos.band_status
        WHEN 'above_ceiling' THEN
          GREATEST(pos.benchmark_usd - pos.ceiling_usd, 0) * pos.volume_bbl * v_usd_aed
        WHEN 'below_floor'   THEN
          GREATEST(pos.floor_usd     - pos.benchmark_usd, 0) * pos.volume_bbl * v_usd_aed
        ELSE 0::NUMERIC
      END AS margin_impact_aed
    FROM positions pos
    WHERE pos.band_status IN ('above_ceiling', 'below_floor', 'no_band')
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'tradePositionId',  f.trade_position_id,
    'positionRef',      f.position_ref,
    'counterpartyName', f.counterparty_name,
    'bandStatus',       f.band_status,
    'marginImpactAed',  ROUND(f.margin_impact_aed, 2)::text,
    'hasClause',        (f.clause_ref IS NOT NULL),
    'thresholdLabel',   CASE f.band_status
      WHEN 'above_ceiling' THEN
        'Ceiling $' || trim(to_char(f.ceiling_usd, 'FM999990.00'))
          || ' vs benchmark $' || trim(to_char(f.benchmark_usd, 'FM999990.00'))
      WHEN 'below_floor'   THEN
        'Floor $' || trim(to_char(f.floor_usd, 'FM999990.00'))
          || ' vs benchmark $' || trim(to_char(f.benchmark_usd, 'FM999990.00'))
      ELSE 'No price-protection clause'
    END
  ) ORDER BY f.margin_impact_aed DESC NULLS LAST, f.position_ref ASC), '[]'::jsonb)
  INTO v_contracts
  FROM (
    SELECT * FROM flagged
    ORDER BY margin_impact_aed DESC NULLS LAST, position_ref ASC
    LIMIT 3
  ) f;

  RETURN jsonb_build_object(
    'count',               v_count,
    'marginAtRiskAed',     ROUND(v_total_at_risk, 2)::text,
    'needsAmendmentCount', v_no_band_count,
    'benchmarkCode',       v_benchmark,
    'benchmarkPriceUsd',   CASE WHEN v_benchmark_usd IS NULL THEN NULL ELSE trim(to_char(v_benchmark_usd, 'FM999990.00')) END,
    'asOf',                v_benchmark_as,
    'contracts',           v_contracts
  );

EXCEPTION WHEN OTHERS THEN
  -- Defensive: never break the executive dashboard if this sidecar fails.
  RETURN jsonb_build_object(
    'count', 0, 'marginAtRiskAed', '0', 'needsAmendmentCount', 0,
    'contracts', '[]'::jsonb,
    'error', SQLERRM
  );
END;
$$;

REVOKE ALL ON FUNCTION fn_executive_index_linked_outside_band() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_executive_index_linked_outside_band() TO neondb_owner;

COMMENT ON FUNCTION fn_executive_index_linked_outside_band() IS
  'Mig 592 — sidecar reader for Executive Insights → Index-Linked Contracts. Returns outside-band positions (above_ceiling / below_floor / no_band) using the same rule as fn_trade_position_list (mig 491), plus per-position margin impact in AED. BE merges into the executive response under tradeMarginSummary.outsideBand. Safe to call with no positions / no benchmark rows — returns the zero envelope. Errors are caught + reported in the response payload (never raised).';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (592, '592_executive_index_linked_outside_band', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_executive_index_linked_outside_band();
-- DELETE FROM schema_migrations WHERE version = 592;
-- COMMIT;
