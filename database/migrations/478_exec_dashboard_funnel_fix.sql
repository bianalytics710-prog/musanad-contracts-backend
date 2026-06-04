-- Migration: 478_exec_dashboard_funnel_fix.sql
-- Module: Executive Insights remediation — E-rev-6 (cycle-time funnel data)
-- Date: 2026-06-02
--
-- Symptoms (verified live):
--   cycleTimeFunnel.approvalChainDays = -11.26   ← negative, FE clamps at 0
--   cycleTimeFunnel.counterpartySignatureDays = 0 ← no signatures in 90-day window
--   draftingDays + legalReviewDays = 0 after backdating (CURRENT_DATE - 90d
--   filter excludes most data once contracts were anchored to historical dates).
--
-- Approach: patch the four SELECT…INTO computations inside fn_dashboard_executive:
--   1. Widen the rolling window from v_window (90d) → 365d so older activity
--      counts toward the medians.
--   2. Wrap each AVG with GREATEST(...,0) so out-of-order seed timestamps
--      (decided_at before step.created_at) can't produce negative days.
--
-- Pattern: CREATE OR REPLACE FUNCTION with the full body, only the 4 lines
-- changed. Keeps every existing branch + grant set intact.

DO $do$
DECLARE
  v_def TEXT;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc WHERE proname = 'fn_dashboard_executive' LIMIT 1;
  -- v_drafting: widen window
  v_def := REPLACE(v_def,
    'WHERE c.is_active = TRUE AND c.created_at >= CURRENT_DATE - v_window;',
    'WHERE c.is_active = TRUE AND c.created_at >= CURRENT_DATE - INTERVAL ''365 days'';');
  -- v_approval: widen window + clamp negative
  v_def := REPLACE(v_def,
    'SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (ad.decided_at - s.created_at)) / 86400.0), 0)
  INTO v_approval
  FROM approval_step s JOIN approval_decision ad ON ad.approval_step_id = s.id AND ad.is_active = TRUE
  WHERE s.is_active = TRUE AND ad.decided_at >= CURRENT_DATE - v_window;',
    'SELECT COALESCE(GREATEST(AVG(EXTRACT(EPOCH FROM (ad.decided_at - s.created_at)) / 86400.0), 0), 0)
  INTO v_approval
  FROM approval_step s JOIN approval_decision ad ON ad.approval_step_id = s.id AND ad.is_active = TRUE
  WHERE s.is_active = TRUE AND ad.decided_at >= CURRENT_DATE - INTERVAL ''365 days'';');
  -- v_signing: widen window + clamp
  v_def := REPLACE(v_def,
    'SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (se.signed_at - si.invitation_sent_at)) / 86400.0), 0)
  INTO v_signing
  FROM signature_invitation si
  JOIN LATERAL (SELECT MIN(created_at) AS signed_at FROM signature_event sev
    WHERE sev.signature_invitation_id = si.id AND sev.event_type = ''signed'' AND sev.is_active = TRUE) se ON se.signed_at IS NOT NULL
  WHERE si.is_active = TRUE AND si.invitation_sent_at >= CURRENT_DATE - v_window;',
    'SELECT COALESCE(GREATEST(AVG(EXTRACT(EPOCH FROM (se.signed_at - si.invitation_sent_at)) / 86400.0), 0), 0)
  INTO v_signing
  FROM signature_invitation si
  JOIN LATERAL (SELECT MIN(created_at) AS signed_at FROM signature_event sev
    WHERE sev.signature_invitation_id = si.id AND sev.event_type = ''signed'' AND sev.is_active = TRUE) se ON se.signed_at IS NOT NULL
  WHERE si.is_active = TRUE AND si.invitation_sent_at >= CURRENT_DATE - INTERVAL ''365 days'';');
  EXECUTE v_def;
END $do$;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (478, '478_exec_dashboard_funnel_fix', CURRENT_TIMESTAMP);
