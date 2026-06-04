/**
 * Mount all /api/v1 routers.
 *
 * CR-V: ECIP route groups are gated by requireModuleEnabled(moduleKey) after
 * authenticate + rlsMiddleware. CLM core routes (contracts, templates, parties,
 * obligations, approvals, etc.) are NOT gated here — per brief, CLM-disable is
 * deferred to a future CR; the FE sidebar filter handles it for now.
 * PLATFORM routes (auth, users, roles, permissions, admin/*) are never gated.
 */
import { Router } from 'express';
import authRouter from './auth.routes';
import userRouter from './user.routes';
import roleRouter from './role.routes';
import permissionRouter from './permission.routes';
import contractsRouter from './contracts.routes';
import importBatchesRouter from './import-batches.routes';
import aiRouter from './ai.routes';
import approvalsRouter from './approvals.routes';
import adminRouter from './admin';
// M22 / CR-MIG-DRIVE — Contract Migration + Google Drive Connector
import integrationsRouter from './integrations.routes';
import migrationRouter from './migration.routes';
import { authenticate } from '../../middleware/auth.middleware';
import { rlsMiddleware } from '../../middleware/rls.middleware';
import { requireModuleEnabled } from '../../middleware/module.middleware';
import signRouter from './sign.routes';
import signaturePartiesRouter from './signature-parties.routes';
import signatureInvitationsRouter from './signature-invitations.routes';
import {
  regulationsRouter,
  regulatoryUpdatesRouter,
  regulatoryImpactsRouter,
  impactCategoriesRouter,
} from './regulatory.routes';
import dashboardsRouter from './dashboards.routes';
import {
  partiesRouter,
  templatesRouter,
  clausesRouter,
  obligationsRouter,
} from './m_parity.routes';
import impactSignalsRouter from './impact-signals.routes';
import adminSourcesRouter from './admin-sources.routes';
import signalsRouter from './signals.routes';
import {
  adminInternalSignalsRouter,
  adminInternalSignalKindsRouter,
} from './admin-internal-signals.routes';
import internalSignalsRouter from './internal-signals.routes';
// M12 (CR-D) — Clause Extraction + Review + Semantic Search
import { extractClausesRouter, clauseReviewRouter } from './clause-extraction.routes';
// M13 (CR-E) — Correlation Rule Engine + DSL + Correlations list/dismiss
import { correlationsRouter } from './correlation-rule.routes';
// Notification feed for the FE bell (mig 504)
import { notificationsRouter } from './notifications.routes';

const v1Router = Router();

v1Router.use('/auth', authRouter);

// Mig 538 — Public dev login personas endpoint (no auth — login page needs it).
import publicRouter from './public.routes';
v1Router.use('/public', publicRouter);
v1Router.use('/users', userRouter);
v1Router.use('/roles', roleRouter);
v1Router.use('/permissions', permissionRouter);
v1Router.use('/contracts', contractsRouter);

// M1c — Bulk & Manual Import
v1Router.use('/import-batches', importBatchesRouter);
// M1c — NEW /api/v1/ai/* namespace (Q3-OI-E / collision-report MD-4).
// M4 will append additional AI endpoints to ai.routes.ts.
v1Router.use('/ai', aiRouter);

// M2 — Approval Workflows (Q3-OI-E)
v1Router.use('/approvals', approvalsRouter);
v1Router.use('/admin', adminRouter);

// M22 / CR-MIG-DRIVE
v1Router.use('/integrations', integrationsRouter);
v1Router.use('/migration', migrationRouter);

// M3 — Signatures + Signer Q&A AI
//   /sign is the verify_jwt=false token-bearer namespace (S3, S4, S5,
//   S11, S12). The other two M3 namespaces are JWT-authenticated (S7, S8).
v1Router.use('/sign', signRouter);
v1Router.use('/signature-parties', signaturePartiesRouter);
v1Router.use('/signature-invitations', signatureInvitationsRouter);

