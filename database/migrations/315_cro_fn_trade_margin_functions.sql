-- Migration: 315_cro_fn_trade_margin_functions.sql
-- Module: CR-O — Oil-Trade Margin (M21 Financial Intelligence, Trade half)
-- Description: ALL CR-O fn_'s (D-1..D-10): fn_margin_compute, fn_margin_recompute_for_price_change,
--              fn_margin_aggregate, fn_trade_position_list, fn_trade_position_get,
--              fn_price_benchmark_list, fn_price_benchmark_record, fn_margin_snapshot_history,
--              fn_price_benchmark_get_by_id (internal), fn_trade_position_get_by_id (internal).
--              Each with COMMENT + REVOKE PUBLIC + GRANT neondb_owner trio (S2-21 / B14).
--              Permission gates IN FUNCTION BODY (DEFECT-CRN-DB-01 lesson): read fns gate
--              finance.margin.read; write/recompute fns gate finance.trade.manage.
--              S2-24: fn_margin_aggregate + fn_margin_recompute use split-aggregate CTEs.
--              S2-19: fn_margin_recompute calls fn_margin_compute(BIGINT,BIGINT,NUMERIC) — 3-arg.
--              S2-25/S2-26: explicit ERRCODE on every RAISE; WHEN OTHERS preserves SQLSTATE.
--              NUMERIC(12,4) per-bbl; NUMERIC(18,2) totals; AED/USD totals as ::text in JSONB.
--              A3: every SELECT from latest_margin includes explicit tenant_id filter.
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

BEGIN;

