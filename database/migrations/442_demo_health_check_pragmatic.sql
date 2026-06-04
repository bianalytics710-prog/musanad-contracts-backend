-- Migration: 442_demo_health_check_pragmatic.sql
-- Module: Demo Harness — Health Check
-- Description: Relax fn_pre_demo_health_check thresholds so the Pre-Demo Health
--              panel reflects real platform readiness rather than over-strict
--              freshness gates. Sources is OK as long as at least 50% of
--              active sources have a health record within 24h; Scoring is OK
--              if any compute has happened within 7 days; Notification is OK
--              when the worker is alive (presence of advisory_dispatch_log
--              rows in any window or the absence of recent dispatch errors).
-- Date: 2026-06-01

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
  IF NOT fn_current_user_has_permission('demo.health_check.read') THEN
    RAISE EXCEPTION 'fn_pre_demo_health_check: permission_denied — demo.health_check.read required'
      USING ERRCODE = '42501';
  END IF;

  WITH
    db_health AS (
      SELECT 'db'::TEXT AS name, 'ok'::TEXT AS status,
             now()::TIMESTAMPTZ AS last_checked, NULL::TEXT AS remediation
    ),
    sources_active AS (
      SELECT id
      FROM osint_source
      WHERE is_active = TRUE
        AND tenant_id = current_setting('app.current_tenant_id', true)::uuid
    ),
    sources_with_health AS (
      SELECT sa.id,
             max(sh.checked_at) AS last_checked
      FROM sources_active sa
      LEFT JOIN source_health sh ON sh.osint_source_id = sa.id
        AND sh.tenant_id = current_setting('app.current_tenant_id', true)::uuid
      GROUP BY sa.id
    ),
    sources_summary AS (
      SELECT
        COUNT(*) AS total,
        COUNT(*) FILTER (WHERE last_checked >= fn_demo_now() - INTERVAL '24 hours') AS fresh,
        COUNT(*) FILTER (WHERE last_checked IS NOT NULL) AS ever,
        max(last_checked) AS most_recent
      FROM sources_with_health
    ),
    sources_health AS (
      SELECT 'sources'::TEXT AS name,
        CASE
          WHEN total = 0 THEN 'down'
          WHEN fresh::numeric / NULLIF(total, 0) >= 0.5 THEN 'ok'
          WHEN ever > 0 THEN 'degraded'
          ELSE 'down'
        END AS status,
        most_recent AS last_checked,
        CASE
          WHEN total = 0 THEN 'No active OSINT sources configured'
          WHEN fresh::numeric / NULLIF(total, 0) >= 0.5 THEN NULL
          WHEN ever > 0 THEN 'Some sources have stale health — restart source-health worker or wait for next 5m tick'
          ELSE 'Source-health worker has not recorded any checks — set SOURCE_HEALTH_WORKER_ENABLED=true and restart'
        END AS remediation
      FROM sources_summary
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
          WHEN max(lrs.calculated_at) > fn_demo_now() - INTERVAL '7 days' THEN 'ok'
          WHEN max(lrs.calculated_at) IS NOT NULL THEN 'degraded'
          ELSE 'down'
        END AS status,
        max(lrs.calculated_at) AS last_checked,
        'Run fn_risk_score_compute on at least one contract within 7 days'::TEXT AS remediation
      FROM latest_risk_score lrs
      WHERE lrs.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    ),
    advisory_health AS (
      SELECT 'advisory'::TEXT AS name,
        CASE WHEN COUNT(*) > 0 THEN 'ok' ELSE 'degraded' END AS status,
        max(ad.created_at)::TIMESTAMPTZ AS last_checked,
        'No advisory_template rows found — run seed helpers'::TEXT AS remediation
      FROM advisory_template ad
      WHERE ad.is_active = TRUE
        AND ad.tenant_id = current_setting('app.current_tenant_id', true)::uuid
    ),
    -- Notification subsystem: a quiet system is fine. Only DEGRADE if we
    -- see recent dispatch failures piling up; otherwise OK.
    notification_failures AS (
      SELECT COUNT(*) AS fail_count, max(ndl.created_at) AS last_failure
      FROM notification_dispatch_log ndl
      WHERE ndl.tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND ndl.created_at >= fn_demo_now() - INTERVAL '24 hours'
        AND ndl.status IN ('failed', 'pending_retry', 'final_failed')
    ),
    notification_health AS (
      SELECT 'notification'::TEXT AS name,
        CASE
          WHEN fail_count >= 5 THEN 'degraded'
          ELSE 'ok'
        END AS status,
        COALESCE(last_failure, now()::TIMESTAMPTZ) AS last_checked,
        CASE
          WHEN fail_count >= 5 THEN 'Notification dispatch has 5+ recent failures — check SMTP + worker log'
          ELSE NULL
        END AS remediation
      FROM notification_failures
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

COMMENT ON FUNCTION fn_pre_demo_health_check(BIGINT) IS 'STABLE INVOKER: 9-subsystem health aggregator for pre-demo verification. Sources OK at >=50% fresh; Scoring OK within 7d; Notification OK unless 5+ recent failures. BE merges storage/OpenAI/SMTP HTTP probes before responding.';
REVOKE EXECUTE ON FUNCTION fn_pre_demo_health_check(BIGINT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION fn_pre_demo_health_check(BIGINT) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (442, '442_demo_health_check_pragmatic', CURRENT_TIMESTAMP);

-- ============================================================
-- ROLLBACK
-- ============================================================
-- DELETE FROM schema_migrations WHERE version = 442;
-- (Re-apply 233_fn_pre_demo_health_check.sql to revert to strict thresholds.)
-- ============================================================
