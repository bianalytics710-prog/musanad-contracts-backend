-- MIGRATION: 545_source_homepage_url_and_filter_zero_contracts.sql
-- Date: 2026-06-04
-- Description:
--   Two changes to make the executive Critical Impact frame look real
--   instead of demo-coded:
--
--   1) Every external signal gets a verifiable source URL.
--
--      osint_source.url today holds the technical feed / API URL
--      (e.g. https://api.exchangerate.host/latest,
--      https://www.treasury.gov/ofac/downloads/sdn.xml). Useful for the
--      adapter, useless for a user who wants to read the underlying news
--      story or check the regulator's announcement. We add a new
--      homepage_url column that points at the source's public landing
--      page, backfill it for the existing registry rows, and INSERT
--      registry rows for the 5 signal sources that exist in
--      osint_signal.source but aren't registered yet (commodity_feed,
--      fx_feed, rss_reuters_energy, open_meteo_noaa, commodity_crude).
--
--      fn_dashboard_executive_critical_impacts is updated to use
--      COALESCE(per-signal s.url, registry homepage_url) so:
--        - RSS-captured rows keep their actual article URL (best)
--        - other external sources fall back to the publisher's homepage
--        - internal:harness + mock_* + smoke_test_* rows stay NULL and
--          the FE just omits the "Verify source" link
--
--   2) Drop critical alerts with 0 affected contracts.
--
--      A critical signal that hasn't been linked to any active contract
--      is news, not an actionable alert for the executive. Filter both
--      streams (osint_signal + risk_case) on jsonb_array_length(
--      contracts) > 0 so the Critical Impact tile count + frame stay
--      decision-grade.

BEGIN;

-- 1. Schema: homepage_url on osint_source ------------------------------

ALTER TABLE osint_source
  ADD COLUMN IF NOT EXISTS homepage_url TEXT;

COMMENT ON COLUMN osint_source.homepage_url IS
  'Public landing page for the source (publisher homepage, regulator landing page, '
  'authoritative reference URL). Used by the executive Critical Impact frame as a '
  'fallback "Verify source" link when the per-signal article URL is NULL. Distinct '
  'from osint_source.url which is the technical feed / API endpoint.';

-- 2. Backfill homepage_url for existing registry rows ------------------

UPDATE osint_source SET homepage_url = CASE source_id
  -- Sanctions / compliance landings
  WHEN 'ofac_sdn'             THEN 'https://ofac.treasury.gov/sanctions-list-search-tool'
  WHEN 'eu_consolidated'      THEN 'https://webgate.ec.europa.eu/fsd/fsf'
  WHEN 'un_security_council'  THEN 'https://www.un.org/securitycouncil/sanctions/information'
  WHEN 'uk_hmt'               THEN 'https://www.gov.uk/government/publications/financial-sanctions-consolidated-list-of-targets'

  -- News / RSS publisher homepages
  WHEN 'rss_lloyds_maritime'   THEN 'https://www.lloydslist.com/'
  WHEN 'rss_sp_platts'         THEN 'https://oilprice.com/'
  WHEN 'rss_argus_oil'         THEN 'https://www.theguardian.com/uk/business'
  WHEN 'rss_khaleej_business'  THEN 'https://www.khaleejtimes.com/business'
  WHEN 'rss_gulf_business'     THEN 'https://gulfnews.com/business'
  WHEN 'rss_uae_gov'           THEN 'https://u.ae/'
  WHEN 'rss_the_national'      THEN 'https://www.thenationalnews.com/'

  -- Weather / climate
  WHEN 'openweather'  THEN 'https://openweathermap.org/'
  WHEN 'noaa_gfs'     THEN 'https://www.noaa.gov/'
  WHEN 'ncm_uae'      THEN 'https://www.ncm.gov.ae/'

  -- FX / commodity authoritative landings (UAE-first where possible)
  WHEN 'fx_usd_aed'   THEN 'https://www.cbuae.gov.ae/en/markets-and-statistics/exchange-rates'

  -- Regulatory / labor
  WHEN 'mohre_labor'  THEN 'https://www.mohre.gov.ae/'

  -- Internal + mock + smoke stay NULL (intentionally no public source)
  ELSE NULL
