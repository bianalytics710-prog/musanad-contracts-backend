-- MIGRATION: 561_risk_classifier_4tier_and_score_sync.sql
-- Date: 2026-06-05
-- Description:
--   Two related changes that together drive the executive "High-risk
--   contracts" card from "4 of 8 = Other" to 0 unexplained pills.
--
--   1. DATA SYNC. Re-derive contract.ai_risk_score from the latest
--      risk_score.health_score row per contract. Rationale: probing
--      surfaced one contract (OQOOD-2026-001, id=5) whose contract row
--      still carried a stale 63 from a March 2026 manual override,
--      even though the most recent compute zeroed it. Stale scores
--      bubble bogus contracts onto executive-facing lists. One UPDATE
--      across the whole table re-aligns the cached column.
--
--   2. CLASSIFIER UPGRADE. The current fn_classify_risk only inspects
--      (a) free-text titles, (b) signal subtypes, (c) case_type/role.
--      But for many contracts the actual derivation evidence lives in
--      risk_score.contributing_correlations — a JSONB array of rule
--      hits like rule.sla.day_rate_breach, rule.hormuz.charter_party_*,
--      rule.brent.* — that the classifier was blind to.
--
--      Fix:
--        a. Extend the FM rule on fn_classify_risk to catch "cyclone
--           watch" / "cyclone advisory" / "weather watch" titles
--           (covers risk_case rows surfaced by the correlation engine
--           that weren't previously classifiable).
--        b. Add a sibling fn fn_classify_risk_by_rule(rule_id) that
--           maps rule.<topic>.* prefixes onto the same 12-type
--           taxonomy. No new master types — just a third entry point
--           into the existing taxonomy.
--        c. Rewrite fn_dashboard_executive_high_risk_extended to walk
--           a 4-tier fallback:
--             T1  classified open risk_case (≠ 'other')
--             T2  top rule in latest risk_score.contributing_correlations
--                 (by marContribution) → fn_classify_risk_by_rule
--             T3  most-severe linked osint_signal → fn_classify_risk
--             T4  'other'
--
--      Net effect on the live dashboard: every contract with score > 0
--      gets a non-"other" classification because every score > 0
--      necessarily has at least one rule correlation that drove it.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────
-- 1. Data sync: refresh stale contract.ai_risk_score from risk_score
-- ─────────────────────────────────────────────────────────────────────

UPDATE contract c
SET ai_risk_score = latest.health_score,
    updated_at    = NOW()
FROM (
  SELECT DISTINCT ON (contract_id)
    contract_id,
    health_score
  FROM risk_score
  ORDER BY contract_id, calculated_at DESC
) latest
WHERE c.id = latest.contract_id
  AND c.ai_risk_score IS DISTINCT FROM latest.health_score;

-- ─────────────────────────────────────────────────────────────────────
-- 2a. Extend fn_classify_risk FM rule with cyclone-watch patterns
-- ─────────────────────────────────────────────────────────────────────
-- Body byte-for-byte identical to migration 544 except for the
-- expanded FM title regex (line 73). The function signature stays the
-- same (8 args). All existing callers (fn_dashboard_executive_critical_impacts,
-- fn_risk_case_list, fn_risk_case_get_by_id, fn_dashboard_executive_high_risk_extended)
-- continue to work unchanged.

CREATE OR REPLACE FUNCTION public.fn_classify_risk(
  p_category           text,
  p_kind               text,
  p_subtype            text,
  p_source             text,
  p_clause_categories  text[],
  p_title              text,
  p_assigned_role      text,
  p_case_type          text
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  t  TEXT := COALESCE(p_title, '');
  cc TEXT[] := COALESCE(p_clause_categories, ARRAY[]::text[]);
BEGIN
  -- 1. Force Majeure Event  (extended 2026-06-05 — adds cyclone watch /
  --    advisory / weather watch patterns to catch correlation_alert
  --    cases like "NCM cyclone watch — sustained-window not yet confirmed"
  --    that fn_classify_risk previously dropped into "other".)
  IF 'force_majeure' = ANY(cc)
     OR p_subtype IN ('cyclone_warning','cyclone_advisory','ics_incident','routing_disruption','scenario_trigger')
     OR p_kind = 'weather'
     OR t ~* '\m(force majeure|fm clause|hormuz routing|hormuz.*fm|cyclone (watch|warning|advisory|forecast)|tropical cyclone|weather watch)\M' THEN
    RETURN 'force_majeure';
  END IF;

  -- 2. Sanctions Exposure
  IF t ~* '\m(ofac|sanction|sanctions)\M'
     OR p_subtype ILIKE '%sanction%' THEN
    RETURN 'sanctions';
  END IF;

  -- 3. ICV / Local Content Gap
  IF t ~* '\m(icv|in-country value|local content)\M' THEN
    RETURN 'icv_local_content';
  END IF;

  -- 4. ESG / Sustainability Risk
  IF (p_assigned_role = 'compliance_esg'
        AND t ~* '\m(esg|water[- ]stress|emissions|sustainab|environmental)\M')
     OR t ~* '\m(esg concern memo|sustainability)\M' THEN
    RETURN 'esg_sustainability';
  END IF;

  -- 5. Budget Overrun
  IF t ~* '\m(budget breach|budget overrun|over budget|projected.{0,40}year[- ]end)\M' THEN
    RETURN 'budget_overrun';
  END IF;

  -- 6. Counterparty Concentration
  IF t ~* '\m(concentration|single[- ]contract.{0,30}exposure|exposure[^a-z0-9]{0,5}>\s*\d{1,2}\s*%)\M' THEN
    RETURN 'counterparty_concentration';
  END IF;

  -- 7. Approval / Workflow Risk
  IF (p_case_type = 'sla_breach' AND p_assigned_role = 'contract_approver')
     OR t ~* '\m(approval cycle|approver assignment|stage[- ]?\d.{0,30}assignment)\M' THEN
    RETURN 'approval_workflow';
  END IF;

  -- 8. SLA / Performance Breach
  IF p_case_type = 'sla_breach'
     OR p_subtype IN ('sla_breach','milestone_slippage')
     OR t ~* '\m(milestone slippage|uptime miss|demurrage|day[- ]rate|ceiling exceeded|scorecard refresh stalled|uptime)\M' THEN
    RETURN 'sla_breach';
  END IF;

  -- 9. Vendor / Supplier Risk
  IF (p_assigned_role = 'procurement_supplier_risk'
        AND t ~* '\m(scorecard|credit.{0,15}downgrade|sub[- ]tier|supplier|vendor)\M')
     OR p_subtype = 'vendor_incident' THEN
    RETURN 'vendor_supplier';
  END IF;

  -- 10. Commodity / Price Risk
  IF p_category = 'commodity_prices'
     OR p_source IN ('commodity_feed','fx_feed','commodity_crude','fx_usd_aed')
     OR t ~* '\m(crude.{0,20}band|price review trigger|brent.{0,20}band)\M' THEN
    RETURN 'commodity_price';
  END IF;

  -- 11. Regulatory Change
  IF p_category = 'regulatory'
     OR p_source IN ('mohre_labor','ncm_uae')
     OR t ~* '\m(decree[- ]law|federal decree|regulator|schedule annex refresh)\M' THEN
    RETURN 'regulatory_change';
  END IF;

  -- 12. Geopolitical Risk
  IF p_category = 'geopolitical' THEN
    RETURN 'geopolitical';
  END IF;

  RETURN 'other';
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────
-- 2b. New helper fn_classify_risk_by_rule(rule_id)
-- ─────────────────────────────────────────────────────────────────────
-- Maps rule.<topic>.* prefix patterns onto the same 12-type taxonomy
-- used elsewhere. Prefixes are chosen from the actual rule_id values
-- observed in risk_score.contributing_correlations: rule.sla.*,
-- rule.epc.*, rule.brent.*, rule.murban.*, rule.commodity.*,
-- rule.hormuz.*, rule.weather.*, rule.cyclone.*, rule.regulatory.*,
-- rule.mohre.*, rule.sanctions.*, rule.ofac.*, rule.budget.*,
-- rule.icv.*, rule.esg.*, rule.vendor.*, rule.supplier.*,
-- rule.counterparty.*, rule.concentration.*, rule.approval.*,
-- rule.workflow.*, rule.geopolitical.*. Anything else falls through
-- to 'other' (and the side-car drops to Tier 3 / osint_signal).

CREATE OR REPLACE FUNCTION public.fn_classify_risk_by_rule(
  p_rule_id text
) RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  r TEXT := LOWER(COALESCE(p_rule_id, ''));
BEGIN
  IF r = '' THEN RETURN 'other'; END IF;

  IF r LIKE 'rule.fm.%'
     OR r LIKE 'rule.hormuz.%'
     OR r LIKE 'rule.weather.%'
     OR r LIKE 'rule.cyclone.%' THEN
    RETURN 'force_majeure';
  END IF;

  IF r LIKE 'rule.sanctions.%' OR r LIKE 'rule.ofac.%' THEN
    RETURN 'sanctions';
  END IF;

  IF r LIKE 'rule.icv.%' OR r LIKE 'rule.local_content.%' THEN
    RETURN 'icv_local_content';
  END IF;

  IF r LIKE 'rule.esg.%' OR r LIKE 'rule.sustainability.%' THEN
    RETURN 'esg_sustainability';
  END IF;

  IF r LIKE 'rule.budget.%' THEN
    RETURN 'budget_overrun';
  END IF;

  IF r LIKE 'rule.counterparty.%' OR r LIKE 'rule.concentration.%' THEN
    RETURN 'counterparty_concentration';
  END IF;

  IF r LIKE 'rule.approval.%' OR r LIKE 'rule.workflow.%' THEN
    RETURN 'approval_workflow';
  END IF;

  -- SLA / EPC / cure_notice patterns are operational SLA-class
  IF r LIKE 'rule.sla.%'
     OR r LIKE 'rule.epc.%'
     OR r LIKE 'rule.cure_notice.%'
     OR r LIKE 'rule.milestone.%' THEN
    RETURN 'sla_breach';
  END IF;

  IF r LIKE 'rule.vendor.%' OR r LIKE 'rule.supplier.%' THEN
    RETURN 'vendor_supplier';
  END IF;

  IF r LIKE 'rule.brent.%'
     OR r LIKE 'rule.murban.%'
     OR r LIKE 'rule.dubai.%'
     OR r LIKE 'rule.commodity.%'
     OR r LIKE 'rule.osp.%'
     OR r LIKE 'rule.fx.%' THEN
    RETURN 'commodity_price';
  END IF;

  IF r LIKE 'rule.regulatory.%'
     OR r LIKE 'rule.mohre.%'
     OR r LIKE 'rule.decree.%' THEN
    RETURN 'regulatory_change';
  END IF;

  IF r LIKE 'rule.geopolitical.%' THEN
    RETURN 'geopolitical';
  END IF;

  RETURN 'other';
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_classify_risk_by_rule(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_classify_risk_by_rule(text) TO neondb_owner;

COMMENT ON FUNCTION public.fn_classify_risk_by_rule(text) IS
  'Maps a rule.<topic>.* rule_id onto the 12-type risk taxonomy. Sibling of fn_classify_risk for callers that hold a rule id from risk_score.contributing_correlations rather than a free-text title.';

-- ─────────────────────────────────────────────────────────────────────
-- 2c. Rewrite fn_dashboard_executive_high_risk_extended with 4-tier picker
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_dashboard_executive_high_risk_extended(
  p_limit INTEGER DEFAULT 8
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_role     TEXT;
  v_user_id  BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  v_rows     JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive_high_risk_extended: unauthorized'
      USING ERRCODE = '42501';
  END IF;

  IF p_limit < 1 OR p_limit > 50 THEN
    RAISE EXCEPTION 'fn_dashboard_executive_high_risk_extended: limit must be 1..50'
      USING ERRCODE = '22023';
  END IF;

  SELECT r.name INTO v_role
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = v_user_id;

  IF v_role NOT IN ('executive', 'platform_admin', 'Super Admin')
     AND NOT fn_current_user_has_permission('insights.executive') THEN
    RAISE EXCEPTION 'fn_dashboard_executive_high_risk_extended: forbidden'
      USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                t.id,
    'contractNumber',    t.contract_number,
    'titleEn',           t.title_en,
    'titleAr',           t.title_ar,
    'valueAed',          t.value_aed,
    'riskScore',         t.ai_risk_score,
    'counterpartyName',  t.counterparty_name,
    'riskType',          COALESCE(t.risk_type, 'other')
  ) ORDER BY t.ai_risk_score DESC NULLS LAST), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      c.id,
      c.contract_number,
      c.title_en,
      c.title_ar,
      c.value_aed,
      c.ai_risk_score,
      cp.name_en AS counterparty_name,
      -- 4-tier risk type fallback. T1 → T2 → T3 → T4='other'.
      COALESCE(
        -- T1: classified open risk_case (skips rows the classifier
        --     would tag 'other' so we don't waste the slot on noise)
        (
          SELECT fn_classify_risk(
            NULL, NULL, NULL, NULL, NULL,
            rc.title, rc.assigned_role, rc.case_type
          )
          FROM risk_case rc
          WHERE rc.contract_id = c.id
            AND rc.is_active = TRUE
            AND rc.status NOT IN ('closed','resolved','accepted_risk','dismissed')
            AND fn_classify_risk(NULL, NULL, NULL, NULL, NULL,
                                 rc.title, rc.assigned_role, rc.case_type) <> 'other'
          ORDER BY
            CASE rc.priority
              WHEN 'critical' THEN 1
              WHEN 'high'     THEN 2
              WHEN 'medium'   THEN 3
              WHEN 'low'      THEN 4
              ELSE 5
            END,
            rc.created_at DESC
          LIMIT 1
        ),
        -- T2: top rule in latest risk_score.contributing_correlations
        --     by marContribution (skips rules that classify to 'other')
        (
          SELECT slug FROM (
            SELECT
              fn_classify_risk_by_rule(corr.value->>'ruleId') AS slug,
              ((corr.value->>'marContribution')::numeric) AS mar
            FROM (
              SELECT contributing_correlations
              FROM risk_score
              WHERE contract_id = c.id
              ORDER BY calculated_at DESC
              LIMIT 1
            ) rs_latest,
            LATERAL jsonb_array_elements(
              COALESCE(rs_latest.contributing_correlations, '[]'::jsonb)
            ) AS corr
          ) ranked
          WHERE slug <> 'other'
          ORDER BY mar DESC NULLS LAST
          LIMIT 1
        ),
        -- T3: most-severe linked osint signal (skips rows that classify
        --     to 'other')
        (
          SELECT slug FROM (
            SELECT
              fn_classify_risk(s.category, s.kind, s.signal_kind_subtype, s.source,
                               s.affected_clause_categories,
                               COALESCE(s.title_en, s.title), NULL, NULL) AS slug,
              s.severity,
              s.published_date
            FROM impact_signal_contract isc
            JOIN osint_signal s ON s.id = isc.signal_id
            WHERE isc.contract_id = c.id
              AND isc.is_active = TRUE
              AND s.is_active = TRUE
          ) sig
          WHERE slug <> 'other'
          ORDER BY
            CASE severity
              WHEN 'critical' THEN 1
              WHEN 'high'     THEN 2
              WHEN 'medium'   THEN 3
              WHEN 'low'      THEN 4
              ELSE 5
            END,
            published_date DESC NULLS LAST
          LIMIT 1
        )
      ) AS risk_type
    FROM contract c
    LEFT JOIN party cp ON cp.id = c.counterparty_id
    WHERE c.is_active = TRUE
      AND c.ai_risk_score IS NOT NULL
      AND c.ai_risk_score > 0
    ORDER BY c.ai_risk_score DESC NULLS LAST
    LIMIT p_limit
  ) t;

  RETURN v_rows;

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_executive_high_risk_extended: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION public.fn_dashboard_executive_high_risk_extended(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_executive_high_risk_extended(INTEGER) TO neondb_owner;

COMMENT ON FUNCTION public.fn_dashboard_executive_high_risk_extended(INTEGER) IS
  'Executive High-risk card data — top N active contracts (score > 0) enriched with counterpartyName + riskType. riskType uses a 4-tier fallback: open risk_case → rule correlation on latest risk_score → linked osint_signal → other.';

COMMIT;
