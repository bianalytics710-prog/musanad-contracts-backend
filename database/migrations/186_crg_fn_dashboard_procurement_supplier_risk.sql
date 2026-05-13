-- Migration: 186_crg_fn_dashboard_procurement_supplier_risk.sql
-- Module: M15 — CR-G (Executive Decision Support Evolution + 4 Persona Dashboards + AI Risk Assistant)
-- Description: CREATE fn_dashboard_procurement_supplier_risk — Procurement & Supplier Risk persona dashboard
--              Returns kpi/kpiPrev/supplierRiskScorecard/icvComplianceTracker/backupSupplierSuggestions/vendorFinancialHealthSummary
--              Per-party composite_risk_score = AVG(latest_risk_score.health_score) over party's active contracts (design lock A4)
--              party.party_type pivot for backupSupplierSuggestions (design lock A4b)
--              W1: camelCase dim keys (dimLegal/dimFinancial/dimOperational/dimReputational/dimCompliance)
--              W2 locked: financial signal filter kind='news' AND signal_kind_subtype IN ('financial_distress','downgrade','default')
--              W3: literal WHEN OTHERS block
--              W-S3-1: windowDays + asOf envelope keys in RETURN
--              S2-21: REVOKE FROM PUBLIC + GRANT TO neondb_owner
-- Rollback: See ROLLBACK section below

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_dashboard_procurement_supplier_risk(
  p_actor_id   BIGINT,
  p_window_days INTEGER DEFAULT 90
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  -- ── Input validation ─────────────────────────────────────────────────────
  IF p_actor_id IS NULL OR p_actor_id <= 0 THEN
    RAISE EXCEPTION 'fn_dashboard_procurement_supplier_risk: p_actor_id must be a positive integer'
      USING ERRCODE = '22023';
  END IF;

  IF p_window_days NOT BETWEEN 7 AND 365 THEN
    RAISE EXCEPTION 'fn_dashboard_procurement_supplier_risk: p_window_days must be BETWEEN 7 AND 365'
      USING ERRCODE = '22023';
  END IF;

  -- ── Permission gate ───────────────────────────────────────────────────────
  -- insights.procurement_supplier_risk OR insights.executive OR Super Admin/platform_admin bypass
  IF NOT (
    fn_current_user_has_permission('insights.procurement_supplier_risk')
    OR fn_current_user_has_permission('insights.executive')
    OR EXISTS (
      SELECT 1
      FROM "user" u
      JOIN role r ON r.id = u.role_id
      WHERE u.id = p_actor_id
        AND r.name IN ('Super Admin', 'platform_admin')
        AND u.is_active = TRUE
    )
  ) THEN
    RAISE EXCEPTION 'permission_denied: insights.procurement_supplier_risk required'
      USING ERRCODE = '42501';
  END IF;

  -- ── Main computation ──────────────────────────────────────────────────────
  WITH

  -- Per-party composite risk aggregation (design lock A4)
  -- AVG(latest_risk_score.health_score) over party's active contracts
  supplier_risk AS (
    SELECT
      p.id                                AS counterparty_id,
      p.name_en                           AS counterparty_name,
      p.party_type,
      p.sanctions_status,
      p.icv_status,
      p.icv_pct,
      p.icv_last_checked,
      AVG(lrs.health_score)::integer      AS composite_risk_score,
      AVG(lrs.dim_legal)::integer         AS dim_legal,
      AVG(lrs.dim_financial)::integer     AS dim_financial,
      AVG(lrs.dim_operational)::integer   AS dim_operational,
      AVG(lrs.dim_reputational)::integer  AS dim_reputational,
      AVG(lrs.dim_compliance)::integer    AS dim_compliance,
      COUNT(DISTINCT co.id)::integer      AS active_contract_count,
      COALESCE(SUM(co.value_aed), 0)      AS total_contract_value_aed,
      CASE
        WHEN AVG(lrs.health_score) < 50 THEN 'high'
        WHEN AVG(lrs.health_score) < 75 THEN 'medium'
        ELSE 'low'
      END                                 AS risk_tier
    FROM party p
    JOIN contract co
      ON co.counterparty_id = p.id
     AND co.is_active = TRUE
    LEFT JOIN latest_risk_score lrs
      ON lrs.contract_id = co.id
     AND lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    WHERE p.is_active = TRUE
    GROUP BY
      p.id, p.name_en, p.party_type, p.sanctions_status,
      p.icv_status, p.icv_pct, p.icv_last_checked
  ),

  -- SLA breach count per counterparty — fixed 180d window per brief
  supplier_breach_count AS (
    SELECT
      co.counterparty_id,
      COUNT(*) FILTER (
        WHERE os.signal_kind_subtype IN ('sla_breach', 'milestone_slippage')
      )::integer AS sla_breach_count_180d
    FROM correlation c
    JOIN osint_signal os ON os.id = c.signal_id
    JOIN contract co ON co.id = c.contract_id
    WHERE c.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND c.is_active = TRUE
      AND c.created_at >= NOW() - 180 * INTERVAL '1 day'
      AND os.kind = 'internal'
    GROUP BY co.counterparty_id
  ),

  -- Backup supplier suggestions (design lock A4b: party_type pivot)
  -- Top-5 distressed primaries × top-3 alternatives each (same party_type, clean, better health)
  backup_suggestions AS (
    SELECT
      primary_party.counterparty_id       AS primary_counterparty_id,
      primary_party.counterparty_name     AS primary_name,
      primary_party.composite_risk_score  AS primary_risk_score,
      primary_party.party_type            AS category,
      (
        SELECT jsonb_agg(jsonb_build_object(
          'counterpartyId',   alt.counterparty_id::text,
          'counterpartyName', alt.counterparty_name,
          'riskScore',        alt.composite_risk_score,
          'cleanStatus',      'clean'
        ) ORDER BY alt.composite_risk_score DESC)
        FROM (
          SELECT alt2.counterparty_id, alt2.counterparty_name, alt2.composite_risk_score
          FROM supplier_risk alt2
          WHERE alt2.party_type        = primary_party.party_type
            AND alt2.counterparty_id  <> primary_party.counterparty_id
            AND alt2.sanctions_status  = 'clean'
            AND (alt2.composite_risk_score IS NULL
                 OR primary_party.composite_risk_score IS NULL
                 OR alt2.composite_risk_score > primary_party.composite_risk_score)
          ORDER BY alt2.composite_risk_score DESC NULLS LAST
          LIMIT 3
        ) alt
      ) AS suggested_alternatives
    FROM supplier_risk primary_party
    ORDER BY primary_party.composite_risk_score ASC NULLS FIRST
    LIMIT 5
  ),

  -- ICV compliance tracker — parties with non-compliant ICV or below 60%
  icv_tracker AS (
    SELECT
      sr.counterparty_id,
      sr.counterparty_name,
      sr.icv_status,
      sr.icv_pct,
      sr.icv_last_checked,
      sr.active_contract_count,
      sr.total_contract_value_aed
    FROM supplier_risk sr
    WHERE sr.icv_status = 'non_compliant'
       OR sr.icv_pct < 60
    ORDER BY sr.icv_pct ASC NULLS FIRST
    LIMIT 15
  ),

  -- Vendor financial health signals (W2 LOCKED: kind='news', subtype IN financial_distress/downgrade/default)
  financial_health AS (
    SELECT
      co.counterparty_id,
      p.name_en                           AS counterparty_name,
      os.signal_kind_subtype              AS signal_kind,
      os.title                            AS signal_headline,
      os.fetched_at                       AS occurred_at,
      os.severity_v2                      AS severity,
      os.url                              AS source_ref
    FROM osint_signal os
    JOIN correlation c ON c.signal_id = os.id
    JOIN contract co   ON co.id = c.contract_id
    JOIN party p       ON p.id = co.counterparty_id
    WHERE os.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND os.kind = 'news'
      AND os.signal_kind_subtype IN ('financial_distress', 'downgrade', 'default')
      AND os.fetched_at >= NOW() - p_window_days * INTERVAL '1 day'
    ORDER BY os.fetched_at DESC
    LIMIT 8
  ),

  -- KPI current window
  kpi_current AS (
    SELECT
      (SELECT COUNT(*)           FROM supplier_risk)::integer                                                       AS total_supplier_count,
      (SELECT COUNT(DISTINCT counterparty_id) FROM supplier_breach_count WHERE sla_breach_count_180d > 0)::integer  AS supplier_breaches_count,
      (SELECT COUNT(*)           FROM supplier_risk WHERE icv_status = 'non_compliant' OR icv_pct < 60)::integer    AS icv_non_compliant_count,
      (SELECT COUNT(DISTINCT counterparty_id) FROM financial_health)::integer                                       AS supplier_financial_distress_count,
      (SELECT AVG(composite_risk_score)::numeric(5,2) FROM supplier_risk WHERE composite_risk_score IS NOT NULL)    AS avg_supplier_risk_score
  ),

  -- KPI previous window (same window_days, shifted back)
  kpi_prev_window AS (
    SELECT
      COUNT(DISTINCT p.id)::integer                                                              AS total_supplier_count,
      COUNT(DISTINCT CASE WHEN sla_hist.has_breach THEN co.counterparty_id END)::integer         AS supplier_breaches_count,
      COUNT(DISTINCT CASE WHEN p.icv_status = 'non_compliant' OR p.icv_pct < 60 THEN p.id END)::integer AS icv_non_compliant_count,
      COUNT(DISTINCT fin_prev.counterparty_id)::integer                                          AS supplier_financial_distress_count,
      AVG(lrs_prev.health_score)::numeric(5,2)                                                   AS avg_supplier_risk_score
    FROM party p
    JOIN contract co ON co.counterparty_id = p.id AND co.is_active = TRUE
    LEFT JOIN latest_risk_score lrs_prev
      ON lrs_prev.contract_id = co.id
     AND lrs_prev.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    LEFT JOIN LATERAL (
      SELECT TRUE AS has_breach
      FROM correlation c2
      JOIN osint_signal os2 ON os2.id = c2.signal_id
      WHERE c2.contract_id = co.id
        AND c2.tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND c2.is_active = TRUE
        AND c2.created_at BETWEEN NOW() - 2 * p_window_days * INTERVAL '1 day'
                               AND NOW() -     p_window_days * INTERVAL '1 day'
        AND os2.kind = 'internal'
        AND os2.signal_kind_subtype IN ('sla_breach', 'milestone_slippage')
      LIMIT 1
    ) sla_hist ON TRUE
    LEFT JOIN LATERAL (
      SELECT DISTINCT co2.counterparty_id
      FROM osint_signal os3
      JOIN correlation c3 ON c3.signal_id = os3.id
      JOIN contract co2   ON co2.id = c3.contract_id
      WHERE co2.counterparty_id = p.id
        AND os3.tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND os3.kind = 'news'
        AND os3.signal_kind_subtype IN ('financial_distress', 'downgrade', 'default')
        AND os3.fetched_at BETWEEN NOW() - 2 * p_window_days * INTERVAL '1 day'
                                AND NOW() -     p_window_days * INTERVAL '1 day'
      LIMIT 1
    ) fin_prev ON TRUE
    WHERE p.is_active = TRUE
  )

  SELECT jsonb_build_object(
    'windowDays',    p_window_days,
    'asOf',          NOW(),

    -- KPI current
    'kpi', (
      SELECT jsonb_build_object(
        'totalSupplierCount',             kc.total_supplier_count,
        'supplierBreachesCount',          kc.supplier_breaches_count,
        'icvNonCompliantCount',           kc.icv_non_compliant_count,
        'supplierFinancialDistressCount', kc.supplier_financial_distress_count,
        'avgSupplierRiskScore',           kc.avg_supplier_risk_score
      )
      FROM kpi_current kc
    ),

    -- KPI previous
    'kpiPrev', (
      SELECT jsonb_build_object(
        'totalSupplierCount',             kp.total_supplier_count,
        'supplierBreachesCount',          kp.supplier_breaches_count,
        'icvNonCompliantCount',           kp.icv_non_compliant_count,
        'supplierFinancialDistressCount', kp.supplier_financial_distress_count,
        'avgSupplierRiskScore',           kp.avg_supplier_risk_score
      )
      FROM kpi_prev_window kp
    ),

    -- Supplier risk scorecard — top 20 worst-first (ASC by compositeRiskScore)
    'supplierRiskScorecard', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'counterpartyId',        sr.counterparty_id::text,
        'counterpartyName',      sr.counterparty_name,
        'compositeRiskScore',    sr.composite_risk_score,
        'dimLegal',              sr.dim_legal,
        'dimFinancial',          sr.dim_financial,
        'dimOperational',        sr.dim_operational,
        'dimReputational',       sr.dim_reputational,
        'dimCompliance',         sr.dim_compliance,
        'slaBreachCount180d',    COALESCE(sbc.sla_breach_count_180d, 0),
        'activeContractCount',   sr.active_contract_count,
        'totalContractValueAed', sr.total_contract_value_aed::text,
        'riskTier',              sr.risk_tier
      ))
      FROM (
        SELECT sr2.*, ROW_NUMBER() OVER (ORDER BY sr2.composite_risk_score ASC NULLS FIRST) AS rn
        FROM supplier_risk sr2
        LIMIT 20
      ) sr
      LEFT JOIN supplier_breach_count sbc ON sbc.counterparty_id = sr.counterparty_id
    ), '[]'::jsonb),

    -- ICV compliance tracker — top 15 non-compliant
    'icvComplianceTracker', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'counterpartyId',       it.counterparty_id::text,
        'counterpartyName',     it.counterparty_name,
        'icvStatus',            it.icv_status,
        'icvPct',               it.icv_pct,
        'icvLastChecked',       it.icv_last_checked,
        'activeContractCount',  it.active_contract_count,
        'contractValueAed',     it.total_contract_value_aed::text
      ))
      FROM icv_tracker it
    ), '[]'::jsonb),

    -- Backup supplier suggestions — top 5 distressed × 3 alternatives
    'backupSupplierSuggestions', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'primaryCounterpartyId', bs.primary_counterparty_id::text,
        'primaryName',           bs.primary_name,
        'primaryRiskScore',      bs.primary_risk_score,
        'category',              bs.category,
        'suggestedAlternatives', COALESCE(bs.suggested_alternatives, '[]'::jsonb)
      ))
      FROM backup_suggestions bs
    ), '[]'::jsonb),

    -- Vendor financial health summary — top 8 news/financial-distress signals
    'vendorFinancialHealthSummary', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'counterpartyId',   fh.counterparty_id::text,
        'counterpartyName', fh.counterparty_name,
        'signalKind',       fh.signal_kind,
        'signalHeadline',   fh.signal_headline,
        'occurredAt',       fh.occurred_at,
        'severity',         fh.severity,
        'sourceRef',        fh.source_ref
      ))
      FROM financial_health fh
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;

