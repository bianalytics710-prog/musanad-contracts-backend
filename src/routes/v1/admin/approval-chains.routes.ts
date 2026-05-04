/**
 * /api/v1/admin/approval-chains routes — M2 admin chain monitor (S11).
 *
 *   GET / → fn_approval_chain_list
 *
 * Permission gate: anyOf(approval.matrix.read, approval.reassign) — RLS
 * + fn_ logic narrows contract visibility for non-privileged callers.
 */
import { Router } from 'express';
import { approvalChainsController } from '../../../controllers/admin/approval-chains.controller';
import { authenticate, authoriseAnyOf } from '../../../middleware/auth.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { authedReadRateLimiter } from '../../../middleware/rate-limit.middleware';
import { ApprovalChainListQuerySchema } from '../../../schemas/approval.schemas';

const router = Router();

const ADMIN_OVERSIGHT = ['approval.matrix.read', 'approval.reassign'] as const;

router.use(authenticate);

// GET /api/v1/admin/approval-chains — S11
router.get(
  '/',
  authedReadRateLimiter,
  authoriseAnyOf(ADMIN_OVERSIGHT),
  validate(ApprovalChainListQuerySchema, 'query'),
  approvalChainsController.list,
);

export default router;
