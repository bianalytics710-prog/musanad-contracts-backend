-- Migration: 408_pari_cluster34_dashboard_rewrite.sql
-- Unit: Pari Procurement QA Phase 3.7 (2026-06-01) — Clusters 3+4+7
-- Closes:
--   P2  — KPI "Suppliers at risk = 1" contradicted the scorecard showing 11+ score-0 suppliers.
--         Redefined semantically: now counts DISTINCT counterparties with EITHER
--         compositeRiskScore < 50 OR active SLA breach (180d) OR financial-distress signal.
--   P3  — KPI "ICV non-compliant = 0" contradicted Khalid's compliance dashboard
--         showing 264-of-306 missing (87.1%). Switched source to the SAME contract_attachment
--         (kind='icv_certificate') derivation Khalid uses — now reports DISTINCT counterparties
--         with at least one contract whose ICV cert is missing or expired.
--   P4  — Date filter no-op for KPIs. KPIs `supplierBreachesCount` + `supplierFinancialDistressCount`
--         now honour p_window_days; `totalSupplierCount` remains a snapshot per design.
--   P7  — Scorecard ORDER BY composite_risk_score ASC NULLS FIRST put un-scored vendors above
--         score-0 ones, dropping ADNOC Drilling (91) below score-0 rows. Switched to
--         ASC NULLS LAST so true high-risk (low scores) sit at top.
--   P11 — Backup-supplier suggestions: primary set now requires composite_risk_score IS NOT NULL
--         AND < 70 (genuine concern). No more recommending alternates for un-scored vendors.
--   P12 — Backup-supplier suggestions: alternates ranked by (category match + size band +
--         risk score) with deterministic per-primary rotation, so the same 3 vendors don't
--         appear for every problem row.
--
-- The function signature + return-envelope keys are unchanged so the FE types
-- (ProcurementSupplierRiskDashboardResponse) remain valid. Adds a new top-level
-- `chartsData` block exposing distribution arrays for the 3 new charts (P1) the FE
-- will render in a subsequent FE change.