// M5 — Regulatory Radar (15 endpoints across four resources). All
// JWT-authenticated; zero new PUBLIC fn_'s (Q1 confirmed). See
// src/routes/v1/regulatory.routes.ts header for permission code mapping.
v1Router.use('/regulations', regulationsRouter);
v1Router.use('/regulatory-updates', regulatoryUpdatesRouter);
v1Router.use('/regulatory-impacts', regulatoryImpactsRouter);
v1Router.use('/impact-categories', impactCategoriesRouter);

// M6 — Dashboards & Reporting (9 endpoints under /dashboards/*; the 10th
// — admin observability health probe — is mounted under /admin/health
// from admin/index.ts). All JWT-authenticated; zero new PUBLIC fn_'s
// (Q1 confirmed); zero new auth modes. See
// src/routes/v1/dashboards.routes.ts header for the per-endpoint
// permission / role-gate strategy.
v1Router.use('/dashboards', dashboardsRouter);

// M_parity — Lovable feature-depth parity (read-only entities).
// migration 058 + 059. All JWT-authenticated; zero new PUBLIC fn_'s;
// permission gating in fn_ body (contract.read.department OR contract.edit).
// CR-M — workforceListRouter handles the literal GET /parties/workforce. It
// MUST be registered BEFORE partiesRouter, whose `GET /:id` route would
// otherwise capture 'workforce' as a numeric :id and fail IdParamSchema
// validation (400) before the list handler is reached. (Import is hoisted;
// see the CR-M block lower in this file for the per-endpoint contract.)
v1Router.use('/parties', workforceListRouter);
v1Router.use('/parties', partyWorkforceRouter);
v1Router.use('/parties', partiesRouter);
v1Router.use('/templates', templatesRouter);
v1Router.use('/obligations', obligationsRouter);
v1Router.use('/notifications', notificationsRouter);
// NOTE: clausesRouter is mounted at /clauses AFTER clauseReviewRouter below.
// clausesRouter has a `/:id` route that would otherwise capture
// `/review-queue`, `/search`, etc. as the :id param and fail Zod validation.
// Mount clauseReviewRouter (with literal /review-queue, /search) first.

// R-LC7 — Impact Watch (multi-source intelligence).
// CR-V — gate /impact-signals (impact_signals module)
v1Router.use('/impact-signals', authenticate, rlsMiddleware, requireModuleEnabled('impact_signals'));
v1Router.use('/impact-signals', impactSignalsRouter);

// M7 — OSINT Source Framework + Adapter Protocol (CR-A). 9 endpoints across
// 3 namespaces:
//   /api/v1/admin/sources/*        — 7 endpoints (registry CRUD + credential
//                                     + test-pull); permission gates in fn_
//   /api/v1/admin/source-health    — 1 endpoint (cron-driven health monitor)
//                                     mounted via admin/index.ts
//   /api/v1/signals                — 1 endpoint (paginated normalised signal
//                                     feed; signal.read.all gate in fn_)
// All JWT-authenticated; zero new PUBLIC fn_'s. Tenant GUC via rls.middleware.
// CR-V — gate /admin/sources (impact_signals module)
v1Router.use('/admin/sources', authenticate, rlsMiddleware, requireModuleEnabled('impact_signals'));
v1Router.use('/admin/sources', adminSourcesRouter);
// CR-V — gate /signals (impact_signals module)
v1Router.use('/signals', authenticate, rlsMiddleware, requireModuleEnabled('impact_signals'));
v1Router.use('/signals', signalsRouter);

