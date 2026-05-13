/**
 * Dashboards service — thin DB-passthrough for M6 (Dashboards & Reporting).
 *
 * One service function per fn_; each returns the parsed JSONB envelope.
 * Positional argument ordering is taken DIRECTLY from migration 056 fn_
 * signatures (see fn_dashboard_* declarations). Any drift here will surface
 * as a 500 at controller invocation.
 *
 *   Operational dashboards (each takes a single p_window_days INTEGER):
 *     fn_dashboard_admin                  (S1 — also reused by S13)
 *     fn_dashboard_drafter                (S2)
 *     fn_dashboard_approver               (S3 — patched in 057 for join chain)
 *     fn_dashboard_legal_counsel          (S4 — auditSummary gate on audit.read)
 *     fn_dashboard_recipient              (S5 — windowDays applies to signedByMeWindow only)
 *
 *   Routing helper (no parameters):
 *     fn_dashboard_router                 (S6 — emits userId/primaryRole/dashboardKey/permissionsSummary)
 *
 *   Executive (windowDays default 90, range 1..365; AI sub-call truncates to 90):
 *     fn_dashboard_executive              (S7 — inline aiCostUsdWindow via Q5 lock)
 *     fn_dashboard_executive_anomalies_history (S8 — limit 1..50; reads M4 ai_insight cache)
 *
 *   Cost / observability:
 *     fn_dashboard_ai_cost_summary        (S11 — gated on ai.observability.read; range 1..90)
 *
 *   Health probe (no parameters; admin-only — distinct from M0 public /api/health):
 *     fn_health_check                     (S12 — db + ai + overall composite)
 *
 * RLS context: every call passes opts.actorId so callFunction sets
 * `app.current_user_id` GUC inside the same transaction. Required by every
 * fn_ in M6 (all 10 are SECURITY INVOKER per ARCH-NEW-3 option (c)).
 *
 * Cross-module internal calls (no signature change — S2-19 N/A):
 *   - fn_dashboard_executive            CALL fn_ai_request_log_cost_report (M4)
 *                                            fn_current_user_has_permission     (M0)
 *   - fn_dashboard_ai_cost_summary      CALL fn_ai_request_log_cost_report (M4)
 *                                            fn_current_user_has_permission     (M0)
 *   - fn_dashboard_executive_anomalies_history CALL fn_ai_insight_list (M4)
 *   - fn_dashboard_router               CALL fn_user_get_by_id (M0)
 *   - All 10 M6 fn_'s                   CALL fn_current_user_has_permission (M0)
 *
 * M6-DB-IMPL-DEFECT-1 (patched in 057): fn_dashboard_approver's contract
 * join chain was corrected at runtime — the BE service module simply calls
 * the live fn_; the bug never reaches this layer.
 */
import { db } from '../database/client';
import type {
  AdminDashboardSnapshot,
  AiCostSummary,
  ApproverDashboardSnapshot,
  DashboardRouterResponse,
  DrafterDashboardSnapshot,
  ExecutiveAnomaliesHistoryResponse,
  ExecutiveDashboardSnapshot,
  HealthCheckSnapshot,
  LegalCounselDashboardSnapshot,
  RecipientDashboardSnapshot,
} from '../types/dashboards.types';

// ------------------------------------------------------------
// 1. Operational dashboards (p_window_days default 30, range 1..365)
// ------------------------------------------------------------

/** GET /api/v1/dashboards/admin → fn_dashboard_admin (S1, reused by S13). */
export const getAdminDashboard = (
  actorId: number,
  windowDays: number | undefined,
): Promise<AdminDashboardSnapshot> =>
  db.callFunction<AdminDashboardSnapshot>(
    'fn_dashboard_admin',
    [windowDays ?? null],
    { actorId },
  );

/** GET /api/v1/dashboards/drafter → fn_dashboard_drafter (S2). */
export const getDrafterDashboard = (
  actorId: number,
  windowDays: number | undefined,
): Promise<DrafterDashboardSnapshot> =>
  db.callFunction<DrafterDashboardSnapshot>(
    'fn_dashboard_drafter',
    [windowDays ?? null],
    { actorId },
  );

/** GET /api/v1/dashboards/approver → fn_dashboard_approver (S3). Live fn_ is post-057 patch. */
export const getApproverDashboard = (
  actorId: number,
  windowDays: number | undefined,
): Promise<ApproverDashboardSnapshot> =>
  db.callFunction<ApproverDashboardSnapshot>(
    'fn_dashboard_approver',
    [windowDays ?? null],
    { actorId },
  );

/**
 * GET /api/v1/dashboards/legal-counsel → fn_dashboard_legal_counsel (S4).
 *
 * auditSummary returns NULL when the caller lacks 'audit.read' permission
 * (CRIT-4 lock — the fn body checks fn_current_user_has_permission). The
 * outer envelope still returns 200; FE inspects auditSummary === null to
 * decide whether to render the audit-summary tile.
 */
export const getLegalCounselDashboard = (
  actorId: number,
  windowDays: number | undefined,
): Promise<LegalCounselDashboardSnapshot> =>
  db.callFunction<LegalCounselDashboardSnapshot>(
    'fn_dashboard_legal_counsel',
    [windowDays ?? null],
    { actorId },
  );

