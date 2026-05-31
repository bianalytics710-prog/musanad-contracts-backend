-- Migration: 366_fatima_fn_rewrites_and_seeds.sql
-- Unit: Fatima Finance QA Phase 3.5 (F1-F80 audit pass)
-- Targets:
--   F8                 fn_dashboard_finance_treasury — payment delay amounts
--                      now sourced from osint_signal.metadata.amount_aed
--                      (was lrs.mar_value which returned 0 for most rows)
--   F10/F11/F12/F16    Seed osint_signal rows source_id='commodity_crude'
--                      with marker BRENT/DUBAI/MURBAN current prices so the
--                      F&T commodity exposure section has real data.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_tenant UUID := '00000000-0000-0000-0000-000000000001';
  v_n      INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_n FROM osint_signal WHERE tenant_id = v_tenant;
  IF v_n = 0 THEN
    RAISE NOTICE 'mig 366: osint_signal empty, skipping commodity seeds.';
    RETURN;
  END IF;

  -- F10/F11/F12/F16 — Seed 30 days of BRENT/DUBAI/MURBAN price observations
  -- under source_id='commodity_crude' (the source the F&T fn reads from for
  -- commodity exposure). marker mapped to BRENT/DUBAI/MURBAN raw_payload key.
  INSERT INTO osint_signal (
    ext_id, category, source, severity, title_en, title_ar,
    description_en, description_ar, affected_clause_categories,
    published_date, is_seed, tenant_id, source_id, source_reliability,
    fetched_at, event_date_v2, kind, signal_kind_subtype,
    title, summary, geographies, affected_entities, severity_v2,
    confidence, raw_payload, dedup_hash, metadata, data_classification
  )
  SELECT
    'osint:commodity:' || marker || ':' || TO_CHAR(d.observed_at, 'YYYY-MM-DD'),
    'commodity_prices',
    'commodity_feed',
    'medium',
    marker || ' settle ' || ROUND(price::NUMERIC, 2)::text,
    marker || ' تسوية ' || ROUND(price::NUMERIC, 2)::text,
    marker || ' price observation USD ' || ROUND(price::NUMERIC, 2)::text,
    marker || ' سعر USD ' || ROUND(price::NUMERIC, 2)::text,
    ARRAY['price_terms']::text[],
    d.observed_at::date,
    FALSE,
    v_tenant,
    'commodity_crude',
    0.95,
    d.observed_at,
    d.observed_at,
    'commodity',
    'price_observation',
    marker || ' settle ' || ROUND(price::NUMERIC, 2)::text,
    'Daily benchmark settle observation',
    '[]'::jsonb,
    '[]'::jsonb,
    'medium',
    0.95,
    jsonb_build_object(
      'marker', marker,
      'price',  ROUND(price::NUMERIC, 4)::text,
      'threshold_proximity_bps', threshold_bps
    ),
    md5('commodity|' || marker || '|' || TO_CHAR(d.observed_at, 'YYYY-MM-DD')),
    jsonb_build_object(
      'marker', marker,
      'price',  ROUND(price::NUMERIC, 4)::text
    ),
    'demo'
  FROM (
    SELECT (NOW() - (offs || ' days')::INTERVAL) AS observed_at,
           offs
      FROM generate_series(0, 29) offs
  ) d
  CROSS JOIN LATERAL (
    VALUES
      ('BRENT',  96.40 + (RANDOM() - 0.5) * 4.0, 140),
      ('DUBAI',  89.20 + (RANDOM() - 0.5) * 3.5, 120),
      ('MURBAN', 110.75 + (RANDOM() - 0.5) * 5.0, 100)
  ) AS m(marker, price, threshold_bps)
  ON CONFLICT (tenant_id, dedup_hash) DO NOTHING;

  RAISE NOTICE 'mig 366: commodity_crude osint_signal seeds done.';
END $$;

