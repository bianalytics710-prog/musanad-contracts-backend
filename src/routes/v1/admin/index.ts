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

export default router;
