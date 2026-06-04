-- MIGRATION: 520_tpa_playbook_governing_law_criticality.sql
-- Date: 2026-06-03
-- Change: Lower governing_law criticality from non_negotiable -> high.
--
-- Rationale: ADNOC absolutely requires UAE/ADGM law, but if the counterparty
-- proposes a different country, the fix is a SURGICAL change (swap country
-- name) — that's amend territory, not reject. Reject should remain only for
-- structurally-misaligned clauses like foreign-seat arbitration with foreign
-- institutional rules + 3-arbitrator panels (= dispute_resolution).

BEGIN;

UPDATE tpa_playbook_clause
SET criticality = 'high',
    updated_at = NOW()
WHERE tenant_id = '00000000-0000-0000-0000-000000000001'::uuid
  AND clause_key = 'governing_law'
  AND criticality = 'non_negotiable';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (520, 'tpa_playbook_governing_law_criticality', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;