-- ============================================================
-- D-9 (internal helper — defined first, used by D-7)
-- fn_price_benchmark_get_by_id
-- ============================================================
CREATE OR REPLACE FUNCTION fn_price_benchmark_get_by_id(
  p_actor_id BIGINT,
  p_id       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_row JSONB;
BEGIN
  -- Internal helper: called only by fn_price_benchmark_record. RLS still tenant-scopes.
  -- No external permission gate (caller already gated finance.trade.manage).
  SELECT jsonb_build_object(
    'id',              pb.id,
    'benchmarkCode',   pb.benchmark_code,
    'priceDate',       pb.price_date,
    'priceValue',      pb.price_value::text,
    'unit',            pb.unit,
    'periodGrain',     pb.period_grain,
    'source',          pb.source,
    'notes',           pb.notes,
    'createdAt',       pb.created_at,
    'updatedAt',       pb.updated_at,
    'createdBy',       pb.created_by,
    'updatedBy',       pb.updated_by,
    'isActive',        pb.is_active
  ) INTO v_row
  FROM price_benchmark pb
  WHERE pb.id = p_id AND pb.is_active = TRUE;

  RETURN v_row;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_price_benchmark_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_price_benchmark_get_by_id(BIGINT, BIGINT) IS
  'CR-O internal helper: returns one price_benchmark row as JSONB. Called by fn_price_benchmark_record after UPSERT. No external permission gate — caller fn already verified finance.trade.manage. RLS provides tenant isolation.';
REVOKE EXECUTE ON FUNCTION fn_price_benchmark_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_price_benchmark_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- D-10 (internal helper — defined before D-1/D-5, used by position write path)
-- fn_trade_position_get_by_id
-- ============================================================
CREATE OR REPLACE FUNCTION fn_trade_position_get_by_id(
  p_actor_id BIGINT,
  p_id       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_row JSONB;
BEGIN
  -- Internal helper: lightweight single-row fetch for write-fn return path.
  -- No external gate — RLS provides tenant isolation.
  SELECT jsonb_build_object(
    'id',              tp.id,
    'positionRef',     tp.position_ref,
    'side',            tp.side,
    'grade',           tp.grade,
    'counterpartyId',  tp.counterparty_id,
    'volumeBbl',       tp.volume_bbl::text,
    'pricingBasis',    tp.pricing_basis,
    'deliveryMonth',   tp.delivery_month,
    'termOrSpot',      tp.term_or_spot,
    'status',          tp.status,
    'isActive',        tp.is_active,
    'createdAt',       tp.created_at,
    'updatedAt',       tp.updated_at
  ) INTO v_row
  FROM trade_position tp
  WHERE tp.id = p_id AND tp.is_active = TRUE;

  RETURN v_row;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_trade_position_get_by_id: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_trade_position_get_by_id(BIGINT, BIGINT) IS
  'CR-O internal helper: lightweight single-row fetch for trade_position. No external permission gate — caller fn already verified. RLS provides tenant isolation.';
REVOKE EXECUTE ON FUNCTION fn_trade_position_get_by_id(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_trade_position_get_by_id(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- D-1. fn_margin_compute
-- SECURITY INVOKER, VOLATILE — writes a margin_snapshot row + refreshes latest_margin MV.
-- Gates finance.margin.read (compute is read-tier — reachable from GET detail).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_margin_compute(
  p_actor_id           BIGINT,
  p_trade_position_id  BIGINT,
  p_benchmark_price    NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id         UUID;
  v_pos               RECORD;
  v_usd_aed_rate      NUMERIC(12,4);
  v_benchmark_price   NUMERIC(12,4);
  v_benchmark_code    TEXT;
  v_revenue_per_bbl   NUMERIC(12,4);
  v_cost_per_bbl      NUMERIC(12,4);
  v_revenue_comps     NUMERIC(12,4);
  v_cost_comps        NUMERIC(12,4);
  v_margin_per_bbl    NUMERIC(12,4);
  v_total_margin_usd  NUMERIC(18,2);
  v_total_margin_aed  NUMERIC(18,2);
  v_recommendation    TEXT;
  v_triggered_by      TEXT;
  v_breakdown         JSONB;
  v_snap_id           BIGINT;
  v_actor             BIGINT;
  v_revenue_items     JSONB;
  v_cost_items        JSONB;
BEGIN
  -- Step 1: Gate finance.margin.read
  IF NOT fn_current_user_has_permission('finance.margin.read') THEN
    RAISE EXCEPTION 'fn_margin_compute: forbidden — finance.margin.read required'
      USING ERRCODE = '42501';
  END IF;

  -- Step 2: Resolve tenant from GUC
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_margin_compute: tenant context not set'
      USING ERRCODE = '42501';
  END IF;

  v_actor := NULLIF(p_actor_id, 0);

  -- Step 3: Fetch position
  SELECT tp.* INTO v_pos
  FROM trade_position tp
  WHERE tp.id = p_trade_position_id
    AND tp.tenant_id = v_tenant_id
    AND tp.is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_margin_compute: trade_position % not found or inactive', p_trade_position_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Step 4: Resolve usd_aed FX rate
  SELECT pb.price_value INTO v_usd_aed_rate
  FROM price_benchmark pb
  WHERE pb.tenant_id = v_tenant_id
    AND pb.benchmark_code = 'usd_aed'
    AND pb.unit = 'aed_per_usd'
    AND pb.is_active = TRUE
  ORDER BY pb.price_date DESC
  LIMIT 1;

  IF v_usd_aed_rate IS NULL THEN
    RAISE EXCEPTION 'fn_margin_compute: usd_aed benchmark not configured'
      USING ERRCODE = '22023';
  END IF;

  -- Step 5: Resolve benchmark price (seller) / compute revenue (buyer)
  IF v_pos.side = 'sell' THEN
    v_benchmark_code := v_pos.pricing_basis;  -- e.g. 'murban_osp'

    IF p_benchmark_price IS NOT NULL THEN
      v_benchmark_price := p_benchmark_price::NUMERIC(12,4);
    ELSE
      -- Resolve: latest price_date <= delivery_month for this benchmark code
      SELECT pb.price_value INTO v_benchmark_price
      FROM price_benchmark pb
      WHERE pb.tenant_id = v_tenant_id
        AND pb.benchmark_code = v_pos.pricing_basis
        AND pb.price_date <= v_pos.delivery_month
        AND pb.unit = 'usd_per_bbl'
        AND pb.is_active = TRUE
      ORDER BY pb.price_date DESC
      LIMIT 1;

      IF v_benchmark_price IS NULL THEN
        RAISE EXCEPTION 'fn_margin_compute: no price_benchmark resolvable for code=% at delivery_month=%',
          v_pos.pricing_basis, v_pos.delivery_month
          USING ERRCODE = '22023';
      END IF;
    END IF;

    v_revenue_per_bbl := v_benchmark_price;

    -- Build revenue items for breakdown
    v_revenue_items := jsonb_build_array(
      jsonb_build_object(
        'label',     'Murban OSP',
        'type',      'benchmark',
        'usdPerBbl', v_benchmark_price::text
      )
    );

  ELSE
    -- Buyer: revenue from downstream_sale component (is_revenue = TRUE)
    v_benchmark_code  := NULL;
    v_benchmark_price := NULL;

    SELECT COALESCE(SUM(tcc.amount_usd_per_bbl), 0) INTO v_revenue_comps
    FROM trade_cost_component tcc
    WHERE tcc.trade_position_id = v_pos.id
      AND tcc.tenant_id = v_tenant_id
      AND tcc.is_revenue = TRUE
      AND tcc.is_active = TRUE;

    v_revenue_per_bbl := v_revenue_comps;

    -- Build revenue items from downstream_sale components
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'label',     tcc.component_type,
        'type',      'component',
        'usdPerBbl', tcc.amount_usd_per_bbl::text
      )
    ), '[]'::jsonb) INTO v_revenue_items
    FROM trade_cost_component tcc
    WHERE tcc.trade_position_id = v_pos.id
      AND tcc.tenant_id = v_tenant_id
      AND tcc.is_revenue = TRUE
      AND tcc.is_active = TRUE;
  END IF;

  -- Step 6: Aggregate cost components (split-aggregate — single scalar SELECT per S2-24)
  SELECT
    COALESCE(SUM(tcc.amount_usd_per_bbl) FILTER (WHERE tcc.is_revenue = FALSE), 0)
  INTO v_cost_per_bbl
  FROM trade_cost_component tcc
  WHERE tcc.trade_position_id = v_pos.id
    AND tcc.tenant_id = v_tenant_id
    AND tcc.is_active = TRUE;

  -- Build cost items for breakdown
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'componentType', tcc.component_type,
      'usdPerBbl',     tcc.amount_usd_per_bbl::text
    ) ORDER BY tcc.id
  ), '[]'::jsonb) INTO v_cost_items
  FROM trade_cost_component tcc
  WHERE tcc.trade_position_id = v_pos.id
    AND tcc.tenant_id = v_tenant_id
    AND tcc.is_revenue = FALSE
    AND tcc.is_active = TRUE;

  -- Step 7: Compute per-bbl + totals per D-0
  v_margin_per_bbl   := v_revenue_per_bbl - v_cost_per_bbl;
  v_total_margin_usd := ROUND((v_margin_per_bbl * v_pos.volume_bbl)::NUMERIC, 2);
  v_total_margin_aed := ROUND((v_total_margin_usd * v_usd_aed_rate)::NUMERIC, 2);

  -- Recommendation
  IF v_pos.side = 'sell' THEN
    v_recommendation := CASE WHEN v_margin_per_bbl > 0 THEN 'sell' ELSE 'review' END;
  ELSE
    v_recommendation := CASE WHEN v_margin_per_bbl > 0 THEN 'buy' ELSE 'hold' END;
  END IF;

  -- Triggered_by
  v_triggered_by := CASE WHEN p_benchmark_price IS NOT NULL THEN 'price_change' ELSE 'manual' END;

  -- Step 8: Build breakdown JSONB
  v_breakdown := jsonb_build_object(
    'revenue',         v_revenue_items,
    'costs',           v_cost_items,
    'totalCostPerBbl', v_cost_per_bbl::text,
    'marginPerBbl',    v_margin_per_bbl::text,
    'fx',              jsonb_build_object('code', 'usd_aed', 'rate', v_usd_aed_rate::text)
  );

  -- Step 9: INSERT margin_snapshot
  INSERT INTO margin_snapshot (
    tenant_id, trade_position_id, side,
    benchmark_code_used, benchmark_price_used,
    revenue_per_bbl, cost_per_bbl, margin_per_bbl,
    volume_bbl, total_margin_usd, usd_aed_rate, total_margin_aed,
    recommendation, breakdown, triggered_by, data_classification,
    created_at, created_by
  ) VALUES (
    v_tenant_id, v_pos.id, v_pos.side,
    v_benchmark_code, v_benchmark_price,
    v_revenue_per_bbl, v_cost_per_bbl, v_margin_per_bbl,
    v_pos.volume_bbl, v_total_margin_usd, v_usd_aed_rate, v_total_margin_aed,
    v_recommendation, v_breakdown, v_triggered_by, 'demo',
    NOW(), v_actor
  )
  RETURNING id INTO v_snap_id;

  -- Step 10: Refresh latest_margin MV
  REFRESH MATERIALIZED VIEW latest_margin;

  -- Step 11: Return summary
  RETURN jsonb_build_object(
    'tradePositionId',    v_pos.id,
    'positionRef',        v_pos.position_ref,
    'side',               v_pos.side,
    'grade',              v_pos.grade,
    'volumeBbl',          v_pos.volume_bbl::text,
    'benchmarkCodeUsed',  v_benchmark_code,
    'benchmarkPriceUsed', v_benchmark_price::text,
    'revenuePerBbl',      v_revenue_per_bbl::text,
    'costPerBbl',         v_cost_per_bbl::text,
    'marginPerBbl',       v_margin_per_bbl::text,
    'totalMarginUsd',     v_total_margin_usd::text,
    'usdAedRate',         v_usd_aed_rate::text,
    'totalMarginAed',     v_total_margin_aed::text,
    'recommendation',     v_recommendation,
    'breakdown',          v_breakdown,
    'computedAt',         NOW(),
    'triggeredBy',        v_triggered_by
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_margin_compute: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_margin_compute(BIGINT, BIGINT, NUMERIC) IS
  'CR-O D-1: Compute margin for a trade_position. Resolves benchmark price (seller) or revenue components (buyer), aggregates costs, writes margin_snapshot, refreshes latest_margin MV. Gates finance.margin.read. Returns full breakdown JSONB with recommendation. ERRCODE: 42501 (perm), P0002 (position absent), 22023 (no FX / no benchmark).';
REVOKE EXECUTE ON FUNCTION fn_margin_compute(BIGINT, BIGINT, NUMERIC) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_margin_compute(BIGINT, BIGINT, NUMERIC) TO neondb_owner;

-- ============================================================
-- D-2. fn_margin_recompute_for_price_change
-- SECURITY DEFINER, VOLATILE — gates finance.trade.manage.
-- Mirrors fn_score_recompute_for_signal (CR-F pattern).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_margin_recompute_for_price_change(
  p_actor_id       BIGINT,
  p_benchmark_code TEXT,
  p_new_price      NUMERIC,
  p_price_date     DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
AS $$
DECLARE
  v_tenant_id           UUID;
  v_actor               BIGINT;
  v_effective_date      DATE;
  v_prior_aggregate     NUMERIC(18,2);
  v_new_aggregate       NUMERIC(18,2);
  v_delta_aed           NUMERIC(18,2);
  v_delta_usd           NUMERIC(18,2);
  v_count               INTEGER := 0;
  v_pos_id              BIGINT;
  v_pos_ids             BIGINT[];
  v_usd_aed_rate        NUMERIC(12,4);
  v_cost_per_bbl        NUMERIC(12,4);
BEGIN
  -- Step 1: Gate finance.trade.manage
  IF NOT fn_current_user_has_permission('finance.trade.manage') THEN
    RAISE EXCEPTION 'fn_margin_recompute_for_price_change: forbidden — finance.trade.manage required'
      USING ERRCODE = '42501';
  END IF;

  -- Step 2: Validate inputs
  IF p_benchmark_code NOT IN ('murban_osp','brent','dubai','wti','west_african_x','usd_aed') THEN
    RAISE EXCEPTION 'fn_margin_recompute_for_price_change: invalid benchmark_code %', p_benchmark_code
      USING ERRCODE = '22023';
  END IF;

  IF p_new_price < 0 THEN
    RAISE EXCEPTION 'fn_margin_recompute_for_price_change: newPrice must be >= 0'
      USING ERRCODE = '22023';
  END IF;

  -- Step 3: Resolve tenant
  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_margin_recompute_for_price_change: tenant context not set'
      USING ERRCODE = '42501';
  END IF;

  v_actor := NULLIF(p_actor_id, 0);
  v_effective_date := COALESCE(p_price_date, date_trunc('month', CURRENT_DATE)::date);

  -- Step 4: UPSERT price_benchmark row
  INSERT INTO price_benchmark (
    tenant_id, benchmark_code, price_date, price_value, unit, period_grain,
    source, data_classification, created_at, updated_at, created_by, updated_by, is_active
  ) VALUES (
    v_tenant_id, p_benchmark_code, v_effective_date, p_new_price::NUMERIC(12,4),
    CASE WHEN p_benchmark_code = 'usd_aed' THEN 'aed_per_usd' ELSE 'usd_per_bbl' END,
    'monthly',
    CASE WHEN p_benchmark_code = 'murban_osp' THEN 'osp_official' ELSE 'market' END,
    'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  )
  ON CONFLICT (tenant_id, benchmark_code, price_date)
  DO UPDATE SET
    price_value = EXCLUDED.price_value,
    updated_at  = NOW(),
    updated_by  = v_actor;

  -- Step 5: Capture PRIOR aggregate (A3 — explicit tenant_id filter)
  SELECT COALESCE(SUM(lm.total_margin_aed), 0) INTO v_prior_aggregate
  FROM latest_margin lm
  JOIN trade_position tp ON tp.id = lm.trade_position_id AND tp.is_active = TRUE
  WHERE lm.tenant_id = v_tenant_id
    AND tp.pricing_basis = p_benchmark_code
    AND tp.delivery_month >= v_effective_date;

  -- Step 6: Collect position IDs to recompute
  SELECT array_agg(tp.id ORDER BY tp.id) INTO v_pos_ids
  FROM trade_position tp
  WHERE tp.tenant_id = v_tenant_id
    AND tp.pricing_basis = p_benchmark_code
    AND tp.status = 'open'
    AND tp.delivery_month >= v_effective_date
    AND tp.is_active = TRUE;

  -- Step 6b: Per-position recompute with SAVEPOINT isolation
  IF v_pos_ids IS NOT NULL THEN
    FOREACH v_pos_id IN ARRAY v_pos_ids LOOP
      BEGIN
        PERFORM fn_margin_compute(p_actor_id, v_pos_id, p_new_price::NUMERIC);
        v_count := v_count + 1;
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'fn_margin_recompute_for_price_change: position % failed: %', v_pos_id, SQLERRM;
      END;
    END LOOP;
  END IF;

  -- Step 7: Final belt-and-suspenders MV refresh
  REFRESH MATERIALIZED VIEW latest_margin;

  -- Step 8: Capture NEW aggregate
  SELECT COALESCE(SUM(lm.total_margin_aed), 0) INTO v_new_aggregate
  FROM latest_margin lm
  JOIN trade_position tp ON tp.id = lm.trade_position_id AND tp.is_active = TRUE
  WHERE lm.tenant_id = v_tenant_id
    AND tp.pricing_basis = p_benchmark_code
    AND tp.delivery_month >= v_effective_date;

  v_delta_aed := v_new_aggregate - v_prior_aggregate;

  -- Resolve USD rate for delta USD calculation
  SELECT pb.price_value INTO v_usd_aed_rate
  FROM price_benchmark pb
  WHERE pb.tenant_id = v_tenant_id
    AND pb.benchmark_code = 'usd_aed'
    AND pb.unit = 'aed_per_usd'
    AND pb.is_active = TRUE
  ORDER BY pb.price_date DESC
  LIMIT 1;

  IF v_usd_aed_rate IS NULL OR v_usd_aed_rate = 0 THEN
    v_delta_usd := NULL;
  ELSE
    v_delta_usd := ROUND((v_delta_aed / v_usd_aed_rate)::NUMERIC, 2);
  END IF;

  -- Step 9: pg_notify
  PERFORM pg_notify(
    'margin_recompute_requested',
    jsonb_build_object(
      'tenantId',      v_tenant_id,
      'benchmarkCode', p_benchmark_code,
      'newPrice',      p_new_price,
      'affected',      v_count
    )::text
  );

  -- Step 10: Return aggregate delta
  RETURN jsonb_build_object(
    'benchmarkCode',           p_benchmark_code,
    'newPrice',                p_new_price::NUMERIC(12,4)::text,
    'priceDate',               v_effective_date,
    'positionsRecomputed',     v_count,
    'deduplicatedCount',       0,
    'priorAggregateMarginAed', v_prior_aggregate::text,
    'newAggregateMarginAed',   v_new_aggregate::text,
    'deltaAed',                v_delta_aed::text,
    'deltaUsd',                COALESCE(v_delta_usd::text, '0'),
    'recomputedPositionIds',   COALESCE(to_jsonb(v_pos_ids), '[]'::jsonb)
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_margin_recompute_for_price_change: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_margin_recompute_for_price_change(BIGINT, TEXT, NUMERIC, DATE) IS
  'CR-O D-2: DEFINER VOLATILE. UPSERTs new benchmark price, captures prior aggregate, recomputes all open forward positions on that benchmark (fn_margin_compute per position with SAVEPOINT isolation), emits pg_notify(margin_recompute_requested), returns aggregate delta. Gates finance.trade.manage. S2-19: calls fn_margin_compute(BIGINT,BIGINT,NUMERIC) — 3-arg. S2-24 split-aggregate for prior/new totals.';
REVOKE EXECUTE ON FUNCTION fn_margin_recompute_for_price_change(BIGINT, TEXT, NUMERIC, DATE) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_margin_recompute_for_price_change(BIGINT, TEXT, NUMERIC, DATE) TO neondb_owner;

-- ============================================================
-- D-3. fn_margin_aggregate
-- SECURITY INVOKER, STABLE. Gates finance.margin.read.
-- S2-24 split-aggregate CTEs: filtered → per_bucket → totals → outer jsonb_build_object.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_margin_aggregate(
  p_actor_id BIGINT,
  p_filters  JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id    UUID;
  v_group_by     TEXT;
  v_result       JSONB;
  v_total_aed    NUMERIC(18,2);
  v_total_usd    NUMERIC(18,2);
  v_pos_count    INTEGER;
  v_breakdown    JSONB;
BEGIN
  -- Gate finance.margin.read
  IF NOT fn_current_user_has_permission('finance.margin.read') THEN
    RAISE EXCEPTION 'fn_margin_aggregate: forbidden — finance.margin.read required'
      USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_margin_aggregate: tenant context not set'
      USING ERRCODE = '42501';
  END IF;

  v_group_by := COALESCE(p_filters->>'groupBy', 'side');

  IF v_group_by NOT IN ('counterparty','quarter','side') THEN
    RAISE EXCEPTION 'fn_margin_aggregate: invalid groupBy %; must be counterparty|quarter|side', v_group_by
      USING ERRCODE = '22023';
  END IF;

  -- S2-24 split-aggregate pattern: filtered → per_bucket → totals → outer SELECT
  IF v_group_by = 'side' THEN
    WITH filtered AS (
      SELECT lm.total_margin_aed, lm.total_margin_usd, tp.side
      FROM latest_margin lm
      JOIN trade_position tp ON tp.id = lm.trade_position_id AND tp.is_active = TRUE
      WHERE lm.tenant_id = v_tenant_id  -- A3 explicit filter
    ),
    per_bucket AS (
      SELECT tp_side AS bucket_key,
             tp_side AS bucket_label,
             SUM(total_margin_aed) AS bucket_aed,
             SUM(total_margin_usd) AS bucket_usd,
             COUNT(*) AS bucket_count
      FROM filtered, LATERAL (SELECT side AS tp_side) _s
      GROUP BY tp_side
    ),
    totals AS (
      SELECT COALESCE(SUM(bucket_aed), 0) AS t_aed,
             COALESCE(SUM(bucket_usd), 0) AS t_usd,
             COALESCE(SUM(bucket_count), 0) AS t_cnt
      FROM per_bucket
    )
    SELECT
      (SELECT t_aed FROM totals)::NUMERIC(18,2),
      (SELECT t_usd FROM totals)::NUMERIC(18,2),
      (SELECT t_cnt FROM totals)::INTEGER,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'key',           pb.bucket_key,
          'label',         pb.bucket_label,
          'marginAed',     pb.bucket_aed::text,
          'marginUsd',     pb.bucket_usd::text,
          'positionCount', pb.bucket_count,
          'pctOfTotal',    CASE WHEN (SELECT t_aed FROM totals) != 0
                                THEN ROUND((pb.bucket_aed / (SELECT t_aed FROM totals) * 100)::NUMERIC, 2)
                                ELSE 0 END
        ) ORDER BY pb.bucket_aed DESC)
        FROM per_bucket pb
      ), '[]'::jsonb)
    INTO v_total_aed, v_total_usd, v_pos_count, v_breakdown;

  ELSIF v_group_by = 'quarter' THEN
    WITH filtered AS (
      SELECT lm.total_margin_aed, lm.total_margin_usd, tp.delivery_month
      FROM latest_margin lm
      JOIN trade_position tp ON tp.id = lm.trade_position_id AND tp.is_active = TRUE
      WHERE lm.tenant_id = v_tenant_id  -- A3 explicit filter
    ),
    per_bucket AS (
      SELECT to_char(delivery_month, 'YYYY-"Q"Q') AS bucket_key,
             to_char(delivery_month, 'YYYY-"Q"Q') AS bucket_label,
             SUM(total_margin_aed) AS bucket_aed,
             SUM(total_margin_usd) AS bucket_usd,
             COUNT(*) AS bucket_count
      FROM filtered
      GROUP BY to_char(delivery_month, 'YYYY-"Q"Q')
    ),
    totals AS (
      SELECT COALESCE(SUM(bucket_aed), 0) AS t_aed,
             COALESCE(SUM(bucket_usd), 0) AS t_usd,
             COALESCE(SUM(bucket_count), 0) AS t_cnt
      FROM per_bucket
    )
    SELECT
      (SELECT t_aed FROM totals)::NUMERIC(18,2),
      (SELECT t_usd FROM totals)::NUMERIC(18,2),
      (SELECT t_cnt FROM totals)::INTEGER,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'key',           pb.bucket_key,
          'label',         pb.bucket_label,
          'marginAed',     pb.bucket_aed::text,
          'marginUsd',     pb.bucket_usd::text,
          'positionCount', pb.bucket_count,
          'pctOfTotal',    CASE WHEN (SELECT t_aed FROM totals) != 0
                                THEN ROUND((pb.bucket_aed / (SELECT t_aed FROM totals) * 100)::NUMERIC, 2)
                                ELSE 0 END
        ) ORDER BY pb.bucket_key ASC)
        FROM per_bucket pb
      ), '[]'::jsonb)
    INTO v_total_aed, v_total_usd, v_pos_count, v_breakdown;

  ELSE -- counterparty
    WITH filtered AS (
      SELECT lm.total_margin_aed, lm.total_margin_usd, tp.counterparty_id
      FROM latest_margin lm
      JOIN trade_position tp ON tp.id = lm.trade_position_id AND tp.is_active = TRUE
      WHERE lm.tenant_id = v_tenant_id  -- A3 explicit filter
    ),
    per_bucket AS (
      SELECT f.counterparty_id::text AS bucket_key,
             COALESCE(p.name_en, 'Party #' || f.counterparty_id::text) AS bucket_label,
             SUM(f.total_margin_aed) AS bucket_aed,
             SUM(f.total_margin_usd) AS bucket_usd,
             COUNT(*) AS bucket_count
      FROM filtered f
      LEFT JOIN party p ON p.id = f.counterparty_id
      GROUP BY f.counterparty_id, p.name_en
    ),
    totals AS (
      SELECT COALESCE(SUM(bucket_aed), 0) AS t_aed,
             COALESCE(SUM(bucket_usd), 0) AS t_usd,
             COALESCE(SUM(bucket_count), 0) AS t_cnt
      FROM per_bucket
    )
    SELECT
      (SELECT t_aed FROM totals)::NUMERIC(18,2),
      (SELECT t_usd FROM totals)::NUMERIC(18,2),
      (SELECT t_cnt FROM totals)::INTEGER,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'key',           pb.bucket_key,
          'label',         pb.bucket_label,
          'marginAed',     pb.bucket_aed::text,
          'marginUsd',     pb.bucket_usd::text,
          'positionCount', pb.bucket_count,
          'pctOfTotal',    CASE WHEN (SELECT t_aed FROM totals) != 0
                                THEN ROUND((pb.bucket_aed / (SELECT t_aed FROM totals) * 100)::NUMERIC, 2)
                                ELSE 0 END
        ) ORDER BY pb.bucket_aed DESC)
        FROM per_bucket pb
      ), '[]'::jsonb)
    INTO v_total_aed, v_total_usd, v_pos_count, v_breakdown;
  END IF;

  RETURN jsonb_build_object(
    'totalMarginAed', COALESCE(v_total_aed, 0)::NUMERIC(18,2)::text,
    'totalMarginUsd', COALESCE(v_total_usd, 0)::NUMERIC(18,2)::text,
    'currency',       'AED',
    'positionCount',  COALESCE(v_pos_count, 0),
    'groupBy',        v_group_by,
    'breakdown',      COALESCE(v_breakdown, '[]'::jsonb)
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_margin_aggregate: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_margin_aggregate(BIGINT, JSONB) IS
  'CR-O D-3: INVOKER STABLE. CFO portfolio rollup. groupBy: counterparty|quarter|side (default side). S2-24 split-aggregate CTEs. A3 explicit tenant_id filter on latest_margin MV. Returns totalMarginAed|Usd + breakdown[]. Gates finance.margin.read.';
REVOKE EXECUTE ON FUNCTION fn_margin_aggregate(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_margin_aggregate(BIGINT, JSONB) TO neondb_owner;

-- ============================================================
-- D-4. fn_trade_position_list
-- INVOKER, STABLE. Gates finance.margin.read.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_trade_position_list(
  p_actor_id BIGINT,
  p_side     TEXT    DEFAULT NULL,
  p_grade    TEXT    DEFAULT NULL,
  p_status   TEXT    DEFAULT NULL,
  p_search   TEXT    DEFAULT NULL,
  p_page     INTEGER DEFAULT 1,
  p_limit    INTEGER DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
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

  -- COUNT
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

  -- Main query — LEFT JOIN latest_margin for inline margin (A3 explicit filter)
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
      'latestComputedAt', lm.computed_at
    ) ORDER BY tp.delivery_month ASC, tp.id ASC
  ), '[]'::jsonb) INTO v_data
  FROM trade_position tp
  LEFT JOIN party cp ON cp.id = tp.counterparty_id
  LEFT JOIN latest_margin lm ON lm.trade_position_id = tp.id
    AND lm.tenant_id = v_tenant_id  -- A3 explicit filter
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

