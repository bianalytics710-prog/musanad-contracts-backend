-- Migration: 453_impact_signal_contract_link_seed.sql
-- Module: Impact Watch — A3-G4 fix
-- Description: impact_signal_contract junction is empty (0 rows) for all
--              502 impact signals; every signal on Impact Watch radar shows
--              "0 impacted contracts" — kills Layla's "which contracts are
--              exposed" narrative. Seed the junction by matching each
--              signal's category to a heuristic set of contracts:
--                regulatory       → contracts ILIKE '%services|consultancy|employment%'
--                commodity_prices → contract_type IN (Supply, Gas SPA, Services)
--                supply_chain     → contracts ILIKE '%shipping|marine|offshore|port%'
--                geopolitical     → all active high-value contracts
--                market_financial → contracts with currency != AED
--              Each signal links to top-5 matching contracts by value_aed.
--              Impact score = severity_aware (critical=90 / high=75 /
--              medium=55 / low=30 / informational=15). Status='pending'.
-- Date: 2026-06-01

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

INSERT INTO impact_signal_contract (
  signal_id, contract_id, impact_score, status, is_seed, is_active, data_classification, created_by, updated_by
)
SELECT
  isig.signal_id,
  isig.contract_id,
  CASE isig.severity
    WHEN 'critical' THEN 90
    WHEN 'high'     THEN 75
    WHEN 'medium'   THEN 55
    WHEN 'low'      THEN 30
    ELSE                 15
  END                                                  AS impact_score,
  'pending'                                            AS status,
  TRUE                                                 AS is_seed,
  TRUE                                                 AS is_active,
  'demo'                                               AS data_classification,
  1                                                    AS created_by,
  1                                                    AS updated_by
FROM (
  SELECT
    s.id AS signal_id,
    c.id AS contract_id,
    s.severity,
    ROW_NUMBER() OVER (
      PARTITION BY s.id
      ORDER BY c.value_aed DESC NULLS LAST, c.id
    ) AS rn
  FROM impact_signal s
  CROSS JOIN LATERAL (
    SELECT c.id, c.value_aed
    FROM contract c
    WHERE c.is_active = TRUE
      AND (
        (s.category = 'regulatory'
          AND (lower(c.title_en) ~ 'services|consultancy|employment|sow|advisory'
               OR c.contract_type IN ('Services','Consultancy','Employment','Advisory')))
     OR (s.category = 'commodity_prices'
          AND c.contract_type IN ('Supply','Gas SPA','Services'))
     OR (s.category = 'supply_chain'
          AND (lower(c.title_en) ~ 'shipping|marine|offshore|port|towage|logistic'
               OR c.contract_type IN ('Services','Supply')))
     OR (s.category = 'geopolitical'
          AND c.value_aed >= 1000000)
     OR (s.category = 'market_financial'
          AND (c.currency IS NULL OR c.currency <> 'AED'))
      )
  ) c
) isig
WHERE isig.rn <= 5
ON CONFLICT DO NOTHING;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (453, '453_impact_signal_contract_link_seed', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 453;
-- DELETE FROM impact_signal_contract WHERE is_seed = TRUE AND data_classification = 'demo';
-- ============================================================
