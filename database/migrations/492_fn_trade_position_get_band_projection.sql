-- Migration: 492_fn_trade_position_get_band_projection.sql
-- Module: Trade Margin — Executive demo Story 5a
-- Date: 2026-06-02
--
-- Extends fn_trade_position_get to surface the same band fields as
-- fn_trade_position_list (mig 491), so the detail page can render the
-- Price-protection card without a separate query.

DO $$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc WHERE proname = 'fn_trade_position_get' LIMIT 1;

  -- Append band + latest-benchmark + bandStatus into the final RETURN
  -- jsonb_build_object. The RETURN block currently closes with
  -- "'isActive', v_pos.is_active\n  );" — splice the new keys in before
  -- the closing parenthesis.
  v_def := REPLACE(v_def,
    $tok$'isActive',         v_pos.is_active
  );$tok$,
    $tok$'isActive',         v_pos.is_active,
    -- E-rev-H — Price-protection band fields (mig 490 + 491).
    'contractedFloorUsdPerBbl',   v_pos.contracted_floor_usd_per_bbl::text,
    'contractedCeilingUsdPerBbl', v_pos.contracted_ceiling_usd_per_bbl::text,
    'bandReviewClauseRef',        v_pos.band_review_clause_ref,
    'latestBenchmarkUsdPerBbl', (
      SELECT pb1.price_value::text
        FROM price_benchmark pb1
        WHERE pb1.benchmark_code = v_pos.pricing_basis
          AND pb1.is_active = TRUE
        ORDER BY pb1.price_date DESC
        LIMIT 1
    ),
    'bandStatus', CASE
      WHEN v_pos.contracted_floor_usd_per_bbl IS NULL
       AND v_pos.contracted_ceiling_usd_per_bbl IS NULL THEN 'no_band'
      ELSE (
        SELECT CASE
          WHEN pb1.price_value IS NULL THEN 'no_band'
          WHEN v_pos.contracted_floor_usd_per_bbl IS NOT NULL
           AND pb1.price_value < v_pos.contracted_floor_usd_per_bbl    THEN 'below_floor'
          WHEN v_pos.contracted_ceiling_usd_per_bbl IS NOT NULL
           AND pb1.price_value > v_pos.contracted_ceiling_usd_per_bbl  THEN 'above_ceiling'
          WHEN v_pos.contracted_floor_usd_per_bbl IS NOT NULL
           AND pb1.price_value <= v_pos.contracted_floor_usd_per_bbl + 1.5 THEN 'at_floor'
          WHEN v_pos.contracted_ceiling_usd_per_bbl IS NOT NULL
           AND pb1.price_value >= v_pos.contracted_ceiling_usd_per_bbl - 1.5 THEN 'at_ceiling'
          ELSE 'within_band'
        END
          FROM price_benchmark pb1
          WHERE pb1.benchmark_code = v_pos.pricing_basis
            AND pb1.is_active = TRUE
          ORDER BY pb1.price_date DESC
          LIMIT 1
      )
    END
  );$tok$);

  EXECUTE v_def;
END $$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (492, '492_fn_trade_position_get_band_projection', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;