COMMENT ON FUNCTION fn_trade_position_list(BIGINT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) IS
  'CR-O D-4: INVOKER STABLE. Paginated list of trade_positions. Filters: side, grade, status, search (ILIKE position_ref + counterparty name_en). Joins latest_margin MV for inline margin per position. A3 explicit tenant_id filter. Never returns NULL — empty data[] with pagination. Gates finance.margin.read.';
REVOKE EXECUTE ON FUNCTION fn_trade_position_list(BIGINT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_trade_position_list(BIGINT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) TO neondb_owner;

-- ============================================================
-- D-5. fn_trade_position_get
-- INVOKER, STABLE. Gates finance.margin.read. Returns NULL if not found (→ 404).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_trade_position_get(
  p_actor_id BIGINT,
  p_id       BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id   UUID;
  v_pos         RECORD;
  v_cost_comps  JSONB;
  v_linked_c    JSONB;
  v_int_entity  JSONB;
  v_latest_m    JSONB;
  v_result      JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('finance.margin.read') THEN
    RAISE EXCEPTION 'fn_trade_position_get: forbidden — finance.margin.read required'
      USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_trade_position_get: tenant context not set'
      USING ERRCODE = '42501';
  END IF;

  SELECT tp.* INTO v_pos
  FROM trade_position tp
  WHERE tp.id = p_id
    AND tp.tenant_id = v_tenant_id
    AND tp.is_active = TRUE;

  IF NOT FOUND THEN
    RETURN NULL;  -- controller → 404
  END IF;

  -- Cost components (single jsonb_agg subquery — N+1 avoided)
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',              tcc.id,
      'componentType',   tcc.component_type,
      'amountUsdPerBbl', tcc.amount_usd_per_bbl::text,
      'isRevenue',       tcc.is_revenue,
      'notes',           tcc.notes
    ) ORDER BY tcc.id
  ), '[]'::jsonb) INTO v_cost_comps
  FROM trade_cost_component tcc
  WHERE tcc.trade_position_id = v_pos.id
    AND tcc.tenant_id = v_tenant_id
    AND tcc.is_active = TRUE;

  -- Linked contract summary (if linked_contract_id is set)
  IF v_pos.linked_contract_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'id',             c.id,
      'contractNumber', c.contract_number,
      'titleEn',        c.title_en,
      'titleAr',        c.title_ar
    ) INTO v_linked_c
    FROM contract c
    WHERE c.id = v_pos.linked_contract_id AND c.is_active = TRUE;
  END IF;

  -- Internal entity (ADNOC Trading / AGT)
  IF v_pos.internal_entity_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'id',     p.id,
      'nameEn', p.name_en,
      'nameAr', p.name_ar
    ) INTO v_int_entity
    FROM party p
    WHERE p.id = v_pos.internal_entity_id;
  END IF;

  -- Latest margin from MV (A3 explicit tenant_id filter)
  SELECT jsonb_build_object(
    'marginPerBbl',     lm.margin_per_bbl::text,
    'totalMarginUsd',   lm.total_margin_usd::text,
    'totalMarginAed',   lm.total_margin_aed::text,
    'recommendation',   lm.recommendation,
    'latestComputedAt', lm.computed_at
  ) INTO v_latest_m
  FROM latest_margin lm
  WHERE lm.trade_position_id = v_pos.id
    AND lm.tenant_id = v_tenant_id;  -- A3 explicit filter

  RETURN jsonb_build_object(
    'id',               v_pos.id,
    'positionRef',      v_pos.position_ref,
    'side',             v_pos.side,
    'grade',            v_pos.grade,
    'counterparty',     (SELECT jsonb_build_object('id', p.id, 'nameEn', p.name_en, 'nameAr', p.name_ar)
                         FROM party p WHERE p.id = v_pos.counterparty_id),
    'internalEntity',   v_int_entity,
    'volumeBbl',        v_pos.volume_bbl::text,
    'pricingBasis',     v_pos.pricing_basis,
    'deliveryMonth',    v_pos.delivery_month,
    'termOrSpot',       v_pos.term_or_spot,
    'linkedContract',   v_linked_c,
    'status',           v_pos.status,
    'notes',            v_pos.notes,
    'costComponents',   v_cost_comps,
    'latestMargin',     v_latest_m,
    'dataClassification', v_pos.data_classification,
    'createdAt',        v_pos.created_at,
    'updatedAt',        v_pos.updated_at,
    'createdBy',        v_pos.created_by,
    'updatedBy',        v_pos.updated_by,
    'isActive',         v_pos.is_active
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_trade_position_get: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_trade_position_get(BIGINT, BIGINT) IS
  'CR-O D-5: INVOKER STABLE. Full trade_position detail: counterparty + internalEntity (party JOINs) + linkedContract summary + costComponents[] (single jsonb_agg subquery, N+1 avoided) + latestMargin from MV (A3 explicit filter). Returns NULL when not found (controller → 404). Gates finance.margin.read.';
REVOKE EXECUTE ON FUNCTION fn_trade_position_get(BIGINT, BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_trade_position_get(BIGINT, BIGINT) TO neondb_owner;

-- ============================================================
-- D-6. fn_price_benchmark_list
-- INVOKER, STABLE. Gates finance.margin.read.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_price_benchmark_list(
  p_actor_id       BIGINT,
  p_benchmark_code TEXT    DEFAULT NULL,
  p_from           DATE    DEFAULT NULL,
  p_to             DATE    DEFAULT NULL,
  p_page           INTEGER DEFAULT 1,
  p_limit          INTEGER DEFAULT 100
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_offset    INTEGER;
  v_total     INTEGER;
  v_data      JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('finance.margin.read') THEN
    RAISE EXCEPTION 'fn_price_benchmark_list: forbidden — finance.margin.read required'
      USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_price_benchmark_list: tenant context not set'
      USING ERRCODE = '42501';
  END IF;

  v_offset := (COALESCE(p_page, 1) - 1) * COALESCE(p_limit, 100);

  SELECT COUNT(*) INTO v_total
  FROM price_benchmark pb
  WHERE pb.tenant_id = v_tenant_id
    AND pb.is_active = TRUE
    AND (p_benchmark_code IS NULL OR pb.benchmark_code = p_benchmark_code)
    AND (p_from IS NULL OR pb.price_date >= p_from)
    AND (p_to   IS NULL OR pb.price_date <= p_to);

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',           pb.id,
      'benchmarkCode', pb.benchmark_code,
      'priceDate',    pb.price_date,
      'priceValue',   pb.price_value::text,
      'unit',         pb.unit,
      'periodGrain',  pb.period_grain,
      'source',       pb.source,
      'notes',        pb.notes
    ) ORDER BY pb.benchmark_code ASC, pb.price_date DESC
  ), '[]'::jsonb) INTO v_data
  FROM price_benchmark pb
  WHERE pb.tenant_id = v_tenant_id
    AND pb.is_active = TRUE
    AND (p_benchmark_code IS NULL OR pb.benchmark_code = p_benchmark_code)
    AND (p_from IS NULL OR pb.price_date >= p_from)
    AND (p_to   IS NULL OR pb.price_date <= p_to)
  LIMIT COALESCE(p_limit, 100) OFFSET v_offset;

  RETURN jsonb_build_object(
    'data', v_data,
    'pagination', jsonb_build_object(
      'total',      v_total,
      'page',       COALESCE(p_page, 1),
      'limit',      COALESCE(p_limit, 100),
      'totalPages', CEIL(v_total::FLOAT / COALESCE(p_limit, 100))::INTEGER
    )
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_price_benchmark_list: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_price_benchmark_list(BIGINT, TEXT, DATE, DATE, INTEGER, INTEGER) IS
  'CR-O D-6: INVOKER STABLE. Paginated benchmark price series. Optional filters: benchmarkCode, from/to date range. ORDER BY benchmark_code ASC, price_date DESC. Gates finance.margin.read.';
REVOKE EXECUTE ON FUNCTION fn_price_benchmark_list(BIGINT, TEXT, DATE, DATE, INTEGER, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_price_benchmark_list(BIGINT, TEXT, DATE, DATE, INTEGER, INTEGER) TO neondb_owner;

-- ============================================================
-- D-7. fn_price_benchmark_record (WRITE)
-- INVOKER, VOLATILE. Gates finance.trade.manage.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_price_benchmark_record(
  p_actor_id BIGINT,
  p_data     JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id      UUID;
  v_actor          BIGINT;
  v_benchmark_code TEXT;
  v_price_date     DATE;
  v_price_value    NUMERIC(12,4);
  v_unit           TEXT;
  v_period_grain   TEXT;
  v_source         TEXT;
  v_notes          TEXT;
  v_row_id         BIGINT;
BEGIN
  IF NOT fn_current_user_has_permission('finance.trade.manage') THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: forbidden — finance.trade.manage required'
      USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: tenant context not set'
      USING ERRCODE = '42501';
  END IF;

  v_actor := NULLIF(p_actor_id, 0);

  -- Validate required fields
  IF p_data->>'benchmarkCode' IS NULL THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: benchmarkCode is required' USING ERRCODE = '22023';
  END IF;
  IF p_data->>'priceDate' IS NULL THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: priceDate is required' USING ERRCODE = '22023';
  END IF;
  IF p_data->>'priceValue' IS NULL THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: priceValue is required' USING ERRCODE = '22023';
  END IF;
  IF p_data->>'unit' IS NULL THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: unit is required' USING ERRCODE = '22023';
  END IF;

  v_benchmark_code := p_data->>'benchmarkCode';
  v_price_date     := (p_data->>'priceDate')::DATE;
  v_price_value    := (p_data->>'priceValue')::NUMERIC(12,4);
  v_unit           := p_data->>'unit';
  v_period_grain   := COALESCE(p_data->>'periodGrain', 'monthly');
  v_source         := COALESCE(p_data->>'source', 'mock');
  v_notes          := p_data->>'notes';

  IF v_benchmark_code NOT IN ('murban_osp','brent','dubai','wti','west_african_x','usd_aed') THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: invalid benchmarkCode %', v_benchmark_code
      USING ERRCODE = '22023';
  END IF;
  IF v_unit NOT IN ('usd_per_bbl','aed_per_usd') THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: invalid unit %', v_unit
      USING ERRCODE = '22023';
  END IF;
  IF v_period_grain NOT IN ('monthly','daily','spot') THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: invalid periodGrain %', v_period_grain
      USING ERRCODE = '22023';
  END IF;
  IF v_source NOT IN ('osp_official','market','mock') THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: invalid source %', v_source
      USING ERRCODE = '22023';
  END IF;
  IF v_price_value < 0 THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: priceValue must be >= 0'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO price_benchmark (
    tenant_id, benchmark_code, price_date, price_value, unit, period_grain,
    source, notes, data_classification, created_at, updated_at, created_by, updated_by, is_active
  ) VALUES (
    v_tenant_id, v_benchmark_code, v_price_date, v_price_value, v_unit, v_period_grain,
    v_source, v_notes, 'demo', NOW(), NOW(), v_actor, v_actor, TRUE
  )
  ON CONFLICT (tenant_id, benchmark_code, price_date)
  DO UPDATE SET
    price_value    = EXCLUDED.price_value,
    unit           = EXCLUDED.unit,
    period_grain   = EXCLUDED.period_grain,
    source         = EXCLUDED.source,
    notes          = EXCLUDED.notes,
    updated_at     = NOW(),
    updated_by     = v_actor
  RETURNING id INTO v_row_id;

  RETURN fn_price_benchmark_get_by_id(p_actor_id, v_row_id);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_price_benchmark_record: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_price_benchmark_record(BIGINT, JSONB) IS
  'CR-O D-7: INVOKER VOLATILE. UPSERT a price_benchmark row. ON CONFLICT (tenant_id, benchmark_code, price_date) DO UPDATE. Returns the row via fn_price_benchmark_get_by_id. Validates required (benchmarkCode, priceDate, priceValue, unit) + enum checks. Gates finance.trade.manage.';
REVOKE EXECUTE ON FUNCTION fn_price_benchmark_record(BIGINT, JSONB) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_price_benchmark_record(BIGINT, JSONB) TO neondb_owner;

-- ============================================================
-- D-8. fn_margin_snapshot_history
-- INVOKER, STABLE. Gates finance.margin.read.
-- Reads directly from margin_snapshot table (NOT MV — history needs all rows).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_margin_snapshot_history(
  p_actor_id           BIGINT,
  p_trade_position_id  BIGINT,
  p_limit              INTEGER DEFAULT 50
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_tenant_id UUID;
  v_count     INTEGER;
  v_snapshots JSONB;
BEGIN
  IF NOT fn_current_user_has_permission('finance.margin.read') THEN
    RAISE EXCEPTION 'fn_margin_snapshot_history: forbidden — finance.margin.read required'
      USING ERRCODE = '42501';
  END IF;

  v_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'fn_margin_snapshot_history: tenant context not set'
      USING ERRCODE = '42501';
  END IF;

  -- Verify position exists (P0002 if absent)
  IF NOT EXISTS (
    SELECT 1 FROM trade_position tp
    WHERE tp.id = p_trade_position_id
      AND tp.tenant_id = v_tenant_id
      AND tp.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'fn_margin_snapshot_history: trade_position % not found', p_trade_position_id
      USING ERRCODE = 'P0002';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM margin_snapshot ms
  WHERE ms.trade_position_id = p_trade_position_id
    AND ms.tenant_id = v_tenant_id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'marginSnapshotId',   ms.id,
      'computedAt',         ms.computed_at,
      'benchmarkPriceUsed', ms.benchmark_price_used::text,
      'revenuePerBbl',      ms.revenue_per_bbl::text,
      'costPerBbl',         ms.cost_per_bbl::text,
      'marginPerBbl',       ms.margin_per_bbl::text,
      'totalMarginUsd',     ms.total_margin_usd::text,
      'totalMarginAed',     ms.total_margin_aed::text,
      'triggeredBy',        ms.triggered_by
    ) ORDER BY ms.computed_at ASC  -- ASC for chart (oldest first)
  ), '[]'::jsonb) INTO v_snapshots
  FROM margin_snapshot ms
  WHERE ms.trade_position_id = p_trade_position_id
    AND ms.tenant_id = v_tenant_id
  LIMIT COALESCE(p_limit, 50);

  RETURN jsonb_build_object(
    'tradePositionId', p_trade_position_id,
    'count',           v_count,
    'snapshots',       v_snapshots
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN no_data_found THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_margin_snapshot_history: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_margin_snapshot_history(BIGINT, BIGINT, INTEGER) IS
  'CR-O D-8: INVOKER STABLE. Snapshot history for a trade_position (ASC computed_at order for chart). Reads directly from margin_snapshot table (NOT latest_margin MV — history needs all rows). P0002 when position absent; count:0 + snapshots:[] when no snapshots yet. Gates finance.margin.read.';
REVOKE EXECUTE ON FUNCTION fn_margin_snapshot_history(BIGINT, BIGINT, INTEGER) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_margin_snapshot_history(BIGINT, BIGINT, INTEGER) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (315, '315_cro_fn_trade_margin_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS fn_margin_snapshot_history(BIGINT, BIGINT, INTEGER);
-- DROP FUNCTION IF EXISTS fn_price_benchmark_record(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_price_benchmark_list(BIGINT, TEXT, DATE, DATE, INTEGER, INTEGER);
-- DROP FUNCTION IF EXISTS fn_trade_position_get(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_trade_position_list(BIGINT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER);
-- DROP FUNCTION IF EXISTS fn_margin_aggregate(BIGINT, JSONB);
-- DROP FUNCTION IF EXISTS fn_margin_recompute_for_price_change(BIGINT, TEXT, NUMERIC, DATE);
-- DROP FUNCTION IF EXISTS fn_margin_compute(BIGINT, BIGINT, NUMERIC);
-- DROP FUNCTION IF EXISTS fn_trade_position_get_by_id(BIGINT, BIGINT);
-- DROP FUNCTION IF EXISTS fn_price_benchmark_get_by_id(BIGINT, BIGINT);
-- DELETE FROM schema_migrations WHERE version = 315;
-- COMMIT;
-- ============================================================