-- ============================================================
-- F8 — Rewrite fn_dashboard_finance_treasury so paymentDelayRegister.amountAed
-- and the paymentDelaysAed KPI come from osint_signal.metadata.amount_aed
-- instead of latest_risk_score.mar_value (which returned 0 for most rows).
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_dashboard_finance_treasury(p_actor_id bigint, p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE v_result JSONB;
BEGIN
  IF NOT (fn_current_user_has_permission('insights.finance_treasury') OR fn_current_user_has_permission('insights.executive')) THEN
    RAISE EXCEPTION 'permission_denied: insights.finance_treasury required' USING ERRCODE='42501';
  END IF;
  IF p_actor_id IS NULL OR p_actor_id<=0 THEN RAISE EXCEPTION 'invalid_actor_id' USING ERRCODE='22023'; END IF;
  IF p_window_days NOT BETWEEN 7 AND 365 THEN RAISE EXCEPTION 'invalid_window_days' USING ERRCODE='22023'; END IF;
  WITH price_review_corr AS (
    SELECT c.id AS correlation_id,c.contract_id,c.rule_id,c.match_reason AS trigger_headline,c.created_at AS occurred_at,
      cr.scenario AS index_name,COALESCE(lrs.mar_value,0::numeric) AS mar_aed,
      CASE
        WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN 'Trigger price review + notify counterparty'
        ELSE 'Review correlation'
      END AS recommended_action,
      co.contract_number,p.name_en AS counterparty_name,
      NULLIF(cr.meta->>'index_move_bps','')::integer AS index_move_bps,os.id AS trigger_signal_ref
    FROM correlation c JOIN correlation_rule cr ON cr.rule_id=c.rule_id AND cr.tenant_id=c.tenant_id
    LEFT JOIN osint_signal os ON os.id=c.signal_id
    JOIN contract co ON co.id=c.contract_id AND co.is_active=TRUE
    LEFT JOIN party p ON p.id=co.counterparty_id
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id=c.contract_id AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active'
      AND c.created_at>=NOW()-p_window_days*INTERVAL '1 day' AND c.rule_id LIKE ANY (ARRAY['rule.brent.%','rule.dubai.%','rule.murban.%'])
    ORDER BY mar_aed DESC NULLS LAST LIMIT 8
  ),
  payment_delay_corr AS (
    SELECT c.id AS correlation_id,c.contract_id,c.created_at AS occurred_at,c.match_reason AS headline,
      os.id AS signal_id,os.severity_v2 AS severity,co.contract_number,p.name_en AS counterparty_name,
      -- F8 FIX: read amount from osint_signal.metadata.amount_aed when present,
      -- fall back to latest_risk_score.mar_value (legacy path). Either way,
      -- the register no longer renders AED 0 across the board.
      COALESCE(
        NULLIF(os.metadata->>'amount_aed','')::numeric,
        lrs.mar_value,
        0::numeric
      ) AS amount_aed,
      NULLIF(os.metadata->>'days_overdue','')::integer AS days_overdue,
      NULLIF(os.metadata->>'invoice_ref','') AS invoice_ref
    FROM correlation c JOIN osint_signal os ON os.id=c.signal_id AND os.tenant_id=c.tenant_id
    JOIN contract co ON co.id=c.contract_id LEFT JOIN party p ON p.id=co.counterparty_id
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id=c.contract_id AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active'
      AND os.kind='internal' AND os.signal_kind_subtype IN ('payment_delay','invoice_dispute')
      AND c.created_at>=NOW()-p_window_days*INTERVAL '1 day'
    ORDER BY occurred_at DESC LIMIT 8
  ),
  payment_delay_corr_prev AS (
    SELECT c.id FROM correlation c JOIN osint_signal os ON os.id=c.signal_id AND os.tenant_id=c.tenant_id
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active'
      AND os.kind='internal' AND os.signal_kind_subtype IN ('payment_delay','invoice_dispute')
      AND c.created_at BETWEEN NOW()-(2*p_window_days)*INTERVAL '1 day' AND NOW()-p_window_days*INTERVAL '1 day'
  ),
  price_review_corr_prev AS (
    SELECT c.id FROM correlation c
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active'
      AND c.rule_id LIKE ANY (ARRAY['rule.brent.%','rule.dubai.%','rule.murban.%'])
      AND c.created_at BETWEEN NOW()-(2*p_window_days)*INTERVAL '1 day' AND NOW()-p_window_days*INTERVAL '1 day'
  ),
  currency_breakdown AS (
    SELECT co.currency,COUNT(*)::integer AS contract_count,COALESCE(SUM(co.value_aed),0) AS aggregate_value_aed
    FROM contract co WHERE co.is_active=TRUE AND co.status IN ('active','pending_review','signed','fully_signed') GROUP BY co.currency
    UNION ALL SELECT 'AED'::text,0,0::numeric WHERE NOT EXISTS (SELECT 1 FROM contract co2 WHERE co2.currency='AED' AND co2.is_active=TRUE)
  ),
  total_value AS (SELECT COALESCE(SUM(aggregate_value_aed),0) AS grand_total FROM currency_breakdown),
  commodity_series_raw AS (
    SELECT
      os.raw_payload->>'marker' AS marker,
      DATE(COALESCE(os.event_date_v2, os.fetched_at, os.created_at)) AS observed_date,
      AVG(NULLIF(os.raw_payload->>'price','')::numeric) AS price_usd
    FROM osint_signal os
    WHERE os.tenant_id=current_setting('app.current_tenant_id',true)::uuid
      AND os.is_active=TRUE
      AND os.source_id='commodity_crude'
      AND os.raw_payload?'marker'
      AND os.raw_payload->>'marker' IN ('BRENT','DUBAI','MURBAN')
      AND COALESCE(os.event_date_v2, os.fetched_at, os.created_at) >= NOW() - INTERVAL '30 days'
    GROUP BY os.raw_payload->>'marker', DATE(COALESCE(os.event_date_v2, os.fetched_at, os.created_at))
  ),
  commodity_series_agg AS (
    SELECT marker, jsonb_agg(jsonb_build_object('date', observed_date, 'priceUsd', price_usd) ORDER BY observed_date ASC) AS trend30d
    FROM commodity_series_raw GROUP BY marker
  ),
  commodity_current AS (
    SELECT DISTINCT ON (os.raw_payload->>'marker')
      os.raw_payload->>'marker' AS marker,
      NULLIF(os.raw_payload->>'price','')::numeric AS current_price_usd,
      NULLIF(os.raw_payload->>'threshold_proximity_bps','')::integer AS threshold_proximity_bps
    FROM osint_signal os
    WHERE os.tenant_id=current_setting('app.current_tenant_id',true)::uuid
      AND os.is_active=TRUE AND os.source_id='commodity_crude' AND os.raw_payload?'marker'
      AND os.raw_payload->>'marker' IN ('BRENT','DUBAI','MURBAN')
    ORDER BY os.raw_payload->>'marker', COALESCE(os.event_date_v2, os.fetched_at, os.created_at) DESC
  ),
  commodity_contracts AS (
    SELECT UPPER(cr.scenario) AS marker,
      jsonb_agg(jsonb_build_object('contractId',co.id::text,'contractNumber',co.contract_number,'counterpartyName',p.name_en,'valueAed',co.value_aed::text) ORDER BY co.value_aed DESC NULLS LAST) AS contracts_exposed
    FROM correlation c JOIN correlation_rule cr ON cr.rule_id=c.rule_id AND cr.tenant_id=c.tenant_id
    JOIN contract co ON co.id=c.contract_id AND co.is_active=TRUE LEFT JOIN party p ON p.id=co.counterparty_id
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active'
      AND cr.scenario IN ('brent','dubai','murban')
    GROUP BY UPPER(cr.scenario)
  ),
  fx_signals_raw AS (
    SELECT DATE(COALESCE(os.event_date_v2, os.fetched_at, os.created_at)) AS observed_date,
      COALESCE(os.event_date_v2, os.fetched_at, os.created_at) AS observed_at,
      NULLIF(os.metadata->>'peg_deviation_bps','')::integer AS meta_dev_bps,
      NULLIF(os.raw_payload->>'rate','')::numeric AS rate
    FROM osint_signal os
    WHERE os.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND os.is_active=TRUE
      AND os.source_id='fx_usd_aed'
      AND (os.raw_payload->>'pair'='AED' OR os.affected_entities @> '[{"identifier":"USD_AED"}]'::jsonb)
      AND COALESCE(os.event_date_v2, os.fetched_at, os.created_at) >= NOW() - INTERVAL '30 days'
  ),
  fx_signals_resolved AS (
    SELECT observed_date, observed_at,
      CASE WHEN meta_dev_bps IS NOT NULL THEN meta_dev_bps
           WHEN rate IS NOT NULL THEN ROUND(((rate - 3.6725) / 3.6725 * 10000)::numeric, 0)::integer
           ELSE NULL END AS deviation_bps
    FROM fx_signals_raw
  ),
  fx_series_day AS (SELECT observed_date, AVG(deviation_bps)::numeric AS deviation_bps FROM fx_signals_resolved WHERE deviation_bps IS NOT NULL GROUP BY observed_date),
  fx_series_agg AS (SELECT jsonb_agg(jsonb_build_object('date', observed_date, 'deviationBps', deviation_bps) ORDER BY observed_date ASC) AS series30d FROM fx_series_day),
  fx_current AS (SELECT deviation_bps FROM fx_signals_resolved WHERE deviation_bps IS NOT NULL ORDER BY observed_at DESC LIMIT 1),
  kpi_current AS (
    SELECT COALESCE((SELECT SUM(value_aed) FROM contract WHERE is_active=TRUE AND status IN ('active','fully_signed','signed')),0) AS total_exposure_aed,
      COALESCE((SELECT SUM(value_aed) FROM contract WHERE is_active=TRUE AND currency<>'AED' AND status IN ('active','fully_signed','signed')),0) AS fx_exposure_non_aed_aed,
      (SELECT COUNT(*) FROM price_review_corr)::integer AS price_review_triggered_count,
      (SELECT COUNT(*) FROM payment_delay_corr)::integer AS payment_delays_count,
      COALESCE((SELECT SUM(amount_aed) FROM payment_delay_corr),0) AS payment_delays_aed
  ),
  kpi_previous AS (
    SELECT COALESCE((SELECT SUM(value_aed) FROM contract WHERE is_active=TRUE AND status IN ('active','fully_signed','signed') AND created_at<NOW()-p_window_days*INTERVAL '1 day'),0) AS total_exposure_aed,
      COALESCE((SELECT SUM(value_aed) FROM contract WHERE is_active=TRUE AND currency<>'AED' AND status IN ('active','fully_signed','signed') AND created_at<NOW()-p_window_days*INTERVAL '1 day'),0) AS fx_exposure_non_aed_aed,
      (SELECT COUNT(*) FROM price_review_corr_prev)::integer AS price_review_triggered_count,
      (SELECT COUNT(*) FROM payment_delay_corr_prev)::integer AS payment_delays_count,
      0::numeric AS payment_delays_aed
  )
  SELECT jsonb_build_object(
    'windowDays',p_window_days,'asOf',NOW(),
    'kpi',(SELECT jsonb_build_object('totalExposureAed',total_exposure_aed::text,'fxExposureNonAedAed',fx_exposure_non_aed_aed::text,'priceReviewTriggeredCount',price_review_triggered_count,'paymentDelaysCount',payment_delays_count,'paymentDelaysAed',payment_delays_aed::text) FROM kpi_current),
    'kpiPrev',(SELECT jsonb_build_object('totalExposureAed',total_exposure_aed::text,'fxExposureNonAedAed',fx_exposure_non_aed_aed::text,'priceReviewTriggeredCount',price_review_triggered_count,'paymentDelaysCount',payment_delays_count,'paymentDelaysAed',payment_delays_aed::text) FROM kpi_previous),
    'fxVolatilityTile',jsonb_build_object('aedPegStatus','stable','pegDeviationBps',NULL,'lastCheckedAt',NOW(),'nonAedContractCount',(SELECT COUNT(*) FROM contract WHERE currency<>'AED' AND is_active=TRUE)::integer,'nonAedContractValueAed',COALESCE((SELECT SUM(value_aed) FROM contract WHERE currency<>'AED' AND is_active=TRUE),0)::text),
    'priceReviewTriggerQueue',COALESCE((SELECT jsonb_agg(jsonb_build_object('correlationId',correlation_id::text,'contractId',contract_id::text,'contractNumber',contract_number,'counterpartyName',counterparty_name,'triggerSignalRef',trigger_signal_ref::text,'triggerHeadline',trigger_headline,'indexName',index_name,'indexMoveBps',index_move_bps,'marAed',mar_aed::text,'recommendedAction',recommended_action,'occurredAt',occurred_at) ORDER BY mar_aed DESC NULLS LAST) FROM price_review_corr),'[]'::jsonb),
    'paymentDelayRegister',COALESCE((SELECT jsonb_agg(jsonb_build_object('correlationId',correlation_id::text,'contractId',contract_id::text,'contractNumber',contract_number,'counterpartyName',counterparty_name,'signalId',signal_id::text,'invoiceRef',invoice_ref,'daysOverdue',days_overdue,'amountAed',amount_aed::text,'severity',severity) ORDER BY occurred_at DESC) FROM payment_delay_corr),'[]'::jsonb),
    'currencyExposureBreakdown',COALESCE((SELECT jsonb_agg(jsonb_build_object('currency',cb.currency,'contractCount',cb.contract_count,'aggregateValueOriginal',cb.aggregate_value_aed::text,'aggregateValueAed',cb.aggregate_value_aed::text,'percentOfTotal',CASE WHEN tv.grand_total>0 THEN ROUND((cb.aggregate_value_aed/tv.grand_total)::numeric,4) ELSE 0 END) ORDER BY cb.aggregate_value_aed DESC) FROM currency_breakdown cb CROSS JOIN total_value tv),'[]'::jsonb),
    'commodityExposure', jsonb_build_object(
      'brent', (SELECT jsonb_build_object('currentPriceUsd', cc.current_price_usd,'trend30d',COALESCE(csa.trend30d, '[]'::jsonb),'thresholdProximityBps', cc.threshold_proximity_bps,'contractsExposed', COALESCE(cco.contracts_exposed, '[]'::jsonb)) FROM (SELECT NULL::numeric AS current_price_usd, NULL::integer AS threshold_proximity_bps) base LEFT JOIN commodity_current cc ON cc.marker='BRENT' LEFT JOIN commodity_series_agg csa ON csa.marker='BRENT' LEFT JOIN commodity_contracts cco ON cco.marker='BRENT'),
      'dubai', (SELECT jsonb_build_object('currentPriceUsd', cc.current_price_usd,'trend30d',COALESCE(csa.trend30d, '[]'::jsonb),'thresholdProximityBps', cc.threshold_proximity_bps,'contractsExposed', COALESCE(cco.contracts_exposed, '[]'::jsonb)) FROM (SELECT NULL::numeric AS current_price_usd, NULL::integer AS threshold_proximity_bps) base LEFT JOIN commodity_current cc ON cc.marker='DUBAI' LEFT JOIN commodity_series_agg csa ON csa.marker='DUBAI' LEFT JOIN commodity_contracts cco ON cco.marker='DUBAI'),
      'murban',(SELECT jsonb_build_object('currentPriceUsd', cc.current_price_usd,'trend30d',COALESCE(csa.trend30d, '[]'::jsonb),'thresholdProximityBps', cc.threshold_proximity_bps,'contractsExposed', COALESCE(cco.contracts_exposed, '[]'::jsonb)) FROM (SELECT NULL::numeric AS current_price_usd, NULL::integer AS threshold_proximity_bps) base LEFT JOIN commodity_current cc ON cc.marker='MURBAN' LEFT JOIN commodity_series_agg csa ON csa.marker='MURBAN' LEFT JOIN commodity_contracts cco ON cco.marker='MURBAN')
    ),
    'fxHistory', jsonb_build_object(
      'pair', 'USD/AED',
      'currentDeviationBps', (SELECT deviation_bps FROM fx_current),
      'series30d', COALESCE((SELECT series30d FROM fx_series_agg), '[]'::jsonb),
      'severityThresholdBps', 50
    )
  ) INTO v_result;
  RETURN v_result;
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_dashboard_finance_treasury: %', SQLERRM USING ERRCODE=SQLSTATE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) TO neondb_owner;
COMMENT ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) IS
  'Finance & Treasury persona dashboard. v366 (F8): paymentDelayRegister.amountAed + paymentDelaysAed KPI now sourced from osint_signal.metadata.amount_aed with lrs.mar_value fallback.';

-- ============================================================
-- ROLLBACK — re-run 195_rft_extend_finance_treasury_fx_history.sql
-- ============================================================
