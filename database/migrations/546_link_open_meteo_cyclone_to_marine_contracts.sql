-- MIGRATION: 546_link_open_meteo_cyclone_to_marine_contracts.sql
-- Date: 2026-06-04
-- Description:
--   The open_meteo_noaa cyclone signal (id 7290250) was seeded without
--   any impact_signal_contract links, so under the new zero-contracts
--   filter (migration 545) it disappears from the executive Critical
--   Impact frame entirely. In production, the correlation engine would
--   auto-link a Category-3 Persian Gulf cyclone to active marine /
--   offshore / Gulf-routed contracts the moment the alert lands.
--
--   This migration mimics that behaviour for the demo: link the cyclone
--   signal to the SAME five marine contracts that the earlier ncm_uae
--   cyclone (signal 4694616) is attached to. Same hazard, same affected
--   contract set. Restores the cyclone to the Critical Impact frame
--   with its open_meteo_noaa source URL intact so the "Verify source"
--   link is demonstrable on an external signal end-to-end.

BEGIN;

INSERT INTO impact_signal_contract (
  signal_id, contract_id, impact_score, status, is_seed,
  created_at, updated_at, is_active
)
SELECT
  7290250::bigint AS signal_id,
  c.contract_id, 80, 'pending', TRUE,
  CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, TRUE
FROM (VALUES (52), (127), (172), (146), (182)) AS c(contract_id)
WHERE NOT EXISTS (
  SELECT 1 FROM impact_signal_contract isc
   WHERE isc.signal_id = 7290250 AND isc.contract_id = c.contract_id
);

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (546, 'link_open_meteo_cyclone_to_marine_contracts', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
