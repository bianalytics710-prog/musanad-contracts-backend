/**
 * /api/v1/dashboards/* — M6 Dashboards & Reporting (9 endpoints).
 *
 * Mounted from src/routes/v1/index.ts. Plus 1 sibling endpoint S12
 * (/api/v1/admin/health) which lives in admin/health.routes.ts (mounted
 * from admin/index.ts) — kept separate because the URL prefix differs
 * and the admin namespace already exists from M2/M4.
 *
 * Endpoint roster:
 *   S1   GET  /admin                     fn_dashboard_admin              (also serves S13)
 *   S2   GET  /drafter                   fn_dashboard_drafter
 *   S3   GET  /approver                  fn_dashboard_approver
 *   S4   GET  /legal-counsel             fn_dashboard_legal_counsel
 *   S5   GET  /recipient                 fn_dashboard_recipient
 *   S6   GET  /router                    fn_dashboard_router
 *   S7   GET  /executive                 fn_dashboard_executive
 *   S8   GET  /executive/anomalies-history fn_dashboard_executive_anomalies_history
 *   S11  GET  /ai-cost-summary           fn_dashboard_ai_cost_summary
 *
 * Path-ordering note (W1 mirror — M5 precedent regulatoryImpactsRouter):
 *   '/executive/anomalies-history' is registered BEFORE '/executive' to
 *   avoid Express partial-match shadowing. (In practice not strictly
 *   necessary because '/executive' uses .get('/executive') exactly and
 *   '/executive/anomalies-history' is a deeper path — Express matches
 *   exact strings — but keeping the literal-deeper-first ordering is
 *   defensive against future param refactors.)
 *
 * Auth posture (Q1 locked CONFIRM):
 *   - 9/9 routes apply `authenticate` (JWT bearer)
 *   - Per-endpoint role / permission gate at the route layer (matches
 *     api-contracts.json _permissionGate annotations); fn body adds an
 *     in-body check as defence-in-depth.
 *
 * Rate limits:
 *   GETs → authedReadRateLimiter (120/min/user) — same as M5 reads.
 *
 * Permission strategy:
 *   M6 introduces only one new permission code (insights.executive,
 *   seeded by migration 054 + role_permission grants for executive /
 *   platform_admin / Super Admin per Q2 lock). Eight of the nine routes
 *   here are role-gated — the role union is enforced inside the fn_
 *   body (42501 → 403 via translatePgError). The route layer applies
 *   `authenticate` only for those eight; we deliberately do NOT
 *   invent permission codes for the role gates (they'd duplicate the
 *   role grants already in the catalog and risk drift if a role gains
 *   a new dashboard later).
 *
 *   The single exception is /ai-cost-summary (S11) which gates on the
 *   pre-existing 'ai.observability.read' permission (M4-seeded migration
 *   044). That route applies authorise(['ai.observability.read']) at
 *   the route layer to fail fast; the fn body re-checks as defence-in-
 *   depth.
 *
 *   /executive (S7) is role-gated at the fn_ body and additionally
 *   accepts callers holding 'insights.executive'. We rely on the fn
 *   body for the OR-branch — pre-gating insights.executive at the route
 *   would 403 role-only callers, which contradicts the OR semantics.
 */
import { Router } from 'express';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import { authedReadRateLimiter } from '../../middleware/rate-limit.middleware';
import { dashboardsController } from '../../controllers/dashboards.controller';
import {
  aiCostSummaryQuerySchema,
  executiveAnomaliesHistoryQuerySchema,
  expiringContractsEscalateBodySchema,
  operationalDashboardQuerySchema,
} from '../../schemas/dashboards.schemas';

const dashboardsRouter = Router();

// All routes require an authenticated user.
dashboardsRouter.use(authenticate);

// ------------------------------------------------------------
// S1 — GET /api/v1/dashboards/admin (also serves S13)
// ------------------------------------------------------------
//
// Role gate: platform_admin / Super Admin (fn body — 42501 → 403).
dashboardsRouter.get(
  '/admin',
  authedReadRateLimiter,
  validate(operationalDashboardQuerySchema, 'query'),
  dashboardsController.admin,
);

// ------------------------------------------------------------
// S2 — GET /api/v1/dashboards/drafter
// ------------------------------------------------------------
//
// Role gate: contract_drafter / platform_admin / Super Admin (fn body).
dashboardsRouter.get(
  '/drafter',
  authedReadRateLimiter,
  validate(operationalDashboardQuerySchema, 'query'),
  dashboardsController.drafter,
);

