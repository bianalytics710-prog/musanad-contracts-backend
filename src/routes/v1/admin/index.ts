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

export default router;
