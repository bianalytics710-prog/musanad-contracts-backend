/**
 * /api/v1/admin/* — admin oversight + configuration endpoints.
 * All routes require JWT (each sub-router applies `authenticate`) and
 * permission-gate per endpoint. First introduced by M2 (Q3-OI-E).
 */
import { Router } from 'express';
import approvalMatrixRouter from './approval-matrix.routes';
import approvalChainsRouter from './approval-chains.routes';
import approvalStepsRouter from './approval-steps.routes';

const router = Router();

router.use('/approval-matrix', approvalMatrixRouter);
router.use('/approval-chains', approvalChainsRouter);
router.use('/approval-steps', approvalStepsRouter);

export default router;
