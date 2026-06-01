-- Migration: 423_dana_cluster_a_verified_counterparties.sql
-- Unit: Dana Drafter PM-grade audit fix pass (2026-06-01) — Cluster A
-- Defect addressed:
--   D40 — Parties Verified column showed "—" for ALL 499 rows. Per audit,
--         12/499 had is_verified=TRUE before this migration. Demo audience
--         opening Parties sees a column with no signal. Seed the top ~30
--         ADNOC-tier counterparties so the column carries information.
-- Test-branch-safe: guard checks that there are parties to verify; UPDATE is
-- a WHERE-clause filter so missing parties on test branch are silent no-ops.
-- Rollback: reset is_verified=FALSE on the seeded names.

BEGIN;

-- Mark the top ~30 ADNOC-tier counterparties as verified so the Verified
-- column on /app/parties has signal across roughly 8% of rows. These are
-- the names that appear in HERO contracts, dashboards, and the demo flow.
UPDATE party SET is_verified = TRUE, updated_at = NOW(), updated_by = 1
 WHERE is_verified = FALSE
   AND name_en IN (
     'ADNOC Distribution PJSC',
     'ADNOC Drilling',
     'ADNOC Offshore',
     'ADNOC Onshore',
     'ADNOC Gas',
     'Mubadala Investment Company',
     'Mubadala Petroleum Support',
     'Emirates NBD Bank PJSC',
     'Etisalat Group (e&)',
     'IBM Middle East FZ-LLC',
     'DEWA — Dubai Electricity & Water Authority',
     'Digital DEWA Innovation Centre',
     'Galadari Brothers Group',
     'Galadari Engineering',
     'EPC Pipeline Contractors LLC',
     'Lamprell Energy',
     'NMDC Marine Services',
     'Borouge Logistics SOW',
     'Crescent Petroleum Service',
     'Gulf Drilling Technologies',
     'Gulf Towage & Salvage',
     'Fujairah Port Logistics',
     'North Star Shipping Services',
     'Al Noor Technical Consulting',
     'Al Jubail Marine Services',
     'Falcon Oil & Gas Consultancy',
     'Zawaya Marine & Offshore',
     'Emirates Petroleum Services',
     'NPCC',
     'Petrofac',
     'Microsoft',
     'Oilfield Pipelines UAE',
     'ABB Power and Automation UAE'
   );

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (423, 'D40 Dana — seed is_verified=TRUE on top ~30 ADNOC-tier counterparties', NOW())
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================
-- ROLLBACK BEGIN
-- ============================================================
-- BEGIN;
--   UPDATE party SET is_verified = FALSE WHERE name_en IN (...same list...);
--   DELETE FROM schema_migrations WHERE version = 423;
-- COMMIT;
-- ROLLBACK END
