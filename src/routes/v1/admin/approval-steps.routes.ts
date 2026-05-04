/**
 * /api/v1/admin/approval-steps routes — M2 admin step reassign (S8).
 *
 *   POST /:stepId/reassign → fn_approval_reassign (approval.reassign)
 */
import { Router } from 'express';
import { approvalChainsController } from '../../../controllers/admin/approval-chains.controller';
import { authenticate, authorise } from '../../../middleware/auth.middleware';
import { validate } from '../../../middleware/validation.middleware';
import { authedWriteRateLimiter } from '../../../middleware/rate-limit.middleware';
import {
  ApprovalStepIdParamSchema,
  ReassignApprovalSchema,
} from '../../../schemas/approval.schemas';

const router = Router();

router.use(authenticate);

// POST /api/v1/admin/approval-steps/:stepId/reassign — S8
router.post(
  '/:stepId/reassign',
  authedWriteRateLimiter,
  authorise(['approval.reassign']),
  validate(ApprovalStepIdParamSchema, 'params'),
  validate(ReassignApprovalSchema, 'body'),
  approvalChainsController.reassign,
);

export default router;
