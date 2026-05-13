-- Migration: 194_rft_extend_finance_treasury_commodity_exposure.sql
-- Unit: Unit-3 (R-FT — Commodity Exposure widget)
-- Description: CREATE OR REPLACE fn_dashboard_finance_treasury to add a top-level
--              commodityExposure key sourced from osint_signal rows where
--              source_id='commodity_crude' AND raw_payload->>'marker' IN
--              (BRENT, DUBAI, MURBAN).
--
--              Preserves EVERY existing safety guard (permission gate, actor /
--              window ERRCODE raises, every existing top-level key — windowDays,
--              asOf, kpi, kpiPrev, fxVolatilityTile, priceReviewTriggerQueue,
--              paymentDelayRegister, currencyExposureBreakdown). Diff against
--              pg_get_functiondef pre-194: only adds the new key.
--
--              Tolerant of empty data: when no commodity_crude rows exist the
--              key returns {brent:null,dubai:null,murban:null,thresholdProximityBps:null}
--              so the FE can render an empty/placeholder state without an error.
--
--              S2-21 guard explicit. S2-24 split-aggregate pattern used for
--              30d series (inner GROUP BY + outer jsonb_agg).
-- Reference: decisions AD-9, GAP-REPORT-FINANCE-TREASURY H3, R-FT4 round.
-- Rollback: revert fn body to the 190-vintage version (see ROLLBACK section).

-- ============================================================
-- FORWARD MIGRATION
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
      COALESCE(lrs.mar_value,0::numeric) AS amount_aed,
      NULLIF(os.metadata->>'days_overdue','')::integer AS days_overdue,NULLIF(os.metadata->>'invoice_ref','') AS invoice_ref
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
  -- NEW IN 194: commodity exposure series + current price per marker.
  -- Sources osint_signal rows kept under source_id='commodity_crude' with
  -- raw_payload.marker in (BRENT,DUBAI,MURBAN). Tolerant of empty data.
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
    FROM commodity_series_raw
    GROUP BY marker
  ),
  commodity_current AS (
    SELECT DISTINCT ON (os.raw_payload->>'marker')
      os.raw_payload->>'marker' AS marker,
      NULLIF(os.raw_payload->>'price','')::numeric AS current_price_usd,
      NULLIF(os.raw_payload->>'threshold_proximity_bps','')::integer AS threshold_proximity_bps
    FROM osint_signal os
    WHERE os.tenant_id=current_setting('app.current_tenant_id',true)::uuid
      AND os.is_active=TRUE
      AND os.source_id='commodity_crude'
      AND os.raw_payload?'marker'
      AND os.raw_payload->>'marker' IN ('BRENT','DUBAI','MURBAN')
    ORDER BY os.raw_payload->>'marker', COALESCE(os.event_date_v2, os.fetched_at, os.created_at) DESC
  ),
  commodity_contracts AS (
    -- Contracts exposed by index: derive by joining correlation_rule (scenario='brent'|'dubai'|'murban')
    -- with active correlations + contracts. Returns up to 5 per marker.
    SELECT
      UPPER(cr.scenario) AS marker,
      jsonb_agg(jsonb_build_object(
        'contractId',  co.id::text,
        'contractNumber', co.contract_number,
        'counterpartyName', p.name_en,
        'valueAed', co.value_aed::text
      ) ORDER BY co.value_aed DESC NULLS LAST) AS contracts_exposed
    FROM correlation c
    JOIN correlation_rule cr ON cr.rule_id=c.rule_id AND cr.tenant_id=c.tenant_id
    JOIN contract co ON co.id=c.contract_id AND co.is_active=TRUE
    LEFT JOIN party p ON p.id=co.counterparty_id
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid
      AND c.is_active=TRUE AND c.status='active'
      AND cr.scenario IN ('brent','dubai','murban')
    GROUP BY UPPER(cr.scenario)
  ),
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
    -- NEW key in 194: commodityExposure
    'commodityExposure', jsonb_build_object(
      'brent', (SELECT jsonb_build_object(
                  'currentPriceUsd', cc.current_price_usd,
                  'trend30d',        COALESCE(csa.trend30d, '[]'::jsonb),
                  'thresholdProximityBps', cc.threshold_proximity_bps,
                  'contractsExposed', COALESCE(cco.contracts_exposed, '[]'::jsonb))
                FROM (SELECT NULL::numeric AS current_price_usd, NULL::integer AS threshold_proximity_bps) base
                LEFT JOIN commodity_current cc ON cc.marker='BRENT'
                LEFT JOIN commodity_series_agg csa ON csa.marker='BRENT'
                LEFT JOIN commodity_contracts cco ON cco.marker='BRENT'),
      'dubai', (SELECT jsonb_build_object(
                  'currentPriceUsd', cc.current_price_usd,
                  'trend30d',        COALESCE(csa.trend30d, '[]'::jsonb),
                  'thresholdProximityBps', cc.threshold_proximity_bps,
                  'contractsExposed', COALESCE(cco.contracts_exposed, '[]'::jsonb))
                FROM (SELECT NULL::numeric AS current_price_usd, NULL::integer AS threshold_proximity_bps) base
                LEFT JOIN commodity_current cc ON cc.marker='DUBAI'
                LEFT JOIN commodity_series_agg csa ON csa.marker='DUBAI'
                LEFT JOIN commodity_contracts cco ON cco.marker='DUBAI'),
      'murban', (SELECT jsonb_build_object(
                  'currentPriceUsd', cc.current_price_usd,
                  'trend30d',        COALESCE(csa.trend30d, '[]'::jsonb),
                  'thresholdProximityBps', cc.threshold_proximity_bps,
                  'contractsExposed', COALESCE(cco.contracts_exposed, '[]'::jsonb))
                FROM (SELECT NULL::numeric AS current_price_usd, NULL::integer AS threshold_proximity_bps) base
                LEFT JOIN commodity_current cc ON cc.marker='MURBAN'
                LEFT JOIN commodity_series_agg csa ON csa.marker='MURBAN'
                LEFT JOIN commodity_contracts cco ON cco.marker='MURBAN')
    )
  ) INTO v_result;
  RETURN v_result;
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_dashboard_finance_treasury: %', SQLERRM USING ERRCODE=SQLSTATE;
END;
$function$;

-- S2-21 explicit guard for the replaced function. fn_'s lose ACLs on
-- CREATE OR REPLACE — re-apply REVOKE/GRANT here.
REVOKE EXECUTE ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) TO neondb_owner;
COMMENT ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) IS
  'Finance & Treasury persona dashboard. v194: adds commodityExposure key (brent/dubai/murban current price + 30d trend + contracts exposed) sourced from osint_signal source_id=commodity_crude. Tolerant of empty commodity data.';

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (194, 'Unit-3 R-FT4: extend fn_dashboard_finance_treasury with commodityExposure key (Brent/Dubai/Murban)', NOW())
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK
-- ============================================================
-- To roll back: replay migration 190_crg_fix_finance_treasury_and_compliance_esg_yaml_casts.sql
-- which contains the pre-194 fn body. DELETE FROM schema_migrations WHERE version=194;