/** GET /api/v1/dashboards/recipient → fn_dashboard_recipient (S5). */
export const getRecipientDashboard = (
  actorId: number,
  windowDays: number | undefined,
): Promise<RecipientDashboardSnapshot> =>
  db.callFunction<RecipientDashboardSnapshot>(
    'fn_dashboard_recipient',
    [windowDays ?? null],
    { actorId },
  );

// ------------------------------------------------------------
// 2. Routing helper (no parameters)
// ------------------------------------------------------------

/**
 * GET /api/v1/dashboards/router → fn_dashboard_router (S6).
 *
 * Returns { userId, primaryRole, dashboardKey, permissionsSummary } —
 * NOT the orchestrator's earlier shorthand. Honors Agent 4/5 design.
 * v_role extraction inside the fn_ uses
 *   COALESCE(v_user->'role'->>'name', v_user->>'roleName', 'unknown')
 * (S2-22-WARN-3-FIX) — caller does not need to know.
 */
export const getDashboardRouter = (
  actorId: number,
): Promise<DashboardRouterResponse> =>
  db.callFunction<DashboardRouterResponse>('fn_dashboard_router', [], { actorId });

// ------------------------------------------------------------
// 3. Executive dashboard + anomalies history
// ------------------------------------------------------------

/**
 * GET /api/v1/dashboards/executive → fn_dashboard_executive (S7).
 *
 * windowDays default 90, range 1..365. The AI cost sub-call inside the fn_
 * truncates to LEAST(windowDays, 90) per Q5 lock + AC-S7-05; no special
 * handling required from the BE service. aiCostUsdWindow is null when the
 * caller lacks 'ai.observability.read' (gate inside the fn_ — wrapper
 * returns the JSONB verbatim).
 */
export const getExecutiveDashboard = (
  actorId: number,
  windowDays: number | undefined,
  tenantId?: string,
): Promise<ExecutiveDashboardSnapshot> =>
  db.callFunction<ExecutiveDashboardSnapshot>(
    'fn_dashboard_executive',
    [windowDays ?? null],
    { actorId, tenantId: tenantId ?? '00000000-0000-0000-0000-000000000001' },
  );

/**
 * GET /api/v1/dashboards/executive/anomalies-history →
 * fn_dashboard_executive_anomalies_history (S8).
 *
 * limit default 10, range 1..50. Returns { anomalies: [...] }; empty array
 * (NOT 404) when the cache is empty (AC-S8-02). The detection refresh action
 * is OWNED BY M4 (POST /api/v1/ai/executive-anomalies) — DO NOT duplicate
 * here.
 */
export const getExecutiveAnomaliesHistory = (
  actorId: number,
  limit: number | undefined,
): Promise<ExecutiveAnomaliesHistoryResponse> =>
  db.callFunction<ExecutiveAnomaliesHistoryResponse>(
    'fn_dashboard_executive_anomalies_history',
    [limit ?? null],
    { actorId },
  );

// ------------------------------------------------------------
// 4. AI cost summary (admin sidebar)
// ------------------------------------------------------------

/**
 * GET /api/v1/dashboards/ai-cost-summary → fn_dashboard_ai_cost_summary (S11).
 *
 * windowDays default 30, range 1..90 (matches M4 cap convention per
 * AC-S11-05). Permission gate inside the fn_ raises 42501 →
 * translatePgError → 403 ForbiddenError if the caller lacks
 * 'ai.observability.read'. The route layer additionally pre-gates with
 * authorise(['ai.observability.read']) so callers without the code never
 * reach the DB.
 *
 * Standalone endpoint per Agent 5 DASH-OI-G — NOT bundled into /admin
 * payload. Single source of compute (Q5 lock): both this endpoint AND
 * fn_dashboard_executive's inline aiCostUsdWindow read from the same
 * fn_ai_request_log_cost_report.
 */
export const getAiCostSummary = (
  actorId: number,
  windowDays: number | undefined,
): Promise<AiCostSummary> =>
  db.callFunction<AiCostSummary>(
    'fn_dashboard_ai_cost_summary',
    [windowDays ?? null],
    { actorId },
  );

// ------------------------------------------------------------
// 5. Admin health probe (no parameters)
// ------------------------------------------------------------

/**
 * GET /api/v1/admin/health → fn_health_check (S12).
 *
 * NOTE: distinct from M0's public liveness probe at /api/health (no version
 * prefix; no auth). This admin-scoped probe requires JWT + platform_admin /
 * Super Admin role.
 *
 * db.latestMigration depends on the schema_migrations_select_admin RLS
 * SELECT policy added in migration 054 (ARCH-NEW-3 option c). Without that
 * policy the deny-all RLS would return NULL on a non-superuser pool
 * connection. fn_health_check stays SECURITY INVOKER (zero DEFINER
 * carve-outs in M6).
 */
export const getAdminHealth = (actorId: number): Promise<HealthCheckSnapshot> =>
  db.callFunction<HealthCheckSnapshot>('fn_health_check', [], { actorId });
