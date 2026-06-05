/**
 * /api/v1/admin/* — admin oversight + configuration endpoints.
 * All routes require JWT (each sub-router applies `authenticate`) and
 * permission-gate per endpoint. First introduced by M2 (Q3-OI-E).
 *
 * CR-V: /admin/demo is gated by requireModuleEnabled('demo_harness').
 * All other /admin/* paths are PLATFORM bundle (always-on); not gated.
 */
import { Router } from 'express';
import { authenticate } from '../../../middleware/auth.middleware';
import { rlsMiddleware } from '../../../middleware/rls.middleware';
import { requireModuleEnabled } from '../../../middleware/module.middleware';
import approvalMatrixRouter from './approval-matrix.routes';
import approvalChainsRouter from './approval-chains.routes';
import approvalStepsRouter from './approval-steps.routes';
import aiAdminRouter from './ai.routes';
import healthRouter from './health.routes';
import settingsRouter from './settings.routes';
import auditRouter from './audit.routes';
import sourceHealthRouter from './source-health.routes';
import partiesSanctionsMatchRouter from './parties-sanctions-match.routes';
// CR-C M10 — Audit Hardening + Multi-Tenancy + Admin Cockpit Foundation.
import auditChainRouter from './audit-chain.routes';
import demoRouter from './demo.routes';
import tenantsRouter from './tenants.routes';
import rolesMgmtRouter from './roles-mgmt.routes';
import notificationTemplatesRouter from './notification-templates.routes';
import emailConfigRouter from './email-config.routes';
import brandingRouter from './branding.routes';

const router = Router();

router.use('/approval-matrix', approvalMatrixRouter);
router.use('/approval-chains', approvalChainsRouter);
router.use('/approval-steps', approvalStepsRouter);

// M4 — admin observability
router.use('/ai', aiAdminRouter);

// M6 — admin observability health probe (S12). Distinct from M0's public
// liveness endpoint at /api/health (no version; no auth). This admin-scoped
// probe requires JWT + platform_admin / Super Admin role and surfaces
// db.latestMigration + ai.estimatedHealthy + composite overall status.
router.use('/health', healthRouter);

// R-PA4 — workspace system settings (General / UAE Pass / Branding tabs).
router.use('/settings', settingsRouter);

// R-PA5 — paginated audit_log viewer + CSV export.
router.use('/audit', auditRouter);

// M7 — OSINT source health monitor (cron-driven; bare-array bounded set).
router.use('/source-health', sourceHealthRouter);

// M9 (CR-B) — admin/system test endpoint: fuzzy entity match with chain
// expansion. Gated by party.graph.manage (admin-narrowed). Returns matches
// only — does NOT update party.sanctions_status (HITL Q-DA4).
router.use('/parties/sanctions-match', partiesSanctionsMatchRouter);

// ============================================================
// CR-C M10 — Audit Hardening + Multi-Tenancy + Admin Cockpit Foundation
// ============================================================

// S3 — POST /admin/audit/verify (mounted alongside the R-PA5 /admin/audit
// router; sub-paths are disjoint so the two routers cohabit cleanly).
router.use('/audit', auditChainRouter);

// S6 — demo data purge + S7 data classification summary.
router.use('/demo', demoRouter);

// S8 — multi-tenancy list / get-by-id (read-only in v1; ADNOC seed only).
router.use('/tenants', tenantsRouter);

// S15 + S16 — Roles & Permissions Editor (write surface). Existing
// /api/v1/roles handles read paths; this admin-mounted router covers the
// write path introduced by CR-C.
router.use('/roles', rolesMgmtRouter);

// S12 + S13 — bilingual notification template CRUD + render.
router.use('/notification-templates', notificationTemplatesRouter);

// S14 — email server config (composed read + multi-key patch + test-send).
router.use('/email-config', emailConfigRouter);

// S11 — branding asset upload + color / footer edit.
router.use('/branding', brandingRouter);

// ============================================================
// M11 (CR-D0) — Admin Ingestion Queue monitor + resolve.
// ============================================================
import ingestionQueueRouter from './ingestion-queue.routes';
router.use('/ingestion-queue', ingestionQueueRouter);

// ============================================================
// M12 (CR-D) — Clause Taxonomy catalogue (read-only reference data).
// CR-D-005: GET /admin/clause-taxonomy
// ============================================================
import clauseTaxonomyRouter from './clause-taxonomy.routes';
router.use('/clause-taxonomy', clauseTaxonomyRouter);

// ============================================================
// M13 (CR-E) — Correlation Rule CRUD + DSL test harness.
// CR-E-001..004, CR-E-007, CR-E-008: /admin/rules
// ============================================================
import { adminRulesRouter } from '../correlation-rule.routes';
router.use('/rules', adminRulesRouter);

// ============================================================
// M14 (CR-F) — Admin Scoring Weights + Bulk Recompute.
// CR-F-004: GET  /admin/scoring-weights          (score.weights.manage)
// CR-F-005: PATCH /admin/scoring-weights         (score.weights.manage)
// CR-F-006: POST /admin/scoring-weights/recompute-all (score.weights.manage)
// ============================================================
import scoringWeightsRouter from './scoring-weights.routes';
router.use('/scoring-weights', scoringWeightsRouter);

