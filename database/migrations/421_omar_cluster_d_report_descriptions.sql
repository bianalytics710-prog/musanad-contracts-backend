-- Migration: 421_omar_cluster_d_report_descriptions.sql
-- Unit: Omar Operations QA Phase 3 — Cluster D (slug leak: report descriptions)
-- Targets:
--   O28  Report cards leak DB column/table names ("delivery.delay",
--        "risk_score.dim_operational") in user-facing description copy.
--   O41  Slug-leak pattern.
--
-- Strategy: rewrite descriptions in business prose.

UPDATE report_template
   SET description = 'Delivery delay correlations with severity, detection time, and remediation status.',
       updated_at = NOW(),
       updated_by = 1
 WHERE template_id = 'operations_delivery_delay'
   AND is_active = TRUE;

UPDATE report_template
   SET description = 'Operational penalty exposure aggregated by contract — counterparty SLA breaches + materialised risk.',
       updated_at = NOW(),
       updated_by = 1
 WHERE template_id = 'operations_penalty_exposure'
   AND is_active = TRUE;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (421, '421_omar_cluster_d_report_descriptions — O28 rewrite ops report copy without slugs', NOW())
ON CONFLICT (version) DO NOTHING;