// ------------------------------------------------------------
// S3 — GET /api/v1/dashboards/approver
// ------------------------------------------------------------
//
// Role gate: contract_approver / contract_approver_2 / platform_admin /
// Super Admin (fn body). Live fn_ is post-057 patch (M6-DB-IMPL-DEFECT-1).
dashboardsRouter.get(
  '/approver',
  authedReadRateLimiter,
  validate(operationalDashboardQuerySchema, 'query'),
  dashboardsController.approver,
);

// ------------------------------------------------------------
// S4b — GET /api/v1/dashboards/legal-counsel/insights  (mig 685)
// ------------------------------------------------------------
//
// Registered BEFORE /legal-counsel (exact-match deeper-first ordering;
// defensive against future param-route refactors — mirrors the pattern
// used for /executive/anomalies-history before /executive).
// Role gate: legal_counsel / platform_admin / Super Admin (fn body).
// Tenant context resolved in controller (req.tenantId ?? ADNOC singleton).
dashboardsRouter.get(
  '/legal-counsel/insights',
  authedReadRateLimiter,
  dashboardsController.legalCounselInsights,
);

// ------------------------------------------------------------
// S4 — GET /api/v1/dashboards/legal-counsel
// ------------------------------------------------------------
//
// Role gate: legal_counsel / platform_admin / Super Admin (fn body).
// auditSummary slot additionally gates on 'audit.read' (CRIT-4 lock —
// NOT 'audit.read.all'); fn returns auditSummary=NULL when caller lacks
// the permission. NULL handling is FE concern.
dashboardsRouter.get(
  '/legal-counsel',
  authedReadRateLimiter,
  validate(operationalDashboardQuerySchema, 'query'),
  dashboardsController.legalCounsel,
);

// ------------------------------------------------------------
// S5 — GET /api/v1/dashboards/recipient
// ------------------------------------------------------------
//
// Role gate: contract_recipient / platform_admin / Super Admin (fn body).
dashboardsRouter.get(
  '/recipient',
  authedReadRateLimiter,
  validate(operationalDashboardQuerySchema, 'query'),
  dashboardsController.recipient,
);

// ------------------------------------------------------------
// S6 — GET /api/v1/dashboards/router
// ------------------------------------------------------------
//
// Any authenticated user. fn body raises 42501 if app.current_user_id GUC
// is unset — should not happen because authenticate middleware sets req.user
// and db.callFunction sets the GUC via opts.actorId.
dashboardsRouter.get(
  '/router',
  authedReadRateLimiter,
  // No query / body validation — endpoint takes no parameters.
  dashboardsController.router,
);

// ------------------------------------------------------------
// S8 — GET /api/v1/dashboards/executive/anomalies-history
// ------------------------------------------------------------
//
// Registered BEFORE /executive to keep literal-deeper-first ordering
// (defensive — see header). Role gate: executive / platform_admin /
// Super Admin (fn body). Wraps M4 fn_ai_insight_list — its own
// permission/RLS plane applies internally.
dashboardsRouter.get(
  '/executive/anomalies-history',
  authedReadRateLimiter,
  validate(executiveAnomaliesHistoryQuerySchema, 'query'),
  dashboardsController.executiveAnomaliesHistory,
);

// E-rev-3 — GET /api/v1/dashboards/executive/expiring-contracts
// Drilldown for the expiry-cliff modal.
dashboardsRouter.get(
  '/executive/expiring-contracts',
  authedReadRateLimiter,
  dashboardsController.executiveExpiringContracts,
);

// Mig 554 — POST /api/v1/dashboards/executive/expiring-contracts/escalate
// Persists renewal-alert escalations for the expiry-cliff frame. Permission
// gated at the route layer (contract.renewal_alert.send) and re-checked in
// the fn body as defence-in-depth.
dashboardsRouter.post(
  '/executive/expiring-contracts/escalate',
  authorise(['contract.renewal_alert.send']),
  validate(expiringContractsEscalateBodySchema, 'body'),
  dashboardsController.executiveExpiringContractsEscalate,
);

// Mig 559 — GET /api/v1/dashboards/executive/trends-extended?months=6
// Side-car for the value-over-time + contracts-created-over-time charts.
dashboardsRouter.get(
  '/executive/trends-extended',
  authedReadRateLimiter,
  dashboardsController.executiveTrendsExtended,
);

// Mig 560 — GET /api/v1/dashboards/executive/high-risk?limit=8
// Side-car for the ECIP "High-risk contracts" card. Returns each row
// with counterpartyName + riskType in addition to the legacy fields.
dashboardsRouter.get(
  '/executive/high-risk',
  authedReadRateLimiter,
  dashboardsController.executiveHighRisk,
);