// M8 — Internal Signal Data Path (CR-A2). 4 endpoints across 3 namespaces:
//   /api/v1/admin/internal-signals       — POST ingest (system-only,
//                                          internal_signal.ingest in fn_)
//   /api/v1/admin/internal-signal-kinds  — GET catalogue (bare-array,
//                                          internal_signal.read in fn_)
//   /api/v1/internal-signals             — GET paginated list + POST
//                                          :id/resolve (idempotent;
//                                          internal_signal.read /
//                                          internal_signal.resolve gates
//                                          + Q-DA3 per-signal_type role
//                                          mapping inside fn_)
// All JWT-authenticated; zero new PUBLIC fn_'s. Tenant GUC via rls.middleware.
// CR-V — gate /admin/internal-signals and /internal-signals (impact_signals module)
v1Router.use('/admin/internal-signals', authenticate, rlsMiddleware, requireModuleEnabled('impact_signals'));
v1Router.use('/admin/internal-signals', adminInternalSignalsRouter);
v1Router.use('/admin/internal-signal-kinds', authenticate, rlsMiddleware, requireModuleEnabled('impact_signals'));
v1Router.use('/admin/internal-signal-kinds', adminInternalSignalKindsRouter);
v1Router.use('/internal-signals', authenticate, rlsMiddleware, requireModuleEnabled('impact_signals'));
v1Router.use('/internal-signals', internalSignalsRouter);

// M12 (CR-D) — Clause Extraction pipeline trigger (mounted under /contracts
// so CR-D-001 POST /contracts/:id/extract-clauses and CR-D-002
// POST /contracts/:id/versions/:vId/extract-clauses resolve cleanly alongside
// the existing /contracts/:id sub-routes).
v1Router.use('/contracts', extractClausesRouter);

// M12 (CR-D) — Clause review-queue + semantic search + review action.
// MUST be mounted BEFORE clausesRouter (also at /clauses) because clausesRouter
// has a `/:id` route that would capture `/review-queue` and `/search` as the
// :id param. Express matches routers in mount order; literal-path routes here
// short-circuit before the wildcard.
// CR-V — gate /clauses (clauses module)
v1Router.use('/clauses', authenticate, rlsMiddleware, requireModuleEnabled('clauses'));
v1Router.use('/clauses', clauseReviewRouter);
v1Router.use('/clauses', clausesRouter);

// M13 (CR-E) — Correlations list + dismiss.
// /admin/rules is mounted separately in admin/index.ts.
v1Router.use('/correlations', correlationsRouter);

// M14 (CR-F) — 5-Dim Risk Scoring + MaR + AVaR.
//   /api/v1/contracts/:id/risk-score        — GET latest explain (score.read)
//   /api/v1/contracts/:id/risk-score/history — GET history (score.read)
//   /api/v1/risk/avar                       — GET AVaR aggregate (score.read)
// /admin/scoring-weights endpoints are mounted in admin/index.ts.
import { contractRiskScoreRouter, riskAvarRouter } from './risk-score.routes';
v1Router.use('/contracts', contractRiskScoreRouter);
v1Router.use('/risk', riskAvarRouter);

// M15 (CR-G) — Executive Decision Support Evolution + 4 Persona Dashboards + AI Risk Assistant.
//   GET /api/v1/dashboards/operations          — Operations & SLA persona (insights.operations)
//   GET /api/v1/dashboards/finance-treasury    — Finance & Treasury persona (insights.finance_treasury)
//   GET /api/v1/dashboards/compliance-esg      — Compliance & ESG persona (insights.compliance_esg)
//   GET /api/v1/dashboards/procurement         — Procurement & Supplier Risk persona (insights.procurement_supplier_risk)
//   POST /api/v1/ai/risk-assistant/ask         — AI Risk Assistant SSE Q&A (ai.invoke.risk_assistant)
// NOTE: /dashboards/executive is served by dashboardsRouter (mounted earlier at /dashboards).
//
// CR-V: module guards for ECIP dashboard sub-paths + AI Risk Assistant.
// dashboardsRouter and dashboardsCrgRouter share the /dashboards prefix.
// The executive route (/dashboards/executive) is in dashboardsRouter (already mounted);
// CR-V adds module guard for the CRG persona dashboard sub-paths by prefixing them
// with authenticate + requireModuleEnabled before the sub-router handles the request.
// Guard pattern: Express matches the longest prefix first, so explicit sub-path
// guards here run before the generic dashboardsRouter catch-all.
import dashboardsCrgRouter from './dashboards-crg.routes';
import aiRiskAssistantRouter from './ai-risk-assistant.routes';

