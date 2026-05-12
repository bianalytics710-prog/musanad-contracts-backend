/**
 * /api/v1/admin/* — admin oversight + configuration endpoints.
 * All routes require JWT (each sub-router applies `authenticate`) and
 * permission-gate per endpoint. First introduced by M2 (Q3-OI-E).
 */
import { Router } from 'express';
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

export default router;