// ============================================================
// Mig 529 — Risk Scoring Formula Config (additive v2 model).
// GET /admin/risk-scoring-config   — score.read OR score.weights.manage OR score.config.manage
// PUT /admin/risk-scoring-config   — score.config.manage
// ============================================================
import riskScoringConfigRouter from './risk-scoring-config.routes';
router.use('/risk-scoring-config', riskScoringConfigRouter);

// ============================================================
// Mig 538 — Dev Login Personas visibility (PUT only; GET is public)
// ============================================================
import devLoginPersonasRouter from './dev-login-personas.routes';
router.use('/dev-login-personas', devLoginPersonasRouter);

// ============================================================
// Mig 539 — Sidebar Role Order (per-role module reordering)
// ============================================================
import sidebarOrderRouter from './sidebar-order.routes';
router.use('/sidebar-order', sidebarOrderRouter);

// ============================================================
// Phase B.2 (mig 549/550) — Risk routing matrix admin
// ============================================================
import riskRoutingRouter from './risk-routing.routes';
router.use('/risk-routing', riskRoutingRouter);

// ============================================================
// M16 (CR-H) — Advisory Drafter + Notification Delivery.
// GET/POST/PATCH/DELETE /admin/advisory-templates   (advisory.template.manage)
// GET /admin/notification-dispatch-log              (notification.dispatch_log.read)
// GET /admin/notification-dispatch-log/:id          (notification.dispatch_log.read)
// ============================================================
import advisoryTemplatesRouter from './advisory-templates.routes';
import notificationDispatchLogRouter from './notification-dispatch-log.routes';
router.use('/advisory-templates', advisoryTemplatesRouter);
router.use('/notification-dispatch-log', notificationDispatchLogRouter);

// ============================================================
// M17+M18 (CR-I + CR-J) — Demo Harness (scenarios, reset, time-freeze,
// health-check). Mounted AFTER CR-C demo router to cohabit at '/demo';
// paths are disjoint (/purge, /data-classification-summary vs /scenarios,
// /reset, /time-freeze, /time-unfreeze, /health-check).
// CR-V: gate demo harness routes on demo_harness module being enabled.
// ============================================================
import demoHarnessRouter from './demo-harness.routes';
router.use('/demo', authenticate, rlsMiddleware, requireModuleEnabled('demo_harness'));
router.use('/demo', demoHarnessRouter);

// ============================================================
// CR-V — Product Module Toggle admin surface.
//   GET    /admin/modules                         (settings.read)
//   PATCH  /admin/modules/:key                   (settings.write)
//   PATCH  /admin/bundles/:code                  (settings.write)
//   GET    /admin/role-modules                   (settings.read)
//   PATCH  /admin/role-modules/:roleId/:moduleKey (settings.write)
// ============================================================
import modulesRouter from './modules.routes';
router.use('/', modulesRouter);

// ============================================================
// M20 (CR-L) — Admin Reports surface.
//   GET    /admin/reports/runs/pending              (internal worker)
//   POST   /admin/reports/runs/:id/complete         (internal worker)
//   GET/POST /admin/reports/data/:slug              (internal worker — 24 data fns)
//   GET    /admin/reports/templates                 (report.template.manage)
//   GET    /admin/reports/templates/:id             (report.template.manage)
//   POST   /admin/reports/templates                 (report.template.manage)
//   PUT    /admin/reports/templates/:id             (report.template.manage)
//   DELETE /admin/reports/templates/:id             (report.template.manage)
// ============================================================
import adminReportsRouter from './reports.routes';
router.use('/reports', adminReportsRouter);

// ============================================================
// M22 (CR-MIG-DRIVE) — Dedicated migration purge (DANGER ZONE).
//   POST /admin/migration/purge-all/preview    migration.purge.all
//   POST /admin/migration/purge-all            migration.purge.all
// ============================================================
import migrationPurgeRouter from './migration-purge.routes';
router.use('/migration/purge-all', migrationPurgeRouter);

// ============================================================
// R-IL (mig 566-572) — Index-Linked Contracts repositioning.
// Platform Admin catalog management for industries, pricing benchmarks,
// and cost components. Gated by platform.catalog.manage.
// ============================================================
import industryCatalogsRouter from './industry-catalogs.routes';
router.use('/industry-catalogs', industryCatalogsRouter);

// ============================================================
// Internal Systems registry — Platform Admin inventory of ERP / Finance /
// HRMS / CRM / etc. integrations. Gated by platform.integrations.manage.
// ============================================================
import internalSystemsRouter from './internal-systems.routes';
router.use('/internal-systems', internalSystemsRouter);

// ============================================================
// Notification trigger rules — Platform Admin registry of which event fires
// which template via which channel. Gated by platform.notifications.manage.
// ============================================================
import notificationRulesRouter from './notification-rules.routes';
router.use('/notification-rules', notificationRulesRouter);

export default router;