END
WHERE is_active = TRUE
  AND source_id IN (
    'ofac_sdn','eu_consolidated','un_security_council','uk_hmt',
    'rss_lloyds_maritime','rss_sp_platts','rss_argus_oil','rss_khaleej_business',
    'rss_gulf_business','rss_uae_gov','rss_the_national',
    'openweather','noaa_gfs','ncm_uae',
    'fx_usd_aed','mohre_labor'
  );

-- 3. INSERT registry rows for sources used in osint_signal but missing
--    from osint_source. These show up in the critical/high impact feed.

INSERT INTO osint_source (
  tenant_id, source_id, display_name, display_name_ar, kind, url,
  homepage_url, format, refresh_seconds, source_reliability, enabled,
  data_classification, is_active
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  src.source_id, src.display_name, src.display_name_ar, src.kind,
  src.feed_url, src.homepage_url, src.format,
  src.refresh_seconds, src.reliability, TRUE,
  'demo', TRUE
FROM (VALUES
  ('commodity_feed',     'Commodity Tracker (S&P Global)',  'متعقّب السلع (S&P Global)',     'commodity',
     'https://www.spglobal.com/commodityinsights/',
     'https://www.spglobal.com/commodityinsights/en',                     'json', 3600, 0.85),
  ('commodity_crude',    'OPEC Crude Reference',            'مرجع النفط الخام أوبك',         'commodity',
     'https://www.opec.org/opec_web/en/data_graphs/40.htm',
     'https://www.opec.org/opec_web/en/data_graphs/40.htm',               'json', 3600, 0.90),
  ('fx_feed',            'FX Rates (CBUAE)',                'أسعار الصرف (مصرف الإمارات المركزي)', 'fx',
     'https://www.cbuae.gov.ae/en/markets-and-statistics/exchange-rates',
     'https://www.cbuae.gov.ae/en/markets-and-statistics/exchange-rates', 'json', 1800, 0.95),
  ('rss_reuters_energy', 'Reuters Energy',                  'رويترز - الطاقة',               'news',
     'https://www.reuters.com/business/energy/',
     'https://www.reuters.com/business/energy/',                          'rss',   900, 0.90),
  ('open_meteo_noaa',    'Open-Meteo (NOAA proxy)',         'Open-Meteo (وكيل NOAA)',         'weather',
     'https://open-meteo.com/',
     'https://www.noaa.gov/',                                             'json', 21600, 0.85)
) AS src(source_id, display_name, display_name_ar, kind, feed_url, homepage_url, format, refresh_seconds, reliability)
WHERE NOT EXISTS (
  SELECT 1 FROM osint_source o WHERE o.source_id = src.source_id
);

-- 4. Update fn_dashboard_executive_critical_impacts --------------------
--
-- Two changes vs migration 544:
--   a) LEFT JOIN osint_source to pick up homepage_url for the source.
--      sourceUrl = COALESCE(per-signal s.url, src.homepage_url).
--   b) Filter the merged set to rows where the contracts array is
--      non-empty — zero-contract critical alerts are noise.

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
      -- Per-signal article URL (best) → source homepage_url (fallback) → NULL
      COALESCE(s.url, src.homepage_url)                    AS source_url,
      s.category                                           AS category,
      fn_classify_risk(
        s.category, s.kind, s.signal_kind_subtype, s.source,
        s.affected_clause_categories, COALESCE(s.title_en, s.title),
        NULL, NULL
      )                                                    AS risk_type,
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
    LEFT JOIN osint_source src
           ON src.source_id = s.source
          AND src.is_active = TRUE
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
      fn_classify_risk(
        NULL, NULL, NULL, NULL, NULL,
        rc.title, rc.assigned_role, rc.case_type
      )                                                    AS risk_type,
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
      'riskType',           m.risk_type,
      'contractsAffected',  jsonb_array_length(m.contracts),
      'contracts',          m.contracts
    ) ORDER BY m.occurred_at DESC, m.id DESC
  ), '[]'::jsonb)
  INTO v_rows
  FROM merged m
  -- Drop rows with no affected contracts — a critical alert that hasn't
  -- been linked to any active contract is news, not an actionable alert.
  WHERE jsonb_array_length(m.contracts) > 0;

  RETURN jsonb_build_object(
    'windowDays', p_window_days,
    'asOf',       CURRENT_TIMESTAMP,
    'rows',       v_rows
  );
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (545, 'source_homepage_url_and_filter_zero_contracts', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