// Mig 558 — GET /api/v1/dashboards/executive/top-counterparty-contracts/:id
// Drilldown for the executive "Top Business Partners" table.
dashboardsRouter.get(
  '/executive/top-counterparty-contracts/:counterpartyId',
  authedReadRateLimiter,
  dashboardsController.executiveCounterpartyContracts,
);

// GET /api/v1/dashboards/executive/critical-impacts
// Merged feed for the "Critical impact" inline frame (osint_signal severity=critical
// + open risk_case priority=critical, each pre-joined to affected contracts).
// Role gate enforced inside fn_dashboard_executive_critical_impacts.
dashboardsRouter.get(
  '/executive/critical-impacts',
  authedReadRateLimiter,
  dashboardsController.executiveCriticalImpacts,
);

// Phase C — GET /api/v1/dashboards/executive/risk-review
// Top N Tier 2 cases for the Executive Risk Review section. Permission
// risk.review.manage enforced inside fn_risk_review_list (and at the
// controller-side authorise gate as defense-in-depth).
import { riskReviewController } from '../../controllers/risk-review.controller';
dashboardsRouter.get(
  '/executive/risk-review',
  authedReadRateLimiter,
  authorise(['risk.review.manage']),
  riskReviewController.list,
);

// Phase E.3 — GET /api/v1/dashboards/executive/risk-triage/tier1
// Tier-1 auto-routed cases (status=open + assigned_role + assigned_user_id)
// for executive oversight in the Risk Triage tab strip. Permission
// risk.review.manage enforced inside fn_risk_triage_tier1_list.
dashboardsRouter.get(
  '/executive/risk-triage/tier1',
  authedReadRateLimiter,
  authorise(['risk.review.manage']),
  riskReviewController.tier1List,
);

// Phase E.1 — GET /api/v1/dashboards/executive/risk-triage/assignee-suggest?role=…
// Returns ranked active users in the target role for the confirm-risk modal
// dropdown. Row 1 carries suggested=true (lightest current open-case load).
dashboardsRouter.get(
  '/executive/risk-triage/assignee-suggest',
  authedReadRateLimiter,
  authorise(['risk.review.manage']),
  riskReviewController.assigneeSuggest,
);

// Gap 3 (mig 658) — GET /api/v1/dashboards/executive/risk-triage/assigned-by-me
// Returns the recent set of risk cases whose routing the actor initiated
// (promoted / reassigned / created). Powers the executive's reverse-view
// section in AssignedByMeView.
dashboardsRouter.get(
  '/executive/risk-triage/assigned-by-me',
  authedReadRateLimiter,
  authorise(['risk.review.manage']),
  riskReviewController.assignedByMe,
);

// ------------------------------------------------------------
// S7 — GET /api/v1/dashboards/executive
// ------------------------------------------------------------
//
// Role gate (fn body): executive OR platform_admin OR Super Admin OR
// fn_current_user_has_permission('insights.executive') = TRUE.
//
// Route-level pre-gate: authoriseAnyOf(['insights.executive']) — this
// catches the permission-grant path early. Role-only callers (executive /
// platform_admin / Super Admin) typically already hold insights.executive
// because migration 054 grants the code to all three roles
// pre-emptively (Q2 locked); but if a future role grant flips, the fn
// body still permits role-only callers and the 403 from the pre-gate
// would be incorrect. To keep the route-layer broad, we do NOT
// pre-gate insights.executive at the route — instead we rely entirely
// on the fn body (authenticate is sufficient at the route). This matches
// M5's approach for fn-body-enforced role gates.
//
// aiCostUsdWindow is INLINE per Q5 lock — null when caller lacks
// 'ai.observability.read' (no error; FE inspects null).
dashboardsRouter.get(
  '/executive',
  authedReadRateLimiter,
  validate(operationalDashboardQuerySchema, 'query'),
  dashboardsController.executive,
);

// ------------------------------------------------------------
// S11 — GET /api/v1/dashboards/ai-cost-summary
// ------------------------------------------------------------
//
// Standalone endpoint per Agent 5 DASH-OI-G — NOT bundled into /admin.
// Permission gate: ai.observability.read (M4-seeded; per AC-S11-04).
// Pre-gate at route layer to fail fast; fn body raises 42501 as defence
// in depth (translatePgError 42501 → 403).
dashboardsRouter.get(
  '/ai-cost-summary',
  authedReadRateLimiter,
  authorise(['ai.observability.read']),
  validate(aiCostSummaryQuerySchema, 'query'),
  dashboardsController.aiCostSummary,
);

export default dashboardsRouter;
