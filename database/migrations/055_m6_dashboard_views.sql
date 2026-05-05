-- ============================================================================
-- 055_m6_dashboard_views.sql
-- ============================================================================
-- Module:    M6 (Dashboards & Reporting)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   054 (permission seed + ARCH-NEW-3 RLS policy).
-- ----------------------------------------------------------------------------
-- Per locked Gate 2 Q3: 4 plain VIEWs (NOT materialized). At M0..M5 row
-- counts (<100K), refresh ceremony adds no benefit; plain views compose
-- naturally with INVOKER fn_ wrappers (RLS applies at SELECT time on
-- underlying tables).
--
-- vw_ai_cost_rollup intentionally NOT created per locked Gate 2 Q5
-- (fn_ai_request_log_cost_report already returns the same shape).
--
-- All column references verified against live DDL post-Patch-Round-1:
--   - approval_step.created_at  (NOT assigned_at — S2-22-FIX-2b)
--   - signature_event.created_at + event_type='signed' + is_active
--     (NOT signed_at / outcome — S2-22-FIX-1)
--   - signature_invitation.invitation_sent_at + invitation_expires_at
--     (NOT sent_at / expires_at — S2-22-FIX-5)
--   - regulatory_impact.resolved BOOLEAN  (NOT resolved_at — CRIT-1)
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 4.1 vw_contract_status_summary
--   Per-status contract count + total value AED + 30/60/90-day expiry buckets.
--   USED BY: fn_dashboard_admin (S1) totalContractsByStatus + expiringWithin*
--            fn_dashboard_executive (S7) contractsByStatus + expiryCliffs
-- ============================================================================
CREATE VIEW vw_contract_status_summary AS
SELECT
  status,
  COUNT(*)                                                                                       AS contract_count,
  COALESCE(SUM(value_aed), 0)                                                                    AS total_value_aed,
  COUNT(*) FILTER (WHERE end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days')    AS expiring_within_30d,
  COUNT(*) FILTER (WHERE end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '60 days')    AS expiring_within_60d,
  COUNT(*) FILTER (WHERE end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days')    AS expiring_within_90d
FROM contract
WHERE is_active = TRUE
GROUP BY status;

COMMENT ON VIEW vw_contract_status_summary IS
  'M6 (055) — per-status contract aggregate for fn_dashboard_admin (S1) + fn_dashboard_executive (S7). RLS applies at SELECT time on contract via INVOKER fn_ wrappers.';

-- ============================================================================
-- 4.2 vw_approval_queue_metrics
--   Pending approval steps grouped by approver_role with median + p95
--   time-pending (hours).  USED BY: fn_dashboard_admin (S1), fn_dashboard_approver (S3).
--   NOTE: live approval_step has no assigned_at — uses created_at instead
--   (S2-22-FIX-2b; rows immutable post-creation per
--   trg_approval_step_immutable_fields).
-- ============================================================================
CREATE VIEW vw_approval_queue_metrics AS
SELECT
  step.approver_role,
  COUNT(*) FILTER (WHERE step.status = 'pending')                                                AS pending_count,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (NOW() - step.created_at))/3600)
    FILTER (WHERE step.status = 'pending')                                                       AS median_time_pending_hours,
  PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (NOW() - step.created_at))/3600)
    FILTER (WHERE step.status = 'pending')                                                       AS p95_time_pending_hours,
  (SELECT MIN(s2.id) FROM approval_step s2
     WHERE s2.approver_role = step.approver_role AND s2.status = 'pending' AND s2.is_active = TRUE) AS oldest_pending_step_id
FROM approval_step step
WHERE step.is_active = TRUE
GROUP BY step.approver_role;

COMMENT ON VIEW vw_approval_queue_metrics IS
  'M6 (055) — approver queue depth + latency aggregates. Uses approval_step.created_at as queue-entry timestamp (live schema has no assigned_at; rows immutable per M2-NEW-2 trigger).';

-- ============================================================================
-- 4.3 vw_signature_status_summary
--   Active signature_invitation rows grouped by status + median time-to-sign.
--   USED BY: fn_dashboard_recipient (S5), fn_dashboard_admin (S1).
--   NOTE: live signature_event has no signed_at / outcome — uses created_at
--         and event_type='signed' (S2-22-FIX-1+5c). Live signature_invitation
--         has invitation_sent_at (NOT sent_at — S2-22-FIX-5a).
-- ============================================================================
CREATE VIEW vw_signature_status_summary AS
SELECT
  si.status,
  COUNT(*)                                                                                       AS invitation_count,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (se.created_at - si.invitation_sent_at))/3600)
    FILTER (WHERE se.created_at IS NOT NULL)                                                     AS median_time_to_sign_hours,
  COUNT(*) FILTER (WHERE si.status = 'expired')                                                  AS expired_count
FROM signature_invitation si
LEFT JOIN signature_event se
  ON se.signature_invitation_id = si.id
 AND se.event_type = 'signed'
 AND se.is_active = TRUE
WHERE si.is_active = TRUE
GROUP BY si.status;

COMMENT ON VIEW vw_signature_status_summary IS
  'M6 (055) — signature invitation status distribution + median time-to-sign. Uses signature_event.created_at (no signed_at column live) and event_type=''signed'' (S2-22-FIX-1+5).';

-- ============================================================================
-- 4.4 vw_regulatory_impact_summary  (CRIT-1-aware)
--   Open vs resolved regulatory_impact counts by impact_category + severity.
--   USED BY: fn_dashboard_legal_counsel (S4), fn_dashboard_executive (S7).
--   NOTE: uses 'resolved' BOOLEAN (NOT resolved_at — CRIT-1); resolution
--         time derived from updated_at - created_at audit columns.
-- ============================================================================
CREATE VIEW vw_regulatory_impact_summary AS
SELECT
  ic.key                                                                                              AS category_key,
  ru.severity                                                                                         AS severity,
  COUNT(*) FILTER (WHERE ri.resolved = FALSE)                                                         AS open_count,
  COUNT(*) FILTER (WHERE ri.resolved = TRUE)                                                          AS resolved_count,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (ri.updated_at - ri.created_at))/86400)
    FILTER (WHERE ri.resolved = TRUE)                                                                 AS median_time_to_resolve_days
FROM regulatory_impact ri
JOIN regulation reg            ON reg.id = ri.regulation_id
LEFT JOIN regulatory_update ru ON ru.id = ri.regulatory_update_id
LEFT JOIN impact_category ic   ON ic.id = ru.category_id
WHERE ri.is_active = TRUE
GROUP BY ic.key, ru.severity;

COMMENT ON VIEW vw_regulatory_impact_summary IS
  'M6 (055) — regulatory impact distribution by category + severity. Uses regulatory_impact.resolved BOOLEAN (CRIT-1; no resolved_at column live) and updated_at - created_at as resolution-velocity proxy.';

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (55, 'm6_dashboard_views', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP VIEW IF EXISTS vw_regulatory_impact_summary;
DROP VIEW IF EXISTS vw_signature_status_summary;
DROP VIEW IF EXISTS vw_approval_queue_metrics;
DROP VIEW IF EXISTS vw_contract_status_summary;
DELETE FROM schema_migrations WHERE version = 55;
COMMIT;
-- ROLLBACK END