EXCEPTION
  WHEN SQLSTATE '42501' THEN
    RAISE;
  WHEN SQLSTATE '22023' THEN
    RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_procurement_supplier_risk: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

-- S2-21 + S2-27 mandatory tail
COMMENT ON FUNCTION fn_dashboard_procurement_supplier_risk(bigint, integer)
  IS 'CR-G Procurement supplier-risk dashboard (no new role — contract_drafter/contract_approver/platform_admin/Super Admin). Returns kpi/kpiPrev/supplierRiskScorecard(top 20 worst-first)/icvComplianceTracker(M9 party.icv_* cols)/backupSupplierSuggestions(v1 heuristic: same party_type + clean sanctions + better health)/vendorFinancialHealthSummary(osint_signal kind=news subtype IN financial_distress/downgrade/default). Per-party composite_risk_score = AVG(latest_risk_score.health_score) over party contracts (design lock — see db-design.md §3.5). Permission gate: insights.procurement_supplier_risk OR insights.executive OR Super Admin/platform_admin. p_window_days BETWEEN 7 AND 365 default 90.';
REVOKE EXECUTE ON FUNCTION fn_dashboard_procurement_supplier_risk(bigint, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_procurement_supplier_risk(bigint, integer) TO neondb_owner;

-- Record this migration
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (186, '186_crg_fn_dashboard_procurement_supplier_risk', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- ROLLBACK (run manually if this migration must be reversed)
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 186;
-- DROP FUNCTION IF EXISTS fn_dashboard_procurement_supplier_risk(bigint, integer);
-- ============================================================
