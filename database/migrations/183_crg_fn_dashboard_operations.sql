-- Migration: 183_crg_fn_dashboard_operations.sql
-- Module: M15 — CR-G (Executive Decision Support Evolution + 4 Persona Dashboards + AI Risk Assistant)
-- Description: CREATE FUNCTION fn_dashboard_operations(p_actor_id bigint, p_window_days integer DEFAULT 30)
--              Returns 9 top-level keys: windowDays, asOf, kpi, kpiPrev, slaBreachesList,
--              deliveryDelayTracker, penaltyExposureByContract, opsEventsFeed, vendorScorecards
--              W-S3-1 applied: windowDays + asOf envelope keys added to RETURN
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_dashboard_operations(
  p_actor_id   BIGINT,
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
  -- Permission gate: insights.operations OR insights.executive fallback
  IF NOT (
    fn_current_user_has_permission('insights.operations')
    OR fn_current_user_has_permission('insights.executive')
  ) THEN
    RAISE EXCEPTION 'permission_denied: insights.operations required'
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

  WITH ops_corrs AS (
    SELECT
      c.id           AS correlation_id,
      c.contract_id  AS contract_id,
      c.created_at   AS occurred_at,
      c.rule_id      AS rule_id,
      c.match_reason AS headline,
      os.id          AS signal_id,
      os.signal_kind_subtype AS subtype,
      os.severity_v2 AS severity,
      CASE WHEN c.created_at >= NOW() - p_window_days * INTERVAL '1 day' THEN 'current'
           WHEN c.created_at >= NOW() - (2*p_window_days) * INTERVAL '1 day' THEN 'previous'
      END            AS bucket
    FROM correlation c
    JOIN osint_signal os
      ON os.id = c.signal_id
     AND os.tenant_id = c.tenant_id
    WHERE c.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND c.is_active = TRUE
      AND c.status = 'active'
      AND os.kind = 'internal'
      AND os.signal_kind_subtype IN ('sla_breach','milestone_slippage','vendor_incident','ics_incident')
      AND c.created_at >= NOW() - (2*p_window_days) * INTERVAL '1 day'
  ),
  ops_corrs_with_mar AS (
    SELECT
      oc.*,
      COALESCE(lrs.mar_value, 0::numeric) AS mar_aed,
      co.contract_number,
      co.title_en AS contract_title,
      co.counterparty_id,
      p.name_en   AS counterparty_name
    FROM ops_corrs oc
    LEFT JOIN latest_risk_score lrs
      ON lrs.contract_id = oc.contract_id
     AND lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    JOIN contract co ON co.id = oc.contract_id AND co.is_active = TRUE
    LEFT JOIN party p ON p.id = co.counterparty_id
  ),
  kpi_current AS (
    SELECT
      COUNT(*) FILTER (WHERE subtype = 'sla_breach' AND bucket = 'current')::integer       AS open_sla_breaches,
      COALESCE(SUM(mar_aed) FILTER (WHERE subtype = 'sla_breach' AND bucket = 'current'), 0) AS open_sla_breaches_mar,
      COUNT(*) FILTER (WHERE subtype IN ('milestone_slippage','sla_breach') AND bucket = 'current')::integer AS delivery_delays,
      COALESCE(SUM(mar_aed) FILTER (WHERE bucket = 'current'), 0)                          AS penalty_exposure,
      COUNT(DISTINCT counterparty_id) FILTER (WHERE bucket = 'current')::integer           AS vendors_with_breaches
    FROM ops_corrs_with_mar
  ),
  kpi_previous AS (
    SELECT
      COUNT(*) FILTER (WHERE subtype = 'sla_breach' AND bucket = 'previous')::integer       AS open_sla_breaches,
      COALESCE(SUM(mar_aed) FILTER (WHERE subtype = 'sla_breach' AND bucket = 'previous'), 0) AS open_sla_breaches_mar,
      COUNT(*) FILTER (WHERE subtype IN ('milestone_slippage','sla_breach') AND bucket = 'previous')::integer AS delivery_delays,
      COALESCE(SUM(mar_aed) FILTER (WHERE bucket = 'previous'), 0)                          AS penalty_exposure,
      COUNT(DISTINCT counterparty_id) FILTER (WHERE bucket = 'previous')::integer           AS vendors_with_breaches
    FROM ops_corrs_with_mar
  ),
  sla_breaches_top8 AS (
    SELECT
      contract_id, contract_number, contract_title, counterparty_name,
      subtype AS breach_kind, signal_id, occurred_at, severity, mar_aed
    FROM ops_corrs_with_mar
    WHERE subtype = 'sla_breach' AND bucket = 'current'
    ORDER BY mar_aed DESC NULLS LAST, occurred_at DESC
    LIMIT 8
  ),
  delivery_delays_per_contract AS (
    SELECT
      contract_id,
      contract_number,
      counterparty_name,
      COUNT(*)::integer                                        AS signal_count_180d,
      MAX(occurred_at)                                         AS last_delayed_at,
      MAX(severity)                                            AS max_severity,
      (ARRAY_AGG(headline ORDER BY occurred_at DESC))[1]       AS last_milestone
    FROM ops_corrs_with_mar
    WHERE subtype IN ('milestone_slippage','sla_breach') AND bucket = 'current'
    GROUP BY contract_id, contract_number, counterparty_name
    ORDER BY signal_count_180d DESC, MAX(mar_aed) DESC
    LIMIT 8
  ),
  penalty_exposure_per_contract AS (
    SELECT
      contract_id,
      contract_number,
      counterparty_name,
      SUM(mar_aed)                                               AS exposure_aed,
      STRING_AGG(headline, '; ' ORDER BY occurred_at DESC)       AS penalty_clause_summary
    FROM ops_corrs_with_mar
    WHERE bucket = 'current'
    GROUP BY contract_id, contract_number, counterparty_name
    ORDER BY exposure_aed DESC NULLS LAST
    LIMIT 8
  ),
  vendor_scorecards AS (
    SELECT
      co.counterparty_id,
      p.name_en AS counterparty_name,
      COUNT(*) FILTER (WHERE oc.subtype = 'sla_breach')::integer                          AS sla_breach_count_180d,
      COUNT(*) FILTER (WHERE oc.subtype IN ('milestone_slippage','sla_breach'))::integer   AS delivery_delay_count_180d,
      COALESCE(AVG(lrs.health_score), 0)::integer                                          AS risk_score,
      CASE
        WHEN COALESCE(AVG(lrs.health_score), 100) < 50 THEN 'high'
        WHEN COALESCE(AVG(lrs.health_score), 100) < 75 THEN 'medium'
        ELSE 'low'
      END                                                                                   AS performance_tier
    FROM ops_corrs oc
    JOIN contract co ON co.id = oc.contract_id
    JOIN party p ON p.id = co.counterparty_id
    LEFT JOIN latest_risk_score lrs
      ON lrs.contract_id = oc.contract_id
     AND lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    WHERE oc.bucket = 'current'
    GROUP BY co.counterparty_id, p.name_en
    ORDER BY risk_score ASC NULLS LAST, sla_breach_count_180d DESC
    LIMIT 8
  )
  SELECT jsonb_build_object(
    'windowDays', p_window_days,
    'asOf',       NOW(),
    'kpi',        (SELECT jsonb_build_object(
                    'openSlaBreaches',            open_sla_breaches,
                    'openSlaBreachesMarAed',      open_sla_breaches_mar::text,
                    'deliveryDelaysCount',        delivery_delays,
                    'contractPenaltyExposureAed', penalty_exposure::text,
                    'vendorsWithBreaches',        vendors_with_breaches) FROM kpi_current),
    'kpiPrev',    (SELECT jsonb_build_object(
                    'openSlaBreaches',            open_sla_breaches,
                    'openSlaBreachesMarAed',      open_sla_breaches_mar::text,
                    'deliveryDelaysCount',        delivery_delays,
                    'contractPenaltyExposureAed', penalty_exposure::text,
                    'vendorsWithBreaches',        vendors_with_breaches) FROM kpi_previous),
    'slaBreachesList',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'contractId',      contract_id::text,
          'contractNumber',  contract_number,
          'contractTitle',   contract_title,
          'counterpartyName',counterparty_name,
          'breachKind',      breach_kind,
          'signalId',        signal_id::text,
          'occurredAt',      occurred_at,
          'severity',        severity,
          'marAed',          mar_aed::text
        ) ORDER BY mar_aed DESC NULLS LAST)
        FROM sla_breaches_top8
      ), '[]'::jsonb),
    'deliveryDelayTracker',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'contractId',          contract_id::text,
          'contractNumber',      contract_number,
          'counterpartyName',    counterparty_name,
          'lastDelayedMilestone',last_milestone,
          'delayDays',           CASE WHEN last_delayed_at IS NOT NULL
                                      THEN (CURRENT_DATE - last_delayed_at::date)::integer
                                      ELSE NULL END,
          'signalCount180d',     signal_count_180d,
          'severity',            max_severity
        ) ORDER BY signal_count_180d DESC)
        FROM delivery_delays_per_contract
      ), '[]'::jsonb),
    'penaltyExposureByContract',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'contractId',          contract_id::text,
          'contractNumber',      contract_number,
          'counterpartyName',    counterparty_name,
          'penaltyClauseSummary',penalty_clause_summary,
          'exposureAed',         exposure_aed::text
        ) ORDER BY exposure_aed DESC NULLS LAST)
        FROM penalty_exposure_per_contract
      ), '[]'::jsonb),
    'opsEventsFeed',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'eventType',        rule_id,
          'contractId',       contract_id::text,
          'counterpartyName', counterparty_name,
          'headline',         headline,
          'occurredAt',       occurred_at,
          'severity',         severity,
          'sourceRef',        signal_id::text
        ) ORDER BY occurred_at DESC)
        FROM (
          SELECT * FROM ops_corrs_with_mar
          WHERE bucket = 'current'
          ORDER BY occurred_at DESC
          LIMIT 15
        ) ev
      ), '[]'::jsonb),
    'vendorScorecards',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'counterpartyId',       counterparty_id::text,
          'counterpartyName',     counterparty_name,
          'slaBreachCount180d',   sla_breach_count_180d,
          'deliveryDelayCount180d',delivery_delay_count_180d,
          'riskScore',            risk_score,
          'performanceTier',      performance_tier
        ) ORDER BY risk_score ASC NULLS LAST)
        FROM vendor_scorecards
      ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_operations: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_dashboard_operations(bigint, integer)
  IS 'CR-G Operations & SLA persona dashboard. Returns windowDays/asOf/kpi/kpiPrev/slaBreachesList/deliveryDelayTracker/penaltyExposureByContract/opsEventsFeed/vendorScorecards. Reads ops-bucket internal signals (subtype IN sla_breach/milestone_slippage/vendor_incident/ics_incident) joined to correlation/contract/party/latest_risk_score MV (tenant-scoped). Permission gate: insights.operations OR insights.executive OR Super Admin/platform_admin. p_window_days BETWEEN 7 AND 365 default 30.';
REVOKE EXECUTE ON FUNCTION fn_dashboard_operations(bigint, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_operations(bigint, integer) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (183, '183_crg_fn_dashboard_operations', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 183;
-- DROP FUNCTION IF EXISTS fn_dashboard_operations(bigint, integer);
-- ============================================================