// CR-V — gate /dashboards/executive (dashboards.executive module)
v1Router.use('/dashboards/executive', authenticate, rlsMiddleware, requireModuleEnabled('dashboards.executive'));
// CR-V — gate /dashboards/operations (dashboards.operations module)
v1Router.use('/dashboards/operations', authenticate, rlsMiddleware, requireModuleEnabled('dashboards.operations'));
// CR-V — gate /dashboards/finance-treasury (dashboards.finance_treasury module)
v1Router.use('/dashboards/finance-treasury', authenticate, rlsMiddleware, requireModuleEnabled('dashboards.finance_treasury'));
// CR-V — gate /dashboards/compliance-esg (dashboards.compliance_esg module)
v1Router.use('/dashboards/compliance-esg', authenticate, rlsMiddleware, requireModuleEnabled('dashboards.compliance_esg'));
// CR-V — gate /dashboards/procurement (dashboards.procurement module)
v1Router.use('/dashboards/procurement', authenticate, rlsMiddleware, requireModuleEnabled('dashboards.procurement'));

v1Router.use('/dashboards', dashboardsCrgRouter);

// CR-V — gate /ai/risk-assistant (ai_risk_assistant module)
v1Router.use('/ai/risk-assistant', authenticate, rlsMiddleware, requireModuleEnabled('ai_risk_assistant'));
v1Router.use('/ai', aiRiskAssistantRouter);

// Unit-3 (R-OPS + R-FT + R-CES) — Persona action routes.
//   POST /api/v1/ops/events/:correlationId/acknowledge   — risk.acknowledge
//   POST /api/v1/ops/events/:correlationId/link-remedy   — risk.acknowledge
//   POST /api/v1/ops/events/:correlationId/escalate      — risk.acknowledge
//   POST /api/v1/finance/contracts/:contractId/price-review         — risk.acknowledge + insights.finance_treasury
//   POST /api/v1/finance/contracts/:contractId/payment-hold         — risk.acknowledge
//   POST /api/v1/finance/contracts/:contractId/hedge-review         — risk.acknowledge
//   POST /api/v1/compliance/contracts/:contractId/raise-flag        — risk.acknowledge
//   POST /api/v1/compliance/contracts/:contractId/supplier-audit    — risk.acknowledge
//   POST /api/v1/compliance/contracts/:contractId/recommend-hold    — risk.acknowledge
//   POST /api/v1/compliance/contracts/:contractId/recommend-termination — risk.acknowledge
//   POST /api/v1/compliance/contracts/:contractId/icv-certificate   — contract.edit (multipart)
//   GET  /api/v1/contracts/:contractId/audit-rights                 — contract.read.* | insights.*
import opsActionsRouter from './ops-actions.routes';
import financeActionsRouter from './finance-actions.routes';
import complianceActionsRouter from './compliance-actions.routes';
import auditRightsRouter from './audit-rights.routes';
import procurementActionsRouter from './procurement-actions.routes';
v1Router.use('/ops', opsActionsRouter);
v1Router.use('/finance', financeActionsRouter);
v1Router.use('/compliance', complianceActionsRouter);
// Unit-4 / R-PROC procurement actions (vendor + contract scoped).
v1Router.use('/procurement', procurementActionsRouter);
// audit-rights is a sub-route under /contracts — mount after all existing /contracts
// routers so the literal /:contractId/audit-rights path doesn't conflict.
v1Router.use('/contracts', auditRightsRouter);

// M16 (CR-H) — Advisory Drafter + Notification Delivery.
//   POST   /api/v1/advisory-drafts/generate            — LLM + persist (advisory.draft.review)
//   GET    /api/v1/advisory-drafts                     — list (advisory.draft.review)
//   GET    /api/v1/advisory-drafts/:id                 — detail (advisory.draft.review)
//   POST   /api/v1/advisory-drafts/:id/approve         — approve (advisory.draft.review)
//   POST   /api/v1/advisory-drafts/:id/reject          — reject (advisory.draft.review)
//   POST   /api/v1/advisory-drafts/:id/modify          — modify text (advisory.draft.review)
//   POST   /api/v1/advisory-drafts/:id/dispatch        — dispatch (advisory.dispatch)
//   GET    /api/v1/advisory-drafts/:id/dispatch-log    — dispatch audit (advisory.draft.review|dispatch_log.read)
//   GET/PATCH /api/v1/users/me/notification-preferences — preferences (notification.preferences.write.self)
// NOTE: /admin/advisory-templates + /admin/notification-dispatch-log are mounted in admin/index.ts.
import advisoryDraftsRouter from './advisory-drafts.routes';
import notificationPreferencesRouter from './users/notification-preferences.routes';

