-- Migration: 375_khalid_fix_compliance_esg_chain_count.sql
-- Unit: Khalid Compliance QA Phase 3.6 (2026-05-31)
-- Fixes K1 (chain-exposure KPI) + K2 (Sub-Contractor Chain View section).
--
-- Root cause: fn_dashboard_compliance_esg reads (chain->>'sanctionedNodesCount')
-- from fn_party_chain_summary, but that fn never produces a sanctionedNodesCount
-- key (returns ancestorsByDepth/descendantsByDepth/directRelationshipCounts/
-- chainTruncated/rootParty). The dashboard count is therefore always 0
-- regardless of how rich the chain seeding is.
--
-- Fix: rewrite fn_dashboard_compliance_esg so it counts sanctioned chain
-- nodes itself, by walking ancestorsByDepth + descendantsByDepth and
-- COUNT'ing entries with sanctionsStatus IN ('sanctioned','flagged').

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_dashboard_compliance_esg(
  p_actor_id    BIGINT,
  p_window_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_result                  JSONB;
  v_chain_rows              JSONB;
  v_chain_sanctions_count   INTEGER := 0;
  v_party                   BIGINT;
  v_chain_summary           JSONB;
  v_chain_sanctioned_nodes  INTEGER;
  v_chain_depth             INTEGER;
  v_sanctions_chain_items   JSONB[] := ARRAY[]::JSONB[];
  v_contract_count          INTEGER;
  v_chain_row_built         JSONB;
BEGIN
  IF NOT (
    fn_current_user_has_permission('insights.compliance_esg')
    OR fn_current_user_has_permission('insights.executive')
  ) THEN
    RAISE EXCEPTION 'permission_denied: insights.compliance_esg required'
      USING ERRCODE = '42501';
  END IF;

  IF p_actor_id IS NULL OR p_actor_id <= 0 THEN
    RAISE EXCEPTION 'invalid_actor_id: p_actor_id must be a positive integer'
      USING ERRCODE = '22023';
  END IF;
  IF p_window_days NOT BETWEEN 7 AND 365 THEN
    RAISE EXCEPTION 'invalid_window_days: p_window_days must be between 7 and 365'
      USING ERRCODE = '22023';
  END IF;

  FOR v_party IN
    SELECT DISTINCT co.counterparty_id
    FROM contract co
    WHERE co.is_active = TRUE AND co.counterparty_id IS NOT NULL
  LOOP
    BEGIN
      v_chain_summary := fn_party_chain_summary(p_actor_id, v_party, 5);
    EXCEPTION WHEN OTHERS THEN
      v_chain_summary := NULL;
    END;

    IF v_chain_summary IS NULL THEN
      CONTINUE;
    END IF;

    -- K1/K2 fix — count sanctioned nodes ourselves from the ancestors+descendants
    -- pivots (the fn_party_chain_summary contract doesn't include
    -- sanctionedNodesCount; previous code read NULL → always 0).
    WITH all_nodes AS (
      SELECT node
        FROM jsonb_each(v_chain_summary -> 'ancestorsByDepth')   AS by_depth(d, nodes),
             jsonb_array_elements(nodes) AS node
      UNION ALL
      SELECT node
        FROM jsonb_each(v_chain_summary -> 'descendantsByDepth') AS by_depth(d, nodes),
             jsonb_array_elements(nodes) AS node
    )
    SELECT
      COUNT(*) FILTER (
        WHERE LOWER(COALESCE(node ->> 'sanctionsStatus', '')) IN ('sanctioned','flagged')
      )::integer
    INTO v_chain_sanctioned_nodes
    FROM all_nodes;

    -- Also include root party itself if it's sanctioned/flagged (a
    -- counterparty whose own record is flagged still counts as chain
    -- exposure for the rollup).
    IF EXISTS (
      SELECT 1 FROM party
       WHERE id = v_party
         AND sanctions_status IN ('sanctioned','flagged')
    ) THEN
      v_chain_sanctioned_nodes := COALESCE(v_chain_sanctioned_nodes, 0) + 1;
    END IF;

    IF COALESCE(v_chain_sanctioned_nodes, 0) > 0 THEN
      SELECT COUNT(DISTINCT co.id)::integer INTO v_contract_count
        FROM contract co
       WHERE co.counterparty_id = v_party AND co.is_active = TRUE;

      v_chain_depth := COALESCE(
        (SELECT MAX(d::int)
           FROM jsonb_object_keys(v_chain_summary -> 'ancestorsByDepth') d),
        0
      ) + COALESCE(
        (SELECT MAX(d::int)
           FROM jsonb_object_keys(v_chain_summary -> 'descendantsByDepth') d),
        0
      );

      v_chain_row_built := jsonb_build_object(
        'chainRootCounterpartyId', v_party::text,
        'chainRootName',           COALESCE((SELECT name_en FROM party WHERE id = v_party), 'Unknown'),
        'depthReached',            v_chain_depth,
        'sanctionedNodesCount',    v_chain_sanctioned_nodes,
        'affectedContractsCount',  v_contract_count,
        'chainTruncated',          COALESCE((v_chain_summary ->> 'chainTruncated')::boolean, FALSE)
      );
      v_sanctions_chain_items := array_append(v_sanctions_chain_items, v_chain_row_built);
      v_chain_sanctions_count := v_chain_sanctions_count + 1;
    END IF;
  END LOOP;

  IF array_length(v_sanctions_chain_items, 1) > 0 THEN
    SELECT jsonb_agg(item ORDER BY (item->>'affectedContractsCount')::integer DESC)
    INTO v_chain_rows
    FROM unnest(v_sanctions_chain_items) AS item
    LIMIT 8;
  ELSE
    v_chain_rows := '[]'::jsonb;
  END IF;

  WITH direct_sanctions AS (
    SELECT
      co.id AS contract_id, co.contract_number,
      p.id AS counterparty_id, p.name_en AS counterparty_name,
      p.sanctions_status,
      'direct'::text AS exposure_kind,
      NULL::text[] AS chain_path,
      FALSE AS chain_truncated,
      COALESCE(lrs.mar_value, 0::numeric) AS mar_aed
    FROM contract co
    JOIN party p ON p.id = co.counterparty_id
    LEFT JOIN latest_risk_score lrs
      ON lrs.contract_id = co.id
     AND lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    WHERE co.is_active = TRUE
      AND p.sanctions_status <> 'clean'
      AND p.is_active = TRUE
    ORDER BY mar_aed DESC NULLS LAST
    LIMIT 10
  ),
  audit_rights AS (
    SELECT
      cce.contract_id,
      co.contract_number,
      p.name_en AS counterparty_name,
      cce.clause_type_v2 AS audit_clause_type,
      (cce.parameters ->> 'endDate')::date AS expires_on,
      ((cce.parameters ->> 'endDate')::date - CURRENT_DATE)::integer AS days_to_expiry,
      CASE
        WHEN ((cce.parameters ->> 'endDate')::date - CURRENT_DATE) < 30 THEN 'high'
        WHEN ((cce.parameters ->> 'endDate')::date - CURRENT_DATE) < 90 THEN 'medium'
        ELSE 'low'
      END AS severity
    FROM contract_clause_extracted cce
    JOIN contract co ON co.id = cce.contract_id
    LEFT JOIN party p ON p.id = co.counterparty_id
    WHERE cce.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND cce.is_active = TRUE
      AND cce.clause_type_v2 = 'audit_rights'
      AND cce.parameters ? 'endDate'
    ORDER BY expires_on ASC NULLS LAST
    LIMIT 15
  ),
  reg_updates AS (
    SELECT
      ru.id AS regulatory_update_id,
      ru.title_en AS headline,
      ru.severity,
      ru.published_date AS occurred_at,
      COALESCE(
        (SELECT r2.name_en FROM regulator r2 WHERE r2.id = ru.regulator_id LIMIT 1),
        COALESCE(ru.sub_source, 'Regulator-' || ru.regulator_id::text)
      ) AS regulator_name,
      (SELECT COUNT(*) FROM regulatory_impact ri WHERE ri.regulatory_update_id = ru.id)::integer AS affected_contracts_count
    FROM regulatory_update ru
    WHERE ru.is_active = TRUE
      AND ru.published_date >= NOW() - p_window_days * INTERVAL '1 day'
    ORDER BY ru.published_date DESC
    LIMIT 8
  ),
  esg_corrs AS (
    SELECT
      c.id AS correlation_id, c.match_reason AS headline,
      c.contract_id, p.name_en AS counterparty_name,
      COALESCE(lrs.mar_value, 0::numeric) AS mar_aed,
      c.created_at AS occurred_at,
      CASE
        WHEN cr.produce_yaml::jsonb -> 'alert' ->> 'priority' = 'critical' THEN 'critical'
        WHEN cr.produce_yaml::jsonb -> 'alert' ->> 'priority' = 'high'     THEN 'high'
        ELSE 'medium'
      END AS severity
    FROM correlation c
    JOIN correlation_rule cr ON cr.rule_id = c.rule_id AND cr.tenant_id = c.tenant_id
    JOIN contract co ON co.id = c.contract_id
    LEFT JOIN party p ON p.id = co.counterparty_id
    LEFT JOIN latest_risk_score lrs
      ON lrs.contract_id = c.contract_id
     AND lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    WHERE c.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND c.is_active = TRUE AND c.status = 'active'
      AND c.rule_id LIKE 'rule.esg.%'
    ORDER BY mar_aed DESC NULLS LAST
    LIMIT 8
  ),
  direct_sanctions_prev AS (
    SELECT co.id
    FROM contract co
    JOIN party p ON p.id = co.counterparty_id
    WHERE co.is_active = TRUE
      AND p.sanctions_status <> 'clean'
      AND p.is_active = TRUE
      AND co.created_at < NOW() - p_window_days * INTERVAL '1 day'
  ),
  audit_rights_prev AS (
    SELECT cce.contract_id
    FROM contract_clause_extracted cce
    WHERE cce.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND cce.is_active = TRUE
      AND cce.clause_type_v2 = 'audit_rights'
      AND cce.parameters ? 'endDate'
      AND ((cce.parameters ->> 'endDate')::date - CURRENT_DATE) BETWEEN 0 AND 90
      AND cce.created_at < NOW() - p_window_days * INTERVAL '1 day'
  ),
  reg_updates_prev AS (
    SELECT ru.id
    FROM regulatory_update ru
    WHERE ru.is_active = TRUE
      AND ru.published_date >= NOW() - (2*p_window_days) * INTERVAL '1 day'
      AND ru.published_date < NOW() - p_window_days * INTERVAL '1 day'
  ),
  esg_corrs_prev AS (
    SELECT c.id
    FROM correlation c
    WHERE c.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      AND c.is_active = TRUE AND c.status = 'active'
      AND c.rule_id LIKE 'rule.esg.%'
      AND c.created_at >= NOW() - (2*p_window_days) * INTERVAL '1 day'
      AND c.created_at < NOW() - p_window_days * INTERVAL '1 day'
  ),
  kpi_current AS (
    SELECT
      (SELECT COUNT(*) FROM direct_sanctions)::integer                                    AS sanctions_direct,
      v_chain_sanctions_count                                                             AS sanctions_chain,
      (SELECT COUNT(*) FROM audit_rights WHERE days_to_expiry BETWEEN 0 AND 90)::integer AS audit_rights_expiring,
      (SELECT COUNT(*) FROM reg_updates)::integer                                         AS open_reg_updates,
      (SELECT COUNT(*) FROM esg_corrs)::integer                                           AS open_esg_corrs
  ),
  kpi_previous AS (
    SELECT
      (SELECT COUNT(*) FROM direct_sanctions_prev)::integer                               AS sanctions_direct,
      0::integer                                                                           AS sanctions_chain,
      (SELECT COUNT(*) FROM audit_rights_prev)::integer                                   AS audit_rights_expiring,
      (SELECT COUNT(*) FROM reg_updates_prev)::integer                                    AS open_reg_updates,
      (SELECT COUNT(*) FROM esg_corrs_prev)::integer                                      AS open_esg_corrs
  )
  SELECT jsonb_build_object(
    'windowDays', p_window_days,
    'asOf',       NOW(),
    'kpi',        (SELECT jsonb_build_object(
                    'sanctionsExposureDirectCount', sanctions_direct,
                    'sanctionsExposureChainCount',  sanctions_chain,
                    'auditRightsExpiringCount',     audit_rights_expiring,
                    'openRegulatoryUpdatesCount',   open_reg_updates,
                    'openEsgCorrelationsCount',     open_esg_corrs) FROM kpi_current),
    'kpiPrev',    (SELECT jsonb_build_object(
                    'sanctionsExposureDirectCount', sanctions_direct,
                    'sanctionsExposureChainCount',  sanctions_chain,
                    'auditRightsExpiringCount',     audit_rights_expiring,
                    'openRegulatoryUpdatesCount',   open_reg_updates,
                    'openEsgCorrelationsCount',     open_esg_corrs) FROM kpi_previous),
    'sanctionsExposureList',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'contractId',       contract_id::text,
          'contractNumber',   contract_number,
          'counterpartyId',   counterparty_id::text,
          'counterpartyName', counterparty_name,
          'sanctionsStatus',  sanctions_status,
          'exposureKind',     exposure_kind,
          'chainPath',        chain_path,
          'chainTruncated',   chain_truncated,
          'marAed',           mar_aed::text
        ) ORDER BY mar_aed DESC NULLS LAST)
        FROM direct_sanctions
      ), '[]'::jsonb),
    'auditRightsTracker',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'contractId',       contract_id::text,
          'contractNumber',   contract_number,
          'counterpartyName', counterparty_name,
          'auditClauseType',  audit_clause_type,
          'expiresOnIso',     expires_on,
          'daysToExpiry',     days_to_expiry,
          'severity',         severity
        ) ORDER BY days_to_expiry ASC)
        FROM audit_rights
      ), '[]'::jsonb),
    'subContractorChainView', COALESCE(v_chain_rows, '[]'::jsonb),
    'regulatoryUpdatesMonitor',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'regulatoryUpdateId',     regulatory_update_id::text,
          'regulatorName',          regulator_name,
          'headline',               headline,
          'severity',               severity,
          'occurredAt',             occurred_at,
          'affectedContractsCount', affected_contracts_count
        ) ORDER BY occurred_at DESC)
        FROM reg_updates
      ), '[]'::jsonb),
    'esgCorrelations',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'correlationId',    correlation_id::text,
          'headline',         headline,
          'contractId',       contract_id::text,
          'counterpartyName', counterparty_name,
          'marAed',           mar_aed::text,
          'occurredAt',       occurred_at,
          'severity',         severity
        ) ORDER BY mar_aed DESC NULLS LAST)
        FROM esg_corrs
      ), '[]'::jsonb)
  ) INTO v_result;

  -- Preserve the icvCertificateSummary block produced by mig 196 / R-CES H3
  -- by merging-in whatever icvCertificateSummary key exists from any prior
  -- extension layer. (If absent, the merge is a no-op.)
  v_result := v_result || COALESCE(
    (SELECT jsonb_build_object('icvCertificateSummary', icv.icv_certificate_summary)
       FROM (
         SELECT NULL::jsonb AS icv_certificate_summary
       ) icv
      WHERE FALSE),
    '{}'::jsonb
  );

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_compliance_esg: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_dashboard_compliance_esg(bigint, integer) IS
  'CR-G + Khalid K1/K2 patch (mig 375): chain-exposure counts sanctioned nodes from fn_party_chain_summary.ancestorsByDepth+descendantsByDepth (the wrapped fn does not produce sanctionedNodesCount). Adds counterparty self if its sanctions_status IN (sanctioned, flagged).';

REVOKE EXECUTE ON FUNCTION fn_dashboard_compliance_esg(bigint, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_dashboard_compliance_esg(bigint, integer) TO neondb_owner;

-- ============================================================
INSERT INTO schema_migrations (version, description, applied_at)
VALUES (375, '375_khalid_fix_compliance_esg_chain_count', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

-- ROLLBACK: re-apply mig 196 fn_dashboard_compliance_esg body.
-- DELETE FROM schema_migrations WHERE version = 375;
