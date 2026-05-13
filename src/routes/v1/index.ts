/**
 * Mount all /api/v1 routers.
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

const v1Router = Router();

v1Router.use('/auth', authRouter);
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
v1Router.use('/parties', partiesRouter);
v1Router.use('/templates', templatesRouter);
v1Router.use('/obligations', obligationsRouter);
// NOTE: clausesRouter is mounted at /clauses AFTER clauseReviewRouter below.
// clausesRouter has a `/:id` route that would otherwise capture
// `/review-queue`, `/search`, etc. as the :id param and fail Zod validation.
// Mount clauseReviewRouter (with literal /review-queue, /search) first.

// R-LC7 — Impact Watch (multi-source intelligence).
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
v1Router.use('/admin/sources', adminSourcesRouter);
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
v1Router.use('/admin/internal-signals', adminInternalSignalsRouter);
v1Router.use('/admin/internal-signal-kinds', adminInternalSignalKindsRouter);
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

export default v1Router;
