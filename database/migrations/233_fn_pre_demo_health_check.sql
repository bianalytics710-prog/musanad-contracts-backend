-- Migration: 233_fn_pre_demo_health_check.sql
-- Module: M17+M18 — Tier 2 Scenarios + Demo Harness (CR-I + CR-J)
-- Description: fn_pre_demo_health_check STABLE — 9-subsystem health aggregator.
--              Uses S2-24 split-aggregate pattern (inner per-subsystem CTEs → outer jsonb_agg).
-- Date: 2026-05-14

-- ============================================================
-- FORWARD MIGRATION
-- ============================================================

CREATE OR REPLACE FUNCTION fn_pre_demo_health_check(
  p_actor_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  -- Permission check
  IF NOT fn_current_user_has_permission('demo.health_check.read') THEN
    RAISE EXCEPTION 'fn_pre_demo_health_check: permission_denied — demo.health_check.read required'
      USING ERRCODE = '42501';
  END IF;

  -- S2-24 split-aggregate pattern: each CTE produces one row (name, status, last_checked, remediation)
  -- Outer SELECT: UNION ALL → jsonb_agg + bool_or for overallStatus (no nested aggregates)
  WITH
    db_health AS (
      SELECT 'db'::TEXT AS name, 'ok'::TEXT AS status,
             now()::TIMESTAMPTZ AS last_checked, NULL::TEXT AS remediation
    ),
    sources_health AS (
      SELECT 'sources'::TEXT AS name,
        CASE
          WHEN COUNT(*) = 0 THEN 'down'
          WHEN bool_and(sh.checked_at >= fn_demo_now() - INTERVAL '1 hour') THEN 'ok'
          WHEN bool_and(sh.checked_at IS NOT NULL) THEN 'degraded'
          ELSE 'down'
        END AS status,
        max(sh.checked_at) AS last_checked,
        'Check adapter cron + retry queue'::TEXT AS remediation
      FROM osint_source os
      LEFT JOIN source_health sh ON sh.osint_source_id = os.id
        AND sh.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      WHERE os.is_active = TRUE
        AND os.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    ),
    rules_health AS (
      SELECT 'rules'::TEXT AS name,
        CASE WHEN COUNT(*) > 0 THEN 'ok' ELSE 'down' END AS status,
        now()::TIMESTAMPTZ AS last_checked,
        'No active correlation rules — add at least one'::TEXT AS remediation
      FROM correlation_rule
      WHERE is_active = TRUE
        AND tenant_id = current_setting('app.current_tenant_id', true)::uuid
    ),
    scoring_health AS (
      SELECT 'scoring'::TEXT AS name,
        CASE
          WHEN max(lrs.calculated_at) > fn_demo_now() - INTERVAL '24 hours' THEN 'ok'
          WHEN max(lrs.calculated_at) IS NOT NULL THEN 'degraded'
          ELSE 'down'
        END AS status,
        max(lrs.calculated_at) AS last_checked,
        'Run fn_risk_score_compute manually for at least one contract'::TEXT AS remediation
      FROM latest_risk_score lrs
      WHERE lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    ),
    advisory_health AS (
      SELECT 'advisory'::TEXT AS name,
        CASE
          WHEN COUNT(*) > 0 THEN 'ok'
          ELSE 'degraded'
        END AS status,
        max(ad.created_at)::TIMESTAMPTZ AS last_checked,
        'No advisory_template rows found — run seed helpers'::TEXT AS remediation
      FROM advisory_template ad
      WHERE ad.is_active = TRUE
        AND ad.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    ),
    notification_health AS (
      SELECT 'notification'::TEXT AS name,
        CASE
          WHEN COUNT(*) > 0 THEN 'ok'
          ELSE 'degraded'
        END AS status,
        max(ndl.created_at)::TIMESTAMPTZ AS last_checked,
        'No recent notification_dispatch_log rows — notifications may not be firing'::TEXT AS remediation
      FROM notification_dispatch_log ndl
      WHERE ndl.tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND ndl.created_at >= fn_demo_now() - INTERVAL '7 days'
    ),
    storage_health AS (
      SELECT 'storage'::TEXT AS name, 'ok'::TEXT AS status, now()::TIMESTAMPTZ AS last_checked,
             'BE controller merges real probe result'::TEXT AS remediation
    ),
    openai_health AS (
      SELECT 'openai'::TEXT AS name, 'ok'::TEXT AS status, now()::TIMESTAMPTZ AS last_checked,
             'BE controller merges real probe result'::TEXT AS remediation
    ),
    smtp_health AS (
      SELECT 'smtp'::TEXT AS name, 'ok'::TEXT AS status, now()::TIMESTAMPTZ AS last_checked,
             'BE controller merges real probe result'::TEXT AS remediation
    ),
    all_subsystems AS (
      SELECT * FROM db_health
      UNION ALL SELECT * FROM sources_health
      UNION ALL SELECT * FROM rules_health
      UNION ALL SELECT * FROM scoring_health
      UNION ALL SELECT * FROM advisory_health
      UNION ALL SELECT * FROM notification_health
      UNION ALL SELECT * FROM storage_health
      UNION ALL SELECT * FROM openai_health
      UNION ALL SELECT * FROM smtp_health
    )
  SELECT jsonb_build_object(
    'subsystems', COALESCE(jsonb_agg(jsonb_build_object(
      'name', s.name,
      'status', s.status,
      'lastChecked', s.last_checked,
      'remediation', CASE WHEN s.status = 'ok' THEN NULL ELSE s.remediation END
    ) ORDER BY s.name), '[]'::jsonb),
    'overallStatus',
      CASE
        WHEN bool_or(s.status = 'down') THEN 'down'
        WHEN bool_or(s.status = 'degraded') THEN 'degraded'
        ELSE 'ok'
      END
  )
  INTO v_result
  FROM all_subsystems s;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_pre_demo_health_check: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$$;

COMMENT ON FUNCTION fn_pre_demo_health_check(BIGINT) IS 'STABLE INVOKER: 9-subsystem health aggregator for pre-demo verification. Returns DB-probeable subsystems; BE merges storage/OpenAI/SMTP HTTP probes before responding.';
REVOKE EXECUTE ON FUNCTION fn_pre_demo_health_check(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_pre_demo_health_check(BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (233, '233_fn_pre_demo_health_check', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 233;
-- DROP FUNCTION IF EXISTS fn_pre_demo_health_check(BIGINT);
-- ============================================================
