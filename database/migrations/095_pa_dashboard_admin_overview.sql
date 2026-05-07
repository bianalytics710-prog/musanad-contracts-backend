-- ============================================================================
-- 095_pa_dashboard_admin_overview.sql
-- ============================================================================
-- Module:    R-PA1 (Platform Admin parity foundation)
-- Owner:     Lovable Modernization Agent — Platform Admin parity
-- Depends:   056 (fn_dashboard_admin), 094 (platform_admin grants).
-- ----------------------------------------------------------------------------
-- Extends fn_dashboard_admin with the four "system overview" data shapes
-- needed by the R-PA1 redesign:
--   * kpiPrev               — same KPI shape over the previous v_window for
--                             delta indicators on the 8 KPI tiles.
--   * systemHealth          — DB check, latest migration version, audit_log
--                             writes (24h), AI request errors (24h).
--   * pendingAdminActions   — counts list (approvals / signatures / imports /
--                             open regulatory impacts) for the
--                             "Pending admin actions" card.
--   * topContractTypes5     — top 5 contract types by active contract count.
--   * systemActivity14d     — admin-relevant audit_log highlights for the
--                             last 14 days (max 8 rows, mirrors events14d
--                             pattern from migration 093).
--
-- Existing kpis + trends keys preserved verbatim — FE consumers continue to
-- work against the unchanged contract.
--
-- Stage 2 standards observed:
--   S2-21 — REVOKE FROM PUBLIC + GRANT EXECUTE TO neondb_owner.
--   S2-22 — every column referenced is verified (audit_log.changed_at,
--           ai_request_log.status etc.).
--   S2-22b — JOIN target columns sourced via approval_step → approval_chain
--            → contract path (no contract_id column on step) — but this fn_
--            does not join through that path; counts are direct.
--   S2-24 — no nested aggregates; multi-step aggregates stay as inner
--           subqueries before jsonb_agg.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION fn_dashboard_admin(
  p_window_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id        BIGINT;
  v_role           TEXT;
  v_window         INTEGER;
  v_kpis           JSONB;
  v_kpi_prev       JSONB;
  v_trends         JSONB;
  v_system_health  JSONB;
  v_pending        JSONB;
  v_top_types      JSONB;
  v_activity       JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_admin: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_admin: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_admin: forbidden — admin dashboard restricted to platform_admin and Super Admin' USING ERRCODE = '42501';
  END IF;

  -- ──────────────────────────────────────────────────────────────────────
  -- KPIs (unchanged shape — FE consumers depend on these keys)
  -- ──────────────────────────────────────────────────────────────────────
  SELECT jsonb_build_object(
    'totalContractsActive',
      (SELECT COUNT(*) FROM contract WHERE is_active = TRUE),
    'totalContractsByStatus',
      COALESCE((
        SELECT jsonb_object_agg(status, contract_count)
        FROM vw_contract_status_summary
      ), '{}'::jsonb),
    'expiringWithin30d',
      (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
        AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days'),
    'expiringWithin90d',
      (SELECT COUNT(*) FROM contract WHERE is_active = TRUE
        AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days'),
    'pendingApprovals',
      (SELECT COUNT(*) FROM approval_step WHERE status = 'pending' AND is_active = TRUE),
    'pendingSignatures',
      (SELECT COUNT(*) FROM signature_invitation WHERE status = 'pending' AND is_active = TRUE),
    'openRegulatoryImpacts',
      (SELECT COUNT(*) FROM regulatory_impact WHERE resolved = FALSE AND is_active = TRUE),
    'recentAuditEvents',
      (SELECT COUNT(*) FROM audit_log WHERE changed_at >= NOW() - (v_window || ' days')::INTERVAL),
    'totalActiveUsers',
      (SELECT COUNT(*) FROM "user" WHERE is_active = TRUE)
  ) INTO v_kpis;

  -- ──────────────────────────────────────────────────────────────────────
  -- kpiPrev — same shape, computed for the previous window. Used by FE
  -- to render delta indicators on the 8 KPI tiles. Counts that are
  -- inherently "as-of-now" (e.g. totalActiveUsers) reflect their
  -- snapshot v_window days ago.
  -- ──────────────────────────────────────────────────────────────────────
  SELECT jsonb_build_object(
    'totalContractsActive',
      (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE
          AND created_at <= NOW() - (v_window || ' days')::INTERVAL),
    'expiringWithin30d',
      (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE
          AND created_at <= NOW() - (v_window || ' days')::INTERVAL
          AND end_date BETWEEN
            CURRENT_DATE - (v_window || ' days')::INTERVAL
            AND CURRENT_DATE - (v_window || ' days')::INTERVAL + INTERVAL '30 days'),
    'expiringWithin90d',
      (SELECT COUNT(*) FROM contract
        WHERE is_active = TRUE
          AND created_at <= NOW() - (v_window || ' days')::INTERVAL
          AND end_date BETWEEN
            CURRENT_DATE - (v_window || ' days')::INTERVAL
            AND CURRENT_DATE - (v_window || ' days')::INTERVAL + INTERVAL '90 days'),
    'pendingApprovals',
      (SELECT COUNT(*) FROM approval_step
        WHERE status = 'pending' AND is_active = TRUE
          AND created_at <= NOW() - (v_window || ' days')::INTERVAL),
    'pendingSignatures',
      (SELECT COUNT(*) FROM signature_invitation
        WHERE status = 'pending' AND is_active = TRUE
          AND created_at <= NOW() - (v_window || ' days')::INTERVAL),
    'openRegulatoryImpacts',
      (SELECT COUNT(*) FROM regulatory_impact
        WHERE resolved = FALSE AND is_active = TRUE
          AND created_at <= NOW() - (v_window || ' days')::INTERVAL),
    'recentAuditEvents',
      (SELECT COUNT(*) FROM audit_log
        WHERE changed_at BETWEEN
          NOW() - (2 * v_window || ' days')::INTERVAL
          AND NOW() - (v_window || ' days')::INTERVAL),
    'totalActiveUsers',
      (SELECT COUNT(*) FROM "user"
        WHERE is_active = TRUE
          AND created_at <= NOW() - (v_window || ' days')::INTERVAL)
  ) INTO v_kpi_prev;

  -- ──────────────────────────────────────────────────────────────────────
  -- Trends (unchanged)
  -- ──────────────────────────────────────────────────────────────────────
  SELECT jsonb_build_object(
    'contractsCreatedByDay',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('date', to_char(d, 'YYYY-MM-DD'), 'count', COALESCE(c.cnt, 0))
                         ORDER BY d)
        FROM generate_series(CURRENT_DATE - v_window, CURRENT_DATE, INTERVAL '1 day') AS gs(d)
        LEFT JOIN (
          SELECT date_trunc('day', created_at)::DATE AS dd, COUNT(*) AS cnt
          FROM contract
          WHERE created_at >= CURRENT_DATE - v_window AND is_active = TRUE
          GROUP BY 1
        ) c ON c.dd = gs.d
      ), '[]'::jsonb),
    'approvalDecisionsByDay',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'date', to_char(d, 'YYYY-MM-DD'),
          'approved', COALESCE(ad.approved_cnt, 0),
          'rejected', COALESCE(ad.rejected_cnt, 0)
        ) ORDER BY d)
        FROM generate_series(CURRENT_DATE - v_window, CURRENT_DATE, INTERVAL '1 day') AS gs(d)
        LEFT JOIN (
          SELECT date_trunc('day', decided_at)::DATE AS dd,
                 COUNT(*) FILTER (WHERE decision = 'approve') AS approved_cnt,
                 COUNT(*) FILTER (WHERE decision = 'reject')  AS rejected_cnt
          FROM approval_decision
          WHERE decided_at >= CURRENT_DATE - v_window AND is_active = TRUE
          GROUP BY 1
        ) ad ON ad.dd = gs.d
      ), '[]'::jsonb)
  ) INTO v_trends;

  -- ──────────────────────────────────────────────────────────────────────
  -- systemHealth — minimal liveness signal for the admin overview card.
  -- We're "ok" if this query runs (DB up, fn_ executable). Migration
  -- version comes from schema_migrations (admin-readable per 054).
  -- ──────────────────────────────────────────────────────────────────────
  SELECT jsonb_build_object(
    'dbStatus', 'ok',
    'latestMigration', COALESCE((SELECT MAX(version) FROM schema_migrations), 0),
    'auditEvents24h',
      (SELECT COUNT(*) FROM audit_log
        WHERE changed_at >= NOW() - INTERVAL '24 hours'),
    'aiErrors24h',
      (SELECT COUNT(*) FROM ai_request_log
        WHERE outcome <> 'success'
          AND is_active = TRUE
          AND created_at >= NOW() - INTERVAL '24 hours')
  ) INTO v_system_health;

  -- ──────────────────────────────────────────────────────────────────────
  -- pendingAdminActions — counts + targets for the "Pending admin actions"
  -- card.
  -- ──────────────────────────────────────────────────────────────────────
  SELECT jsonb_build_object(
    'pendingApprovals',
      (SELECT COUNT(*) FROM approval_step WHERE status = 'pending' AND is_active = TRUE),
    'pendingSignatures',
      (SELECT COUNT(*) FROM signature_invitation WHERE status = 'pending' AND is_active = TRUE),
    'pendingImports',
      (SELECT COUNT(*) FROM import_batch
        WHERE status IN ('in_progress', 'paused') AND is_active = TRUE),
    'openImpacts',
      (SELECT COUNT(*) FROM regulatory_impact WHERE resolved = FALSE AND is_active = TRUE)
  ) INTO v_pending;

  -- ──────────────────────────────────────────────────────────────────────
  -- topContractTypes5 — top 5 contract types by active contract count
  -- (excluding NULL contract_type rows). Used to render the
  -- "Top contract types" card.
  -- ──────────────────────────────────────────────────────────────────────
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'contractType', t.contract_type,
      'count', t.cnt
    ) ORDER BY t.cnt DESC, t.contract_type ASC
  ), '[]'::jsonb)
    INTO v_top_types
  FROM (
    SELECT contract_type, COUNT(*) AS cnt
    FROM contract
    WHERE is_active = TRUE AND contract_type IS NOT NULL
    GROUP BY contract_type
    ORDER BY cnt DESC, contract_type ASC
    LIMIT 5
  ) t;

  -- ──────────────────────────────────────────────────────────────────────
  -- systemActivity14d — admin-relevant audit_log highlights from the last
  -- 14 days. Mirrors the events14d shape from migration 093: occurredAt
  -- DESC, max 8 rows, normalized headline + entity reference.
  -- ──────────────────────────────────────────────────────────────────────
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'eventType',  a."eventType",
      'headline',   a.headline,
      'occurredAt', a."occurredAt",
      'entityType', a."entityType",
      'entityId',   a."entityId"
    ) ORDER BY a."occurredAt" DESC
  ), '[]'::jsonb)
    INTO v_activity
  FROM (
    SELECT
      al.table_name || '.' || lower(al.action) AS "eventType",
      CASE al.table_name
        WHEN 'user' THEN 'User ' || lower(al.action) || 'd'
        WHEN 'role' THEN 'Role ' || lower(al.action) || 'd'
        WHEN 'role_permission' THEN 'Role permissions updated'
        WHEN 'contract' THEN 'Contract ' || lower(al.action) || 'd'
        WHEN 'regulation' THEN 'Regulation ' || lower(al.action) || 'd'
        WHEN 'approval_matrix' THEN 'Approval matrix changed'
        ELSE al.table_name || ' ' || lower(al.action) || 'd'
      END AS headline,
      al.changed_at AS "occurredAt",
      al.table_name AS "entityType",
      al.record_id  AS "entityId"
    FROM audit_log al
    WHERE al.changed_at >= NOW() - INTERVAL '14 days'
      AND al.table_name IN (
        'user', 'role', 'role_permission',
        'contract', 'regulation', 'approval_matrix'
      )
    ORDER BY al.changed_at DESC
    LIMIT 8
  ) a;

  RETURN jsonb_build_object(
    'kpis',                v_kpis,
    'kpiPrev',             v_kpi_prev,
    'trends',              v_trends,
    'systemHealth',        v_system_health,
    'pendingAdminActions', v_pending,
    'topContractTypes5',   v_top_types,
    'systemActivity14d',   v_activity
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_admin: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_admin(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_admin(INTEGER) TO neondb_owner;

INSERT INTO schema_migrations (version, description, applied_at)
VALUES (95, 'pa_dashboard_admin_overview', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN (restores the 056 body — kpis + trends only)
-- ============================================================================
-- Apply 056 once more to restore the prior fn_dashboard_admin body.
-- DELETE FROM schema_migrations WHERE version = 95;
-- ROLLBACK END