// CR-V — gate /advisory-drafts (advisory_queue module)
v1Router.use('/advisory-drafts', authenticate, rlsMiddleware, requireModuleEnabled('advisory_queue'));
v1Router.use('/advisory-drafts', advisoryDraftsRouter);
// Mount /users/me/notification-preferences under /users namespace.
// The existing userRouter is mounted at '/users' in v1Router above.
// We mount a separate router for the /me/notification-preferences sub-path
// so we don't modify the existing user routes.
v1Router.use('/users', notificationPreferencesRouter);

// ============================================================
// M19 (CR-K) — Risk Cases.
//   14 endpoints under /api/v1/risk-cases/* including 2 internal-only
//   worker endpoints (escalation-check, auto-create-from-correlation).
// ============================================================
import riskCaseRouter from './risk-case.routes';
// CR-V — gate /risk-cases (risk_cases module)
v1Router.use('/risk-cases', authenticate, rlsMiddleware, requireModuleEnabled('risk_cases'));
v1Router.use('/risk-cases', riskCaseRouter);

// ============================================================
// M20 (CR-L) — Reports & Briefings — user-facing surface.
//   GET    /api/v1/reports/templates                (report.read)
//   POST   /api/v1/reports/templates/:id/run        (report.read)
//   GET    /api/v1/reports/runs/:id                 (report.read)
// Admin template CRUD + worker pickup mount in routes/v1/admin/index.ts.
// ============================================================
import reportRouter from './report.routes';
// CR-V — gate /reports (reports module)
v1Router.use('/reports', authenticate, rlsMiddleware, requireModuleEnabled('reports'));
v1Router.use('/reports', reportRouter);

// ============================================================
// CR-M — Labor-Law Cascade + ADNOC-World Foundation.
//
// Party Workforce:
//   GET    /api/v1/parties/workforce                    — list (party.workforce.read)
//   POST   /api/v1/parties/:partyId/workforce           — upsert (party.workforce.manage)
//   GET    /api/v1/parties/:partyId/workforce           — get (party.workforce.read)
//
// workforceListRouter (literal /workforce) MUST be mounted BEFORE partyWorkforceRouter
// (:partyId param) so '/workforce' does not match as a partyId.
//
// Regulatory Cascade:
//   POST   /api/v1/regulatory/cascade/run               — run (regulatory.cascade.run)
//   GET    /api/v1/regulatory/cascade                   — list (regulatory.cascade.read)
//   GET    /api/v1/regulatory/cascade/:runId            — detail (regulatory.cascade.read)
//   PATCH  /api/v1/regulatory/cascade/items/:itemId/status — status (regulatory.cascade.read)
//   POST   /api/v1/regulatory/cascade/items/:itemId/draft-amendment — advisory seam
// ============================================================
import { workforceListRouter, partyWorkforceRouter } from './party-workforce.routes';
import regulatoryCascadeRouter from './regulatory-cascade.routes';
// NOTE: workforceListRouter + partyWorkforceRouter are mounted earlier in this
// file (immediately before partiesRouter) so the literal /parties/workforce
// path is matched before partiesRouter's `GET /:id`. Do not re-mount them here.
// CR-V — gate /regulatory/cascade (regulatory_cascade module)
v1Router.use('/regulatory/cascade', authenticate, rlsMiddleware, requireModuleEnabled('regulatory_cascade'));
v1Router.use('/regulatory/cascade', regulatoryCascadeRouter);

