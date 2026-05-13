/**
 * Dashboards controllers — M6 Dashboards & Reporting (10 endpoints).
 *
 * Each method is a thin HTTP layer over a single fn_ call routed through
 * src/services/dashboards.service.ts. No business logic in this file.
 *
 *   dashboardsController       — 9 endpoints under /api/v1/dashboards/*
 *     S1  admin              S5  recipient            S8  executive/anomalies-history
 *     S2  drafter            S6  router               S11 ai-cost-summary
 *     S3  approver           S7  executive
 *     S4  legal-counsel
 *
 *   adminHealthController      — 1 endpoint under /api/v1/admin/health (S12)
 *
 * Logging contract (BP-04 + BE template in skill-logging-patterns.md):
 *   - req.logger.info on entry with action, userId, method, path
 *   - req.logger.info on exit with action, userId, duration, statusCode
 *   - req.logger.error in catch with action, userId, duration, errorType
 *   - sensitive fields NEVER appear in log lines (M6 endpoints aggregate
 *     only — no new sensitive payload classes; existing pino redact
 *     coverage from M0..M5 is sufficient — see logger.util.ts header)
 *
 * Auth posture (Q1 locked CONFIRM):
 *   - 10/10 M6 endpoints are JWT-authenticated
 *   - 0 signed-token, 0 PUBLIC, 0 anonymous
 *   - Per-endpoint authorise(...) gate at the route layer (see
 *     dashboards.routes.ts); the fn body adds an in-body role/permission
 *     check as defence-in-depth that maps via translatePgError 42501→403
 *     when the route gate is broader than the fn_ gate.
 *
 * Response envelope:
 *   - res.status(200).json(result) — fn_ JSONB returned verbatim. Matches
 *     M5 regulatory pass-through pattern; FE expects the inner shape
 *     directly. The conceptual ApiResponse<T> envelope from
 *     api-contracts.json is documented in dashboards.types.ts but not
 *     re-wrapped at the controller.
 */
import type { NextFunction, Request, Response } from 'express';
import { ApiError } from '../utils/errors.util';
import * as dashboardsService from '../services/dashboards.service';
import type {
  ExecutiveAnomaliesHistoryQueryInput,
  OperationalDashboardQueryInput,
  AiCostSummaryQueryInput,
} from '../schemas/dashboards.schemas';

const errorType = (e: unknown): string =>
  e instanceof ApiError ? e.code : e instanceof Error ? e.name : 'UNKNOWN';

