-- Migration 190: Fix produce_yaml::jsonb casts in fn_dashboard_finance_treasury and fn_dashboard_compliance_esg
-- produce_yaml is YAML TEXT, not JSON — the ::jsonb cast raises "invalid input syntax for type json".
-- Replace with rule_id-pattern CASE expressions (same approach as migration 189 for fn_dashboard_executive).
--
-- fn_dashboard_finance_treasury: 1 produce_yaml reference (recommended_action in price_review_corr CTE).
--   The correlation_rule JOIN is preserved because cr.scenario and cr.meta are also referenced.
-- fn_dashboard_compliance_esg: 3 produce_yaml references (severity CASE in esg_corrs CTE).
--   The correlation_rule JOIN in esg_corrs is dropped — it was only used for produce_yaml there.
--
-- Rollback: Re-apply bodies from migration 184 (fn_dashboard_finance_treasury) and 185 (fn_dashboard_compliance_esg).

-- ============================================================
-- FUNCTION 1: fn_dashboard_finance_treasury
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_dashboard_finance_treasury(p_actor_id bigint, p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
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
    'currencyExposureBreakdown',COALESCE((SELECT jsonb_agg(jsonb_build_object('currency',cb.currency,'contractCount',cb.contract_count,'aggregateValueOriginal',cb.aggregate_value_aed::text,'aggregateValueAed',cb.aggregate_value_aed::text,'percentOfTotal',CASE WHEN tv.grand_total>0 THEN ROUND((cb.aggregate_value_aed/tv.grand_total)::numeric,4) ELSE 0 END) ORDER BY cb.aggregate_value_aed DESC) FROM currency_breakdown cb CROSS JOIN total_value tv),'[]'::jsonb)
  ) INTO v_result;
  RETURN v_result;
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_dashboard_finance_treasury: %', SQLERRM USING ERRCODE=SQLSTATE;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) TO neondb_owner;

COMMENT ON FUNCTION public.fn_dashboard_finance_treasury(bigint, integer) IS
  'Finance & Treasury persona dashboard. Returns KPIs, price-review trigger queue (brent/dubai/murban correlations), payment-delay register, FX volatility tile, and currency exposure breakdown. SECURITY DEFINER — caller must hold insights.finance_treasury or insights.executive permission. Migration 190: replaced produce_yaml::jsonb cast with rule_id-pattern CASE expressions.';