// ============================================================
// M21 (CR-N) — Financial Budget Burn (Services-Contract Budget Burn).
//   GET  /api/v1/financial/budget-burn                       — portfolio rollup (finance.budget.read)
//   GET  /api/v1/financial/budget-burn/budgets               — list budget lines (finance.budget.read)
//   GET  /api/v1/financial/budget-burn/budgets/:id           — budget line detail (finance.budget.read)
//   GET  /api/v1/financial/budget-burn/cost-actuals          — list actuals (finance.budget.read)
//   GET  /api/v1/financial/budget-burn/:contractId           — burn compute (finance.budget.read)
//   GET  /api/v1/financial/budget-burn/:contractId/variance  — variance+clause refs (finance.budget.read)
//   GET  /api/v1/financial/budget-burn/:contractId/projection — year-end projection (finance.budget.read)
//   POST /api/v1/financial/budget-burn/:contractId/cost-actuals — record actual (finance.budget.manage)
//   POST /api/v1/financial/budget-burn/variance/:contractId/draft-cure-notice — cure-notice (advisory.draft.review)
// ============================================================
import financialBudgetBurnRouter from './financial-budget-burn.routes';
// CR-V — gate /financial/budget-burn (financial.budget_burn module)
v1Router.use('/financial/budget-burn', authenticate, rlsMiddleware, requireModuleEnabled('financial.budget_burn'));
v1Router.use('/financial/budget-burn', financialBudgetBurnRouter);

// ============================================================
// M21 (CR-O) — Oil-Trade Margin (Financial Intelligence, Trade half).
//   GET  /api/v1/financial/trade-margin                      — positions list (finance.margin.read)
//   GET  /api/v1/financial/trade-margin/aggregate            — portfolio rollup (finance.margin.read)
//   GET  /api/v1/financial/trade-margin/:positionId          — position detail (finance.margin.read)
//   GET  /api/v1/financial/trade-margin/:positionId/history  — snapshot history (finance.margin.read)
//   GET  /api/v1/financial/price-benchmarks                  — benchmark series list (finance.margin.read)
//   POST /api/v1/financial/price-benchmarks/recompute        — OSP-drop demo action (finance.trade.manage)
//   POST /api/v1/financial/price-benchmarks                  — record benchmark (finance.trade.manage)
// ============================================================
import { tradeMarginRouter, priceBenchmarksRouter } from './financial-trade-margin.routes';
// CR-V — gate /financial/trade-margin and /financial/price-benchmarks (financial.trade_margin module)
v1Router.use('/financial/trade-margin', authenticate, rlsMiddleware, requireModuleEnabled('financial.trade_margin'));
v1Router.use('/financial/trade-margin', tradeMarginRouter);
v1Router.use('/financial/price-benchmarks', authenticate, rlsMiddleware, requireModuleEnabled('financial.trade_margin'));
v1Router.use('/financial/price-benchmarks', priceBenchmarksRouter);

// ============================================================
// TPA — Third-Party Agreement Assessment (Legal Counsel).
//   GET    /api/v1/tpa/playbooks                  — list ADNOC playbooks (tpa.review.read)
//   GET    /api/v1/tpa/playbooks/:id              — playbook + clauses
//   POST   /api/v1/tpa/reviews/upload             — multipart upload + analyse (tpa.review.create)
//   GET    /api/v1/tpa/reviews                    — list reviews
//   GET    /api/v1/tpa/reviews/:id                — detail + findings + documents
//   PATCH  /api/v1/tpa/reviews/:id/findings/:fid  — override AI verdict (tpa.review.amend)
//   POST   /api/v1/tpa/reviews/:id/status         — transition status (tpa.review.amend)
//   GET    /api/v1/tpa/reviews/:id/redline.docx   — stream redline DOCX (tpa.review.amend)
// ============================================================
import tpaRouter from './tpa.routes';
v1Router.use('/tpa', authenticate, rlsMiddleware, requireModuleEnabled('tpa_review'));
v1Router.use('/tpa', tpaRouter);

export default v1Router;
