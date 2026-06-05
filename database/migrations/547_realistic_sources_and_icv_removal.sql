-- MIGRATION: 547_realistic_sources_and_icv_removal.sql
-- Date: 2026-06-04
-- Description:
--   Three coupled changes that finish the "make the Critical Impact frame
--   look like production, not a demo seed" effort.
--
--   1) Stop showing INTERNAL:HARNESS to the executive.
--
--      Two seeded osint_signal rows that currently show as
--      "INTERNAL:HARNESS · regulatory" describe content that would have a
--      real provenance in production:
--        - signal 7290235 ("Hormuz Strait routing disruption — vessel
--          transit hold") is maritime-security intel → relabel source to
--          rss_lloyds_maritime (already in the registry, has homepage).
--        - signal 7290223 ("Day-rate billing exceeded ceiling …") is
--          internal operational data → relabel to a new honest registry
--          entry internal_erp_billing (kind='internal', no homepage URL —
--          internal systems don't have public verify links).
--
--      The internal:harness source slug stays in the registry for future
--      seed work, just nothing visible to executives uses it anymore.
--
--   2) Propagate source URL through risk_cases.
--
--      Current state: every risk_case row in the Critical Impact frame
--      hardcodes sourceUrl = NULL because there's no per-case URL field
--      and the demo never wired risk_case.correlation_id even when the
--      case clearly maps to a known external source (OFAC SDN list,
--      Lloyd's List for the Hormuz routing case).
--
--      Fix: use risk_case.metadata as a soft pointer.
--      metadata.triggeringSourceId, if set, names the osint_source slug
--      the case was triggered by. The fn first tries correlation_id
--      (the real linkage in production), then falls back to the metadata
--      slug, then NULL. Backfill the 2 existing critical correlation_alert
--      cases:
--        - id  8 (OFAC SDN designation)     → ofac_sdn
--        - id 24 (Hormuz routing FM event)  → rss_lloyds_maritime
--
--   3) Remove the DEWA ICV thread entirely.
--
--      ICV isn't surfaced anywhere in the Insights module per product
--      decision, so soft-delete:
--        - risk_case 16    "DEWA — ICV certificates missing …"
--        - osint_signal 3801229 "ICV status downgraded for counterparty"
--      Plus any active impact_signal_contract junction rows pointing at
--      the signal. risk_case_event rows for the case become unreachable
--      via is_active=FALSE on the parent, which matches how every other
--      soft-delete behaves on this surface.
--
--   Same fn body also adds sourceDisplayName + propagates source from the
--   registry's display_name so the UI can stop showing raw slugs like
--   "OFAC_SDN" and render the proper "OFAC SDN List" label.

BEGIN;

-- 1. Add registry entry for the internal billing system ---------------

INSERT INTO osint_source (
  tenant_id, source_id, display_name, display_name_ar, kind, url,
  homepage_url, format, refresh_seconds, source_reliability, enabled,
  data_classification, is_active
)
SELECT '00000000-0000-0000-0000-000000000001'::uuid,
       'internal_erp_billing', 'Internal Billing / ERP', 'النظام المالي الداخلي',
       'internal', NULL,
       NULL,           -- internal-only, no public verify URL
       'json', 3600, 0.95, TRUE,
       'demo', TRUE
WHERE NOT EXISTS (
  SELECT 1 FROM osint_source WHERE source_id = 'internal_erp_billing'
);

-- 2. Relabel the two misleading internal:harness signals --------------

UPDATE osint_signal SET source = 'rss_lloyds_maritime'
 WHERE id = 7290235 AND is_active = TRUE;

UPDATE osint_signal SET source = 'internal_erp_billing'
 WHERE id = 7290223 AND is_active = TRUE;

-- 3. Backfill triggeringSourceId on the two known correlation_alert
--    critical risk_cases so the fn can propagate a real verify URL.

UPDATE risk_case
   SET metadata = COALESCE(metadata, '{}'::jsonb)
                  || jsonb_build_object('triggeringSourceId', 'ofac_sdn')
 WHERE id = 8 AND is_active = TRUE;

UPDATE risk_case
   SET metadata = COALESCE(metadata, '{}'::jsonb)
                  || jsonb_build_object('triggeringSourceId', 'rss_lloyds_maritime')
 WHERE id = 24 AND is_active = TRUE;

-- 4. Remove the DEWA ICV thread (soft-delete) -------------------------

UPDATE risk_case
   SET is_active = FALSE,
       updated_at = CURRENT_TIMESTAMP
 WHERE id = 16 AND is_active = TRUE;

-- Drop the high-severity "ICV status downgraded" signal too — same
-- product decision applies (ICV not in scope for the Insights module).
UPDATE osint_signal
   SET is_active = FALSE,
       updated_at = CURRENT_TIMESTAMP
 WHERE id = 3801229 AND is_active = TRUE;

-- Any junction rows pointing at the dropped signal go inactive too.
UPDATE impact_signal_contract
   SET is_active = FALSE,
       updated_at = CURRENT_TIMESTAMP
 WHERE signal_id = 3801229 AND is_active = TRUE;

-- 5. Rewrite fn_dashboard_executive_critical_impacts ------------------
--
--   Two new behaviours on top of migration 545:
--     a) For risk_case rows, resolve the underlying triggering source
--        via correlation_id → osint_signal first, then metadata
--        triggeringSourceId. Use that to pick up source slug, display
--        name, category, and source URL.
--     b) Surface sourceDisplayName so the FE can show "OFAC SDN List"
--        instead of "OFAC_SDN".

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
      src.display_name                                     AS source_display_name,
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
      -- Source slug: correlation-engine path → metadata pointer → case_type.
      COALESCE(
        (SELECT s2.source
           FROM correlation co
           JOIN osint_signal s2 ON s2.id = co.signal_id AND s2.is_active = TRUE
          WHERE co.id = rc.correlation_id),
        rc.metadata->>'triggeringSourceId',
        rc.case_type
      )                                                    AS source,
      -- Display name from the registry when the source resolves.
      (SELECT src2.display_name
         FROM osint_source src2
        WHERE src2.source_id = COALESCE(
          (SELECT s2.source
             FROM correlation co
             JOIN osint_signal s2 ON s2.id = co.signal_id AND s2.is_active = TRUE
            WHERE co.id = rc.correlation_id),
          rc.metadata->>'triggeringSourceId'
        )
          AND src2.is_active = TRUE)                       AS source_display_name,
      -- Source URL chain: correlation→signal.url OR signal source homepage,
      -- then metadata-pointer homepage_url, then NULL.
      COALESCE(
        (SELECT COALESCE(s2.url, src2.homepage_url)
           FROM correlation co
           JOIN osint_signal s2 ON s2.id = co.signal_id AND s2.is_active = TRUE
           LEFT JOIN osint_source src2 ON src2.source_id = s2.source AND src2.is_active = TRUE
          WHERE co.id = rc.correlation_id),
        (SELECT src3.homepage_url
           FROM osint_source src3
          WHERE src3.source_id = rc.metadata->>'triggeringSourceId'
            AND src3.is_active = TRUE)
      )                                                    AS source_url,
      -- Category derived from the triggering source's kind, else "risk_case".
      COALESCE(
        (SELECT src4.kind
           FROM osint_source src4
          WHERE src4.source_id = COALESCE(
            (SELECT s2.source
               FROM correlation co
               JOIN osint_signal s2 ON s2.id = co.signal_id AND s2.is_active = TRUE
              WHERE co.id = rc.correlation_id),
            rc.metadata->>'triggeringSourceId'
          )
            AND src4.is_active = TRUE),
        'risk_case'
      )                                                    AS category,
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
      'kind',                m.kind,
      'id',                  m.id,
      'title',               m.title,
      'description',         m.description,
      'criticality',         m.criticality,
      'occurredAt',          m.occurred_at,
      'source',              m.source,
      'sourceDisplayName',   m.source_display_name,
      'sourceUrl',           m.source_url,
      'category',            m.category,
      'riskType',            m.risk_type,
      'contractsAffected',   jsonb_array_length(m.contracts),
      'contracts',           m.contracts
    ) ORDER BY m.occurred_at DESC, m.id DESC
  ), '[]'::jsonb)
  INTO v_rows
  FROM merged m
  WHERE jsonb_array_length(m.contracts) > 0;

  RETURN jsonb_build_object(
    'windowDays', p_window_days,
    'asOf',       CURRENT_TIMESTAMP,
    'rows',       v_rows
  );
END;
$function$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (547, 'realistic_sources_and_icv_removal', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
