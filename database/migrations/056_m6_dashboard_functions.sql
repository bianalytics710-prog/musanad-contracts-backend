-- ============================================================================
-- 056_m6_dashboard_functions.sql
-- ============================================================================
-- Module:    M6 (Dashboards & Reporting)
-- Owner:     Agent 6 — DB Implementation
-- Depends:   054 (insights.executive permission + grants + ARCH-NEW-3 RLS)
--            055 (4 plain VIEWs)
-- ----------------------------------------------------------------------------
-- 10 read-only fn_'s. ALL SECURITY INVOKER. ALL with REVOKE FROM PUBLIC +
-- GRANT EXECUTE TO neondb_owner only. Zero new PUBLIC EXECUTE grants
-- (S2-21 baseline = 5 preserved — sixth-consecutive-clean module).
--
-- Functions:
--   fn_dashboard_admin                          (S1, S13)
--   fn_dashboard_drafter                        (S2)
--   fn_dashboard_approver                       (S3)
--   fn_dashboard_legal_counsel                  (S4) — CRIT-1 + CRIT-4 locked
--   fn_dashboard_recipient                      (S5)
--   fn_dashboard_router                         (S6)
--   fn_dashboard_executive                      (S7) — INVOKER (CRIT-3 confirmed)
--   fn_dashboard_executive_anomalies_history    (S8)
--   fn_dashboard_ai_cost_summary                (S11)
--   fn_health_check                             (S12) — INVOKER (ARCH-NEW-3 (c))
--
-- All column references verified against live DDL post-Patch-Round-1.
-- ----------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 3.1 fn_dashboard_admin (S1, S13)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_dashboard_admin(
  p_window_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id   BIGINT;
  v_role      TEXT;
  v_window    INTEGER;
  v_kpis      JSONB;
  v_trends    JSONB;
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

  -- KPIs
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

  -- Trends
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

  RETURN jsonb_build_object('kpis', v_kpis, 'trends', v_trends);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_admin: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_admin(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_admin(INTEGER) TO neondb_owner;


-- ============================================================================
-- 3.2 fn_dashboard_drafter (S2)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_dashboard_drafter(
  p_window_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id BIGINT;
  v_role    TEXT;
  v_window  INTEGER;
  v_kpis    JSONB;
  v_lists   JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('contract_drafter', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: forbidden — drafter dashboard restricted to contract_drafter, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'myDraftsCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id AND status = 'draft' AND is_active = TRUE),
    'awaitingMyActionCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id
          AND status IN ('draft','resubmission_requested')
          AND is_active = TRUE),
    'readyToSendCount',
      (SELECT COUNT(*) FROM contract c
        WHERE c.drafted_by = v_user_id
          AND c.status = 'approved'
          AND c.is_active = TRUE
          AND NOT EXISTS (
            SELECT 1 FROM signature_invitation si
            WHERE si.contract_id = c.id AND si.is_active = TRUE
          )),
    'myRecentlyApprovedCount',
      (SELECT COUNT(*) FROM contract
        WHERE drafted_by = v_user_id AND status = 'approved'
          AND updated_at >= NOW() - (v_window || ' days')::INTERVAL
          AND is_active = TRUE)
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'myDrafts5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'status', c.status,
          'valueAed', c.value_aed,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id AND status = 'draft' AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb),
    'awaitingMyAction5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', c.id,
          'contractNumber', c.contract_number,
          'titleEn', c.title_en,
          'titleAr', c.title_ar,
          'status', c.status,
          'updatedAt', c.updated_at
        ) ORDER BY c.updated_at DESC)
        FROM (
          SELECT * FROM contract
          WHERE drafted_by = v_user_id
            AND status IN ('draft','resubmission_requested')
            AND is_active = TRUE
          ORDER BY updated_at DESC LIMIT 5
        ) c
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_drafter: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_drafter(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_drafter(INTEGER) TO neondb_owner;


-- ============================================================================
-- 3.3 fn_dashboard_approver (S3)
--   PATCH ROUND 1: live approval_step has no assigned_to/assigned_at;
--   effective-assignee = COALESCE(delegated_to, reassigned_to, approver_user_id).
--   live approval_decision uses decided_by (NOT decider_user_id).
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_dashboard_approver(
  p_window_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id BIGINT;
  v_role    TEXT;
  v_window  INTEGER;
  v_kpis    JSONB;
  v_lists   JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_approver: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_approver: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('contract_approver', 'contract_approver_2', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_approver: forbidden — approver dashboard restricted to contract_approver, contract_approver_2, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'pendingMyApprovalCount',
      (SELECT COUNT(*) FROM approval_step
        WHERE COALESCE(delegated_to, reassigned_to, approver_user_id) IS NOT DISTINCT FROM v_user_id
          AND status = 'pending' AND is_active = TRUE),
    'decidedByMeCount',
      (SELECT COUNT(*) FROM approval_decision
        WHERE decided_by = v_user_id
          AND decided_at >= NOW() - (v_window || ' days')::INTERVAL
          AND is_active = TRUE),
    'averageDecisionHoursMine',
      (SELECT AVG(EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0)::NUMERIC(12,2)
       FROM approval_decision ad
       JOIN approval_step step ON step.id = ad.approval_step_id
       WHERE ad.decided_by = v_user_id
         AND ad.decided_at >= NOW() - (v_window || ' days')::INTERVAL
         AND ad.is_active = TRUE),
    'averageDecisionHoursTeam',
      (SELECT AVG(EXTRACT(EPOCH FROM (ad.decided_at - step.created_at))/3600.0)::NUMERIC(12,2)
       FROM approval_decision ad
       JOIN approval_step step ON step.id = ad.approval_step_id
       JOIN "user" u ON u.id = ad.decided_by
       JOIN role  r ON r.id = u.role_id
       WHERE ad.decided_by != v_user_id
         AND r.name = v_role
         AND ad.decided_at >= NOW() - (v_window || ' days')::INTERVAL
         AND ad.is_active = TRUE)
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'pendingQueue5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'stepId', q.step_id,
          'contractId', q.contract_id,
          'contractNumber', q.contract_number,
          'titleEn', q.title_en,
          'titleAr', q.title_ar,
          'valueAed', q.value_aed,
          'requestedAt', q.requested_at,
          'hoursWaiting', q.hours_waiting
        ) ORDER BY q.requested_at ASC)
        FROM (
          SELECT step.id AS step_id,
                 step.contract_id AS contract_id,
                 c.contract_number,
                 c.title_en,
                 c.title_ar,
                 c.value_aed,
                 step.created_at AS requested_at,
                 ROUND((EXTRACT(EPOCH FROM (NOW() - step.created_at))/3600.0)::NUMERIC, 2) AS hours_waiting
          FROM approval_step step
          JOIN contract c ON c.id = step.contract_id AND c.is_active = TRUE
          WHERE COALESCE(step.delegated_to, step.reassigned_to, step.approver_user_id) IS NOT DISTINCT FROM v_user_id
            AND step.status = 'pending'
            AND step.is_active = TRUE
          ORDER BY step.created_at ASC
          LIMIT 5
        ) q
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_approver: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_approver(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_approver(INTEGER) TO neondb_owner;


-- ============================================================================
-- 3.4 fn_dashboard_legal_counsel (S4) — CRIT-1 + CRIT-4 locked
--   CRIT-1: regulatory_impact.resolved BOOLEAN (NOT resolved_at).
--   CRIT-4: uses 'audit.read' (live seeded code) — NOT 'audit.read.all' (M4 drift, ARCH-NEW-1 carry-forward).
--   PATCH ROUND 1 S2-22-FIX-4: audit_log column is table_name (NOT entity_type).
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_dashboard_legal_counsel(
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
  v_has_audit_read BOOLEAN;
  v_kpis           JSONB;
  v_lists          JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('legal_counsel', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: forbidden — legal counsel dashboard restricted to legal_counsel, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  v_has_audit_read := fn_current_user_has_permission('audit.read');

  SELECT jsonb_build_object(
    'regulatoryUpdatesThisWindow',
      (SELECT COUNT(*) FROM regulatory_update
        WHERE published_date >= CURRENT_DATE - v_window
          AND is_active = TRUE),
    'openRegulatoryImpacts',
      (SELECT COUNT(*) FROM regulatory_impact
        WHERE resolved = FALSE AND is_active = TRUE),
    'criticalSeverityCount',
      (SELECT COUNT(*) FROM regulatory_update ru
       JOIN regulatory_impact ri ON ri.regulatory_update_id = ru.id
       WHERE ru.severity = 'critical'
         AND ri.resolved = FALSE
         AND ru.is_active = TRUE
         AND ri.is_active = TRUE),
    'regulationCatalogSize',
      (SELECT COUNT(*) FROM regulation WHERE is_active = TRUE),
    'templateUsageThisWindow',
      jsonb_build_object('value', 0, 'placeholder', true),
    'auditSummary',
      CASE WHEN v_has_audit_read THEN
        COALESCE((
          SELECT jsonb_object_agg(table_name, cnt)
          FROM (
            SELECT table_name, COUNT(*) AS cnt
            FROM audit_log
            WHERE changed_at >= NOW() - (v_window || ' days')::INTERVAL
            GROUP BY table_name
          ) s
        ), '{}'::jsonb)
      ELSE NULL END
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'recentRegulatoryUpdates5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', x.id,
          'titleEn', x.title_en,
          'severity', x.severity,
          'effectiveDate', x.effective_date,
          'regulator', CASE WHEN x.reg_id IS NULL THEN NULL ELSE
            jsonb_build_object('id', x.reg_id, 'nameEn', x.reg_name_en)
          END
        ) ORDER BY x.effective_date DESC NULLS LAST, x.published_date DESC)
        FROM (
          SELECT ru.id, ru.title_en, ru.severity, ru.effective_date, ru.published_date,
                 r.id AS reg_id, r.name_en AS reg_name_en
          FROM regulatory_update ru
          LEFT JOIN regulator r ON r.id = ru.regulator_id
          WHERE ru.is_active = TRUE
          ORDER BY ru.effective_date DESC NULLS LAST, ru.published_date DESC
          LIMIT 5
        ) x
      ), '[]'::jsonb),
    'openImpacts5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', x.id,
          'contractId', x.contract_id,
          'contractNumber', x.contract_number,
          'regulationTitleEn', x.regulation_title_en,
          'severity', COALESCE(x.severity, 'unknown'),
          'detectedAt', x.detected_at
        ) ORDER BY x.detected_at DESC)
        FROM (
          SELECT ri.id, ri.contract_id, c.contract_number,
                 reg.title_en AS regulation_title_en,
                 ru.severity, ri.detected_at
          FROM regulatory_impact ri
          JOIN contract c ON c.id = ri.contract_id
          JOIN regulation reg ON reg.id = ri.regulation_id
          LEFT JOIN regulatory_update ru ON ru.id = ri.regulatory_update_id
          WHERE ri.resolved = FALSE AND ri.is_active = TRUE
          ORDER BY ri.detected_at DESC
          LIMIT 5
        ) x
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_legal_counsel: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_legal_counsel(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_legal_counsel(INTEGER) TO neondb_owner;


-- ============================================================================
-- 3.5 fn_dashboard_recipient (S5)
--   PATCH ROUND 1: signature_event uses actor_user_id / created_at / event_type;
--   signature_invitation uses invitation_sent_at / invitation_expires_at.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_dashboard_recipient(
  p_window_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id BIGINT;
  v_email   TEXT;
  v_role    TEXT;
  v_window  INTEGER;
  v_kpis    JSONB;
  v_lists   JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name, u.email INTO v_role, v_email
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('contract_recipient', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: forbidden — recipient dashboard restricted to contract_recipient, platform_admin, Super Admin' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'myContractsCount',
      (SELECT COUNT(DISTINCT c.id) FROM contract c
        WHERE c.is_active = TRUE
          AND v_email IS NOT NULL
          AND EXISTS (
            SELECT 1 FROM signature_party sp
            WHERE sp.contract_id = c.id
              AND lower(sp.signer_email) = lower(v_email)
              AND sp.is_active = TRUE
          )),
    'pendingMySignatureCount',
      (SELECT COUNT(*) FROM signature_invitation si
       JOIN signature_party sp ON sp.id = si.signature_party_id
       WHERE v_email IS NOT NULL
         AND lower(sp.signer_email) = lower(v_email)
         AND si.status = 'pending'
         AND si.is_active = TRUE
         AND sp.is_active = TRUE),
    'signedByMeWindow',
      (SELECT COUNT(*) FROM signature_event se
       WHERE se.actor_user_id = v_user_id
         AND se.created_at >= NOW() - (v_window || ' days')::INTERVAL
         AND se.event_type = 'signed'
         AND se.is_active = TRUE),
    'myObligationsCount',
      jsonb_build_object('value', 0, 'placeholder', true)
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'myContracts5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', x.id,
          'contractNumber', x.contract_number,
          'titleEn', x.title_en,
          'titleAr', x.title_ar,
          'status', x.status,
          'ourPartyId', x.our_party_id,
          'counterpartyId', NULL
        ) ORDER BY x.updated_at DESC)
        FROM (
          SELECT DISTINCT ON (c.id)
                 c.id, c.contract_number, c.title_en, c.title_ar,
                 c.status, c.updated_at, sp.id AS our_party_id
          FROM contract c
          JOIN signature_party sp ON sp.contract_id = c.id
          WHERE c.is_active = TRUE
            AND v_email IS NOT NULL
            AND lower(sp.signer_email) = lower(v_email)
            AND sp.is_active = TRUE
          ORDER BY c.id, c.updated_at DESC
          LIMIT 5
        ) x
      ), '[]'::jsonb),
    'pendingSignatures5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'invitationId', x.invitation_id,
          'contractId', x.contract_id,
          'contractNumber', x.contract_number,
          'sentAt', x.sent_at,
          'expiresAt', x.expires_at
        ) ORDER BY x.sent_at DESC)
        FROM (
          SELECT si.id AS invitation_id,
                 si.contract_id,
                 c.contract_number,
                 si.invitation_sent_at AS sent_at,
                 si.invitation_expires_at AS expires_at
          FROM signature_invitation si
          JOIN signature_party sp ON sp.id = si.signature_party_id
          JOIN contract c ON c.id = si.contract_id
          WHERE v_email IS NOT NULL
            AND lower(sp.signer_email) = lower(v_email)
            AND si.status = 'pending'
            AND si.is_active = TRUE
            AND sp.is_active = TRUE
          ORDER BY si.invitation_sent_at DESC
          LIMIT 5
        ) x
      ), '[]'::jsonb)
  ) INTO v_lists;

  RETURN jsonb_build_object('kpis', v_kpis, 'lists', v_lists);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_recipient: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_recipient(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_recipient(INTEGER) TO neondb_owner;


-- ============================================================================
-- 3.6 fn_dashboard_router (S6)
--   PATCH ROUND 1 S2-22-WARN-3-FIX: defensive COALESCE chain for v_role
--   (live fn_user_get_by_id returns nested role:{id,name}, NOT flat roleName).
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_dashboard_router()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id   BIGINT;
  v_user      JSONB;
  v_role      TEXT;
  v_dash_key  TEXT;
  v_perms     JSONB;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_router: unauthorized' USING ERRCODE = '42501';
  END IF;

  v_user := fn_user_get_by_id(v_user_id);
  IF v_user IS NULL OR v_user = 'null'::jsonb THEN
    RAISE EXCEPTION 'fn_dashboard_router: user not found' USING ERRCODE = '42501';
  END IF;

  -- Live fn_user_get_by_id returns nested 'role':{id,name}; defensive fallbacks.
  v_role := COALESCE(v_user->'role'->>'name', v_user->>'roleName', 'unknown');

  v_dash_key := CASE
    WHEN v_role = 'Super Admin'                                  THEN 'admin'
    WHEN v_role = 'platform_admin'                               THEN 'admin'
    WHEN v_role = 'legal_counsel'                                THEN 'legal_counsel'
    WHEN v_role = 'contract_drafter'                             THEN 'drafter'
    WHEN v_role IN ('contract_approver', 'contract_approver_2')  THEN 'approver'
    WHEN v_role = 'contract_recipient'                           THEN 'recipient'
    WHEN v_role = 'executive'                                    THEN 'executive'
    ELSE 'recipient'
  END;

  v_perms := jsonb_build_object(
    'canViewAdminDashboard',     v_role IN ('platform_admin', 'Super Admin'),
    'canViewExecutiveDashboard', v_role IN ('executive', 'platform_admin', 'Super Admin')
  );

  RETURN jsonb_build_object(
    'userId', v_user_id,
    'primaryRole', v_role,
    'dashboardKey', v_dash_key,
    'permissionsSummary', v_perms
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_router: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_router() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_router() TO neondb_owner;


-- ============================================================================
-- 3.7 fn_dashboard_executive (S7) — CRIT-3 INVOKER LOCK
--   CRIT-3 confirmed: contract_select_role_aware line 18 includes 'executive'.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_dashboard_executive(
  p_window_days INTEGER DEFAULT 90
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id     BIGINT;
  v_role        TEXT;
  v_window      INTEGER;
  v_has_ai_obs  BOOLEAN;
  v_has_exec    BOOLEAN;
  v_from        DATE;
  v_to          DATE;
  v_cost_report JSONB;
  v_ai_cost     NUMERIC;
  v_kpis        JSONB;
  v_trends      JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 90);
  IF v_window < 1 OR v_window > 365 THEN
    RAISE EXCEPTION 'fn_dashboard_executive: windowDays must be between 1 and 365' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  v_has_exec := fn_current_user_has_permission('insights.executive');

  IF NOT (
    (v_role IS NOT NULL AND v_role IN ('executive', 'platform_admin', 'Super Admin'))
    OR v_has_exec
  ) THEN
    RAISE EXCEPTION 'fn_dashboard_executive: forbidden — executive dashboard restricted to executive, platform_admin, Super Admin or insights.executive permission' USING ERRCODE = '42501';
  END IF;

  -- AI cost panel — only if caller has ai.observability.read; capped at 90 days
  v_has_ai_obs := fn_current_user_has_permission('ai.observability.read');
  IF v_has_ai_obs THEN
    v_to   := CURRENT_DATE;
    v_from := CURRENT_DATE - LEAST(v_window, 90);
    BEGIN
      v_cost_report := fn_ai_request_log_cost_report(v_from, v_to, FALSE);
      SELECT COALESCE(SUM((elem->>'totalCostUsdMicros')::BIGINT), 0) / 1000000.0
      INTO v_ai_cost
      FROM jsonb_array_elements(COALESCE(v_cost_report->'data', '[]'::jsonb)) AS elem;
    EXCEPTION
      WHEN OTHERS THEN
        v_ai_cost := NULL;
    END;
  ELSE
    v_ai_cost := NULL;
  END IF;

  SELECT jsonb_build_object(
    'totalActiveValueAed',
      (SELECT COALESCE(SUM(value_aed), 0) FROM contract
        WHERE is_active = TRUE
          AND status NOT IN ('cancelled','expired','rejected')),
    'contractsByStatus',
      COALESCE((
        SELECT jsonb_object_agg(status, contract_count)
        FROM vw_contract_status_summary
      ), '{}'::jsonb),
    'expiryCliffs',
      jsonb_build_object(
        'next30d', (SELECT COUNT(*) FROM contract
                     WHERE is_active = TRUE
                       AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days'),
        'next60d', (SELECT COUNT(*) FROM contract
                     WHERE is_active = TRUE
                       AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '60 days'),
        'next90d', (SELECT COUNT(*) FROM contract
                     WHERE is_active = TRUE
                       AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '90 days')
      ),
    'topCounterpartiesByValue5',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'counterpartyId', x.counterparty_id,
          'totalValueAed', x.total_value_aed,
          'contractCount', x.contract_count
        ) ORDER BY x.total_value_aed DESC)
        FROM (
          SELECT counterparty_id,
                 COALESCE(SUM(value_aed), 0) AS total_value_aed,
                 COUNT(*) AS contract_count
          FROM contract
          WHERE is_active = TRUE AND counterparty_id IS NOT NULL
          GROUP BY counterparty_id
          ORDER BY total_value_aed DESC
          LIMIT 5
        ) x
      ), '[]'::jsonb),
    'valueDistribution',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('bucket', bucket, 'count', cnt) ORDER BY ord)
        FROM (
          SELECT '<100k'::TEXT AS bucket, 1 AS ord,
                 (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND COALESCE(value_aed, 0) < 100000) AS cnt
          UNION ALL
          SELECT '100k-1M', 2,
                 (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND value_aed >= 100000 AND value_aed < 1000000)
          UNION ALL
          SELECT '1M-10M', 3,
                 (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND value_aed >= 1000000 AND value_aed < 10000000)
          UNION ALL
          SELECT '10M+', 4,
                 (SELECT COUNT(*) FROM contract WHERE is_active = TRUE AND value_aed >= 10000000)
        ) buckets
      ), '[]'::jsonb),
    'openRegulatoryImpactsCritical',
      (SELECT COUNT(*) FROM regulatory_impact ri
       JOIN regulatory_update ru ON ru.id = ri.regulatory_update_id
       WHERE ri.resolved = FALSE AND ri.is_active = TRUE
         AND ru.severity = 'critical' AND ru.is_active = TRUE),
    'aiCostUsdWindow', v_ai_cost
  ) INTO v_kpis;

  SELECT jsonb_build_object(
    'valueOverTimeByMonth',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'month', to_char(month_start, 'YYYY-MM'),
          'totalValueAed', COALESCE(c.total_value_aed, 0)
        ) ORDER BY month_start)
        FROM generate_series(
          date_trunc('month', CURRENT_DATE - v_window),
          date_trunc('month', CURRENT_DATE),
          INTERVAL '1 month'
        ) AS gs(month_start)
        LEFT JOIN (
          SELECT date_trunc('month', created_at) AS m, SUM(value_aed) AS total_value_aed
          FROM contract
          WHERE is_active = TRUE
            AND created_at >= CURRENT_DATE - v_window
          GROUP BY 1
        ) c ON c.m = month_start
      ), '[]'::jsonb),
    'contractsCreatedByMonth',
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'month', to_char(month_start, 'YYYY-MM'),
          'count', COALESCE(c.cnt, 0)
        ) ORDER BY month_start)
        FROM generate_series(
          date_trunc('month', CURRENT_DATE - v_window),
          date_trunc('month', CURRENT_DATE),
          INTERVAL '1 month'
        ) AS gs(month_start)
        LEFT JOIN (
          SELECT date_trunc('month', created_at) AS m, COUNT(*) AS cnt
          FROM contract
          WHERE is_active = TRUE
            AND created_at >= CURRENT_DATE - v_window
          GROUP BY 1
        ) c ON c.m = month_start
      ), '[]'::jsonb)
  ) INTO v_trends;

  RETURN jsonb_build_object('kpis', v_kpis, 'trends', v_trends);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_executive: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_executive(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_executive(INTEGER) TO neondb_owner;


-- ============================================================================
-- 3.8 fn_dashboard_executive_anomalies_history (S8)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_dashboard_executive_anomalies_history(
  p_limit INTEGER DEFAULT 10
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id   BIGINT;
  v_role      TEXT;
  v_limit     INTEGER;
  v_result    JSONB;
  v_anomalies JSONB;
BEGIN
  v_limit := COALESCE(p_limit, 10);
  IF v_limit < 1 OR v_limit > 50 THEN
    RAISE EXCEPTION 'fn_dashboard_executive_anomalies_history: limit must be between 1 and 50' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_executive_anomalies_history: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('executive', 'platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_dashboard_executive_anomalies_history: forbidden' USING ERRCODE = '42501';
  END IF;

  v_result := fn_ai_insight_list(
    1,                        -- p_page
    v_limit,                  -- p_limit
    'executive_anomalies',    -- p_entity_type
    NULL,                     -- p_insight_type
    NULL,                     -- p_language
    NULL,                     -- p_provider
    FALSE                     -- p_include_expired
  );

  v_anomalies := COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', elem->'id',
      'summaryEn', elem->'summaryEn',
      'summaryAr', elem->'summaryAr',
      'severity', elem->'severity',
      'detectedAt', elem->'createdAt',
      'payload', elem->'payload'
    ))
    FROM jsonb_array_elements(COALESCE(v_result->'data', '[]'::jsonb)) AS elem
  ), '[]'::jsonb);

  RETURN jsonb_build_object('anomalies', v_anomalies);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_executive_anomalies_history: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_executive_anomalies_history(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_executive_anomalies_history(INTEGER) TO neondb_owner;


-- ============================================================================
-- 3.9 fn_dashboard_ai_cost_summary (S11)
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_dashboard_ai_cost_summary(
  p_window_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id    BIGINT;
  v_window     INTEGER;
  v_has_ai_obs BOOLEAN;
  v_from       DATE;
  v_to         DATE;
  v_report     JSONB;
  v_total_cost      NUMERIC;
  v_total_requests  BIGINT;
  v_top5            JSONB;
BEGIN
  v_window := COALESCE(p_window_days, 30);
  IF v_window < 1 OR v_window > 90 THEN
    RAISE EXCEPTION 'fn_dashboard_ai_cost_summary: windowDays must be between 1 and 90' USING ERRCODE = '22023';
  END IF;

  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_dashboard_ai_cost_summary: unauthorized' USING ERRCODE = '42501';
  END IF;

  v_has_ai_obs := fn_current_user_has_permission('ai.observability.read');
  IF NOT v_has_ai_obs THEN
    RAISE EXCEPTION 'fn_dashboard_ai_cost_summary: forbidden — requires ai.observability.read' USING ERRCODE = '42501';
  END IF;

  v_to   := CURRENT_DATE;
  v_from := CURRENT_DATE - v_window;
  v_report := fn_ai_request_log_cost_report(v_from, v_to, FALSE);

  SELECT
    COALESCE(SUM((elem->>'totalCostUsdMicros')::BIGINT), 0) / 1000000.0,
    COALESCE(SUM(COALESCE((elem->>'successCount')::BIGINT, 0) + COALESCE((elem->>'errorCount')::BIGINT, 0)), 0)
  INTO v_total_cost, v_total_requests
  FROM jsonb_array_elements(COALESCE(v_report->'data', '[]'::jsonb)) AS elem;

  v_top5 := COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'promptId', elem->'promptId',
      'requestCount', COALESCE((elem->>'successCount')::BIGINT, 0) + COALESCE((elem->>'errorCount')::BIGINT, 0),
      'totalCostUsd', COALESCE((elem->>'totalCostUsdMicros')::BIGINT, 0) / 1000000.0,
      'cacheHitRatio', elem->'cacheHitRatio'
    ) ORDER BY COALESCE((elem->>'totalCostUsdMicros')::BIGINT, 0) DESC)
    FROM (
      SELECT elem
      FROM jsonb_array_elements(COALESCE(v_report->'data', '[]'::jsonb)) AS elem
      ORDER BY COALESCE((elem->>'totalCostUsdMicros')::BIGINT, 0) DESC
      LIMIT 5
    ) ranked
  ), '[]'::jsonb);

  RETURN jsonb_build_object(
    'totalCostUsdWindow', v_total_cost,
    'totalRequestsWindow', v_total_requests,
    'cacheHitRatioOverall',
      CASE WHEN v_total_requests > 0 THEN
        (SELECT COALESCE(SUM(COALESCE((elem->>'cacheHitCount')::BIGINT, 0)), 0)::NUMERIC / v_total_requests
         FROM jsonb_array_elements(COALESCE(v_report->'data', '[]'::jsonb)) AS elem)
      ELSE NULL END,
    'topPromptsByCost5', v_top5
  );

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN invalid_parameter_value THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_dashboard_ai_cost_summary: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_dashboard_ai_cost_summary(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_dashboard_ai_cost_summary(INTEGER) TO neondb_owner;


-- ============================================================================
-- 3.10 fn_health_check (S12) — ARCH-NEW-3 OPTION (c) — INVOKER
--   Reads schema_migrations via the new schema_migrations_select_admin
--   policy (added in 054). Audit probe DROPPED per Patch Round 1
--   S2-22-WARN-2-FIX (audit_log.action enum is INSERT/UPDATE/DELETE only).
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_health_check()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
AS $fn$
DECLARE
  v_user_id     BIGINT;
  v_role        TEXT;
  v_db          JSONB;
  v_ai          JSONB;
  v_overall     TEXT;
  v_in_recovery BOOLEAN;
  v_latest_mig  INTEGER;
  v_last_succ   TIMESTAMPTZ;
  v_last_fail   TIMESTAMPTZ;
  v_healthy     BOOLEAN;
BEGIN
  v_user_id := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'fn_health_check: unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT r.name INTO v_role
  FROM "user" u JOIN role r ON r.id = u.role_id
  WHERE u.id = v_user_id AND u.is_active = TRUE AND r.is_active = TRUE;

  IF v_role IS NULL OR v_role NOT IN ('platform_admin', 'Super Admin') THEN
    RAISE EXCEPTION 'fn_health_check: forbidden — health check restricted to platform_admin and Super Admin' USING ERRCODE = '42501';
  END IF;

  -- DB probe — schema_migrations.MAX(version) requires schema_migrations_select_admin (054)
  v_in_recovery := pg_is_in_recovery();
  SELECT MAX(version) INTO v_latest_mig FROM schema_migrations;

  v_db := jsonb_build_object(
    'status', CASE WHEN NOT v_in_recovery THEN 'ok' ELSE 'degraded' END,
    'latestMigration', v_latest_mig,
    'currentTimestamp', CURRENT_TIMESTAMP
  );

  -- AI probe — canonical error source per ai_request_log.outcome enum
  SELECT MAX(created_at) INTO v_last_succ
  FROM ai_request_log WHERE outcome = 'success';

  SELECT MAX(created_at) INTO v_last_fail
  FROM ai_request_log
  WHERE outcome IN ('error','timeout','rate_limited','cancelled');

  v_healthy := (v_last_succ IS NOT NULL
                AND (v_last_fail IS NULL OR v_last_succ > v_last_fail));

  v_ai := jsonb_build_object(
    'lastSuccessfulRequestAt', v_last_succ,
    'lastFailureAt', v_last_fail,
    'estimatedHealthy', v_healthy
  );

  v_overall := CASE
    WHEN (v_db->>'status') <> 'ok' THEN 'unhealthy'
    WHEN v_healthy = FALSE         THEN 'degraded'
    ELSE 'ok'
  END;

  RETURN jsonb_build_object('db', v_db, 'ai', v_ai, 'overall', v_overall);

EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RAISE EXCEPTION 'fn_health_check: %', SQLERRM USING ERRCODE = SQLSTATE;
END;
$fn$;

REVOKE ALL ON FUNCTION fn_health_check() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_health_check() TO neondb_owner;


INSERT INTO schema_migrations (version, description, applied_at)
VALUES (56, 'm6_dashboard_functions', CURRENT_TIMESTAMP)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- ============================================================================
-- ROLLBACK BEGIN
-- ============================================================================
BEGIN;
DROP FUNCTION IF EXISTS fn_health_check();
DROP FUNCTION IF EXISTS fn_dashboard_ai_cost_summary(INTEGER);
DROP FUNCTION IF EXISTS fn_dashboard_executive_anomalies_history(INTEGER);
DROP FUNCTION IF EXISTS fn_dashboard_executive(INTEGER);
DROP FUNCTION IF EXISTS fn_dashboard_router();
DROP FUNCTION IF EXISTS fn_dashboard_recipient(INTEGER);
DROP FUNCTION IF EXISTS fn_dashboard_legal_counsel(INTEGER);
DROP FUNCTION IF EXISTS fn_dashboard_approver(INTEGER);
DROP FUNCTION IF EXISTS fn_dashboard_drafter(INTEGER);
DROP FUNCTION IF EXISTS fn_dashboard_admin(INTEGER);
DELETE FROM schema_migrations WHERE version = 56;
COMMIT;
-- ROLLBACK END