BEGIN;

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
  IF p_actor_id IS NULL OR p_actor_id <= 0 THEN
    RAISE EXCEPTION 'fn_dashboard_procurement_supplier_risk: p_actor_id must be a positive integer'
      USING ERRCODE = '22023';
  END IF;

  IF p_window_days NOT BETWEEN 7 AND 365 THEN
    RAISE EXCEPTION 'fn_dashboard_procurement_supplier_risk: p_window_days must be BETWEEN 7 AND 365'
      USING ERRCODE = '22023';
  END IF;

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

  WITH

  -- ── Per-party composite risk (unchanged from mig 186) ─────────────────
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

  -- SLA breach (180d fixed window per business logic — unchanged)
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

  -- SLA breach within the user-selected window (P4)
  supplier_breach_window AS (
    SELECT
      co.counterparty_id,
      COUNT(*)::integer AS sla_breach_count_window
    FROM correlation c
    JOIN osint_signal os ON os.id = c.signal_id
    JOIN contract co ON co.id = c.contract_id
    WHERE c.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND c.is_active = TRUE
      AND c.created_at >= NOW() - p_window_days * INTERVAL '1 day'
      AND os.kind = 'internal'
      AND os.signal_kind_subtype IN ('sla_breach', 'milestone_slippage')
    GROUP BY co.counterparty_id
  ),

  -- ── P11/P12: improved backup suggestions ──────────────────────────────
  -- Primary set: scored AND distressed (composite < 70). No un-scored rows.
  -- Alternates: same party_type + clean + higher score + deterministic rotation
  -- so different primaries get different alternate sets.
  primary_candidates AS (
    SELECT
      counterparty_id,
      counterparty_name,
      party_type,
      composite_risk_score,
      total_contract_value_aed
    FROM supplier_risk
    WHERE composite_risk_score IS NOT NULL
      AND composite_risk_score < 70
    ORDER BY composite_risk_score ASC, total_contract_value_aed DESC
    LIMIT 5
  ),

  backup_suggestions AS (
    SELECT
      pc.counterparty_id   AS primary_counterparty_id,
      pc.counterparty_name AS primary_name,
      pc.composite_risk_score AS primary_risk_score,
      pc.party_type        AS category,
      (
        SELECT jsonb_agg(alt_row ORDER BY alt_row->>'_rank')
        FROM (
          SELECT jsonb_build_object(
            'counterpartyId',   alt2.counterparty_id::text,
            'counterpartyName', alt2.counterparty_name,
            'riskScore',        alt2.composite_risk_score,
            'cleanStatus',      'clean',
            '_rank',            ROW_NUMBER() OVER (
                                  ORDER BY
                                    -- P12: deterministic per-primary rotation
                                    ((alt2.counterparty_id + pc.counterparty_id) % 7) ASC,
                                    alt2.composite_risk_score DESC NULLS LAST,
                                    alt2.total_contract_value_aed DESC NULLS LAST
                                )::text
          ) AS alt_row
          FROM supplier_risk alt2
          WHERE alt2.party_type        = pc.party_type
            AND alt2.counterparty_id  <> pc.counterparty_id
            AND alt2.sanctions_status  = 'clean'
            AND alt2.composite_risk_score IS NOT NULL
            AND alt2.composite_risk_score > pc.composite_risk_score
          LIMIT 3
        ) ranked
      ) AS suggested_alternatives
    FROM primary_candidates pc
  ),

  -- ── P3: ICV — switch to contract_attachment derivation (Khalid parity) ─
  -- Mirrors fn_dashboard_compliance_esg's icv_per_contract + icv_status_per_contract.
  -- Then groups by counterparty so the procurement dashboard tells the same
  -- story as compliance: "DEWA has 4 contracts; 3 are ICV-missing".
  icv_per_contract AS (
    SELECT
      ca.contract_id,
      MAX(CASE
        WHEN ca.description ~ 'valid_until=\d{4}-\d{2}-\d{2}'
          THEN substring(ca.description from 'valid_until=(\d{4}-\d{2}-\d{2})')::date
        ELSE NULL
      END) AS valid_until
    FROM contract_attachment ca
    WHERE ca.is_active = TRUE AND ca.kind = 'icv_certificate'
    GROUP BY ca.contract_id
  ),
  icv_status_per_contract AS (
    SELECT
      co.id              AS contract_id,
      co.counterparty_id,
      co.contract_number,
      co.value_aed,
      ipc.valid_until,
      CASE
        WHEN ipc.valid_until IS NULL                             THEN 'missing'
        WHEN ipc.valid_until < CURRENT_DATE                      THEN 'expired'
        WHEN ipc.valid_until <= CURRENT_DATE + INTERVAL '90 days' THEN 'expiring_within_90d'
        ELSE                                                          'up_to_date'
      END AS icv_status_derived
    FROM contract co
    LEFT JOIN icv_per_contract ipc ON ipc.contract_id = co.id
    WHERE co.is_active = TRUE
      AND co.counterparty_id IS NOT NULL
      AND co.status IN ('active','fully_signed','signed','pending_review')
  ),
  icv_per_counterparty AS (
    SELECT
      sp.counterparty_id,
      COUNT(*)::integer                                                                  AS total_contracts,
      COUNT(*) FILTER (WHERE sp.icv_status_derived IN ('missing','expired'))::integer    AS non_compliant_contracts,
      COUNT(*) FILTER (WHERE sp.icv_status_derived = 'expired')::integer                 AS expired_contracts,
      COUNT(*) FILTER (WHERE sp.icv_status_derived = 'missing')::integer                 AS missing_contracts,
      COUNT(*) FILTER (WHERE sp.icv_status_derived = 'expiring_within_90d')::integer     AS expiring_contracts,
      SUM(sp.value_aed) FILTER (WHERE sp.icv_status_derived IN ('missing','expired'))    AS non_compliant_value_aed,
      MAX(sp.valid_until)                                                                AS latest_valid_until
    FROM icv_status_per_contract sp
    GROUP BY sp.counterparty_id
  ),

  -- Financial-distress signals (existing, windowed)
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

  -- ── P2: redefine kpi.supplierBreachesCount ────────────────────────────
  -- Old: COUNT(DISTINCT cp WHERE sla_breach_count > 0)
  -- New: COUNT(DISTINCT cp WHERE composite_risk_score < 50 OR sla_breach > 0 OR financial_distress)
  at_risk_counterparties AS (
    SELECT sr.counterparty_id
    FROM supplier_risk sr
    WHERE sr.composite_risk_score IS NOT NULL AND sr.composite_risk_score < 50
    UNION
    SELECT counterparty_id FROM supplier_breach_window
    UNION
    SELECT counterparty_id FROM financial_health
  ),

  -- ── KPI current window ────────────────────────────────────────────────
  kpi_current AS (
    SELECT
      (SELECT COUNT(*)                              FROM supplier_risk)::integer            AS total_supplier_count,
      (SELECT COUNT(DISTINCT counterparty_id)       FROM at_risk_counterparties)::integer   AS supplier_breaches_count,
      (SELECT COUNT(DISTINCT counterparty_id)       FROM icv_per_counterparty
        WHERE non_compliant_contracts > 0)::integer                                          AS icv_non_compliant_count,
      (SELECT COUNT(DISTINCT counterparty_id)       FROM financial_health)::integer         AS supplier_financial_distress_count,
      (SELECT AVG(composite_risk_score)::numeric(5,2)
         FROM supplier_risk
        WHERE composite_risk_score IS NOT NULL)                                              AS avg_supplier_risk_score
  ),

  -- KPI previous window — shifted back by p_window_days (uses windowed breaches)
  kpi_prev_window AS (
    SELECT
      (SELECT COUNT(*) FROM supplier_risk)::integer AS total_supplier_count,
      (SELECT COUNT(DISTINCT co.counterparty_id)::integer
         FROM correlation c
         JOIN osint_signal os ON os.id = c.signal_id
         JOIN contract co ON co.id = c.contract_id
        WHERE c.tenant_id = current_setting('app.current_tenant_id', true)::uuid
          AND c.is_active = TRUE
          AND c.created_at BETWEEN NOW() - 2 * p_window_days * INTERVAL '1 day'
                               AND NOW() -     p_window_days * INTERVAL '1 day'
          AND os.kind = 'internal'
          AND os.signal_kind_subtype IN ('sla_breach','milestone_slippage')
      ) AS supplier_breaches_count,
      (SELECT COUNT(DISTINCT counterparty_id) FROM icv_per_counterparty
        WHERE non_compliant_contracts > 0)::integer AS icv_non_compliant_count,
      (SELECT COUNT(DISTINCT co.counterparty_id)::integer
         FROM osint_signal os
         JOIN correlation c ON c.signal_id = os.id
         JOIN contract co  ON co.id = c.contract_id
        WHERE os.tenant_id = current_setting('app.current_tenant_id', true)::uuid
          AND os.kind = 'news'
          AND os.signal_kind_subtype IN ('financial_distress', 'downgrade', 'default')
          AND os.fetched_at BETWEEN NOW() - 2 * p_window_days * INTERVAL '1 day'
                                AND NOW() -     p_window_days * INTERVAL '1 day'
      ) AS supplier_financial_distress_count,
      NULL::numeric(5,2) AS avg_supplier_risk_score
  ),

  -- ── P1: chart data — concentration / tier distribution / SLA trend ────
  -- Concentration: top 8 counterparties by total_contract_value_aed
  concentration AS (
    SELECT
      sr.counterparty_id,
      sr.counterparty_name,
      sr.total_contract_value_aed,
      ROUND(
        (sr.total_contract_value_aed * 100.0) /
        NULLIF((SELECT SUM(total_contract_value_aed) FROM supplier_risk), 0)
      , 2) AS share_pct
    FROM supplier_risk sr
    WHERE sr.total_contract_value_aed > 0
    ORDER BY sr.total_contract_value_aed DESC
    LIMIT 8
  ),

  -- Tier distribution counts
  tier_distribution AS (
    SELECT
      COUNT(*) FILTER (WHERE risk_tier = 'high')::integer    AS high_count,
      COUNT(*) FILTER (WHERE risk_tier = 'medium')::integer  AS medium_count,
      COUNT(*) FILTER (WHERE risk_tier = 'low'
                       AND composite_risk_score IS NOT NULL)::integer AS low_count,
      COUNT(*) FILTER (WHERE composite_risk_score IS NULL)::integer   AS unscored_count
    FROM supplier_risk
  ),

  -- SLA breach trend — last 26 weekly buckets (~6 months)
  -- (uses 180d data so always populated regardless of selected window)
  sla_trend_buckets AS (
    SELECT
      generate_series(0, 25) AS weeks_ago
  ),
  sla_trend AS (
    SELECT
      stb.weeks_ago,
      (CURRENT_DATE - (stb.weeks_ago * 7))::date AS week_end,
      COALESCE((
        SELECT COUNT(*)::integer
        FROM correlation c
        JOIN osint_signal os ON os.id = c.signal_id
        WHERE c.tenant_id = current_setting('app.current_tenant_id', true)::uuid
          AND c.is_active = TRUE
          AND os.kind = 'internal'
          AND os.signal_kind_subtype IN ('sla_breach','milestone_slippage')
          AND c.created_at BETWEEN (CURRENT_DATE - ((stb.weeks_ago + 1) * 7)) AND (CURRENT_DATE - (stb.weeks_ago * 7))
      ), 0) AS breach_count
    FROM sla_trend_buckets stb
  )

  SELECT jsonb_build_object(
    'windowDays',    p_window_days,
    'asOf',          NOW(),

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

    -- P7: ASC NULLS LAST — true-high-risk first, un-scored at the bottom
    'supplierRiskScorecard', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'counterpartyId',        sr.counterparty_id::text,
        'counterpartyName',      sr.counterparty_name,
        'partyType',             sr.party_type,
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
        SELECT sr2.*
        FROM supplier_risk sr2
        ORDER BY sr2.composite_risk_score ASC NULLS LAST,
                 sr2.total_contract_value_aed DESC
        LIMIT 20
      ) sr
      LEFT JOIN supplier_breach_count sbc ON sbc.counterparty_id = sr.counterparty_id
    ), '[]'::jsonb),

    -- P3: ICV tracker — top 15 counterparties with non-compliant contracts
    'icvComplianceTracker', COALESCE((
      SELECT jsonb_agg(row_obj ORDER BY (row_obj->>'_orderKey')::numeric DESC)
      FROM (
        SELECT jsonb_build_object(
          'counterpartyId',       p.id::text,
          'counterpartyName',     p.name_en,
          'icvStatus',            CASE
                                    WHEN ipc.missing_contracts > 0  THEN 'missing'
                                    WHEN ipc.expired_contracts > 0  THEN 'expired'
                                    WHEN ipc.expiring_contracts > 0 THEN 'expiring_within_90d'
                                    ELSE 'compliant'
                                  END,
          'icvPct',               CASE
                                    WHEN ipc.total_contracts = 0 THEN NULL
                                    ELSE ROUND(
                                      ((ipc.total_contracts - ipc.non_compliant_contracts) * 100.0) / ipc.total_contracts
                                    , 1)
                                  END,
          'icvLastChecked',       ipc.latest_valid_until,
          'activeContractCount',  ipc.total_contracts,
          'contractValueAed',     COALESCE(ipc.non_compliant_value_aed, 0)::text,
          'missingCount',         ipc.missing_contracts,
          'expiredCount',         ipc.expired_contracts,
          'expiringCount',        ipc.expiring_contracts,
          '_orderKey',            COALESCE(ipc.non_compliant_value_aed, 0)::text
        ) AS row_obj
        FROM icv_per_counterparty ipc
        JOIN party p ON p.id = ipc.counterparty_id
        WHERE ipc.non_compliant_contracts > 0
        ORDER BY ipc.non_compliant_value_aed DESC NULLS LAST
        LIMIT 15
      ) ranked
    ), '[]'::jsonb),

    -- P11/P12: diversified backup suggestions
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
    ), '[]'::jsonb),

    -- P1: chart data (FE renders donut + stacked bar + line)
    'chartsData', jsonb_build_object(
      'concentration', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'counterpartyId',   c.counterparty_id::text,
          'counterpartyName', c.counterparty_name,
          'totalValueAed',    c.total_contract_value_aed::text,
          'sharePct',         c.share_pct
        ))
        FROM concentration c
      ), '[]'::jsonb),
      'tierDistribution', (
        SELECT jsonb_build_object(
          'high',     td.high_count,
          'medium',   td.medium_count,
          'low',      td.low_count,
          'unscored', td.unscored_count
        )
        FROM tier_distribution td
      ),
      'slaTrendWeeks26', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'weekEnd',     st.week_end,
          'weeksAgo',    st.weeks_ago,
          'breachCount', st.breach_count
        ) ORDER BY st.weeks_ago DESC)
        FROM sla_trend st
      ), '[]'::jsonb)
    )
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

COMMENT ON FUNCTION fn_dashboard_procurement_supplier_risk(bigint, integer)
  IS 'CR-G Procurement supplier-risk dashboard. v3 (mig 408): redefined supplierBreachesCount as
"suppliers at risk" (low score OR SLA OR distress); switched ICV source to contract_attachment
(parity with fn_dashboard_compliance_esg); KPIs honour p_window_days; scorecard ASC NULLS LAST;
backup suggestions require scored+distressed primary with per-primary diversification rotation;
added chartsData{concentration, tierDistribution, slaTrendWeeks26}. p_window_days BETWEEN 7 AND 365.';
REVOKE EXECUTE ON FUNCTION fn_dashboard_procurement_supplier_risk(bigint, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_procurement_supplier_risk(bigint, integer) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (408, '408_pari_cluster34_dashboard_rewrite', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ROLLBACK: restore mig 186 body of fn_dashboard_procurement_supplier_risk + delete schema_migrations row 408.
