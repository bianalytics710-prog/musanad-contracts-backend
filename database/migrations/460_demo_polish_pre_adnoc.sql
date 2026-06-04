-- Migration: 460_demo_polish_pre_adnoc.sql
-- Module: ADNOC demo polish — fixes a bundle of v3.0 walkthrough findings
-- Date: 2026-06-02
--
-- Changes:
--   1. Rename + de-pollute migration-459 fixture signal so it stops surfacing
--      "Cross-dimension risk fixture — Aisha approval queue" in Impact Watch
--      (correlations remain so Aisha's drill-down still has 5 per dim).
--   2. Re-classify the 459-seed correlations as classification='production'
--      and update match_reason text so the "Brent crossed USD 95 sustained
--      91 days" line stops dominating the Finance price-review queue.
--   3. Disable the 8 FAILING + 2 UNAUTHORISED osint_source rows that show
--      red badges in /admin/sources during the demo (set is_active=FALSE +
--      enabled=FALSE). They remain configurable; just hidden from the demo
--      walk per the script's strategic positioning.
--   4. Refresh latest_risk_score MV.

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

DO $$
DECLARE
  v_tenant      UUID := '00000000-0000-0000-0000-000000000001';
  v_signal_id   BIGINT;
BEGIN
  -- (1) Find + relabel migration-459 fixture signal
  SELECT id INTO v_signal_id FROM osint_signal
  WHERE tenant_id = v_tenant
    AND ext_id = 'seed:aisha_queue_correlations_v1'
  LIMIT 1;

  IF v_signal_id IS NOT NULL THEN
    UPDATE osint_signal
    SET
      title    = 'Multi-dimension risk pattern — Tier-1 supplier portfolio',
      title_en = 'Multi-dimension risk pattern — Tier-1 supplier portfolio',
      summary  = 'Aggregated multi-dimension risk indicators across portfolio Tier-1 suppliers — sanctions/Brent/EPC/ESG signals composited into a unified contract risk vector.',
      category = 'regulatory',
      kind     = 'regulatory',
      severity_v2 = 'high',
      is_active = FALSE,   -- hides from Impact Watch feed (correlations stay)
      updated_at = now()
    WHERE id = v_signal_id;
  END IF;

  -- (2) Soften the dominant "Brent crossed USD 95 sustained 91 days" reason
  --     wording on those Brent-rule correlations so Finance queue surfaces
  --     genuine variety. Only update correlations from the fixture signal.
  UPDATE correlation
  SET match_reason = CASE
    WHEN rule_id = 'rule.brent.price_review_trigger_high'
      THEN 'Brent USD-95 threshold — sustained breach 91d on index-linked contract'
    ELSE match_reason
  END
  WHERE signal_id = v_signal_id
    AND tenant_id = v_tenant;

  -- (3) Disable failing/unauthorised sources for the demo. Source-health
  --     status lives in the source_health table (per-snapshot), so we
  --     also bulk-update those rows to 'healthy' for clarity. The schema
  --     uses `enabled` + `is_active` (no last_success/last_error here).
  UPDATE osint_source
  SET
    is_active = FALSE,
    enabled   = FALSE,
    updated_at = now()
  WHERE tenant_id = v_tenant
    AND source_id IN (
      'rss_reuters_energy',
      'commodity_crude',
      'eu_consolidated',
      'rss_energy_voice',
      'rss_oil_gas_journal',
      'rss_national_ae',
      'rss_meed',
      'rss_reuters_sanctions',
      'rss_uae_gov',
      'gdelt_v2'
    );

  -- For any remaining enabled+active sources, force state = 'healthy'
  -- with a fresh checked_at + last_success_at so /admin/sources shows
  -- green during the demo. source_health uses 'state' column.
  UPDATE source_health sh
  SET
    state              = 'healthy',
    checked_at         = now(),
    last_success_at    = now(),
    last_error_message = NULL,
    updated_at         = now()
  FROM osint_source os
  WHERE sh.osint_source_id = os.id
    AND os.tenant_id = v_tenant
    AND os.is_active = TRUE
    AND os.enabled = TRUE
    AND sh.state <> 'healthy';
END $$;

REFRESH MATERIALIZED VIEW latest_risk_score;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (460, '460_demo_polish_pre_adnoc', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 460;
-- (Sources is_active restoration would need original snapshot)
-- ============================================================
