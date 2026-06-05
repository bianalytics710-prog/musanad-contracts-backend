-- MIGRATION: 543_critical_impact_source_url_and_fn.sql
-- Date: 2026-06-04
-- Description:
--   Reshapes the executive "Critical regulatory impacts" tile into a
--   broader "Critical impact" surface that merges TWO existing critical
--   streams already captured by the platform:
--
--     1. osint_signal rows with severity='critical'    (regulatory +
--        commodity + supply-chain + geopolitical alerts captured by
--        Impact Watch + the OSINT pipeline). The "impact_signal" view
--        registered at M7 is a backwards-compat shim over osint_signal;
--        we read directly from osint_signal here to pick up the existing
--        `url` column (the M7 view does not expose it).
--     2. risk_case rows with priority='critical' and an open status
--        (correlation-engine alerts the risk-cases module surfaces).
--
--   Changes:
--     a. Backfill osint_signal.url for a handful of seeded rows whose
--        url today is an obvious placeholder ("https://demo/..." or
--        "https://demo.example/...") with public landing pages on the
--        real publishers, so the FE "Verify source" link actually opens
--        something useful in the demo. Real RSS rows already carry the
--        article URL captured at ingest, so we leave those alone.
--        internal:harness rows stay NULL and the FE simply omits the
--        verify link.
--     b. CREATE fn_dashboard_executive_critical_impacts(window_days int)
--        — returns a JSONB envelope merging both streams, with the
--        affected-contracts list pre-joined so the FE can render the
--        drill-down without a second round-trip.
--
-- Permissions / role gate:
--   The new fn reuses the existing role union from
--   fn_dashboard_executive_expiring_contracts (executive / platform_admin
--   / Super Admin OR insights.executive permission). The data it returns
--   is a strict subset of what fn_impact_signal_list + fn_risk_case_list
--   already return to the same callers, so no new permission code is
--   needed.

BEGIN;

-- 1. Backfill placeholder source URLs ----------------------------------
--
-- Only updates rows where the existing url is an obvious placeholder.
-- Real captured RSS URLs are untouched.

UPDATE osint_signal
   SET url = CASE source
     WHEN 'ncm_uae'          THEN 'https://www.ncm.gov.ae/'
     WHEN 'open_meteo_noaa'  THEN 'https://open-meteo.com/'
     WHEN 'mohre_labor'      THEN 'https://www.mohre.gov.ae/'
   END
 WHERE is_active = TRUE
   AND source IN ('ncm_uae','open_meteo_noaa','mohre_labor')
   AND (url IS NULL OR url LIKE 'https://demo/%' OR url LIKE 'https://demo.example/%');

-- 2. Function: fn_dashboard_executive_critical_impacts -----------------
--
-- Returns:
--   {
--     "windowDays": 7,
--     "asOf": "2026-06-04T...",
--     "rows": [
--       {
--         "kind": "impact_signal" | "risk_case",
--         "id": "...",
--         "title": "...",
--         "description": "...",
--         "criticality": "critical",
--         "occurredAt": "2026-05-30T00:00:00+00:00",
--         "source": "internal:harness" | "rss_reuters_energy" | "correlation_engine" | "manual",
--         "sourceUrl": "https://..." | null,
--         "category": "regulatory" | "supply_chain" | "manual" | ...,
--         "contractsAffected": 5,
--         "contracts": [
--           { "id": "248", "contractNumber": "CRQ-GAS-014", "titleEn": "...",
--             "valueAed": "8500000000.00", "currency": "AED",
--             "counterpartyName": "Gulf Towage & Salvage" },
--           ...
--         ]
--       }, ...
--     ]
--   }
--
-- Sort: occurredAt DESC, id DESC.
-- Window: osint_signal.published_date >= today - p_window_days,
--         risk_case.created_at       >= now() - p_window_days days.
-- Critical filter:
--   osint_signal.severity = 'critical'
--   risk_case.priority    = 'critical'
--     AND risk_case.status NOT IN ('closed','resolved','accepted_risk','dismissed')