// ============================================================
// 1. Dashboards controller (9 endpoints)
// ============================================================
export const dashboardsController = {
  /**
   * GET /api/v1/dashboards/admin → fn_dashboard_admin (S1, S13).
   *
   * Admin landing dashboard. system-wide KPIs + day-bucketed trends.
   * Role gate (in fn_): platform_admin OR Super Admin. Else 42501 → 403.
   * windowDays default 30, range 1..365.
   */
  async admin(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'dashboard.admin',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as OperationalDashboardQueryInput;
      const result = await dashboardsService.getAdminDashboard(
        req.user!.id,
        q.windowDays,
      );
      req.logger.info(
        {
          action: 'dashboard.admin',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'dashboard.admin',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/dashboards/drafter → fn_dashboard_drafter (S2).
   *
   * Drafter-scoped projection: drafted_by = caller. Role gate (in fn_):
   * contract_drafter OR platform_admin OR Super Admin. windowDays 1..365.
   */
  async drafter(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'dashboard.drafter',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as OperationalDashboardQueryInput;
      const result = await dashboardsService.getDrafterDashboard(
        req.user!.id,
        q.windowDays,
      );
      req.logger.info(
        {
          action: 'dashboard.drafter',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'dashboard.drafter',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/dashboards/approver → fn_dashboard_approver (S3).
   *
   * Approver-scoped projection. Effective-assignee = COALESCE(delegated_to,
   * reassigned_to, approver_user_id) per S2-22-FIX-2a M2 override-chain
   * semantic. step.created_at replaces non-existent assigned_at.
   *
   * Migration 057 patch: contract join chain corrected at runtime
   * (M6-DB-IMPL-DEFECT-1 — caught at fn_ probe). The BE service module
   * calls the live (post-057) fn_ — the bug never reaches this layer.
   */
  async approver(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'dashboard.approver',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as OperationalDashboardQueryInput;
      const result = await dashboardsService.getApproverDashboard(
        req.user!.id,
        q.windowDays,
      );
      req.logger.info(
        {
          action: 'dashboard.approver',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'dashboard.approver',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/dashboards/legal-counsel → fn_dashboard_legal_counsel (S4).
   *
   * Legal counsel scope. Role gate (in fn_): legal_counsel OR platform_admin
   * OR Super Admin. The auditSummary slot is additionally gated on
   * fn_current_user_has_permission('audit.read') per CRIT-4 lock — fn_
   * returns auditSummary=NULL when caller lacks the permission (no error;
   * FE inspects null to decide tile visibility).
   */
  async legalCounsel(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'dashboard.legalCounsel',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as OperationalDashboardQueryInput;
      const result = await dashboardsService.getLegalCounselDashboard(
        req.user!.id,
        q.windowDays,
      );
      req.logger.info(
        {
          action: 'dashboard.legalCounsel',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          auditSummaryAvailable: result?.kpis?.auditSummary !== null,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'dashboard.legalCounsel',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/dashboards/recipient → fn_dashboard_recipient (S5).
   *
   * Recipient identifies via signature_party.signer_email = current_user.email
   * (case-insensitive). signedByMeWindow uses signature_event.actor_user_id
   * + created_at + event_type='signed' + is_active=TRUE per S2-22-FIX-1.
   * Role gate (in fn_): contract_recipient OR platform_admin OR Super Admin.
   */
  async recipient(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'dashboard.recipient',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as OperationalDashboardQueryInput;
      const result = await dashboardsService.getRecipientDashboard(
        req.user!.id,
        q.windowDays,
      );
      req.logger.info(
        {
          action: 'dashboard.recipient',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'dashboard.recipient',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/dashboards/router → fn_dashboard_router (S6).
   *
   * Routing helper. Returns { userId, primaryRole, dashboardKey,
   * permissionsSummary } — honors db-design.md §3.6 shape, not the
   * orchestrator's prompt shorthand (per feedback_db_impl_report_dont_fix.md).
   * Any authenticated user — fn_ raises 42501 only if app.current_user_id
   * GUC is unset.
   */
  async router(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'dashboard.router',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const result = await dashboardsService.getDashboardRouter(req.user!.id);
      req.logger.info(
        {
          action: 'dashboard.router',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          dashboardKey: result?.dashboardKey,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'dashboard.router',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/dashboards/executive → fn_dashboard_executive (S7).
   *
   * Enterprise overview. windowDays default 90, range 1..365 (AI sub-call
   * truncates to LEAST(windowDays, 90)). Role gate (in fn_): executive OR
   * platform_admin OR Super Admin OR insights.executive permission.
   * aiCostUsdWindow is INLINE per Q5 lock and returns null when caller
   * lacks ai.observability.read (AC-S7-05 explicit panel marker — no
   * error, FE inspects null).
   */
  async executive(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'dashboard.executive',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as OperationalDashboardQueryInput;
      const result = await dashboardsService.getExecutiveDashboard(
        req.user!.id,
        q.windowDays,
        req.tenantId,
      );
      req.logger.info(
        {
          action: 'dashboard.executive',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          aiCostAvailable: result?.kpis?.aiCostUsdWindow !== null,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'dashboard.executive',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/dashboards/executive/anomalies-history →
   * fn_dashboard_executive_anomalies_history (S8).
   *
   * Cached AI executive anomalies (entityType='executive_anomalies' on M4
   * ai_insight). limit default 10, range 1..50. Returns
   * { anomalies: [...] }; empty array (NOT 404) when cache empty per
   * AC-S8-02. Detection refresh action is OWNED BY M4 — DO NOT duplicate
   * a write endpoint here.
   */
  async executiveAnomaliesHistory(
    req: Request,
    res: Response,
    next: NextFunction,
  ): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'dashboard.executiveAnomaliesHistory',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as ExecutiveAnomaliesHistoryQueryInput;
      const result = await dashboardsService.getExecutiveAnomaliesHistory(
        req.user!.id,
        q.limit,
      );
      req.logger.info(
        {
          action: 'dashboard.executiveAnomaliesHistory',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          anomalyCount: result?.anomalies?.length ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'dashboard.executiveAnomaliesHistory',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },

  /**
   * GET /api/v1/dashboards/ai-cost-summary → fn_dashboard_ai_cost_summary (S11).
   *
   * Standalone AI cost rollup (NOT bundled into /admin per Agent 5
   * DASH-OI-G). windowDays default 30, range 1..90 (matches M4 cap per
   * AC-S11-05). Permission gate (in fn_):
   * fn_current_user_has_permission('ai.observability.read'); else 42501 →
   * 403. The route layer pre-gates the same permission to fail fast.
   */
  async aiCostSummary(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'dashboard.aiCostSummary',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const q = req.query as unknown as AiCostSummaryQueryInput;
      const result = await dashboardsService.getAiCostSummary(
        req.user!.id,
        q.windowDays,
      );
      req.logger.info(
        {
          action: 'dashboard.aiCostSummary',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          totalRequestsWindow: result?.totalRequestsWindow ?? 0,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'dashboard.aiCostSummary',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },
};

// ============================================================
// 2. Admin health controller (1 endpoint)
// ============================================================
export const adminHealthController = {
  /**
   * GET /api/v1/admin/health → fn_health_check (S12).
   *
   * Admin observability probe — distinct from M0's public liveness
   * /api/health (no version prefix; no auth). Requires JWT +
   * platform_admin / Super Admin. fn_ stays SECURITY INVOKER per
   * ARCH-NEW-3 option (c); db.latestMigration depends on migration 054's
   * schema_migrations_select_admin SELECT policy.
   *
   * Audit block (errorCountLastHour + lastErrorAt) was DROPPED in Patch
   * Round 1 — error signal sourced from ai probe instead. Body returns
   * { db, ai, overall }.
   */
  async health(req: Request, res: Response, next: NextFunction): Promise<void> {
    const startTime = Date.now();
    req.logger.info(
      {
        action: 'admin.health',
        userId: req.user?.id,
        method: req.method,
        path: req.path,
      },
      'Controller entry',
    );
    try {
      const result = await dashboardsService.getAdminHealth(req.user!.id);
      req.logger.info(
        {
          action: 'admin.health',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          statusCode: 200,
          overall: result?.overall,
          dbStatus: result?.db?.status,
          latestMigration: result?.db?.latestMigration ?? null,
        },
        'Controller exit',
      );
      res.status(200).json(result);
    } catch (error) {
      req.logger.error(
        {
          action: 'admin.health',
          userId: req.user?.id,
          duration: Date.now() - startTime,
          errorType: errorType(error),
        },
        'Controller error',
      );
      next(error);
    }
  },
};
