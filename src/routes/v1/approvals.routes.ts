/**
 * /api/v1/approvals routes — M2 (S1, S2, S3).
 *
 * Route ordering (W1 — literal-path FIRST, :stepId-prefixed routes after):
 *   1. GET    /my-pending          — S1 (literal)
 *   2. POST   /:stepId/decide      — S2
 *   3. POST   /:stepId/delegate    — S3
 */
import { Router } from 'express';
import { approvalController } from '../../controllers/approval.controller';
import { authenticate, authorise } from '../../middleware/auth.middleware';
import { validate } from '../../middleware/validation.middleware';
import {
  authedReadRateLimiter,
  authedWriteRateLimiter,
} from '../../middleware/rate-limit.middleware';
import {
  ApprovalStepIdParamSchema,
  DecideApprovalSchema,
  DelegateApprovalSchema,
  MyPendingApprovalListQuerySchema,
} from '../../schemas/approval.schemas';

const router = Router();

router.use(authenticate);

// GET /api/v1/approvals/my-pending — S1
//   No specific permission gate; each user sees their own pending steps via
//   the 4-OR-arm narrowing inside fn_approval_my_pending. RLS narrows
//   contract visibility silently.
router.get(
  '/my-pending',
  authedReadRateLimiter,
  validate(MyPendingApprovalListQuerySchema, 'query'),
  approvalController.listMyPending,
);

// POST /api/v1/approvals/:stepId/decide — S2
router.post(
  '/:stepId/decide',
  authedWriteRateLimiter,
  authorise(['approval.act']),
  validate(ApprovalStepIdParamSchema, 'params'),
  validate(DecideApprovalSchema, 'body'),
  approvalController.decide,
);

// POST /api/v1/approvals/:stepId/delegate — S3
//   Requires both approval.act (action grant) AND approval.delegate (specific
//   capability gate). Self-delegation is rejected by the controller (defense-
//   in-depth) and again by fn_approval_delegate (AC-S3-04).
router.post(
  '/:stepId/delegate',
  authedWriteRateLimiter,
  authorise(['approval.act', 'approval.delegate']),
  validate(ApprovalStepIdParamSchema, 'params'),
  validate(DelegateApprovalSchema, 'body'),
  approvalController.delegate,
);

export default router;