-- ============================================================
-- FUNCTION 2: fn_dashboard_compliance_esg
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_dashboard_compliance_esg(p_actor_id bigint, p_window_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
AS $function$
DECLARE
  v_result JSONB; v_chain_rows JSONB; v_chain_row JSONB;
  v_chain_sanctions_count INTEGER := 0; v_party BIGINT; v_chain_summary JSONB;
  v_sanctions_chain_items JSONB[] := ARRAY[]::JSONB[]; v_contract_count INTEGER; v_chain_row_built JSONB;
BEGIN
  IF NOT (fn_current_user_has_permission('insights.compliance_esg') OR fn_current_user_has_permission('insights.executive')) THEN
    RAISE EXCEPTION 'permission_denied: insights.compliance_esg required' USING ERRCODE='42501';
  END IF;
  IF p_actor_id IS NULL OR p_actor_id<=0 THEN RAISE EXCEPTION 'invalid_actor_id' USING ERRCODE='22023'; END IF;
  IF p_window_days NOT BETWEEN 7 AND 365 THEN RAISE EXCEPTION 'invalid_window_days' USING ERRCODE='22023'; END IF;
  FOR v_party IN SELECT DISTINCT co.counterparty_id FROM contract co WHERE co.is_active=TRUE AND co.counterparty_id IS NOT NULL
  LOOP
    BEGIN v_chain_summary := fn_party_chain_summary(p_actor_id,v_party,5);
    EXCEPTION WHEN OTHERS THEN v_chain_summary := NULL; END;
    IF v_chain_summary IS NOT NULL AND (v_chain_summary->>'sanctionedNodesCount')::integer>0 THEN
      SELECT COUNT(DISTINCT co.id)::integer INTO v_contract_count FROM contract co WHERE co.counterparty_id=v_party AND co.is_active=TRUE;
      v_chain_row_built := jsonb_build_object('chainRootCounterpartyId',v_party::text,'chainRootName',COALESCE((SELECT name_en FROM party WHERE id=v_party),'Unknown'),'depthReached',COALESCE((v_chain_summary->>'chainDepth')::integer,0),'sanctionedNodesCount',(v_chain_summary->>'sanctionedNodesCount')::integer,'affectedContractsCount',v_contract_count,'chainTruncated',COALESCE((v_chain_summary->>'chainTruncated')::boolean,FALSE));
      v_sanctions_chain_items := array_append(v_sanctions_chain_items,v_chain_row_built);
      v_chain_sanctions_count := v_chain_sanctions_count+1;
    END IF;
  END LOOP;
  IF array_length(v_sanctions_chain_items,1)>0 THEN
    SELECT jsonb_agg(item ORDER BY (item->>'affectedContractsCount')::integer DESC) INTO v_chain_rows FROM unnest(v_sanctions_chain_items) AS item LIMIT 8;
  ELSE v_chain_rows := '[]'::jsonb; END IF;
  WITH direct_sanctions AS (
    SELECT co.id AS contract_id,co.contract_number,p.id AS counterparty_id,p.name_en AS counterparty_name,
      p.sanctions_status,'direct'::text AS exposure_kind,NULL::text[] AS chain_path,FALSE AS chain_truncated,
      COALESCE(lrs.mar_value,0::numeric) AS mar_aed
    FROM contract co JOIN party p ON p.id=co.counterparty_id
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id=co.id AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    WHERE co.is_active=TRUE AND p.sanctions_status<>'clean' AND p.is_active=TRUE ORDER BY mar_aed DESC NULLS LAST LIMIT 10
  ),
  audit_rights AS (
    SELECT cce.contract_id,co.contract_number,p.name_en AS counterparty_name,cce.clause_type_v2 AS audit_clause_type,
      (cce.parameters->>'endDate')::date AS expires_on,((cce.parameters->>'endDate')::date-CURRENT_DATE)::integer AS days_to_expiry,
      CASE WHEN ((cce.parameters->>'endDate')::date-CURRENT_DATE)<30 THEN 'high' WHEN ((cce.parameters->>'endDate')::date-CURRENT_DATE)<90 THEN 'medium' ELSE 'low' END AS severity
    FROM contract_clause_extracted cce JOIN contract co ON co.id=cce.contract_id LEFT JOIN party p ON p.id=co.counterparty_id
    WHERE cce.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND cce.is_active=TRUE AND cce.clause_type_v2='audit_rights' AND cce.parameters?'endDate'
    ORDER BY expires_on ASC NULLS LAST LIMIT 15
  ),
  reg_updates AS (
    SELECT ru.id AS regulatory_update_id,ru.title_en AS headline,ru.severity,ru.published_date AS occurred_at,
      COALESCE((SELECT r2.name_en FROM regulator r2 WHERE r2.id=ru.regulator_id LIMIT 1),COALESCE(ru.sub_source,'Regulator-'||ru.regulator_id::text)) AS regulator_name,
      (SELECT COUNT(*) FROM regulatory_impact ri WHERE ri.regulatory_update_id=ru.id)::integer AS affected_contracts_count
    FROM regulatory_update ru
    WHERE ru.is_active=TRUE AND ru.published_date>=NOW()-p_window_days*INTERVAL '1 day'
    ORDER BY ru.published_date DESC LIMIT 8
  ),
  esg_corrs AS (
    SELECT c.id AS correlation_id,c.match_reason AS headline,c.contract_id,p.name_en AS counterparty_name,COALESCE(lrs.mar_value,0::numeric) AS mar_aed,c.created_at AS occurred_at,
      CASE
        WHEN c.rule_id LIKE 'rule.sanctions.%' THEN 'critical'
        WHEN c.rule_id LIKE 'rule.hormuz.%' THEN 'high'
        WHEN c.rule_id LIKE 'rule.brent.%' OR c.rule_id LIKE 'rule.dubai.%' OR c.rule_id LIKE 'rule.murban.%' THEN 'medium'
        WHEN c.rule_id LIKE 'rule.epc_sla.%' THEN 'medium'
        ELSE 'medium'
      END AS severity
    FROM correlation c
    JOIN contract co ON co.id=c.contract_id LEFT JOIN party p ON p.id=co.counterparty_id
    LEFT JOIN latest_risk_score lrs ON lrs.contract_id=c.contract_id AND lrs.tenant_id=current_setting('app.current_tenant_id',true)::uuid
    WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active' AND c.rule_id LIKE 'rule.esg.%'
    ORDER BY mar_aed DESC NULLS LAST LIMIT 8
  ),
  direct_sanctions_prev AS (SELECT co.id FROM contract co JOIN party p ON p.id=co.counterparty_id WHERE co.is_active=TRUE AND p.sanctions_status<>'clean' AND p.is_active=TRUE AND co.created_at<NOW()-p_window_days*INTERVAL '1 day'),
  audit_rights_prev AS (SELECT cce.contract_id FROM contract_clause_extracted cce WHERE cce.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND cce.is_active=TRUE AND cce.clause_type_v2='audit_rights' AND cce.parameters?'endDate' AND ((cce.parameters->>'endDate')::date-CURRENT_DATE) BETWEEN 0 AND 90 AND cce.created_at<NOW()-p_window_days*INTERVAL '1 day'),
  reg_updates_prev AS (SELECT ru.id FROM regulatory_update ru WHERE ru.is_active=TRUE AND ru.published_date>=NOW()-(2*p_window_days)*INTERVAL '1 day' AND ru.published_date<NOW()-p_window_days*INTERVAL '1 day'),
  esg_corrs_prev AS (SELECT c.id FROM correlation c WHERE c.tenant_id=current_setting('app.current_tenant_id',true)::uuid AND c.is_active=TRUE AND c.status='active' AND c.rule_id LIKE 'rule.esg.%' AND c.created_at>=NOW()-(2*p_window_days)*INTERVAL '1 day' AND c.created_at<NOW()-p_window_days*INTERVAL '1 day'),
  kpi_current AS (SELECT (SELECT COUNT(*) FROM direct_sanctions)::integer AS sanctions_direct,v_chain_sanctions_count AS sanctions_chain,(SELECT COUNT(*) FROM audit_rights WHERE days_to_expiry BETWEEN 0 AND 90)::integer AS audit_rights_expiring,(SELECT COUNT(*) FROM reg_updates)::integer AS open_reg_updates,(SELECT COUNT(*) FROM esg_corrs)::integer AS open_esg_corrs),
  kpi_previous AS (SELECT (SELECT COUNT(*) FROM direct_sanctions_prev)::integer AS sanctions_direct,0::integer AS sanctions_chain,(SELECT COUNT(*) FROM audit_rights_prev)::integer AS audit_rights_expiring,(SELECT COUNT(*) FROM reg_updates_prev)::integer AS open_reg_updates,(SELECT COUNT(*) FROM esg_corrs_prev)::integer AS open_esg_corrs)
  SELECT jsonb_build_object(
    'windowDays',p_window_days,'asOf',NOW(),
    'kpi',(SELECT jsonb_build_object('sanctionsExposureDirectCount',sanctions_direct,'sanctionsExposureChainCount',sanctions_chain,'auditRightsExpiringCount',audit_rights_expiring,'openRegulatoryUpdatesCount',open_reg_updates,'openEsgCorrelationsCount',open_esg_corrs) FROM kpi_current),
    'kpiPrev',(SELECT jsonb_build_object('sanctionsExposureDirectCount',sanctions_direct,'sanctionsExposureChainCount',sanctions_chain,'auditRightsExpiringCount',audit_rights_expiring,'openRegulatoryUpdatesCount',open_reg_updates,'openEsgCorrelationsCount',open_esg_corrs) FROM kpi_previous),
    'sanctionsExposureList',COALESCE((SELECT jsonb_agg(jsonb_build_object('contractId',contract_id::text,'contractNumber',contract_number,'counterpartyId',counterparty_id::text,'counterpartyName',counterparty_name,'sanctionsStatus',sanctions_status,'exposureKind',exposure_kind,'chainPath',chain_path,'chainTruncated',chain_truncated,'marAed',mar_aed::text) ORDER BY mar_aed DESC NULLS LAST) FROM direct_sanctions),'[]'::jsonb),
    'auditRightsTracker',COALESCE((SELECT jsonb_agg(jsonb_build_object('contractId',contract_id::text,'contractNumber',contract_number,'counterpartyName',counterparty_name,'auditClauseType',audit_clause_type,'expiresOnIso',expires_on,'daysToExpiry',days_to_expiry,'severity',severity) ORDER BY days_to_expiry ASC) FROM audit_rights),'[]'::jsonb),
    'subContractorChainView',COALESCE(v_chain_rows,'[]'::jsonb),
    'regulatoryUpdatesMonitor',COALESCE((SELECT jsonb_agg(jsonb_build_object('regulatoryUpdateId',regulatory_update_id::text,'regulatorName',regulator_name,'headline',headline,'severity',severity,'occurredAt',occurred_at,'affectedContractsCount',affected_contracts_count) ORDER BY occurred_at DESC) FROM reg_updates),'[]'::jsonb),
    'esgCorrelations',COALESCE((SELECT jsonb_agg(jsonb_build_object('correlationId',correlation_id::text,'headline',headline,'contractId',contract_id::text,'counterpartyName',counterparty_name,'marAed',mar_aed::text,'occurredAt',occurred_at,'severity',severity) ORDER BY mar_aed DESC NULLS LAST) FROM esg_corrs),'[]'::jsonb)
  ) INTO v_result;
  RETURN v_result;
EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'fn_dashboard_compliance_esg: %', SQLERRM USING ERRCODE=SQLSTATE;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_dashboard_compliance_esg(bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_compliance_esg(bigint, integer) TO neondb_owner;

COMMENT ON FUNCTION public.fn_dashboard_compliance_esg(bigint, integer) IS
  'Compliance & ESG persona dashboard. Returns KPIs, sanctions exposure (direct + subcontractor chain), audit-rights tracker, regulatory updates monitor, and ESG correlations. SECURITY DEFINER — caller must hold insights.compliance_esg or insights.executive permission. Migration 190: replaced produce_yaml::jsonb cast with rule_id-pattern CASE expressions; dropped correlation_rule JOIN from esg_corrs CTE (was only used for produce_yaml).';

-- ============================================================
-- Schema migrations registration
-- ============================================================
INSERT INTO schema_migrations (version, description) VALUES (190, '190_crg_fix_finance_treasury_and_compliance_esg_yaml_casts');