CREATE OR REPLACE FUNCTION public.fn_dashboard_executive_critical_impacts(
  p_window_days integer DEFAULT 7
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_role     TEXT;
  v_user_id  BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  v_rows     JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive_critical_impacts: unauthorized'
      USING ERRCODE = '42501';
  END IF;

  IF p_window_days < 1 OR p_window_days > 90 THEN
    RAISE EXCEPTION 'fn_dashboard_executive_critical_impacts: windowDays must be 1..90'
      USING ERRCODE = '22023';
  END IF;

  SELECT r.name INTO v_role
    FROM "user" u JOIN role r ON r.id = u.role_id
   WHERE u.id = v_user_id;

  IF v_role NOT IN ('executive', 'platform_admin', 'Super Admin')
     AND NOT fn_current_user_has_permission('insights.executive') THEN
    RAISE EXCEPTION 'fn_dashboard_executive_critical_impacts: forbidden'
      USING ERRCODE = '42501';
  END IF;

  WITH
  signal_rows AS (
    SELECT
      'impact_signal'::text                                AS kind,
      s.id::text                                           AS id,
      COALESCE(s.title_en, s.title, '(untitled signal)')   AS title,
      COALESCE(s.description_en, s.summary)                AS description,
      s.severity                                           AS criticality,
      (s.published_date::timestamptz)                      AS occurred_at,
      s.source                                             AS source,
      s.url                                                AS source_url,
      s.category                                           AS category,
      COALESCE(
        (SELECT jsonb_agg(jsonb_build_object(
            'id',               c.id::text,
            'contractNumber',   c.contract_number,
            'titleEn',          c.title_en,
            'valueAed',         c.value_aed,
            'currency',         c.currency,
            'counterpartyName', cp.name_en
          ) ORDER BY c.value_aed DESC NULLS LAST, c.id ASC)
         FROM impact_signal_contract isc
         JOIN contract c ON c.id = isc.contract_id AND c.is_active = TRUE
         LEFT JOIN party cp ON cp.id = c.counterparty_id
         WHERE isc.signal_id = s.id AND isc.is_active = TRUE),
        '[]'::jsonb
      )                                                    AS contracts
    FROM osint_signal s
    WHERE s.is_active = TRUE
      AND s.severity = 'critical'
      AND s.published_date >= CURRENT_DATE - (p_window_days || ' days')::interval
  ),
  case_rows AS (
    SELECT
      'risk_case'::text                                    AS kind,
      rc.id::text                                          AS id,
      rc.title                                             AS title,
      LEFT(COALESCE(rc.body, ''), 600)                     AS description,
      rc.priority                                          AS criticality,
      rc.created_at                                        AS occurred_at,
      COALESCE(rc.case_type, 'manual')                     AS source,
      NULL::text                                           AS source_url,
      'risk_case'::text                                    AS category,
      CASE
        WHEN rc.contract_id IS NULL THEN '[]'::jsonb
        ELSE COALESCE(
          (SELECT jsonb_build_array(jsonb_build_object(
              'id',               c.id::text,
              'contractNumber',   c.contract_number,
              'titleEn',          c.title_en,
              'valueAed',         c.value_aed,
              'currency',         c.currency,
              'counterpartyName', cp.name_en
            ))
           FROM contract c
           LEFT JOIN party cp ON cp.id = c.counterparty_id
           WHERE c.id = rc.contract_id AND c.is_active = TRUE),
          '[]'::jsonb)
      END                                                  AS contracts
    FROM risk_case rc
    WHERE rc.is_active = TRUE
      AND rc.priority  = 'critical'
      AND rc.status NOT IN ('closed','resolved','accepted_risk','dismissed')
      AND rc.created_at >= CURRENT_TIMESTAMP - (p_window_days || ' days')::interval
  ),
  merged AS (
    SELECT * FROM signal_rows
    UNION ALL
    SELECT * FROM case_rows
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'kind',               m.kind,
      'id',                 m.id,
      'title',              m.title,
      'description',        m.description,
      'criticality',        m.criticality,
      'occurredAt',         m.occurred_at,
      'source',             m.source,
      'sourceUrl',          m.source_url,
      'category',           m.category,
      'contractsAffected',  jsonb_array_length(m.contracts),
      'contracts',          m.contracts
    ) ORDER BY m.occurred_at DESC, m.id DESC
  ), '[]'::jsonb)
  INTO v_rows
  FROM merged m;

  RETURN jsonb_build_object(
    'windowDays', p_window_days,
    'asOf',       CURRENT_TIMESTAMP,
    'rows',       v_rows
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_dashboard_executive_critical_impacts(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_executive_critical_impacts(integer) TO neondb_owner;

COMMENT ON FUNCTION public.fn_dashboard_executive_critical_impacts(integer) IS
  'Returns critical impacts (osint_signal severity=critical + risk_case priority=critical) '
  'with affected-contracts drill-down for the executive dashboard Critical Impact tile. '
  'Role gate mirrors fn_dashboard_executive_expiring_contracts.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (543, 'critical_impact_source_url_and_fn', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
