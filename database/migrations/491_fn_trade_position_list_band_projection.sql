-- Migration: 491_fn_trade_position_list_band_projection.sql
-- Module: Trade Margin — Executive demo Story 5a
-- Date: 2026-06-02
--
-- Extends fn_trade_position_list to project:
--   contractedFloorUsdPerBbl
--   contractedCeilingUsdPerBbl
--   bandReviewClauseRef
--   latestBenchmarkUsdPerBbl  (latest price_benchmark for the position's pricing_basis)
--   bandStatus                (one of: within_band | at_floor | at_ceiling |
--                              below_floor | above_ceiling | no_band)
--
-- Body otherwise byte-for-byte identical to 315. Same signature, same perm
-- check, same tenant gate.

CREATE OR REPLACE FUNCTION public.fn_trade_position_list(
  p_actor_id BIGINT,
  p_side     TEXT    DEFAULT NULL,
  p_grade    TEXT    DEFAULT NULL,
  p_status   TEXT    DEFAULT NULL,
  p_search   TEXT    DEFAULT NULL,
  p_page     INTEGER DEFAULT 1,
  p_limit    INTEGER DEFAULT 50
) RETURNS JSONB
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_tenant_id UUID;
  v_offset    INTEGER;
  v_total     INTEGER;
  v_data      JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('finance.margin.read') THEN
    RAISE EXCEPTION 'fn_trade_position_list: forbidden — finance.margin.read required'
      USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_trade_position_list: tenant context not set'
      USING ERRCODE = '42501';
  END IF;

  v_offset := (COALESCE(p_page, 1) - 1) * COALESCE(p_limit, 50);

  SELECT COUNT(*) INTO v_total
  FROM trade_position tp
  LEFT JOIN party cp ON cp.id = tp.counterparty_id
  WHERE tp.tenant_id = v_tenant_id
    AND tp.is_active = TRUE
    AND (p_side   IS NULL OR tp.side   = p_side)
    AND (p_grade  IS NULL OR tp.grade  = p_grade)
    AND (p_status IS NULL OR tp.status = p_status)
    AND (p_search IS NULL OR
         tp.position_ref ILIKE '%' || p_search || '%' OR
         cp.name_en ILIKE '%' || p_search || '%');

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',              tp.id,
      'positionRef',     tp.position_ref,
      'side',            tp.side,
      'grade',           tp.grade,
      'counterparty',    jsonb_build_object('id', cp.id, 'nameEn', cp.name_en, 'nameAr', cp.name_ar),
      'volumeBbl',       tp.volume_bbl::text,
      'pricingBasis',    tp.pricing_basis,
      'deliveryMonth',   tp.delivery_month,
      'termOrSpot',      tp.term_or_spot,
      'status',          tp.status,
      'marginPerBbl',    lm.margin_per_bbl::text,
      'totalMarginUsd',  lm.total_margin_usd::text,
      'totalMarginAed',  lm.total_margin_aed::text,
      'recommendation',  lm.recommendation,
      'latestComputedAt', lm.computed_at,
      -- E-rev-H — Price-protection band fields (mig 490).
      'contractedFloorUsdPerBbl',   tp.contracted_floor_usd_per_bbl::text,
      'contractedCeilingUsdPerBbl', tp.contracted_ceiling_usd_per_bbl::text,
      'bandReviewClauseRef',        tp.band_review_clause_ref,
      'latestBenchmarkUsdPerBbl',   pb.price_value::text,
      'bandStatus', CASE
        WHEN tp.contracted_floor_usd_per_bbl IS NULL
         AND tp.contracted_ceiling_usd_per_bbl IS NULL THEN 'no_band'
        WHEN pb.price_value IS NULL THEN 'no_band'
        WHEN tp.contracted_floor_usd_per_bbl IS NOT NULL
         AND pb.price_value < tp.contracted_floor_usd_per_bbl   THEN 'below_floor'
        WHEN tp.contracted_ceiling_usd_per_bbl IS NOT NULL
         AND pb.price_value > tp.contracted_ceiling_usd_per_bbl THEN 'above_ceiling'
        WHEN tp.contracted_floor_usd_per_bbl IS NOT NULL
         AND pb.price_value <= tp.contracted_floor_usd_per_bbl + 1.5 THEN 'at_floor'
        WHEN tp.contracted_ceiling_usd_per_bbl IS NOT NULL
         AND pb.price_value >= tp.contracted_ceiling_usd_per_bbl - 1.5 THEN 'at_ceiling'
        ELSE 'within_band'
      END
    ) ORDER BY tp.delivery_month ASC, tp.id ASC
  ), '[]'::jsonb) INTO v_data
  FROM trade_position tp
  LEFT JOIN party cp ON cp.id = tp.counterparty_id
  LEFT JOIN latest_margin lm ON lm.trade_position_id = tp.id
    AND lm.tenant_id = v_tenant_id
  -- E-rev-H — Latest benchmark price for this position's pricing_basis.
  -- pricing_basis is one of {murban_osp, brent, dubai, wti, spot}; map 1:1
  -- onto benchmark_code (spot has no entry, so the LEFT JOIN nulls out).
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
    AND (p_side   IS NULL OR tp.side   = p_side)
    AND (p_grade  IS NULL OR tp.grade  = p_grade)
    AND (p_status IS NULL OR tp.status = p_status)
    AND (p_search IS NULL OR
         tp.position_ref ILIKE '%' || p_search || '%' OR
         cp.name_en ILIKE '%' || p_search || '%')
  LIMIT COALESCE(p_limit, 50) OFFSET v_offset;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       COALESCE(p_page, 1),
      'limit',      COALESCE(p_limit, 50),
      'totalPages', CEIL(v_total::FLOAT / COALESCE(p_limit, 50))::INTEGER
    )
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_trade_position_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (491, '491_fn_trade_position_list_band_projection', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;
