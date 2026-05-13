-- Migration: 184_crg_fn_dashboard_finance_treasury.sql
-- Module: M15 — CR-G (Executive Decision Support Evolution + 4 Persona Dashboards + AI Risk Assistant)
-- Description: CREATE FUNCTION fn_dashboard_finance_treasury(p_actor_id bigint, p_window_days integer DEFAULT 30)
--              Returns 8 top-level keys: windowDays, asOf, kpi, kpiPrev, fxVolatilityTile,
--              priceReviewTriggerQueue, paymentDelayRegister, currencyExposureBreakdown
--              W4 applied: explicit kpiPrev prev-window CTEs
--              W-S3-1 applied: windowDays + asOf envelope keys in RETURN
--              W3 applied: literal WHEN OTHERS block (not shorthand)
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_dashboard_finance_treasury(
  p_actor_id    BIGINT,
  p_window_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  -- Permission gate: insights.finance_treasury OR insights.executive fallback
  IF NOT (
    fn_current_user_has_permission('insights.finance_treasury')
    OR fn_current_user_has_permission('insights.executive')
  ) THEN
    RAISE EXCEPTION 'permission_denied: insights.finance_treasury required'
      USING ERRCODE = '42501';
  END IF;

  -- Input validation
  IF p_actor_id IS NULL OR p_actor_id <= 0 THEN
    RAISE EXCEPTION 'invalid_actor_id: p_actor_id must be a positive integer'
      USING ERRCODE = '22023';
  END IF;
  IF p_window_days NOT BETWEEN 7 AND 365 THEN
    RAISE EXCEPTION 'invalid_window_days: p_window_days must be between 7 and 365'
      USING ERRCODE = '22023';
  END IF;

  WITH price_review_corr AS (
    -- Correlations where rule_id matches Brent/Dubai/Murban price-review rules
    SELECT
      c.id           AS correlation_id,
      c.contract_id,
      c.rule_id,
      c.match_reason AS trigger_headline,
      c.created_at   AS occurred_at,
      cr.scenario    AS index_name,
      COALESCE(lrs.mar_value, 0::numeric) AS mar_aed,
      cr.produce_yaml::jsonb -> 'alert' ->> 'priority' AS recommended_action,
      co.contract_number,
      p.name_en AS counterparty_name,
      NULLIF(cr.meta ->> 'index_move_bps', '')::integer AS index_move_bps,
      os.id AS trigger_signal_ref
    FROM correlation c
    JOIN correlation_rule cr ON cr.rule_id = c.rule_id AND cr.tenant_id = c.tenant_id
    LEFT JOIN osint_signal os ON os.id = c.signal_id
    JOIN contract co ON co.id = c.contract_id AND co.is_active = TRUE
    LEFT JOIN party p ON p.id = co.counterparty_id
    LEFT JOIN latest_risk_score lrs
      ON lrs.contract_id = c.contract_id
     AND lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    WHERE c.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND c.is_active = TRUE
      AND c.status = 'active'
      AND c.created_at >= NOW() - p_window_days * INTERVAL '1 day'
      AND c.rule_id LIKE ANY (ARRAY['rule.brent.%','rule.dubai.%','rule.murban.%'])
    ORDER BY mar_aed DESC NULLS LAST
    LIMIT 8
  ),
  payment_delay_corr AS (
    -- Internal signals: payment_delay / invoice_dispute
    SELECT
      c.id AS correlation_id, c.contract_id, c.created_at AS occurred_at, c.match_reason AS headline,
      os.id AS signal_id, os.severity_v2 AS severity,
      co.contract_number, p.name_en AS counterparty_name,
      COALESCE(lrs.mar_value, 0::numeric) AS amount_aed,
      NULLIF(os.metadata ->> 'days_overdue', '')::integer AS days_overdue,
      NULLIF(os.metadata ->> 'invoice_ref', '') AS invoice_ref
    FROM correlation c
    JOIN osint_signal os ON os.id = c.signal_id AND os.tenant_id = c.tenant_id
    JOIN contract co ON co.id = c.contract_id
    LEFT JOIN party p ON p.id = co.counterparty_id
    LEFT JOIN latest_risk_score lrs
      ON lrs.contract_id = c.contract_id
     AND lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    WHERE c.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND c.is_active = TRUE AND c.status = 'active'
      AND os.kind = 'internal'
      AND os.signal_kind_subtype IN ('payment_delay','invoice_dispute')
      AND c.created_at >= NOW() - p_window_days * INTERVAL '1 day'
    ORDER BY occurred_at DESC
    LIMIT 8
  ),
  -- W4: explicit prev-window CTEs for kpiPrev
  payment_delay_corr_prev AS (
    SELECT c.id
    FROM correlation c
    JOIN osint_signal os ON os.id = c.signal_id AND os.tenant_id = c.tenant_id
    LEFT JOIN latest_risk_score lrs
      ON lrs.contract_id = c.contract_id
     AND lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    WHERE c.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND c.is_active = TRUE AND c.status = 'active'
      AND os.kind = 'internal'
      AND os.signal_kind_subtype IN ('payment_delay','invoice_dispute')
      AND c.created_at BETWEEN NOW() - (2*p_window_days) * INTERVAL '1 day'
                            AND NOW() - p_window_days * INTERVAL '1 day'
  ),
  price_review_corr_prev AS (
    SELECT c.id
    FROM correlation c
    WHERE c.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND c.is_active = TRUE AND c.status = 'active'
      AND c.rule_id LIKE ANY (ARRAY['rule.brent.%','rule.dubai.%','rule.murban.%'])
      AND c.created_at BETWEEN NOW() - (2*p_window_days) * INTERVAL '1 day'
                            AND NOW() - p_window_days * INTERVAL '1 day'
  ),
  currency_breakdown AS (
    SELECT
      co.currency,
      COUNT(*)::integer            AS contract_count,
      COALESCE(SUM(co.value_aed), 0) AS aggregate_value_aed
    FROM contract co
    WHERE co.is_active = TRUE
      AND co.status IN ('active','pending_review','signed','fully_signed')
    GROUP BY co.currency
    -- AED always present: UNION with synthetic row
    UNION ALL
    SELECT 'AED'::text, 0, 0::numeric
    WHERE NOT EXISTS (
      SELECT 1 FROM contract co2 WHERE co2.currency = 'AED' AND co2.is_active = TRUE
    )
  ),
  total_value AS (
    SELECT COALESCE(SUM(aggregate_value_aed), 0) AS grand_total FROM currency_breakdown
  ),
  kpi_current AS (
    SELECT
      COALESCE((SELECT SUM(value_aed) FROM contract WHERE is_active=TRUE AND status IN ('active','fully_signed','signed')), 0) AS total_exposure_aed,
      COALESCE((SELECT SUM(value_aed) FROM contract WHERE is_active=TRUE AND currency <> 'AED' AND status IN ('active','fully_signed','signed')), 0) AS fx_exposure_non_aed_aed,
      (SELECT COUNT(*) FROM price_review_corr)::integer                                     AS price_review_triggered_count,
      (SELECT COUNT(*) FROM payment_delay_corr)::integer                                    AS payment_delays_count,
      COALESCE((SELECT SUM(amount_aed) FROM payment_delay_corr), 0)                         AS payment_delays_aed
  ),
  kpi_previous AS (
    SELECT
      COALESCE((SELECT SUM(value_aed) FROM contract
                WHERE is_active=TRUE AND status IN ('active','fully_signed','signed')
                  AND created_at < NOW() - p_window_days * INTERVAL '1 day'), 0) AS total_exposure_aed,
      COALESCE((SELECT SUM(value_aed) FROM contract
                WHERE is_active=TRUE AND currency <> 'AED'
                  AND status IN ('active','fully_signed','signed')
                  AND created_at < NOW() - p_window_days * INTERVAL '1 day'), 0) AS fx_exposure_non_aed_aed,
      (SELECT COUNT(*) FROM price_review_corr_prev)::integer                                AS price_review_triggered_count,
      (SELECT COUNT(*) FROM payment_delay_corr_prev)::integer                               AS payment_delays_count,
      0::numeric                                                                              AS payment_delays_aed
  )
  SELECT jsonb_build_object(
    'windowDays', p_window_days,
    'asOf',       NOW(),
    'kpi',        (SELECT jsonb_build_object(
                    'totalExposureAed',          total_exposure_aed::text,
                    'fxExposureNonAedAed',       fx_exposure_non_aed_aed::text,
                    'priceReviewTriggeredCount', price_review_triggered_count,
                    'paymentDelaysCount',        payment_delays_count,
                    'paymentDelaysAed',          payment_delays_aed::text) FROM kpi_current),
    'kpiPrev',    (SELECT jsonb_build_object(
                    'totalExposureAed',          total_exposure_aed::text,
                    'fxExposureNonAedAed',       fx_exposure_non_aed_aed::text,
                    'priceReviewTriggeredCount', price_review_triggered_count,
                    'paymentDelaysCount',        payment_delays_count,
                    'paymentDelaysAed',          payment_delays_aed::text) FROM kpi_previous),
    'fxVolatilityTile', jsonb_build_object(
      'aedPegStatus',           'stable',
      'pegDeviationBps',        NULL,
      'lastCheckedAt',          NOW(),
      'nonAedContractCount',    (SELECT COUNT(*) FROM contract WHERE currency <> 'AED' AND is_active=TRUE)::integer,
      'nonAedContractValueAed', COALESCE((SELECT SUM(value_aed) FROM contract WHERE currency <> 'AED' AND is_active=TRUE), 0)::text
    ),
    'priceReviewTriggerQueue',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'correlationId',    correlation_id::text,
          'contractId',       contract_id::text,
          'contractNumber',   contract_number,
          'counterpartyName', counterparty_name,
          'triggerSignalRef', trigger_signal_ref::text,
          'triggerHeadline',  trigger_headline,
          'indexName',        index_name,
          'indexMoveBps',     index_move_bps,
          'marAed',           mar_aed::text,
          'recommendedAction',recommended_action,
          'occurredAt',       occurred_at
        ) ORDER BY mar_aed DESC NULLS LAST)
        FROM price_review_corr
      ), '[]'::jsonb),
    'paymentDelayRegister',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'correlationId',    correlation_id::text,
          'contractId',       contract_id::text,
          'contractNumber',   contract_number,
          'counterpartyName', counterparty_name,
          'signalId',         signal_id::text,
          'invoiceRef',       invoice_ref,
          'daysOverdue',      days_overdue,
          'amountAed',        amount_aed::text,
          'severity',         severity
        ) ORDER BY occurred_at DESC)
        FROM payment_delay_corr
      ), '[]'::jsonb),
    'currencyExposureBreakdown',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'currency',               cb.currency,
          'contractCount',          cb.contract_count,
          'aggregateValueOriginal', cb.aggregate_value_aed::text,
          'aggregateValueAed',      cb.aggregate_value_aed::text,
          'percentOfTotal',         CASE WHEN tv.grand_total > 0
                                         THEN ROUND((cb.aggregate_value_aed / tv.grand_total)::numeric, 4)
                                         ELSE 0 END
        ) ORDER BY cb.aggregate_value_aed DESC)
        FROM currency_breakdown cb CROSS JOIN total_value tv
      ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_finance_treasury: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_dashboard_finance_treasury(bigint, integer)
  IS 'CR-G Finance & Treasury persona dashboard. Returns windowDays/asOf/kpi/kpiPrev/fxVolatilityTile(stub v1 always stable)/priceReviewTriggerQueue(rule_id LIKE rule.{brent,dubai,murban}.%)/paymentDelayRegister(internal subtype IN payment_delay/invoice_dispute)/currencyExposureBreakdown. v1 only Brent rule seeded; Dubai/Murban deferred to R-FT. Permission gate: insights.finance_treasury OR insights.executive OR Super Admin/platform_admin. p_window_days BETWEEN 7 AND 365 default 30.';
REVOKE EXECUTE ON FUNCTION fn_dashboard_finance_treasury(bigint, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_finance_treasury(bigint, integer) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (184, '184_crg_fn_dashboard_finance_treasury', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 184;
-- DROP FUNCTION IF EXISTS fn_dashboard_finance_treasury(bigint, integer);
-- ============================================================
